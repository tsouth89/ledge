// Unit tests for shell/Core/Markup.js.
//
// This is the one part of Ledge that is plain JavaScript with no Qt in it, so
// it is the one part that can be tested without a Wayland session, a compositor
// or a window. That matters twice over: it runs in CI, where there is no
// display at all, and it runs without taking the keyboard away from whoever is
// at the machine.
//
// The file is QML's flavour of JS: it opens with `.pragma library`, which node
// cannot parse. Strip that one line and the rest is ordinary script.

const fs = require("fs")
const path = require("path")
const vm = require("vm")

const src = fs
  .readFileSync(path.join(__dirname, "..", "shell", "Core", "Markup.js"), "utf8")
  .replace(/^\s*\.pragma\s+library\s*$/m, "")

const M = {}
vm.createContext(M)
vm.runInContext(src, M, { filename: "Markup.js" })

let pass = 0
let fail = 0

function is(what, got, want) {
  if (got === want) {
    console.log("  \x1b[32mok\x1b[0m   " + what)
    pass++
  } else {
    console.log("  \x1b[31mFAIL\x1b[0m " + what)
    console.log("        expected " + JSON.stringify(want) + ", got " + JSON.stringify(got))
    fail++
  }
}

// Where the click lands matters more than anything else here: a link you can
// see but cannot open is the bug this function exists to prevent.
function urlUnder(text, needle) {
  return M.urlAt(text, text.indexOf(needle))
}

console.log("markup tests")

// ---------------------------------------------------------------- urlAt

is("a bare url is found from its first character",
   M.urlAt("https://example.com", 0), "https://example.com")

is("and from the middle of it",
   M.urlAt("see https://example.com now", 10), "https://example.com")

is("and from its last character",
   M.urlAt("https://example.com", 18), "https://example.com")

is("text either side of a url is not a link",
   M.urlAt("see https://example.com now", 1), "")

is("an index past the end of a url is not a link",
   M.urlAt("https://example.com now", 22), "")

is("http as well as https", urlUnder("go to http://x.test/a", "http://"), "http://x.test/a")

is("a bare word is not a url", M.urlAt("example.com", 3), "")

is("the second url on a line is its own link",
   urlUnder("https://one.test and https://two.test", "https://two"), "https://two.test")

is("no url at all", M.urlAt("just some words", 4), "")

is("an empty note has no links", M.urlAt("", 0), "")

// A URL only ever lives on one line, so a line break always ends one.
is("a url stops at a newline",
   M.urlAt("https://example.com\nmore text", 0), "https://example.com")

// ------------------------------------------------- trailing punctuation

is("a full stop ending the sentence is not part of the link",
   M.urlAt("see https://example.com.", 10), "https://example.com")

is("nor is a comma",
   M.urlAt("https://example.com, and then", 4), "https://example.com")

is("nor a question mark",
   M.urlAt("did you see https://example.com?", 20), "https://example.com")

is("a bracket the sentence opened is not part of the link",
   M.urlAt("(see https://example.com)", 10), "https://example.com")

// The case the naive version gets wrong.
is("a bracket the url opened is kept",
   M.urlAt("https://en.wikipedia.org/wiki/Foo_(bar)", 10),
   "https://en.wikipedia.org/wiki/Foo_(bar)")

is("a query string is kept whole",
   M.urlAt("https://x.test/a?b=1&c=2", 10), "https://x.test/a?b=1&c=2")

is("a trailing slash is kept",
   M.urlAt("https://x.test/a/", 5), "https://x.test/a/")

is("a fragment is kept",
   M.urlAt("https://x.test/a#section", 5), "https://x.test/a#section")

// ------------------------------------------------------------- styling

const palette = {
  marker: "#888888",
  accent: "#00ff00",
  link: "#0000ff",
  code: "#ff0000",
  heading: "#ffffff",
  quote: "#cccccc"
}

// The invariant the whole styling layer rests on: the visible characters must
// come out in the same order, or the caret drifts off the glyph it is sitting
// next to. Strip the tags and you must get the input back.
function visible(html) {
  return html
    .replace(/<[^>]*>/g, "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
}

const samples = [
  "plain text",
  "see https://example.com.",
  "(https://en.wikipedia.org/wiki/Foo_(bar))",
  "**bold** and *italic* and `code`",
  "- [ ] a task",
  "- [x] a done task",
  "# a heading",
  "> a quote",
  "a & b < c > d",
  "https://x.test/a?b=1&c=2",
  ""
]

let sameText = true
for (const sample of samples) {
  const got = visible(M.toHtml(sample, palette))
  if (got !== sample) {
    sameText = false
    console.log("        styling changed the text: " + JSON.stringify(sample)
                + " -> " + JSON.stringify(got))
  }
}
is("styling never changes the characters or their order", sameText, true)

is("a url is underlined",
   M.toHtml("https://example.com", palette).indexOf("<u>https://example.com</u>") >= 0, true)

is("and the full stop after it is not",
   M.toHtml("https://example.com.", palette).indexOf("<u>https://example.com</u>") >= 0, true)

console.log("")
if (fail) {
  console.log("\x1b[31m" + pass + " passed, " + fail + " failed\x1b[0m")
  process.exit(1)
}
console.log("\x1b[32m" + pass + " passed\x1b[0m")
