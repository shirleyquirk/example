"""The op-list model: the single source of truth for every variant.

The whole generator rests on four small pure functions, each of which you
should be able to check in your head. Read them in this order:

    interleave()  decides the order of loads and stores in one block
    allocate()    decides which registers hold which bytes
    build()       assembles the blocks into a body
    simulate()    replays a body against a model memory and checks D1-D3

Everything else renders or lints what these produce.

The central idea
----------------
A block moves T bytes. The load side issues T/Wl instructions, the store side
T/Ws. A *schedule* is any interleaving of those two sequences in which a store
only issues once every load covering its bytes has issued. There is exactly one
knob: LOOKAHEAD, the number of bytes that may be loaded but not yet stored.

    lookahead = max(Wl, Ws)  ->  lockstep: load, store, load, store
    lookahead = T            ->  all loads, then all stores (the old "batch")
    lookahead in between     ->  everything else

Register need is the peak of that same quantity, so the knob that sets the
overlap is the knob that sets the register pressure. That is the whole model.

What happened to "pipe"
-----------------------
Classic software pipelining overlaps across the loop back-edge, which needs a
prologue to prime and an epilogue to drain, and the prologue is exactly where
an unguarded batch of device loads reads past the end of the buffer. The same
overlap is available with neither by making the block bigger -- a block of 2T
with lookahead T has one batch in flight at all times within the block. The
only thing lost is the overlap across the back-edge itself: one bubble per T
bytes. In exchange every segment is a single straight-line block guarded by one
`nbytes >= T` test, with no state live across an iteration. That trade is worth
it, and it is why there is no prologue or epilogue anywhere in this generator.
"""

from collections import namedtuple
import isa

# side: 'dev' or 'ram'. kind: 'L' (load) or 'S' (store).
# off:  byte offset within the block, on that side.
# regs: physical register numbers, in operand order.
Op = namedtuple("Op", "side kind off size regs instr")

# A straight-line run of ops that moves `nbytes` bytes, emitted under the
# guard `remaining >= nbytes`.
Block = namedtuple("Block", "nbytes ops need")


def gcd(a, b):
    while b:
        a, b = b, a % b
    return a


def lcm(a, b):
    return a * b // gcd(a, b)


def interleave(nbytes, wl, ws, lookahead):
    """Order the loads and stores of one block.

    Issue a load whenever one more load would still leave no more than
    `lookahead` bytes in flight; otherwise issue the next store. A store's
    bytes are always covered by then, because loads run ahead of stores by
    construction and `lookahead >= ws`.

    Returns [('L', off, wl) | ('S', off, ws)] in issue order.
    """
    assert nbytes % wl == 0 and nbytes % ws == 0
    assert lookahead >= max(wl, ws), "a store could never become issuable"
    ops, loaded, stored = [], 0, 0
    while stored < nbytes:
        if loaded < nbytes and (loaded - stored) + wl <= lookahead:
            ops.append(("L", loaded, wl))
            loaded += wl
        else:
            assert loaded >= stored + ws, "store issued before its data"
            ops.append(("S", stored, ws))
            stored += ws
    return ops


def peak_inflight(ops):
    """Most bytes loaded-but-not-stored at any point. Sets register need."""
    live = peak = 0
    for kind, _off, size in ops:
        live += size if kind == "L" else -size
        peak = max(peak, live)
    return peak


class RegPool:
    """Hands out runs of consecutive registers and takes them back.

    Registers are allocated a *group* at a time, where a group is
    G = lcm(Wl, Ws) bytes -- the smallest unit both sides tile evenly. Every
    load and every store therefore covers a whole number of groups or sits
    inside one, and because a group's registers are consecutive, any
    instruction's operands are consecutive too. That is what satisfies LD1/ST1
    without a special case, and it is why allocation needs no interference
    graph: groups are born and die in order.

    Slightly conservative -- a perfect allocator would sometimes fit one more
    group -- and deliberately so. A register allocator you cannot check by
    reading it is not worth the variants it buys.
    """

    def __init__(self, tier, cls, per_group):
        self.free = list(isa.TIERS[tier][cls])
        self.per_group = per_group
        self.high = 0

    def take(self):
        """Lowest run of `per_group` consecutive free registers, or None."""
        n = self.per_group
        for i in range(len(self.free) - n + 1):
            run = self.free[i:i + n]
            if run[-1] - run[0] == n - 1:
                del self.free[i:i + n]
                self.high = max(self.high, len(run))
                return run
        return None

    def give(self, run):
        self.free.extend(run)
        self.free.sort()


