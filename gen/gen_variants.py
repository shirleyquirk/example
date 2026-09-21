"""Generate and validate. Any failure exits non-zero and fails the build."""

import argparse
import os
import sys
import emit
import validate
import variants


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", default="build/gen")
    p.add_argument("--tier", default="caller", choices=["caller", "saved"])
    p.add_argument("--explain", metavar="NAME",
                   help="print a human-readable trace of one variant and exit")
    p.add_argument("--list-skipped", action="store_true")
    a = p.parse_args()

    vs, skipped, dups = variants.enumerate_variants(a.tier)

    if a.explain:
        hit = [v for v in vs if a.explain in v["name"]]
        if not hit:
            sys.exit("no variant matching %r" % a.explain)
        for v in hit[:8]:
            print(emit.explain(v))
            print()
        return

    if a.list_skipped:
        for row in skipped:
            print("skipped %s" % (row,))

    os.makedirs(a.out, exist_ok=True)
    asm = emit.render_asm(vs)
    try:
        validate.validate_all(vs, asm, a.out)
    except validate.Bad as e:
        sys.exit("VALIDATOR FAILED: %s" % e)

    open(os.path.join(a.out, "variants.S"), "w").write(asm)
    open(os.path.join(a.out, "variants_table.c"), "w").write(emit.render_table(vs))
    open(os.path.join(a.out, "bodies_table.c"), "w").write(emit.render_test_table(vs))
    print("%d variants, %d skipped (%d register-class, %d out of registers), "
          "%d duplicate code paths dropped"
          % (len(vs), len(skipped),
             sum(1 for s in skipped if "class" in s[-1]),
             sum(1 for s in skipped if "registers" in s[-1]), dups))
    print("all gates passed: model, registers, lint, assemble-and-re-parse")


if __name__ == "__main__":
    main()
