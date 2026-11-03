## Characterisation runs: simulates the circuit in ngspice, writes CSVs and a
## report to hardware/results/, and plots the CSVs with gnuplot (plots.gp).
##
##   nim r -d:release hardware/results.nim          # everything (nim results)
##   nim r -d:release hardware/results.nim chain    # whole-chain check only (nim sim)

import std/[os, osproc, strformat, strutils, tables, math, sequtils]
import ../src/[model, odds]
import plates, simgen, experiments

const
  ResultsDir = "hardware/results"
  SimDir = "build/sim"

proc runAll(jobs: seq[(string, string)]): seq[string] =
  ## Runs ngspice on each (name, netlist) in parallel; returns each output.
  createDir SimDir
  var commands: seq[string]
  for (name, netlist) in jobs:
    writeFile(SimDir / name & ".cir", netlist)
    commands.add "ngspice -b " & SimDir / name & ".cir -o " & SimDir / name & ".log"
  let failed = execProcesses(commands, n = countProcessors(),
                             options = {poStdErrToStdOut, poUsePath, poEvalCommand})
  if failed != 0: quit "an ngspice run failed; see " & SimDir & "/*.log"
  for (name, _) in jobs: result.add readFile(SimDir / name & ".log")

proc csv(fields: varargs[string, `$`]): string = fields.join(",") & "\n"

proc f(x: float, decimals: int): string = formatFloat(x, ffDecimal, decimals)

# ---------------------------------------------------------------- experiments

proc dividerAccuracy(report: var string) =
  echo "divider accuracy sweep..."
  var cases: seq[(int, int)]                     # (danger left, cards left)
  for cardsLeft in [1, 2, 3, 4, 5, 6, 8, 10, 13, 16, 20, 25, 30, 35, 40]:
    for fraction in [0.0, 0.25, 0.5, 0.75, 1.0]:
      let c = (int(round(fraction * float(cardsLeft))), cardsLeft)
      if c notin cases: cases.add c
  let outputs = runAll(cases.mapIt(("divider_" & $it[0] & "_" & $it[1],
                                    dividerNetlist(it[0], it[1]))))
  var table = csv("cards_left", "danger_left", "expected_pct", "circuit_pct",
                  "error_pct_fs", "ripple_mv")
  var worst = 0.0
  for i, (dangerLeft, cardsLeft) in cases:
    let expected = 100.0 * (dangerLeft / cardsLeft)
    let circuit = 10.0 * measured(outputs[i], "vp")
    worst = max(worst, abs(circuit - expected))
    table.add csv(cardsLeft, dangerLeft, f(expected, 3), f(circuit, 4),
                  f(circuit - expected, 4), f(1000 * measured(outputs[i], "ripple"), 3))
  writeFile(ResultsDir / "divider-accuracy.csv", table)
  report.add &"""## 1. Divider accuracy

![Divider error](divider-accuracy.svg)

{cases.len} cases, cards left 1–40, danger 0–100 %. **Worst error {f(worst, 3)} % of
full scale** ({f(worst / 2.5, 3)} of a card). Data: [divider-accuracy.csv](divider-accuracy.csv).

"""

proc dividerSettling(report: var string) =
  echo "divider settling..."
  const cardsLefts = [40, 10, 4, 2]
  discard runAll(cardsLefts.mapIt(("settle_" & $it,
    dividerNetlist(it div 2, it, waveFile = SimDir / "wave" & $it & ".txt"))))
  var table = csv("cards_left", "time_ms", "output_pct")
  var settleTimes = ""
  for cardsLeft in cardsLefts:
    var settled = 0.0          # last time the output was more than 0.1 % off
    for (t, v) in readWave(SimDir / "wave" & $cardsLeft & ".txt"):
      if t <= 0.300:
        table.add csv(cardsLeft, f(t * 1000, 3), f(v * 10, 4))
        if abs(v * 10 - 50.0) > 0.1: settled = t * 1000
    settleTimes.add &"- {cardsLeft} cards left: within 0.1 % after {int(round(settled))} ms\n"
  writeFile(ResultsDir / "divider-settling.csv", table)
  report.add &"""## 2. Divider settling

![Divider settling](divider-settling.svg)

{settleTimes}
The 2-pole output filter dominates. With few cards left the loop itself is slower
(time constant 40 ms ÷ cards left): it starts at full duty, so the output rises
faster and overshoots a little before settling. Either way it's under a fifth of a
second. Data: [divider-settling.csv](divider-settling.csv).

"""

