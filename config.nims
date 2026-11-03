# Build tasks. Run from the repository root:
#
#   nim test     unit tests
#   nim build    tests, then compile the app to JS and write index.html
#   nim icons    trace the biome icons from the rulebook image (needs ImageMagick, potrace)
#   nim plates   laser-cutting SVGs for the symbol plates (hardware/plates/)
#   nim sim      quick check: whole analog chain in ngspice vs the app's maths
#   nim results  every simulation, CSVs, gnuplot charts and a report in
#                hardware/results/ (needs ngspice, gnuplot)
#
# The tasks only run commands; the generators are ordinary compiled programs.

const run = "nim r --hints:off -d:release "

task test, "Run the unit tests":
  for test in ["tests/test_odds.nim", "tests/test_plates.nim"]:
    exec "nim c -r --hints:off --outdir:build/tests " & test

task build, "Test, compile the app to JavaScript and write index.html":
  exec "nim test"
  exec "nim js -d:release --hints:off -o:build/app.js src/app.nim"
  exec run & "src/genpage.nim"

task icons, "Trace the biome icons from hardware/icons/source/ into hardware/icons/":
  # Each icon is 64 px square in the source, in a column at x = 56..119. These
  # are the top edges, found by scanning that column for dark rows. Tutorial
  # isn't in this deck, so it's skipped.
  const
    source = "hardware/icons/source/biome-icons.png"
    iconTops = [("caves", 182), ("crystalline", 250), ("deadly", 369), ("desert", 550),
                ("frigid", 618), ("hostile", 796), ("rocky", 919), ("ruins", 1042),
                ("vegetation", 1342), ("void", 1465), ("volcanic", 1643), ("water", 1766)]
  mkDir "build/icons"
  for (name, top) in iconTops:
    let bitmap = "build/icons/" & name & ".pbm"
    # 66 px crop with a pixel of margin, upscale 8x with smoothing so the trace
    # gets curves rather than pixel steps, then threshold to 1 bit.
    exec "convert " & source & " -crop 66x66+55+" & $(top - 1) &
      " +repage -colorspace gray -resize 800% -threshold 50% " & bitmap
    exec "potrace " & bitmap & " --svg --flat --turdsize 40 --alphamax 1.1" &
      " -o hardware/icons/" & name & ".svg"

task plates, "Write laser-cutting SVGs for the plates to hardware/plates/":
  exec run & "hardware/genplates.nim"

task sim, "Whole analog chain in ngspice vs the app's maths":
  exec run & "hardware/results.nim chain"

task results, "Run every simulation and write hardware/results/":
  exec run & "hardware/results.nim"
