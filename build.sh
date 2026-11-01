#!/bin/sh
# Compile src/app.nim to JS and inline it into a single self-contained index.html.
set -e
cd "$(dirname "$0")"
nim js -d:release --hints:off -o:build/app.js src/app.nim
python3 - <<'PY'
t = open('src/index.template.html', encoding='utf-8').read()
js = open('build/app.js', encoding='utf-8').read()
open('index.html', 'w', encoding='utf-8').write(t.replace('/*APP*/', js))
PY
echo "wrote index.html ($(wc -c < index.html) bytes)"
