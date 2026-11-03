## Generates SPICE netlists of the analog chain for a game situation, so the
## circuit can be checked against the app's own maths (`nim sim`).
##
## Signal scale throughout: 0.25 V per card, so 40 cards = 10 V.
##
##   stacked plates ──► 40 detector bits (0 / 5.000 V, from 74HC14s on the ref)
##                      └─ 40 × 100k to one node = 5 V·D/40 ──► ×2 ──► V_D
##   thumbwheel n ──► BCD DAC ──► V_n        thumbwheel d ──► BCD DAC ──► V_d
##   V_num = V_D − V_d      V_den = 10 V − V_n      (unity-gain difference amps)
##   V_P   = 10 V · V_num / V_den                     (duty-cycle divider)

import std/strutils
import ../src/model
import plates

const
  BitHigh* = 5.0          ## detector logic high: 74HC14s supplied from a 5.000 V reference
  PopcountR* = "100k"     ## one per aperture; only their matching matters
  DacR0 = 400_000         ## BCD DAC weight-1 resistor; weight w uses DacR0 / w
  DacRf = "20k"           ## gives 0.25 V per card from the 5 V reference

proc litPositions*(stack: seq[Plate]): Cards =
  ## Positions where light gets through every plate in the stack.
  result = AllCards
  for plate in stack: result = result * plate.holes

proc bcdWeights(value: int): seq[int] =
  ## Weights of the closed contacts on a two-digit BCD thumbwheel showing `value`.
  for (digit, scale) in [(value mod 10, 1), (value div 10, 10)]:
    for bit in 0 .. 3:
      if (digit shr bit and 1) == 1: result.add scale * (1 shl bit)

proc dac(name, output: string, value: int): string =
  ## Inverting summer on the BCD contacts, then an inverter: +0.25 V per count.
  ## Internal nodes are prefixed with "dac_<name>_" so they can't collide.
  let node = "dac_" & name & "_"
  result.add "* thumbwheel " & name & " = " & $value & "\n"
  for weight in bcdWeights(value):
    result.add "R" & name & "w" & $weight & " vref5 " & node & "sum " &
      $(DacR0 div weight) & "\n"
  result.add "R" & name & "f " & node & "sum " & node & "neg " & DacRf & "\n" &
    "E" & name & "a " & node & "neg 0 0 " & node & "sum 1e6\n" &
    "R" & name & "i1 " & node & "neg " & node & "inv 10k\n" &
    "R" & name & "i2 " & node & "inv " & output & " 10k\n" &
    "E" & name & "b " & output & " 0 0 " & node & "inv 1e6\n"

const Divider = """
* duty-cycle divider (see sim/divider.cir for the stand-alone version)
Vtri  tri 0 PULSE(0 10 0 50u 50u 1n 100u)
Bsw1  swd 0 V = -V(vden) * (0.5 + 0.5*tanh(1e3*(V(pwm)-2.5)))
Rd1   vnum dinv 100k
Rd2   swd dinv 100k
Cd1   dinv dint 10n
Edop  dint 0 0 dinv 1e5
Bcmp  pwm 0 V = 2.5 + 2.5*tanh(1e3*(V(tri)-V(dint)))
Bsw2  swr 0 V = V(vref10) * (0.5 + 0.5*tanh(1e3*(V(pwm)-2.5)))
Rf1   swr f1 10k
Cf1   f1 0 1u
Rf2   f1 vp 10k
Cf2   vp 0 1u
"""

proc chainNetlist*(stack: seq[Plate], played, dangerPlayed: int): string =
  let lit = litPositions(stack)
  result = "* analog chain: " & $card(lit) & " lit, n=" & $played &
    ", d=" & $dangerPlayed & "\n" &
    "Vref5 vref5 0 5\nVref10 vref10 0 10\n"
  for index in CardIndex:
    result.add "Vbit" & $index & " bit" & $index & " 0 " &
      (if index in lit: $BitHigh else: "0") & "\n" &
      "Rpc" & $index & " bit" & $index & " popnode " & PopcountR & "\n"
  result.add "Egain vd 0 popnode 0 2\n"           # non-inverting ×2 (ideal here)
  result.add dac("n", "vn", played)
  result.add dac("d", "vdp", dangerPlayed)
  result.add "Enum vnum 0 vd vdp 1\n"            # difference amps (ideal here)
  result.add "Eden vden 0 vref10 vn 1\n"
  result.add Divider
  result.add ".tran 2u 300m 0 2u\n.control\nrun\n" &
    "meas tran vd avg v(vd) from=250m to=300m\n" &
    "meas tran vp avg v(vp) from=250m to=300m\n.endc\n.end\n"

proc measured*(spiceOutput, name: string): float =
  ## Reads a `meas` result such as "vp = 7.750000e+00 from=...".
  for line in spiceOutput.splitLines:
    let fields = line.splitWhitespace
    if fields.len >= 3 and fields[0] == name and fields[1] == "=":
      return parseFloat(fields[2])
  raise newException(ValueError, "no measurement '" & name & "' in ngspice output")
