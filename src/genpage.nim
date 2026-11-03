## Writes index.html: the page shell with the stylesheet and compiled app inlined.
## Run after `nim js` has produced build/app.js (`nim build` does both).
import page

writeFile("index.html", renderPage(css = readFile("src/style.css"),
                                   appJs = readFile("build/app.js")))
echo "wrote index.html"
