## The probability calculation, free of any UI code so it can be unit tested.
##
## Terms
## -----
## * The player selects some symbols. A card is **safe** if it shows at least
##   one selected symbol; otherwise it is **danger**. The blank card has no
##   symbols, so whether it is safe is a rule the player picks (`BlankRule`).
## * Some cards have already been played. We know how many, and maybe some
##   counts about them (an `Observation`), but not exactly which cards.
##
## The question: what is the chance that the next `draw` cards include at
## least one safe (or at least one danger) card?

import std/[tables, hashes, options]
import model

type
  BlankRule* = enum
    blankIsSafe    ## the blank card matches every symbol
    blankIsDanger  ## the blank card matches nothing

  Outcome* = enum
    Danger, Safe

  Observation* = object
    ## What is known about the cards already played.
    played*: Natural
      ## How many cards have been played.
    safePlayed*: Option[Natural]
      ## How many of them were safe, if known (the blank card counts here
      ## when `blankIsSafe`).
    symbolPlayed*: array[Symbol, Option[Natural]]
      ## How many of them showed each symbol, if known.

  Odds* = object
    ## The result of `analyse`: everything needed to answer "what about the
    ## next N cards?" for any N.
    possible*: bool
      ## False if no set of played cards fits the observation.
    safeInDeck*: int
      ## Safe cards in the whole deck, played or not.
    remaining*: int
      ## Cards not yet played.
    safePlayedChance*: seq[float]
      ## safePlayedChance[k] = probability that exactly k of the played
      ## cards were safe, given the observation.

proc isSafe*(card: Card, selected: set[Symbol], rule: BlankRule): bool =
  if card == {}: rule == blankIsSafe
  else: card * selected != {}

proc safeCards*(deck: Deck, selected: set[Symbol], rule: BlankRule): int =
  for card in deck:
    if isSafe(card, selected, rule): inc result

proc binomial*(n, k: int): float =
  ## n choose k: the number of ways to pick k cards out of n.
  ## Zero when that is impossible (k < 0 or k > n).
  ##
  ## Returned as a float because the counts get large (40 choose 20 is about
  ## 1.4e11, and `analyse` multiplies several of these together), and we only
  ## ever use them in ratios, so floating point is exact enough.
  if k < 0 or k > n: return 0.0
  let k = min(k, n - k)   # same value, fewer multiplications
  result = 1.0
  for i in 1 .. k:
    result = result * float(n - k + i) / float(i)

# ----------------------------------------------------------------------------
# Working out what the played cards could have been
#
# Every set of `played` cards is equally likely (the deck was shuffled). We
# want, for each k, how many of those sets contain exactly k safe cards *and*
# agree with the observation. Dividing by the total gives P(k safe played).
#
# Listing every possible set of played cards is far too slow (40 choose 20 is
# about 1.4e11), but most cards are interchangeable for this question: two
# cards differ only if one is safe and the other isn't, or if they differ on a
# symbol whose played count we were told. So we sort cards into these
# `CardKind`s and count by kind. If a kind has n cards and m of them were
# played, there are `binomial(n, m)` ways to pick which ones.
#
# Then we go through the kinds one at a time, keeping a table
#   ways[tally] = number of ways to pick played cards from the kinds seen so
#                 far that give this tally (how many played, how many safe,
#                 how many of each observed symbol).
# Adding a kind means: for each tally and each m, add m cards of that kind.
# Tallies that already exceed an observed count are dropped straight away.
# At the end we keep only tallies that match the observation exactly.
#
# The table is rebuilt on every call because it *is* the calculation: its
# contents depend on the selection, the blank rule and every observed number.
# It holds at most a few thousand entries, so this takes well under a
# millisecond.

type
  CardKind = object
    ## Cards that are interchangeable for this question.
    safe: bool
    observedSymbols: set[Symbol]  ## which observed symbols the card shows

  Tally = object
    ## Running totals for one way of choosing the played cards.
    played: int
    safe: int
    bySymbol: array[Symbol, int]  ## only observed symbols are counted

proc hash(kind: CardKind): Hash =
  var h = hash(kind.safe)
  for symbol in kind.observedSymbols: h = h !& hash(ord(symbol))
  !$h

proc hash(tally: Tally): Hash =
  var h = hash(tally.played) !& hash(tally.safe)
  for count in tally.bySymbol: h = h !& hash(count)
  !$h

proc fitsSoFar(tally: Tally, obs: Observation): bool =
  ## Could more cards still be added to reach the observation?
  if tally.played > obs.played: return false
  if obs.safePlayed.isSome and tally.safe > obs.safePlayed.get: return false
  for symbol in Symbol:
    let seen = obs.symbolPlayed[symbol]
    if seen.isSome and tally.bySymbol[symbol] > seen.get: return false
  true

proc matches(tally: Tally, obs: Observation): bool =
  if tally.played != obs.played: return false
  if obs.safePlayed.isSome and tally.safe != obs.safePlayed.get: return false
  for symbol in Symbol:
    let seen = obs.symbolPlayed[symbol]
    if seen.isSome and tally.bySymbol[symbol] != seen.get: return false
  true

proc analyse*(deck: Deck, selected: set[Symbol], rule: BlankRule,
              obs: Observation): Odds =
  result.safeInDeck = safeCards(deck, selected, rule)
  result.remaining = DeckSize - obs.played
  result.safePlayedChance = newSeq[float](obs.played + 1)
  if obs.played > DeckSize: return

  var observed: set[Symbol]
  for symbol in Symbol:
    if obs.symbolPlayed[symbol].isSome: observed.incl symbol

  var kindSizes = initCountTable[CardKind]()
  for card in deck:
    kindSizes.inc CardKind(safe: isSafe(card, selected, rule),
                           observedSymbols: card * observed)

  var ways = {Tally(): 1.0}.toTable
  for kind, size in kindSizes:
    var next = initTable[Tally, float]()
    for tally, count in ways:
      for taken in 0 .. size:
        var t = tally
        t.played += taken
        if kind.safe: t.safe += taken
        for symbol in kind.observedSymbols: t.bySymbol[symbol] += taken
        if not t.fitsSoFar(obs): break   # taking more only makes it worse
        next[t] = next.getOrDefault(t) + count * binomial(size, taken)
    ways = next

  var total = 0.0
  for tally, count in ways:
    if tally.matches(obs):
      result.safePlayedChance[tally.safe] += count
      total += count
  result.possible = total > 0
  if result.possible:
    for chance in result.safePlayedChance.mitems: chance /= total

proc chanceAtLeastOne*(odds: Odds, draw: int, wanted: Outcome): float =
  ## Probability that at least one of the next `draw` cards is `wanted`.
  ##
  ## If w of the r remaining cards are `wanted`, the chance that a random
  ## `draw` of them contains none is binomial(r - w, draw) / binomial(r, draw)
  ## (pick all of them from the other r - w cards). We average that over how
  ## many safe cards were played, then take the complement.
  let draw = min(draw, odds.remaining)
  var none = 0.0
  for safePlayed, chance in odds.safePlayedChance:
    if chance == 0: continue
    let safeLeft = odds.safeInDeck - safePlayed
    let wantedLeft = if wanted == Safe: safeLeft else: odds.remaining - safeLeft
    none += chance * binomial(odds.remaining - wantedLeft, draw) /
                     binomial(odds.remaining, draw)
  1.0 - none

proc expectedSafeLeft*(odds: Odds): float =
  for safePlayed, chance in odds.safePlayedChance:
    result += chance * float(odds.safeInDeck - safePlayed)
