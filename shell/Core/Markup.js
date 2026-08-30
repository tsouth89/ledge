.pragma library

// Inline markdown styling for a plain-text note.
//
// The rule that governs everything here: the output must contain exactly the
// same characters as the input, in the same order. This layer is painted behind
// a transparent editor holding the real text, so if a single character changes
// width the caret drifts away from the glyph it is supposed to be sitting next
// to. That is why markers are dimmed rather than hidden, why `- [ ]` is not
// swapped for a nicer checkbox glyph, and why headings change weight and colour
// but never size.
//
// It also means bold has to occupy the same advance width as regular, which is
// true in a monospaced face and not in a proportional one. Styling is a
// per-note and per-config switch for exactly that reason.

function escapeHtml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

// Where the bare URLs are in a string.
//
// One definition, used both to underline a link and to decide what a click
// landed on, so what looks like a link and what actually opens can never
// disagree.
var URL_PATTERN = /https?:\/\/[^\s<>"']+/g

function countChar(text, ch) {
  var n = 0
  for (var i = 0; i < text.length; i++) if (text.charAt(i) === ch) n++
  return n
}

// Trailing punctuation is not part of the link. "see https://x.com." should not
// open a URL with the full stop on the end of it.
//
// A closing bracket is the exception: it only counts as punctuation when the
// URL did not open one itself, so `en.wikipedia.org/wiki/Foo_(bar)` keeps its
// brackets while `(see https://x.com)` does not steal the sentence's.
function trimUrl(url) {
  var pairs = { ")": "(", "]": "[", "}": "{" }
  while (url.length) {
    var last = url.charAt(url.length - 1)
    if (".,;:!?'\"".indexOf(last) >= 0) { url = url.slice(0, -1); continue }
    if (pairs[last]) {
      if (countChar(url, pairs[last]) >= countChar(url, last)) break
      url = url.slice(0, -1)
      continue
    }
    break
  }
  return url
}

function urlSpans(text) {
  var out = []
  var s = String(text || "")
  var m
  URL_PATTERN.lastIndex = 0
  while ((m = URL_PATTERN.exec(s)) !== null) {
    var url = trimUrl(m[0])
    if (url.length) out.push({ start: m.index, end: m.index + url.length, url: url })
  }
  return out
}

// The URL covering a character index, or "" if the index is not on one. The
// end is inclusive, so a click just past the last character still counts --
// that is where the caret lands when you click the right half of a glyph.
function urlAt(text, index) {
  var spans = urlSpans(text)
  for (var i = 0; i < spans.length; i++)
    if (index >= spans[i].start && index <= spans[i].end) return spans[i].url
  return ""
}

function dim(color, text) {
  return '<span style="color:' + color + '">' + text + "</span>"
}

// Wrap the delimiters in a dimmed span and the content in `tag`, so the syntax
// stays visible but recedes.
function inlineRule(line, pattern, tag, marker) {
  return line.replace(pattern, function (_, open, body, close) {
    return dim(marker, open) + "<" + tag + ">" + body + "</" + tag + ">" + dim(marker, close)
  })
}

function styleLine(raw, palette) {
  var line = escapeHtml(raw)

  // Task list marker. Ticked items get their text struck through, which is the
  // one place a whole line changes appearance rather than a span.
  var task = line.match(/^(\s*[-*]\s*\[)([ xX])(\]\s?)([\s\S]*)$/)
  if (task) {
    var done = task[2] !== " "
    var box = dim(done ? palette.accent : palette.marker, task[1] + task[2] + task[3])
    var rest = task[4]
    if (done) rest = '<span style="color:' + palette.marker + '"><s>' + rest + "</s></span>"
    return box + styleInline(rest, palette)
  }

  // Heading. Weight and colour only; changing the size would break alignment.
  var heading = line.match(/^(\s*#{1,6}\s+)([\s\S]*)$/)
  if (heading) {
    return dim(palette.marker, heading[1])
         + '<b><span style="color:' + palette.strong + '">'
         + styleInline(heading[2], palette) + "</span></b>"
  }

  // Bullet and quote markers.
  var bullet = line.match(/^(\s*(?:[-*+]|\d+\.)\s+)([\s\S]*)$/)
  if (bullet) return dim(palette.marker, bullet[1]) + styleInline(bullet[2], palette)

  var quote = line.match(/^(\s*&gt;\s?)([\s\S]*)$/)
  if (quote) {
    return dim(palette.marker, quote[1])
         + '<span style="color:' + palette.marker + '"><i>'
         + styleInline(quote[2], palette) + "</i></span>"
  }

  return styleInline(line, palette)
}

function styleInline(line, palette) {
  // Bare URLs, before anything else can chew on the punctuation in them.
  var spans = urlSpans(line)
  if (spans.length) {
    var woven = ""
    var at = 0
    for (var s = 0; s < spans.length; s++) {
      woven += line.slice(at, spans[s].start)
             + '<span style="color:' + palette.link + '"><u>' + spans[s].url + "</u></span>"
      at = spans[s].end
    }
    line = woven + line.slice(at)
  }

  // Markers must sit against a non-space character, so `2 * 3 * 4` and a lone
  // asterisk are left alone. Nothing matches across a line break.
  line = inlineRule(line, /(\*\*)(\S(?:[^*\n]*\S)?)(\*\*)/g, "b", palette.marker)
  line = inlineRule(line, /(__)(\S(?:[^_\n]*\S)?)(__)/g, "b", palette.marker)
  line = inlineRule(line, /(~~)(\S(?:[^~\n]*\S)?)(~~)/g, "s", palette.marker)
  // Single-asterisk italics runs after the double-asterisk pass, so `**x**`
  // has already been consumed and cannot be mistaken for two italic markers.
  line = line.replace(/(\*)(\S(?:[^*\n]*\S)?)(\*)/g, function (_, o, b, c) {
    return dim(palette.marker, o) + "<i>" + b + "</i>" + dim(palette.marker, c)
  })
  line = line.replace(/(`)([^`\n]+)(`)/g, function (_, o, b, c) {
    return dim(palette.marker, o)
         + '<span style="color:' + palette.code + '">' + b + "</span>"
         + dim(palette.marker, c)
  })
  return line
}

// Whitespace is preserved by the caller's white-space:pre-wrap, so lines are
// joined with a plain newline rather than <br>, which would add height.
function toHtml(text, palette) {
  var lines = String(text || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) out.push(styleLine(lines[i], palette))
  return out.join("\n")
}
