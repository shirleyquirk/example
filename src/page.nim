## The static page shell, written with `std/htmlgen`. The build task in
## `config.nims` calls `renderPage` with the stylesheet and compiled app.
##
## htmlgen does not escape text, so `&` in text is written as `&amp;`.

import std/htmlgen

proc stepper(target, value: string, minimum = "0"): string =
  ## A number box with − / + buttons on either side.
  span(class = "row",
    button(class = "step", `data-t` = target, `data-d` = "-1", "−"),
    input(id = target, `type` = "number", inputmode = "numeric",
          min = minimum, value = value),
    button(class = "step", `data-t` = target, `data-d` = "1", "+"))

proc toggle(id, first, second: string): string =
  ## Two-button segmented control; the app marks the chosen one with `on`.
  `div`(class = "seg", id = id,
    button(`data-v` = "1", first),
    button(`data-v` = "0", second))

proc numberBox(id: string): string =
  input(id = id, `type` = "number", inputmode = "numeric", min = "0",
        placeholder = "?")

proc ruleLink(href, title, note: string): string =
  li(a(href = href, target = "_blank", rel = "noopener", title), small(note))

const BlankChoice = ("Matches all (safe)", "Matches none (danger)")

proc renderPage*(css, appJs: string): string =
  "<!doctype html>\n" & html(lang = "en",
    head(
      meta(charset = "utf-8"),
      meta(name = "viewport",
           content = "width=device-width, initial-scale=1, viewport-fit=cover"),
      meta(name = "apple-mobile-web-app-capable", content = "yes"),
      meta(name = "apple-mobile-web-app-title", content = "Vanguard Odds"),
      meta(name = "theme-color", content = "#1d1b26"),
      link(rel = "manifest", href = "manifest.webmanifest"),
      title("Vanguard Odds"),
      style(css)),
    body(
      main(
        h1("ISS Vanguard · Odds ",
          button(id = "gear", class = "hbtn", title = "Settings", "⚙︎"),
          button(id = "clear", class = "hbtn", "reset")),

        section(
          h2("Symbols"),
          `div`(id = "chips"),
          `div`(id = "countOut", style = "margin-top:12px")),

        section(
          h2("Odds for the next draw"),
          toggle("modeSeg", "Danger (no match)", "Safe (match)"),
          label("cards already played", stepper("played", "0")),
          label("…of which were safe (matched)", numberBox("safePlayed")),
          `div`(id = "symbolPlayed"),
          p(style = "margin-top:10px", "Blank card"),
          toggle("blankSeg2", BlankChoice[0], BlankChoice[1]),
          label("drawing next", stepper("draw", "1", minimum = "1")),
          `div`(id = "oddsOut"),
          p(class = "muted", "Leave a box as “?” if you don’t know it. " &
            "Assumes the deck was shuffled and nothing else is known about " &
            "the played cards.")),

        section(
          h2("Rules"),
          ul(class = "links",
            ruleLink("https://www.orderofgamers.com/downloads/ISSVanguard_v2.pdf",
              "Rules summary &amp; reference (Order of Gamers, PDF)",
              "Fan-made, v2 incl. Ship Book procedures"),
            ruleLink("https://rulespal.com/iss-vanguard/rulebook",
              "Rulebook, browsable (RulesPal)",
              "Planetary exploration &amp; general rules"))),

        section(id = "settings", hidden = "",
          h2("Settings ", button(id = "closeSettings", class = "hbtn", "close")),
          p("Blank card counts as"),
          toggle("blankSeg", BlankChoice[0], BlankChoice[1]),
          h2(style = "margin-top:16px", "Cards × symbols"),
          p(class = "muted", "Rows are notebook page·row. ", span(id = "matrixNote")),
          `div`(class = "mx", id = "matrix"),
          button(class = "btn", id = "lockBtn"),
          button(class = "btn", id = "restoreBtn", hidden = "", "Restore original"))),

      script(appJs),
      script("if ('serviceWorker' in navigator && location.protocol === 'https:') " &
             "navigator.serviceWorker.register('sw.js');")))
