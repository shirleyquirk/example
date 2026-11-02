## Run with:  nim c -r --hints:off tests/test_odds.nim
## Expected values are worked out by hand, or (marked MC) checked against a
## 2-million-deal Monte Carlo simulation.
import std/[unittest, options]
import ../src/[model, odds]

proc near(a, b: float, tol = 1e-3): bool = abs(a - b) < tol

suite "deck":
  test "notebook column totals":
    const expected: array[Symbol, int] = [8, 13, 11, 5, 4, 11, 11, 10, 13, 9, 13, 12]
    for symbol in Symbol:
      check NotebookDeck.cardsWith(symbol) == expected[symbol]
  test "one blank card":
    check NotebookDeck.blankCards == 1

suite "odds":
  test "nothing played, blank safe: danger = 31/40":
    let o = analyse(NotebookDeck, {Void}, blankIsSafe, Observation())
    check near(o.chanceAtLeastOne(1, Danger), 31 / 40)
    check near(o.chanceAtLeastOne(1, Safe), 9 / 40)
  test "blank as danger: danger = 32/40":
    let o = analyse(NotebookDeck, {Void}, blankIsDanger, Observation())
    check near(o.chanceAtLeastOne(1, Danger), 32 / 40)
  test "safe count known: (9-2)/35 safe":
    let obs = Observation(played: 5, safePlayed: some(Natural 2))
    let o = analyse(NotebookDeck, {Void}, blankIsSafe, obs)
    check near(o.chanceAtLeastOne(1, Safe), 7 / 35)
  test "safe count known, 3 drawn: 1 - C(12,3)/C(30,3)":
    let obs = Observation(played: 10, safePlayed: some(Natural 3))
    let o = analyse(NotebookDeck, {Void, Caves}, blankIsDanger, obs)
    check near(o.chanceAtLeastOne(3, Safe), 1 - 220 / 4060)
  test "per-symbol count only (MC 0.9145)":
    var obs = Observation(played: 10)
    obs.symbolPlayed[Void] = some(Natural 1)
    let o = analyse(NotebookDeck, {Void, Caves}, blankIsDanger, obs)
    check near(o.chanceAtLeastOne(3, Safe), 0.9145, 0.003)
  test "blank safe with both counts (MC 0.6491)":
    var obs = Observation(played: 10, safePlayed: some(Natural 4))
    obs.symbolPlayed[Void] = some(Natural 1)
    let o = analyse(NotebookDeck, {Void, Caves}, blankIsSafe, obs)
    check near(o.chanceAtLeastOne(2, Danger), 0.6491, 0.003)
  test "impossible observation":
    let obs = Observation(played: 5, safePlayed: some(Natural 6))
    check not analyse(NotebookDeck, {Void}, blankIsSafe, obs).possible
  test "binomial":
    check binomial(40, 20) == 137846528820.0
    check binomial(3, 5) == 0.0
