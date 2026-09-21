"""Every gate the generated code has to pass. Any failure fails the build.

Four gates, deliberately overlapping as little as possible:

  check_model     replays the op list over model memory: D1, D2, D3, and a
                  byte-exact copy. This is the alignment gate, and the only
                  one that can be, since no emulator models Device memory.
  check_registers the tier's registers and nothing else; LD1/ST1 operands
                  consecutive; no register overwritten while it still holds
                  bytes nobody has stored.
  check_asm_text  a lint of the rendered text: forbidden mnemonics on the
                  device side, forbidden registers, one global per body.
  check_roundtrip assembles the text and disassembles it back, and asserts
                  the machine code's accesses are the model's accesses. This
                  is what catches the renderer lying about the model.
"""

import re
import subprocess
import isa
import model

# D4 splits in two. Barriers, cache maintenance, exclusives and atomics have
# no business anywhere in a copy function, whichever side they name. PRFM and
# the non-temporal forms are forbidden only on the device side -- they are
# candidates for the RAM side in phase G, which is why the tables are separate.
FORBIDDEN_ANYWHERE = re.compile(
    r"\b(dmb|dsb|isb|dc|ic|at|tlbi|ldxr\w*|stxr\w*|ldaxr\w*|stlxr\w*|"
    r"ldar\w*|stlr\w*|cas\w*|swp\w*|ldadd\w*|ldset\w*|ldclr\w*|ldeor\w*)\b",
    re.I)
FORBIDDEN_DEV = re.compile(r"\b(prfm|prfum|ldnp|stnp)\b", re.I)

AS = "aarch64-linux-gnu-as"
OBJDUMP = "aarch64-linux-gnu-objdump"


class Bad(Exception):
    pass


def check_model(v):
    """D1-D3 and a correct copy, for every length the wrapper can pass."""
    g, t = v["group"], v["block"]
    for nbytes in range(0, 4 * t + 4 * g + 1, g):
        dev, dst, left = model.simulate(v["blocks"], nbytes, 0)
        if left >= g:
            raise Bad("%d bytes left over, tail only handles < %d" % (left, g))
        copied = nbytes - left
        # D2: no device byte outside what this call copies.
        if dev and (min(dev) < 0 or max(dev) >= copied):
            raise Bad("D2: device access outside [0,%d) at n=%d" % (copied, nbytes))
        # D3 is checked inside simulate(); confirm full coverage as well.
        if len(dev) != copied:
            raise Bad("D3: %d device bytes touched, %d expected at n=%d"
                      % (len(dev), copied, nbytes))
        if len(dst) != copied:
            raise Bad("destination covered %d bytes, %d expected" % (len(dst), copied))
        for i in range(copied):
            if dst.get(i) != i:
                raise Bad("byte %d came from %r at n=%d" % (i, dst.get(i), nbytes))


def check_registers(v):
    allowed = set(isa.TIERS[v["tier"]][v["dev"].regclass])
    for b in v["blocks"]:
        holding = {}                     # register -> bytes it holds, unstored
        for op in b.ops:
            for r in op.regs:
                if r not in allowed:
                    raise Bad("register %d outside the %s tier" % (r, v["tier"]))
            if op.instr.contig:
                rs = list(op.regs)
                if rs != list(range(rs[0], rs[0] + len(rs))):
                    raise Bad("%s needs consecutive registers, got %s"
                              % (op.instr.id, rs))
            if op.kind == "L":
                for r in op.regs:
                    if holding.get(r):
                        raise Bad("register %d overwritten before it was stored" % r)
                    holding[r] = True
            else:
                for r in op.regs:
                    if not holding.get(r):
                        raise Bad("register %d stored before it was loaded" % r)
                    holding[r] = False
        if any(holding.values()):
            raise Bad("block ends with data still in registers")