def allocate(ops, dev_is_load, dev_i, ram_i, group, cls, pool):
    """Turn ('L'/'S', off, size) into Ops with real register numbers.

    A group is allocated when its first load issues and released when its last
    store retires. Since both sides walk offsets upward, that is simply: take
    on first touch by a load, give back on last touch by a store.
    """
    rb = isa.REG_BYTES[cls]
    held = {}          # group index -> [register numbers]
    out = []
    for kind, off, size in ops:
        g0, g1 = off // group, (off + size - 1) // group
        if kind == "L":
            for g in range(g0, g1 + 1):
                if g not in held:
                    run = pool.take()
                    if run is None:
                        return None
                    held[g] = run
        regs = []
        for g in range(g0, g1 + 1):
            run = held[g]
            lo = max(off, g * group) - g * group
            hi = min(off + size, (g + 1) * group) - g * group
            regs += run[lo // rb:hi // rb]
        instr = (dev_i if (kind == "L") == dev_is_load else ram_i)
        side = "dev" if (kind == "L") == dev_is_load else "ram"
        out.append(Op(side, kind, off, size, tuple(regs), instr))
        if kind == "S":
            for g in range(g0, g1 + 1):
                if (g + 1) * group <= off + size:
                    pool.give(held.pop(g))
    assert not held, "a group was loaded and never stored"
    return out


def build(dev_i, ram_i, direction, block, lookahead, tier):
    """The whole body: one big block, then one group-sized block.

        while (n >= T) { block_T }     overlap happens here
        while (n >= G) { block_G }     remainder, lockstep
        return                         n < G is the C tail's problem

    Two loops, each guarded by its own comparison, nothing live between
    iterations, nothing live between the loops. That is the entire control
    flow of every generated body.
    """
    dev_is_load = (direction == "rd")
    wl = dev_i.width if dev_is_load else ram_i.width
    ws = ram_i.width if dev_is_load else dev_i.width
    cls = dev_i.regclass
    group = lcm(wl, ws)
    if block % group or block < group:
        return None
    # When the block is already one group there is nothing for a remainder
    # loop to do, so emit one loop rather than two identical ones.
    shape = [(block, lookahead)] if block == group else [(block, lookahead),
                                                         (group, group)]
    blocks = []
    for nb, la in shape:
        seq = interleave(nb, wl, ws, min(la, nb))
        pool = RegPool(tier, cls, group // isa.REG_BYTES[cls])
        ops = allocate(seq, dev_is_load, dev_i, ram_i, group, cls, pool)
        if ops is None:
            return None
        need = peak_inflight(seq) // isa.REG_BYTES[cls]
        blocks.append(Block(nb, ops, need))
    return blocks


def simulate(blocks, nbytes, dev_base_align):
    """Replay a body over model memory.

    Returns (device accesses, destination image, bytes left for the C tail).
    The destination image maps each destination byte to the source byte that
    reached it, carried through the registers -- so a wrong register, a wrong
    offset and a missing store all show up as a wrong image, not just as a
    count that happens to match.

    Checks D1 (natural alignment) and D3 (exactly once) as it goes; D2 is the
    caller's to check against nbytes. Device addresses are relative to a
    Wdev-aligned base, so alignment is judged the way the hardware would.
    """
    dev_seen = {}
    dst_image = {}
    regs = {}
    dev_p = ram_p = 0
    remaining = nbytes
    for b in blocks:
        while remaining >= b.nbytes:
            for op in b.ops:
                base = dev_p if op.side == "dev" else ram_p
                addr = base + op.off
                if op.side == "dev":
                    if (dev_base_align + addr) % op.size:
                        raise AssertionError(
                            "D1: %d-byte device access at +%d" % (op.size, addr))
                    for k in range(op.size):
                        if addr + k in dev_seen:
                            raise AssertionError("D3: device byte +%d twice"
                                                 % (addr + k))
                        dev_seen[addr + k] = op.kind
                rb = isa.REG_BYTES[op.instr.regclass]
                if op.kind == "L":
                    for k in range(op.size):
                        regs[op.regs[k // rb], k % rb] = addr + k
                else:
                    for k in range(op.size):
                        src = regs.get((op.regs[k // rb], k % rb))
                        if src is None:
                            raise AssertionError("store of an unloaded register")
                        dst_image[addr + k] = src
            dev_p += b.nbytes
            ram_p += b.nbytes
            remaining -= b.nbytes
    return dev_seen, dst_image, remaining
