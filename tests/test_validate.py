"""Break things deliberately and insist the validator notices.

A gate nobody has watched fail is decoration. Each case here is a defect the
generator could plausibly have, expressed as a mutation of a known-good
variant, paired with the gate that is supposed to catch it.
"""

import copy
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "gen"))

import emit          # noqa: E402
import model         # noqa: E402
import validate      # noqa: E402
import variants      # noqa: E402

FAILURES = []


def expect_bad(what, fn):
    try:
        fn()
    except validate.Bad as e:
        print("  caught  %-34s %s" % (what, str(e)[:70]))
        return
    except AssertionError as e:
        print("  caught  %-34s assertion: %s" % (what, str(e)[:60]))
        return
    FAILURES.append(what)
    print("  MISSED  %s" % what)


def mutate(v, blk, idx, **kw):
    w = copy.deepcopy(v)
    ops = list(w["blocks"][blk].ops)
    ops[idx] = ops[idx]._replace(**kw)
    w["blocks"][blk] = w["blocks"][blk]._replace(ops=ops)
    return w


def splice(v, blk, ops):
    w = copy.deepcopy(v)
    w["blocks"][blk] = w["blocks"][blk]._replace(ops=ops)
    return w


def main():
    vs, _, _ = variants.enumerate_variants()
    by = {x["name"]: x for x in vs}
    v = by["rd_qp32_q16_t128_la64"]          # mixed widths, some overlap
    l4 = next(x for x in vs if x["dev"].id == "l4d64" and x["dir"] == "rd")

    print("model gate (D1-D3 and a correct copy):")
    expect_bad("misaligned device access",
               lambda: validate.check_model(mutate(v, 0, 0, off=v["blocks"][0].ops[0].off + 1)))
    expect_bad("device byte touched twice",
               lambda: validate.check_model(
                   splice(v, 0, list(v["blocks"][0].ops) + [v["blocks"][0].ops[0]])))
    expect_bad("device read past the block",
               lambda: validate.check_model(
                   splice(v, 0, list(v["blocks"][0].ops)
                          + [v["blocks"][0].ops[0]._replace(off=v["blocks"][0].nbytes)])))
    expect_bad("a store dropped",
               lambda: validate.check_model(
                   splice(v, 0, [o for o in v["blocks"][0].ops if o.side != "ram"]
                          or list(v["blocks"][0].ops)[:1])))
    expect_bad("store reads the wrong register",
               lambda: validate.check_model(
                   mutate(v, 0, 2, regs=(v["blocks"][0].ops[3].regs[0],))))

    print("register gate:")
    # v8-v15 are callee-saved; 19/20 would have been legal V registers, which
    # is the sort of thing that makes a negative test pass for the wrong reason.
    expect_bad("callee-saved reg in caller tier",
               lambda: validate.check_registers(mutate(v, 0, 0, regs=(8, 9))))
    expect_bad("LD1 operands not consecutive",
               lambda: validate.check_registers(mutate(l4, 0, 0, regs=(0, 1, 2, 5))))
    expect_bad("store before the load",
               lambda: validate.check_registers(
                   splice(v, 0, list(v["blocks"][0].ops)[::-1])))

    print("text lint gate:")
    text = emit.render_body(v)
    expect_bad("PRFM on the device side",
               lambda: validate.check_asm_text(
                   v, text.replace("    ret", "    prfm pldl1keep, [x1]\n    ret")))
    expect_bad("barrier inside a body",
               lambda: validate.check_asm_text(
                   v, text.replace("    ret", "    dsb sy\n    ret")))
    expect_bad("platform register x18 used",
               lambda: validate.check_asm_text(
                   v, text.replace("    ret", "    mov x18, x0\n    ret")))
    expect_bad("two globals in one body",
               lambda: validate.check_asm_text(v, text + "\n    .global sneaky\n"))

    print("assemble-and-re-parse gate:")
    with tempfile.TemporaryDirectory() as d:
        good = emit.render_asm([v])
        expect_bad("rendered code disagrees with the model",
                   lambda: validate.check_roundtrip(
                       [v], good.replace("q0, q1, [x1], #32", "q0, q5, [x1], #32", 1), d))
        expect_bad("a body that does not assemble",
                   lambda: validate.check_roundtrip(
                       [v], good.replace("ldp  q0, q1,", "ldp  q0, q1, q2,", 1), d))
        validate.check_roundtrip([v], good, d)
        print("  (the unmutated variant still passes)")

    if FAILURES:
        print("\n%d defect(s) NOT caught: %s" % (len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("\nall %d injected defects were caught" % 13)
    return 0


if __name__ == "__main__":
    sys.exit(main())
