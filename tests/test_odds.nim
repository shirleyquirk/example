## Run with:  nim c -r --hints:off tests/test_odds.nim
## Expected values are worked out by hand, or (marked MC) checked against a
## 2-million-deal Monte Carlo simulation.
import std/unittest
import ../src/[model, odds]

proc near(a, b: float, tol = 1e-3): bool = abs(a - b) < tol

let deck = NotebookDeck

suite "deck":
  test "notebook column totals":
    const expected: array[Symbol, int] = [8, 13, 11, 5, 4, 11, 11, 10, 13, 9, 13, 12]
    for symbol in Symbol:
      check card(deck[symbol]) == expected[symbol]
  test "one blank card, the last":
    check deck.blank == {CardIndex(DeckSize - 1)}
  test "set queries":
    check card(deck.withAny({Void, Caves})) == 21
    check card(deck.withAll({Void, Caves})) == 0
    check deck.symbolsOn(4) == {Void, Deadly, Vegetation, Water}   # notebook row 1·5 "AFGH"
  test "text round trip":
    var copy: Deck
    check parseRows(deck.toRows, copy)
    check copy == deck
    check not parseRows(["A", "B"], copy)

suite "odds":
  test "nothing played, blank safe: danger = 31/40":
    let o = analyse(deck.safe({Void}, blankIsSafe), Observation())
    check near(o.chanceAtLeastOne(1, Danger), 31 / 40)
    check near(o.chanceAtLeastOne(1, Safe), 9 / 40)
  test "blank as danger: danger = 32/40":
    let o = analyse(deck.safe({Void}, blankIsDanger), Observation())
    check near(o.chanceAtLeastOne(1, Danger), 32 / 40)
  test "safe count known: (9-2)/35 safe":
    let safe = deck.safe({Void}, blankIsSafe)
    let o = analyse(safe, Observation(played: 5, counts: @[Count(cards: safe, played: 2)]))
    check near(o.chanceAtLeastOne(1, Safe), 7 / 35)
  test "safe count known, 3 drawn: 1 - C(12,3)/C(30,3)":
    let safe = deck.safe({Void, Caves}, blankIsDanger)
    let o = analyse(safe, Observation(played: 10, counts: @[Count(cards: safe, played: 3)]))
    check near(o.chanceAtLeastOne(3, Safe), 1 - 220 / 4060)
  test "per-symbol count only (MC 0.9145)":
    let safe = deck.safe({Void, Caves}, blankIsDanger)
    let o = analyse(safe, Observation(played: 10, counts: @[Count(cards: deck[Void], played: 1)]))
    check near(o.chanceAtLeastOne(3, Safe), 0.9145, 0.003)
  test "blank safe with both counts (MC 0.6491)":
    let safe = deck.safe({Void, Caves}, blankIsSafe)
    let o = analyse(safe, Observation(played: 10, counts: @[
      Count(cards: safe, played: 4), Count(cards: deck[Void], played: 1)]))
    check near(o.chanceAtLeastOne(2, Danger), 0.6491, 0.003)
  test "impossible observation":
    let safe = deck.safe({Void}, blankIsSafe)
    check not analyse(safe, Observation(played: 5, counts: @[Count(cards: safe, played: 6)])).possible
  test "binomial":
    check binomial(40, 20) == 137846528820.0
    check binomial(3, 5) == 0.0
