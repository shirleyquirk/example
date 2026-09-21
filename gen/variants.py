"""The parameter space, and which points in it are buildable.

A variant is five things:

    direction        rd (device -> RAM) or wr (RAM -> device)
    device instr     which instruction touches Device-nGnRnE memory
    RAM instr        which instruction touches normal memory
    block bytes T    how much one guarded straight-line block moves
    lookahead bytes  how far the loads may run ahead of the stores

There is no separate "batch size" and no separate "schedule": T sets how much
work is unrolled, lookahead sets how much of it overlaps, and the two of them
between them decide register pressure. The old (B, batch|pipe) pair is the two
extreme values of lookahead at two values of T.

Feasibility is not a formula. The candidate is built, its registers allocated,
and it is kept if allocation succeeded. A new instruction in isa.py therefore
gets a correct answer without anyone deriving one.
"""

import isa
import model

# T is expressed as a multiple of the group size G = lcm(Wdev, Wram), so the
# same list means the same thing for every width pairing.
BLOCK_GROUPS = [1, 2, 3, 4, 6, 8, 12, 16]

DIRECTIONS = ["rd", "wr"]


def lookaheads(block, group):
    """Every distinct overlap depth for this block, coarse to fine.

    Multiples of the group size from one group (lockstep) to the whole block
    (load everything, then store everything). Anything finer than a group is
    not expressible: a group is the unit in which registers are held.
    """
    return [g * group for g in range(1, block // group + 1)]


def enumerate_variants(tier="caller", verbose=False):
    kept, skipped = [], []
    for direction in DIRECTIONS:
        for dev_i in isa.DEV:
            if not dev_i.dev_ok:
                continue
            for ram_i in isa.RAM:
                if ram_i.regclass != dev_i.regclass:
                    # Data flows load -> store through registers. Crossing
                    # register classes would need an FMOV per chunk, which
                    # would be what we were measuring.
                    skipped.append((direction, dev_i.id, ram_i.id, None, None,
                                    "register class mismatch"))
                    continue
                group = model.lcm(dev_i.width, ram_i.width)
                for ng in BLOCK_GROUPS:
                    block = ng * group
                    for la in lookaheads(block, group):
                        name = "%s_%s_%s_t%d_la%d" % (
                            direction, dev_i.id, ram_i.id, block, la)
                        blocks = model.build(dev_i, ram_i, direction, block,
                                             la, tier)
                        if blocks is None:
                            skipped.append((direction, dev_i.id, ram_i.id,
                                            block, la, "out of registers"))
                            continue
                        kept.append(dict(name=name, dir=direction, dev=dev_i,
                                         ram=ram_i, block=block, la=la,
                                         group=group, tier=tier,
                                         blocks=blocks,
                                         need=max(b.need for b in blocks)))
    # Distinct parameters can render the same instruction sequence (lookahead
    # above the point where every load has already issued, for instance).
    # Keep the first, drop the rest: identical code timed twice is noise.
    seen, uniq, dups = {}, [], 0
    for v in kept:
        key = (v["dir"], tuple((b.nbytes, tuple(b.ops)) for b in v["blocks"]))
        if key in seen:
            dups += 1
            continue
        seen[key] = v["name"]
        uniq.append(v)
    return uniq, skipped, dups
