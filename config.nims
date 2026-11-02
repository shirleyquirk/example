# Build tasks. Run from the repository root:
#
#   nim test    unit tests (C backend)
#   nim build   tests, then compile the app to JS and write index.html
#
# index.html is self-contained: the stylesheet and compiled app are inlined.

import "src/page.nim"

const
  AppJs = "build/app.js"
  Page = "index.html"

task test, "Run the unit tests":
  exec "nim c -r --hints:off --outdir:build/tests tests/test_odds.nim"

task build, "Test, compile the app to JavaScript and write " & Page:
  exec "nim test"
  exec "nim js -d:release --hints:off -o:" & AppJs & " src/app.nim"
  writeFile(Page, renderPage(css = readFile("src/style.css"),
                             appJs = readFile(AppJs)))
  echo "wrote ", Page
