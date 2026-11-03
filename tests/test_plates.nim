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
  test "upside-down plate can't seat":
    check PinAngle mod 180.0 != 0.0
