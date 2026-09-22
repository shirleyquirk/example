"""Instruction tables. Adding an instruction is a one-row edit here.

Addressing: every generated access uses post-index addressing
(`ldr x3, [x1], #8`). That is a deliberate choice, not an accident:

  - LD1/ST1 multi-register forms have *no* immediate-offset addressing mode,
    only post-index. Using post-index everywhere means one rule for all
    instructions instead of two.
  - The pointer bump is free, folded into the access.
  - There are no immediate-offset range limits to check, because there are
    no immediate offsets.
  - Accesses on each side issue in strictly increasing address order, so
    "the k'th access on this side is at base + k*W" is true by construction.
    That is what makes D1 (natural alignment) provable by inspection rather
    than by simulation.
"""

from collections import namedtuple

# width      bytes moved per instruction
# regclass   'x' or 'v'; data flows load -> store through registers, so both
#            sides of a variant must agree on the class
# nregs      registers the instruction reads/writes
# contig     True if those registers must be numerically consecutive (LD1/ST1)
# dev_ok     may appear on the Device-nGnRnE side (SPEC D4)
# regpfx     how this instruction spells a register: x3, q3 or v3
Instr = namedtuple("Instr",
                   "id width regclass nregs contig dev_ok regpfx load store note")

DEV = [
    Instr("x8",    8,  "x", 1, False, True, "x",
          "ldr  {r0}, [{b}], #{w}",       "str  {r0}, [{b}], #{w}", ""),
    Instr("xp16",  16, "x", 2, False, True, "x",
          "ldp  {r0}, {r1}, [{b}], #{w}", "stp  {r0}, {r1}, [{b}], #{w}", ""),
    Instr("q16",   16, "v", 1, False, True, "q",
          "ldr  {r0}, [{b}], #{w}",       "str  {r0}, [{b}], #{w}", ""),
    Instr("qp32",  32, "v", 2, False, True, "q",
          "ldp  {r0}, {r1}, [{b}], #{w}", "stp  {r0}, {r1}, [{b}], #{w}", ""),
    Instr("l4b64", 64, "v", 4, True, True, "v",
          "ld1  {{{r0}.16b, {r1}.16b, {r2}.16b, {r3}.16b}}, [{b}], #{w}",
          "st1  {{{r0}.16b, {r1}.16b, {r2}.16b, {r3}.16b}}, [{b}], #{w}",
          "byte element size: may split into byte-sized bus transactions"),
    Instr("l4d64", 64, "v", 4, True, True, "v",
          "ld1  {{{r0}.2d, {r1}.2d, {r2}.2d, {r3}.2d}}, [{b}], #{w}",
          "st1  {{{r0}.2d, {r1}.2d, {r2}.2d, {r3}.2d}}, [{b}], #{w}",
          "doubleword element size: expected to split into 8-byte transactions"),
]

# The RAM side is ordinary Normal memory, so it may eventually use forms the
# device side must never see (LDNP/STNP, PRFM). Those are phase G; for now the
# table is the same set, which keeps the two tables' independence honest
# without inventing variants nobody asked for.
RAM = list(DEV)

BY_ID = {i.id: i for i in DEV}

# Bytes held by one register of each class.
REG_BYTES = {"x": 8, "v": 16}

# Register tiers (SPEC 4.2). x0/x1/x2 carry the arguments; x18 is the platform
# register and is never touched.
TIERS = {
    "caller": {"x": list(range(3, 18)),
               "v": list(range(0, 8)) + list(range(16, 32))},
    "saved":  {"x": list(range(3, 18)) + list(range(19, 29)),
               "v": list(range(0, 32))},
}


def reg_name(instr, n):
    """How this instruction spells register number n."""
    return "%s%d" % (instr.regpfx, n)