proc chainVsApp(report: var string): float =
  ## Returns the worst disagreement, % of full scale.
  echo "whole chain vs app..."
  const scenarios = [
    ({Void}, false, 0, 0),
    ({Void, Caves}, true, 10, 3),
    ({Rocky, Desert, Caves}, false, 20, 5),
    ({Ruins}, true, 37, 1),
    ({Void .. Desert}, false, 0, 0),
    ({Hostile, Crystalline}, false, 30, 27)]
  var jobs: seq[(string, string)]
  var stacks: seq[seq[Plate]]
  for i, (symbols, blankSafe, played, dangerPlayed) in scenarios:
    var stack = toSeq(symbols).mapIt(plateFor(it))
    if blankSafe: stack.add blankSafePlate()
    stacks.add stack
    jobs.add ("chain_" & $i, chainNetlist(stack, played, dangerPlayed))
  let outputs = runAll(jobs)
  var table = csv("scenario", "plates", "blank_safe", "cards_played", "danger_played",
                  "lit_positions", "app_pct", "circuit_pct", "error_pct_fs")
  var md = "| # | Plates stacked | n | d | Lit | App | Circuit |\n|---|---|---|---|---|---|---|\n"
  for i, (symbols, blankSafe, played, dangerPlayed) in scenarios:
    let rule = if blankSafe: blankIsSafe else: blankIsDanger
    let safe = NotebookDeck.safe(symbols, rule)
    let odds = analyse(safe, Observation(played: played,
      counts: @[Count(cards: safe, played: played - dangerPlayed)]))
    let app = 100.0 * odds.chanceAtLeastOne(1, Danger)
    let circuit = 10.0 * measured(outputs[i], "vp")
    result = max(result, abs(circuit - app))
    let names = if symbols.card == 12: "all 12" else: toSeq(symbols).mapIt($it).join(" + ")
    let plateList = names & (if blankSafe: " + blank-safe" else: "")
    let lit = card(litPositions(stacks[i]))
    table.add csv(i + 1, "\"" & plateList & "\"", blankSafe, played, dangerPlayed, lit,
                  f(app, 3), f(circuit, 3), f(circuit - app, 4))
    md.add &"| {i + 1} | {plateList} | {played} | {dangerPlayed} | {lit} | {f(app, 2)} % | {f(circuit, 2)} % |\n"
  writeFile(ResultsDir / "chain-vs-app.csv", table)
  report.add &"""## 3. Whole chain vs the app

![Chain vs app](chain-vs-app.svg)

{md}
n = cards played, d = danger cards played, Lit = detector positions lit by the
stack. **Worst disagreement {f(result, 3)} % of full scale.** Ideal op-amps;
resistor tolerance is section 4. Data: [chain-vs-app.csv](chain-vs-app.csv).

"""

