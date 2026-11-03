# Vanguard Odds — physical version

A light box that answers the app's main question with acrylic plates, op-amps and a
Nixie bargraph: **what is the chance the next card is danger?**

```
            ┌──────────── light (M2) ────────────┐
            │  stack of symbol plates (M1)       │   one plate per selected symbol,
            │  + optional "blank safe" plate     │   on a spindle + locating pin
            │  baffle (M1)                       │
            └──── 40 detectors on a ring (M3) ───┘
                     │ 40 logic bits, 1 = light = danger card
                     ▼
              popcount summer (M4) ──► V_D = 0.25 V × danger cards in deck
 thumbwheel "cards played" n  ──► BCD DAC (M5) ──► V_n
 thumbwheel "danger played" d ──► BCD DAC (M5) ──► V_d
              subtractors (M6): V_num = V_D − V_d      V_den = 10 V − V_n
              divider (M7):     V_P = 10 V × V_num / V_den      (0–10 V = 0–100 %)
              IN-13 driver (M8): bar length ∝ V_P
 power + single 5.000 V reference (M9), enclosure (M10)
```

Scale everywhere: **0.25 V per card, 40 cards = 10 V.**

## Current design: the stand

```
            lid: plate on the strip tops, LED board underneath
            (40 LEDs over the 40 slots), batteries on top
        ┃   ┃                                   ┃   ┃
        ┃   ┃   up to 6 plywood tokens          ┃   ┃   guide strips at 4 corners;
        ┃   ┃   (likely 2–3), keyed corner      ┃   ┃   open corners
        ┃   ┣━━ floor = baffle: 40 slots ━━━━━━━┫   ┃   between them for fingers
        ┃   ┃   sensor board on spacers          ┃   ┃
        ┗━━━┻━━ base ━━━━━━━━━━━━━━━━━━━━━━━━━━━┻━━━┛
   danger meter beside it: needle over green / yellow / red
```

| Part | Choice |
|---|---|
| Tokens | 3 mm plywood octagons, icon engraved in the centre, 40 leaning slots (`nim plates`) |
| Stand | Tab-and-slot plywood: base, floor/baffle, 6 guide strips + 1 angled key strip, lid (`nim cup`) |
| Light | Lid with 40 LEDs over the 40 slots, own batteries |
| Detection | Factory-assembled octagonal sensor board, 40 visible-light detectors + Schmitt triggers + 40 resistors (M3, M4) |
| Inputs | Two pots with printed 0–40 dials |
| Maths | Pot divider, one quad op-amp ([schematic](schematics/rheostat-divider.svg)) |
| Display | **Danger meter**: analog panel meter with a green / yellow / red dial (`nim meter`) |

**Why 40 LEDs rather than one panel:** each sensor gets a strong, focused light,
so every slot reads a clear 0 or 1 even through plywood, and neighbouring slots
don't spill into each other. Battery: 40 LEDs at 1 mA is 40 mA, many hours on 3×AA.

**The pot divider.** An inverting amplifier's gain is R_f / R_in. If R_in *is*
the "cards played" pot, wired as a rheostat so its resistance is proportional to
the cards **left**, the amplifier divides by cards left: the knob is the divider.
The "danger played" pot is a plain voltage divider feeding a difference amp:

    V_P = 10 V · (D − d) / (40 − n)

Accuracy is the pots' own, about ±1 card: track linearity (carbon ±5–10 %,
conductive plastic ±1–2 %) and how precisely you set them. A mechanical stop
at n = 39 keeps R_in above zero. The more accurate alternative is the
duty-cycle divider (M7, [schematic](schematics/duty-cycle-divider.svg)).

**Tokens** (`hardware/plates/`): regular octagons 80 mm across flats. Card i is
slot (i mod 5) on side (i div 5), clockwise from the top. Every slot is the same
leaning parallelogram (6 × 2.2 mm), so every position passes the same light.
No text: names are in the file names and SVG titles. Registration: one corner
(upper left) is clipped unevenly, 9 mm back along one side and 4 mm along the
other, and the stand has an angled key strip against it. An evenly clipped
corner would not key it, since every corner of an octagon lies on a mirror
axis; clipped unevenly, a token turned over doesn't seat (tested). On plywood the engraved icon burns dark, which suits it.

