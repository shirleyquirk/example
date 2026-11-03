## Netlists for the characterisation runs behind `nim results`:
##
## * divider accuracy: every combination of cards left × danger fraction
## * divider settling: output vs time, same 50 % target, fewer cards left
## * resistor tolerance: Monte Carlo of the resistor networks (M4–M6)
##
## Signal scale: 0.25 V per card, 10 V = 40 cards = 100 %.

import std/[random, strutils, tables]
import ../src/model
import plates, simgen

const VoltsPerCard* = 0.25

proc settleTimeMs*(cardsLeft: int): int =
  ## Two things settle from power-up: the divider loop (time constant
  ## 10·RC / V_den = 40 ms / cards left, RC = 1 ms) and the 2-pole output
  ## filter (slow pole ~26 ms). Allow 8 time constants of each.
  8 * 40 div cardsLeft + 8 * 26 + 50

proc dividerNetlist*(dangerLeft, cardsLeft: int, waveFile = ""): string =
  ## The divider alone, fed with exact V_num and V_den. With `waveFile`, also
  ## writes v(vp) against time to that file.
  let stopMs = settleTimeMs(cardsLeft)
  result = "* divider: " & $dangerLeft & " danger of " & $cardsLeft & " left\n" &
    "Vnum vnum 0 " & $(VoltsPerCard * float(dangerLeft)) & "\n" &
    "Vden vden 0 " & $(VoltsPerCard * float(cardsLeft)) & "\n" &
    "Vref10 vref10 0 10\n" & Divider &
    # uic: start from all-zero capacitor voltages; the integrator has no
    # meaningful DC operating point to solve for.
    (if waveFile.len > 0:
      # report the waveform every 0.5 ms (interpolated); internal step stays 2 µs
      ".options interp\n.tran 0.5m " else: ".tran 2u ") &
    $stopMs & "m 0 2u uic\n.control\nrun\n"
  if waveFile.len > 0:
    # before `meas`, which creates a scalar named vp that hides the node
    result.add "wrdata " & waveFile & " v(vp)\n"
  result.add "meas tran vp avg v(vp) from=" & $(stopMs - 40) & "m to=" & $stopMs & "m\n" &
    "meas tran ripple pp v(vp) from=" & $(stopMs - 40) & "m to=" & $stopMs & "m\n" &
    ".endc\n.end\n"

proc readWave*(path: string, every = 1): seq[(float, float)] =
  ## Reads ngspice `wrdata` output (time, value columns), keeping every n-th row.
  var row = 0
  for line in readFile(path).splitLines:
    let fields = line.splitWhitespace
    if fields.len >= 2:
      if row mod every == 0:
        result.add (parseFloat(fields[0]), parseFloat(fields[1]))
      inc row

# ---------------------------------------------------------------- Monte Carlo

proc toleranceNetlist*(stack: seq[Plate], played, dangerPlayed: int,
                       tolerance, pairTolerance: float, trials: int, seed: int): string =
  ## `trials` independent copies of the resistor networks M4 (popcount, ×2),
  ## M5 (both DACs), M6 (both difference amps) and the 10 V doubler. Each
  ## resistor is drawn uniformly within its tolerance of nominal:
  ## `tolerance` for the 40 popcount resistors and the DAC weights,
  ## `pairTolerance` for the gain-setting pairs (×2 amps, DAC feedback and
  ## inverters, difference amps), which can come from matched networks.
  ## Op-amps are ideal here. One `.op` solves all copies; the report reads
  ## v(vnum_k) and v(vden_k).
  var rng = initRand(seed)
  proc r(nominal: float): string =
    $(nominal * (1.0 + tolerance * rng.rand(-1.0 .. 1.0)))
  proc rp(nominal: float): string =
    $(nominal * (1.0 + pairTolerance * rng.rand(-1.0 .. 1.0)))

  let lit = litPositions(stack)
  result = "* resistors ±" & $(tolerance * 100) & "%, pairs ±" & $(pairTolerance * 100) & "%, " & $trials & " trials\n" &
    "Vref5 vref5 0 5\n"
  for index in CardIndex:
    result.add "Vbit" & $index & " bit" & $index & " 0 " &
      (if index in lit: "5" else: "0") & "\n"

  proc opAmp(name, output, plus, minus: string): string =
    "E" & name & " " & output & " 0 " & plus & " " & minus & " 1e6\n"

  proc dac(k, name, output: string, value: int): string =
    let node = name & "_" & k & "_"
    for (digit, scale) in [(value mod 10, 1), (value div 10, 10)]:
      for bit in 0 .. 3:
        if (digit shr bit and 1) == 1:
          let weight = scale * (1 shl bit)
          result.add "R" & node & "w" & $weight & " vref5 " & node & "sum " &
            r(400_000.0 / float(weight)) & "\n"
    result.add "R" & node & "f " & node & "sum " & node & "neg " & rp(20_000) & "\n" &
      opAmp(node & "a", node & "neg", "0", node & "sum") &
      "R" & node & "i1 " & node & "neg " & node & "inv " & rp(10_000) & "\n" &
      "R" & node & "i2 " & node & "inv " & output & " " & rp(10_000) & "\n" &
      opAmp(node & "b", output, "0", node & "inv")

  proc difference(k, name, output, plus, minus: string): string =
    ## output = plus − minus, four resistors
    let node = name & "_" & k & "_"
    "R" & node & "1 " & minus & " " & node & "m " & rp(10_000) & "\n" &
      "R" & node & "2 " & node & "m " & output & " " & rp(10_000) & "\n" &
      "R" & node & "3 " & plus & " " & node & "p " & rp(10_000) & "\n" &
      "R" & node & "4 " & node & "p 0 " & rp(10_000) & "\n" &
      opAmp(node & "a", output, node & "p", node & "m")

  for trial in 0 ..< trials:
    let k = $trial
    for index in CardIndex:
      result.add "Rpc" & $index & "_" & k & " bit" & $index & " pop_" & k & " " &
        r(100_000) & "\n"
    # popcount ×2 and the 10 V doubler: non-inverting, two resistors each
    result.add opAmp("g_" & k, "vd_" & k, "pop_" & k, "fbg_" & k) &
      "Rga_" & k & " fbg_" & k & " 0 " & rp(10_000) & "\n" &
      "Rgb_" & k & " vd_" & k & " fbg_" & k & " " & rp(10_000) & "\n" &
      opAmp("t_" & k, "v10_" & k, "vref5", "fbt_" & k) &
      "Rta_" & k & " fbt_" & k & " 0 " & rp(10_000) & "\n" &
      "Rtb_" & k & " v10_" & k & " fbt_" & k & " " & rp(10_000) & "\n"
    result.add dac(k, "n", "vn_" & k, played)
    result.add dac(k, "d", "vdp_" & k, dangerPlayed)
    result.add difference(k, "num", "vnum_" & k, "vd_" & k, "vdp_" & k)
    result.add difference(k, "den", "vden_" & k, "v10_" & k, "vn_" & k)

  result.add ".control\nop\n"
  for trial in 0 ..< trials:
    result.add "print v(vnum_" & $trial & ") v(vden_" & $trial & ")\n"
  result.add ".endc\n.end\n"

proc printedValues*(spiceOutput: string): Table[string, float] =
  ## All ngspice `print` lines such as "v(vnum_3) = 2.000000e+00", by name.
  for line in spiceOutput.splitLines:
    let parts = line.split(" = ")
    if parts.len == 2:
      try: result[parts[0].strip] = parseFloat(parts[1].strip)
      except ValueError: discard