proc resistorTolerance(report: var string) =
  echo "resistor tolerance Monte Carlo..."
  const
    trials = 500
    played = 30
    dangerPlayed = 24
    # (label, counting resistors and DAC weights, gain-setting pairs, seed)
    configs = [("1 % everywhere", 0.01, 0.01, 2),
               ("0.1 % everywhere", 0.001, 0.001, 1),
               ("0.1 % + 0.01 % matched pairs", 0.001, 0.0001, 3)]
  let stack = @[plateFor(Void)]                    # 32 danger cards
  let expected = 100.0 * ((32 - dangerPlayed) / (40 - played))
  let outputs = runAll(configs.mapIt(("tolerance_" & $it[3],
    toleranceNetlist(stack, played, dangerPlayed, it[1], it[2], trials, it[3]))))
  var table = csv("config_index", "config", "trial", "error_pct_fs")
  var md = &"| Resistors | SD | Worst of {trials} | Worst, in cards |\n|---|---|---|---|\n"
  for c, (name, _, _, _) in configs:
    let values = printedValues(outputs[c])
    var errors: seq[float]
    for trial in 0 ..< trials:
      errors.add 100.0 * values[&"v(vnum_{trial})"] / values[&"v(vden_{trial})"] - expected
      table.add csv(c, "\"" & name & "\"", trial, f(errors[^1], 4))
    let mean = errors.sum / float(trials)
    let sd = sqrt(errors.mapIt((it - mean) ^ 2).sum / float(trials))
    let worst = errors.mapIt(abs(it)).max
    md.add &"| {name} | {f(sd, 3)} % | {f(worst, 3)} % | {f(worst / 2.5, 2)} |\n"
  writeFile(ResultsDir / "resistor-tolerance.csv", table)
  report.add &"""## 4. Resistor tolerance (Monte Carlo)

![Resistor tolerance](resistor-tolerance.svg)

Every resistor in M4–M6 is drawn uniformly within its tolerance; op-amps are ideal.
The case is late in the game (10 cards left): the circuit subtracts nearly equal
large voltages there (8 V − 6 V, 10 V − 7.5 V), so a 0.1 % gain error on 8 V becomes
0.4 % of a 2 V difference. Matched 0.01 % networks for the gain-setting pairs (×2
amps, DAC feedback and inverters, difference amps) fix most of it; the 40 counting
resistors and the DAC weights can stay 0.1 %.

{md}
1 % parts aren't plotted: their spread is far off this scale. Data:
[resistor-tolerance.csv](resistor-tolerance.csv).

"""

proc unitTests(report: var string) =
  echo "unit tests..."
  var log = ""
  for test in ["tests/test_odds.nim", "tests/test_plates.nim"]:
    let (output, code) = execCmdEx("nim c -r --hints:off --outdir:build/tests " & test)
    if code != 0: quit "unit tests failed:\n" & output
    for line in output.splitLines:
      if "[OK]" in line or "[FAILED]" in line or "[Suite]" in line: log.add line & "\n"
  writeFile(ResultsDir / "unit-tests.txt", log)
  report.add """## 5. Unit tests

Including the optics check: every one of the 8190 plate stacks lights exactly the
app's danger cards. Log: [unit-tests.txt](unit-tests.txt).

## Reproduce

```
nim results   # this report (needs ngspice and gnuplot)
nim sim       # whole-chain check only
nim test      # unit tests
```

`hardware/results.nim` runs the simulations and writes the CSVs; `hardware/plots.gp`
draws the charts from them. Netlists and ngspice logs go to `build/sim/`.
"""

# ---------------------------------------------------------------- main

when isMainModule:
  createDir ResultsDir
  if paramCount() >= 1 and paramStr(1) == "chain":
    var ignored = ""
    let worst = chainVsApp(ignored)
    echo "worst disagreement ", f(worst, 3), " % of full scale"
    if worst > 0.5: quit "circuit disagrees with the app"
  else:
    var report = """# Simulation results

Generated by `nim results`. Every number below comes from the CSV files beside this
report, and every chart is drawn from those CSVs by gnuplot.

Scale: 0.25 V per card, 10 V = 40 cards = 100 %. Errors are in % of full scale
(10 V), so 2.5 % = one card.

"""
    dividerAccuracy(report)
    dividerSettling(report)
    discard chainVsApp(report)
    resistorTolerance(report)
    unitTests(report)
    writeFile(ResultsDir / "README.md", report)
    let code = execCmd("gnuplot -e \"dir='" & ResultsDir & "/'\" hardware/plots.gp")
    if code != 0: quit "gnuplot failed"
    echo "wrote ", ResultsDir
