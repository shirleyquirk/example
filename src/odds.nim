## The probability calculation. It knows nothing about symbols or blank cards:
## it works on sets of cards, so it can be unit tested on its own.
##
## * `safe` is the set of cards that count as a match. Every other card is
##   danger.
## * Some cards have already been played. We know how many, and maybe how
##   many of them fell in certain sets of cards (`Count`s), e.g. "4 of the
##   played cards were safe" or "1 of them showed Void".
##
## The question: what is the chance that the next `draw` cards include at
## least one safe (or at least one danger) card?

import std/[tables, hashes]
import model

type
  Outcome* = enum
    Danger, Safe

  Count* = object
    ## "Exactly `played` of the played cards were among `cards`."
    cards*: Cards
    played*: Natural

  Observation* = object
    played*: Natural      ## how many cards have been played
    counts*: seq[Count]   ## what is known about them; may be empty

  Odds* = object
    ## The result of `analyse`: enough to answer "what about the next N
    ## cards?" for any N.
    possible*: bool
      ## False if no set of played cards fits the observation.
    safeInDeck*: int
      ## Safe cards in the whole deck, played or not.
    remaining*: int
      ## Cards not yet played.
    safePlayedChance*: seq[float]
      ## safePlayedChance[k] = probability that exactly k of the played cards
      ## were safe, given the observation.

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
# agree with every Count. Dividing by the total gives P(k safe played).
#
# Listing every possible set of played cards is far too slow (40 choose 20 is
# about 1.4e11), but most cards are interchangeable for this question: two
# cards only differ if one is safe and the other isn't, or if one is in some
# Count's set and the other isn't. Cards that agree on all of those form a
# `Kind`. If a kind has n cards and m of them were played, there are
# `binomial(n, m)` ways to pick which ones.
#
# Then we go through the kinds one at a time, keeping a table
#   ways[tally] = number of ways to pick played cards from the kinds seen so
#                 far that give this tally (how many played, how many safe,
#                 how many in each Count's set).
# Adding a kind means: for each tally and each m, add m cards of that kind.
# Tallies that already go over a Count are dropped straight away. At the end
# we keep only tallies that match every Count exactly.
#
# The table is rebuilt on every call because it *is* the calculation: its
# contents depend on the safe set and every observed number. It holds at most
# a few thousand entries, so this takes well under a millisecond.

const MaxCounts = 16

type
  CountIndex = range[0 .. MaxCounts - 1]

  Kind = object
    ## Cards that are interchangeable for this question.
    safe: bool
    inCounts: set[CountIndex]   ## which Counts' sets the cards belong to

  Tally = object
    ## Running totals for one way of choosing the played cards.
    played: int
    safe: int
    perCount: array[CountIndex, int]

proc hash(kind: Kind): Hash =
  var h = hash(kind.safe)
  for index in kind.inCounts: h = h !& hash(index)
  !$h

proc hash(tally: Tally): Hash =
  var h = hash(tally.played) !& hash(tally.safe)
  for n in tally.perCount: h = h !& hash(n)
  !$h

proc kindOf(index: CardIndex, safe: Cards, counts: seq[Count]): Kind =
  result.safe = index in safe
  for countIndex, count in counts:
    if index in count.cards: result.inCounts.incl countIndex

proc fitsSoFar(tally: Tally, obs: Observation): bool =
  ## Could adding more cards still reach the observation?
  if tally.played > obs.played: return false
  for index, count in obs.counts:
    if tally.perCount[index] > count.played: return false
  true

proc matches(tally: Tally, obs: Observation): bool =
  if tally.played != obs.played: return false
  for index, count in obs.counts:
    if tally.perCount[index] != count.played: return false
  true

proc analyse*(safe: Cards, obs: Observation): Odds =
  doAssert obs.counts.len <= MaxCounts
  result.safeInDeck = card(safe)
  result.remaining = DeckSize - obs.played
  if obs.played > DeckSize: return
  result.safePlayedChance = newSeq[float](obs.played + 1)

  var kindSizes = initCountTable[Kind]()
  for index in CardIndex:
    kindSizes.inc kindOf(index, safe, obs.counts)

  var ways = {Tally(): 1.0}.toTable
  for kind, size in kindSizes:
    var next = initTable[Tally, float]()
    for tally, count in ways:
      for taken in 0 .. size:
        var t = tally
        t.played += taken
        if kind.safe: t.safe += taken
        for countIndex in kind.inCounts: t.perCount[countIndex] += taken
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