**Stand** (`hardware/cup/`), all 3 mm plywood, tab and slot:
- *Base* and *lid*: 100 mm octagons with slots for the strip tabs.
- *Floor*: the 40 slots (it's the baffle), plus slots the strips pass through.
  It rests on a shoulder on each strip, 6 mm above the base, leaving room for
  the sensor board on spacers.
- *Guide strips* at 4 of the 8 corners: three corners have a pair (one strip
  on each side near the corner), so each of those sides is held. The keyed
  corner has one angled *key strip* lying against the clipped corner. The open
  corners are finger access. The 6 plain strips are the same shape; flip one
  over for the other side of a pair, so its shoulder is on the end away from the
  corner.
- Slots are cut 0.1 mm oversize per side. Change `Fit` after a test cut, because
  plywood thickness and laser kerf vary.
- `top-view.svg` is a plan view for checking the fit, not a cut file.
- The board outline files are for importing into KiCad, with the 40 positions
  marked in blue. The LED board's are mirrored because it faces down.

**Danger meter** (`nim meter` → `hardware/meter/`): `dial.svg` is a replacement
face for a small analog panel meter, with a green / yellow / red arc (zones at
33 % and 66 %, one constant each), DANGER and "% next card". Measure your meter
(visible face, needle pivot, sweep) and set the constants at the top of
`meter.nim` before printing. Drive: V_P (0–10 V) through a series resistor into a
1 mA movement (about 8.2 k plus a 5 k trimmer to set full scale), or use a 0–10 V
voltmeter movement directly. No high voltage.

`in13-scale.svg` is the same zones as a vertical strip, if you'd rather have the
IN-13's glowing column beside a printed scale. It's still the coolest-looking
option, at the cost of a 170 V supply.

## Four changes to the original idea

1. **Plates are negatives.** Stacked plates pass light only where *every* plate has
   a hole (AND), not OR. So a plate has a hole where the card does **not** show
   its symbol. Then light gets through position *i* only if card *i* shows none
   of the stacked symbols, which is exactly "danger". The detectors count danger
   cards directly; no inversion needed. Stacking the extra **blank-safe** plate
   (holes everywhere except the blank card) counts the blank as safe, which
   replaces the app's toggle.
2. **Don't measure light linearly.** A single photodetector reading total light
   would need every aperture, LED and the detector's response to be uniform
   to better than 2.5 % (one card in 40). Instead, each of the 40 positions gets
   its own detector and a Schmitt trigger: a clean 0/1 per card. The 40 bits then
   go into 40 equal resistors to one node. That node sits at 5 V × (lit count)/40,
   linear by construction, and the accuracy comes from resistor matching, not
   from optics. Static, no motor, as you wanted.
3. **Thumbwheels or pots.** A pot doesn't show you that it's on 17 rather than
   16, and one card is 2.5 %. Thumbwheels are exact. Pots with a printed dial
   are about ±1 card, and they make the pot divider possible (see the
   simplified design above).
4. **The divider is a duty-cycle servo, not an analog multiplier IC.** An AD633
   used as a divider loses accuracy as the denominator gets small, which is
   exactly the end of the deck. The duty-cycle divider (M7) simulates within
   0.08 % of full scale down to one card left.

**Limit:** the analog version answers "next card" only. "At least one danger in
the next S cards" is 1 − C(R−D, S)/C(R, S), which isn't practical in analog. See
the digital alternative at the end.

## Status

| Module | What | Status |
|---|---|---|
| M1 | Symbol plates, blank-safe plate, baffle | **Done:** SVGs generated from the app's deck data (`nim plates`); all 8190 stacks tested against the app |
| M2 | Light source | Specified |
| M3 | 40-channel detector ring | Specified; PCB next |
| M4 | Popcount summer | **Simulated** |
| M5 | Thumbwheel BCD DACs (×2) | **Simulated** |
| M6 | Subtractors | Simulated with ideal parts; parts chosen |
| M7 | Duty-cycle divider | **Simulated**, stand-alone and in the chain |
| M8 | IN-13 driver + HV supply | Specified; needs datasheet check |
| M9 | Power and reference | Specified |
| M10 | Enclosure and mechanics | Specified |

`nim sim` simulates M3 outputs through M7 in ngspice for six game situations
and compares with the app's own maths: worst error 0.004 % of full scale
with ideal parts. **`nim results` runs the full characterisation (divider sweep,
settling, whole chain, resistor-tolerance Monte Carlo, unit tests) and writes
graphs, CSVs and a report to [`results/`](results/README.md).**

---

## M1 — Plates *(superseded by the octagonal tokens above; the infrared note still applies)*

Generated by `hardware/plates.nim` from `NotebookDeck`, so they can't drift
from the app: `nim plates` writes `hardware/plates/*.svg` and `sheet.svg` (all 14).

- 100 mm discs, **opaque** black acrylic, 2 mm.
- 40 apertures, Ø3 mm, on a 40 mm radius ring (9° / ~6.3 mm pitch). Card *i* is at
  *i* × 9° clockwise from the top. Numbers are engraved every 5 cards.
- Ø8.2 mm centre hole on an 8 mm spindle. Ø3.1 mm locating-pin hole at 22 mm
  radius, 20°. A plate placed upside down puts that hole at −20° and won't seat,
  so there's only one way on.
- 12 symbol plates, each engraved with its biome icon (24 mm, below the spindle)
  and name. The notebook letter and blocked count are in small print at the top,
  for documentation. Plus a **blank-safe** plate and a **baffle**
  (all 40 holes, fixed over the detectors to stop light leaking between
  neighbouring positions).
- Files: red hairline = cut, black = engrave. Convert text to paths in your
  laser software.
- Icons are traced from the rulebook's Biome Icons page by `nim icons`
  (ImageMagick crop, 8× smooth upscale, threshold, potrace) into
  `icons/*.svg`. The source image is in `icons/source/`. They're Awaken Realms'
  artwork, for a personal copy of the game.

⚠️ **Test first:** some black acrylic is transparent to infrared, and most
phototransistors peak in the IR. Cut one plate and check it with the chosen
detector, or use a visible-only detector (M3) and green light (M2).

## M2 — Light source

- Above the stack, inside a light-tight lid: a diffuse panel, either an LED strip
  behind a diffuser or 40 LEDs on a ring board matching M3.
- Green (~570 nm) to match visible-light detectors and avoid the IR problem.
- Uniformity only needs to clear a threshold: aim for at least 5× margin between
  the dimmest open position and the comparator threshold, with the thickest
  stack (13 plates, 26 mm).

## M3 — Detector ring (40 channels)

- 40 visible-light phototransistors (e.g. TEPT5700-class, peak ~570 nm) at the
  ring positions, under the baffle.
- Each with a pull-up into one 74HC14 Schmitt inverter: light → transistor on →
  input low → **output high = danger card**. Seven 74HC14s.
- **The 74HC14s run from the 5.000 V reference** (M9), so a logic high is
  exactly 5.000 V. They draw microamps statically; the load is 40 × 50 µA = 2 mA.
- Optional: a status LED per channel needs separate gates. Don't load the M4
  outputs.

## M4 — Popcount summer *(simulated)*

- Each of the 40 bits → 100 kΩ 0.1 % → one common node. Node = 5 V × D/40.
- Non-inverting ×2 (two 0.1 % resistors, precision op-amp) → **V_D = 0.25 V × D**.
- Only resistor *matching* matters. With 0.1 % parts the worst case is ±0.04
  of a card at D = 40.

## M5 — Thumbwheel DACs, ×2 *(simulated)*

- Two-digit BCD thumbwheels: **cards played n** and **danger cards played d**
  (cards played that had none of the stacked symbols, or the blank card when
  the blank-safe plate isn't stacked).
- Each closed contact connects the 5.000 V reference through a weighted resistor
  to an inverting summer's virtual ground:
  units 1/2/4/8 → 400k/200k/100k/50k, tens 10/20/40 → 40k/20k/10k, Rf = 20k
  → −0.25 V per count, then a unity inverter → **+0.25 V per count**. 0.1 % resistors.
- Contact resistance (<0.1 Ω) is negligible next to 10k.

## M6 — Subtractors

- **V_num = V_D − V_d** and **V_den = 10 V − V_n**, using unity-gain difference
  amplifiers with laser-trimmed resistors (INA105/INA133-class), or an op-amp
  with a **0.01 % matched resistor network** (LT5400-class). Not 0.1 % discretes:
  late in the game these subtract nearly equal large voltages (8 V − 6 V), which
  magnifies gain errors. See the Monte Carlo in `results/`.
- The 10 V is the 5.000 V reference ×2, so the whole chain is ratiometric: the
  answer V_num / V_den doesn't depend on the reference's absolute accuracy.

## M7 — Duty-cycle divider *(simulated: `sim/divider.cir`; [schematic](schematics/duty-cycle-divider.svg))*

How it works: a PWM switch subtracts V_den at an integrator's input for a
fraction δ of each period. The integrator drives δ until δ·V_den = V_num on
average. The same PWM chops the 10 V reference, which is then filtered, giving
**V_P = 10 V × V_num / V_den**. The result depends only on switch timing and the
reference, not on the triangle's shape.

- 10 kHz triangle (0–10 V), integrator 100k/10 nF, comparator, two SPDT analog
  switches in one package (DG403-class, ±15 V) so their timing errors cancel,
  2-pole RC output filter 10k/1 µF (ripple < 1 mV).
- Simulated: within 0.08 % of full scale for every case tried, down to one card left.
  Settling time scales with 1/(cards left): about 0.3 s worst case, fine for a
  human turning a thumbwheel.
- If inputs are impossible (more danger left than cards left), it clamps at 100 %.
  With all 40 cards played the reading is meaningless.

## M8 — IN-13 driver and HV

The thin vertical violet bargraph is (I think) the **IN-13**; the IN-9 is the
thicker orange one.

- Op-amp + 300 V NPN (MPSA42) + sense resistor as a voltage-controlled current
  sink: cathode current I = V_P / R_sense, with zero and span trims because the
  bar has a dead zone at the bottom.
- The IN-13 needs a ~170–200 V supply, an anode resistor, and a small fixed
  current on its auxiliary cathode to keep the glow started.
  ⚠️ **These values are from memory. Check the IN-13 datasheet before choosing
  resistors:** maximum indicator current (a few mA), auxiliary cathode current
  and ignition voltage.
- HV: a 12 V → 170–200 V Nixie boost module (buy, don't build).
  ⚠️ Lethal-ish: keep HV on its own corner of the PCB and give it a cover.
- Calibrate with the thumbwheels: with no plates stacked (D = 40) and n = 0,
  setting d = 0 / 10 / 20 / 30 / 40 gives exactly 100 / 75 / 50 / 25 / 0 %. These
  aren't real game positions, but the circuit doesn't mind.
  Engrave a scale beside the tube to absorb any remaining nonlinearity in the
  bar length.

## M9 — Power and reference

- 12 V DC in → ±15 V (isolated DC-DC module) for the analog section; 5 V for logic
  and pull-ups; HV module from 12 V.
- **One 5.000 V reference** (REF5050-class, sources 10 mA) for: 74HC14 supply,
  DAC contacts, and (×2) the 10 V for V_den and the divider's output switch.
- Op-amps: any 36 V precision quad (OPA4197-class). TL074 would do, since its
  ~3 mV offset is ~0.01 card.

## M10 — Enclosure and mechanics

- Base: detector board, baffle, 8 mm spindle, 3 mm locating pin.
- Plate rack beside it holding the unused plates.
- Hinged light-tight lid with the light source (M2).
- Front panel: two thumbwheels, IN-13 with its engraved scale.

## Error budget

From the Monte Carlo in [`results/`](results/README.md) (late game, 10 cards
left, where errors are magnified), op-amps ideal:

| Resistors | SD | Worst of 500 builds |
|---|---|---|
| 1 % everywhere | 4.6 % FS | 13 % FS (5 cards): unusable |
| 0.1 % everywhere | 0.47 % FS | 1.4 % FS (0.55 card) |
| 0.1 % counting resistors and DAC weights, 0.01 % matched pairs for every gain-setting pair | 0.16 % FS | 0.44 % FS (0.17 card) |

**Use the third row.** "Gain-setting pairs" means: the ×2 after the popcount,
the 10 V doubler, each DAC's feedback and inverter, and both difference amps.

Other sources:

| Source | Effect |
|---|---|
| M7 divider (simulated, 69 cases) | ≤ 0.08 % FS |
| M7 switch timing (100 ns at 10 kHz, the two switches' errors largely cancel) | ≤ 0.1 % FS, estimated |
| Op-amp offsets (≤ 100 µV, precision parts) | ≤ 0.01 % FS |
| IN-13 bar length | ~1 % (1 mm in ~100 mm). Calibrate it. |

With matched pairs, the electronics are about as good as you can read off the
bar. With plain 0.1 % parts they're about one bar-millimetre worse in the late
game. (An earlier version of this table claimed ≤ 0.04 card per block and
"far better than the bar". The Monte Carlo showed that was wrong for the late game.)

## The digital alternative (honest comparison)

Replace M4–M7 with a small microcontroller: read the 40 detector bits through
five 74HC165 shift registers and the thumbwheels directly, compute the answer
exactly (including "≥1 danger in next S cards", per-symbol counts, and the same
`odds.nim` maths compiled for the MCU), and drive M8 from a DAC.

- **Pros:** exact, more features, fewer precision parts.
- **Cons:** it's a computer, which is less fun.
- The optics, thumbwheels and IN-13 stay exactly the same, so it's a later swap
  of one board.

On Eurorack: mixers and attenuverters can do the sums and differences, and VCAs
multiply, but division is rare and not to this accuracy. One custom PCB is
simpler.

## Files

- `plates.nim`: token geometry and SVG output; `genplates.nim` writes them (`nim plates`).
- `schematics/`: divider schematics (SVG), drawn by `draw.py` (schemdraw).
- `receptacle.nim`, `gencup.nim`: the plywood stand, lid and board outlines (`nim cup`).
- `meter.nim`: danger meter dial and IN-13 scale (`nim meter`).
- `icons/`: traced biome icons (`nim icons`) and their source image.
- `simgen.nim`, `experiments.nim`: netlist generators for the chain, divider and Monte Carlo.
- `results.nim`: runs ngspice in parallel, writes `results/*.csv` and the report
  (`nim results`; `nim sim` runs just the whole-chain check).
- `plots.gp`: gnuplot script drawing `results/*.svg` from the CSVs.
- `sim/divider.cir`: stand-alone divider netlist.
- `../tests/test_plates.nim`: checks the optics against the app for every stack.
