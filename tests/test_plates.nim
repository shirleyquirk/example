## The plates' optics must agree with the app: for any stack, the lit
## positions are exactly the danger cards.
import std/[unittest, math]
import ../src/[model, odds]
import ../hardware/[plates, simgen]

suite "plates":
  test "every combination of symbols, both blank rules (8190 stacks)":
    for mask in 1 ..< (1 shl 12):
      var symbols: set[Symbol]
      var stack: seq[Plate]
      for symbol in Symbol:
        if (mask shr ord(symbol) and 1) == 1:
          symbols.incl symbol
          stack.add plateFor(symbol)
      check litPositions(stack) == AllCards - NotebookDeck.safe(symbols, blankIsDanger)
      stack.add blankSafePlate()
      check litPositions(stack) == AllCards - NotebookDeck.safe(symbols, blankIsSafe)
  test "registration notch has no mirror image":
    # Offset from the side's centre (so mirroring about the mid-side axis moves
    # it) and not reaching a corner (so mirroring about a corner axis moves it
    # to another side).
    check NotchFrom > 0.0 and NotchTo < SideLength / 2
  test "every slot has the same area":
    proc area(c: array[4, Point]): float =
      for i in 0 .. 3:
        let j = (i + 1) mod 4
        result += c[i].x * c[j].y - c[j].x * c[i].y
      abs(result) / 2
    for index in CardIndex:
      check abs(area(slotCorners(index)) - SlotLength * SlotWidth) < 1e-9
  test "slots stay inside the token and clear the icon":
    for index in CardIndex:
      for p in slotCorners(index):
        let r = sqrt(p.x * p.x + p.y * p.y)
        check r > IconSize / sqrt(2.0)                  # outside the icon's square
        check r < Apothem - 1.0                         # at least 1 mm of material
