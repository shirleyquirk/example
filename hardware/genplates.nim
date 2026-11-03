## Writes the laser-cutting SVGs to hardware/plates/ (`nim plates`).
import std/os
import plates

const dir = "hardware/plates"
createDir dir
let all = allPlates()
for plate in all:
  writeFile(dir / plate.fileName, plate.plateSvg)
writeFile(dir / "sheet.svg", all.sheetSvg)
echo "wrote ", all.len, " plates and sheet.svg to ", dir