def check_asm_text(v, text):
    dev_reg = "x1" if v["dir"] == "rd" else "x0"
    for line in text.splitlines():
        code = line.split("//")[0].strip()
        if not code or code.startswith((".", "/")) or re.match(r"^\d+:", code):
            body = re.sub(r"^\d+:\s*", "", code)
        else:
            body = code
        if not body:
            continue
        if FORBIDDEN_ANYWHERE.search(body):
            raise Bad("forbidden instruction in a copy body: %s" % body)
        if FORBIDDEN_DEV.search(body) and ("[%s]" % dev_reg) in body:
            raise Bad("forbidden instruction on the device side: %s" % body)
        if re.search(r"\b(x18|sp)\b", body):
            raise Bad("platform register or sp used: %s" % body)
        if v["tier"] == "caller":
            if re.search(r"\bx(19|2[0-8])\b", body):
                raise Bad("callee-saved X register in the caller tier: %s" % body)
            if re.search(r"\b[qvd](8|9|1[0-5])\b", body):
                raise Bad("callee-saved V register in the caller tier: %s" % body)
    if text.count(".global ") != 1:
        raise Bad("expected exactly one global symbol per body")


_MEM = re.compile(r"^(ld1|st1|ldp|stp|ldr|str)\b")


def _accesses(lines):
    """(mnemonic, register list, base, post-index amount) per memory access."""
    out = []
    for ln in lines:
        ln = re.sub(r"\s+", " ", ln.split("//")[0].strip())
        ln = re.sub(r"^\d+: ", "", ln)
        m = _MEM.match(ln)
        if not m:
            continue
        head = ln.split("[")[0]
        # objdump prints LD1/ST1 operand lists as a range: {v0.16b-v3.16b}.
        head = re.sub(r"\bv(\d+)(\.\w+)-v(\d+)\2",
                      lambda m: ", ".join("v%d%s" % (n, m.group(2))
                                          for n in range(int(m.group(1)),
                                                         int(m.group(3)) + 1)),
                      head)
        regs = re.findall(r"\b[xqv](\d+)(?:\.\w+)?\b", head)
        base = re.search(r"\[(\w+)\]", ln)
        imm = re.search(r"#(\d+)\s*$", ln)
        out.append((m.group(1), tuple(int(r) for r in regs),
                    base.group(1) if base else None,
                    int(imm.group(1)) if imm else None))
    return out


def check_roundtrip(vs, asm_text, workdir):
    """Assemble, disassemble, and compare the machine code to the model."""
    src, obj = workdir + "/variants.S", workdir + "/variants.o"
    open(src, "w").write(asm_text)
    try:
        subprocess.run([AS, "-o", obj, src], check=True, capture_output=True)
        dis = subprocess.run([OBJDUMP, "-d", "--no-show-raw-insn", obj],
                             check=True, capture_output=True, text=True).stdout
    except FileNotFoundError:
        raise Bad("%s not found: install binutils-aarch64-linux-gnu. This gate "
                  "is never skipped." % AS)
    except subprocess.CalledProcessError as e:
        raise Bad("assembling the generated code failed:\n%s"
                  % e.stderr.decode(errors="replace"))

    bodies, cur = {}, None
    for ln in dis.splitlines():
        m = re.match(r"^[0-9a-f]+ <(\S+)>:", ln)
        if m:
            cur = m.group(1)
            bodies[cur] = []
        elif cur and re.match(r"^\s+[0-9a-f]+:", ln):
            bodies[cur].append(ln.split(":", 1)[1].strip())

    for v in vs:
        name = "body_" + v["name"]
        if name not in bodies:
            raise Bad("%s did not survive assembly" % name)
        got = _accesses(bodies[name])
        want = []
        dev_reg = "x1" if v["dir"] == "rd" else "x0"
        ram_reg = "x0" if v["dir"] == "rd" else "x1"
        for b in v["blocks"]:
            for op in b.ops:
                mn = (op.instr.load if op.kind == "L" else op.instr.store).split()[0]
                want.append((mn, tuple(op.regs),
                             dev_reg if op.side == "dev" else ram_reg, op.size))
        if got != want:
            for i, (a, b2) in enumerate(zip(got, want)):
                if a != b2:
                    raise Bad("%s access %d: machine code %r, model %r"
                              % (name, i, a, b2))
            raise Bad("%s: %d accesses in the machine code, %d in the model"
                      % (name, len(got), len(want)))


def validate_all(vs, asm_text, workdir):
    for v in vs:
        try:
            check_model(v)
            check_registers(v)
            check_asm_text(v, __import__("emit").render_body(v))
        except Bad as e:
            raise Bad("%s: %s" % (v["name"], e))
    check_roundtrip(vs, asm_text, workdir)
