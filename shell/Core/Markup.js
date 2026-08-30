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
  line = line.replace(/(https?:\/\/[^\s<]+)/g, function (url) {
    return '<span style="color:' + palette.link + '"><u>' + url + "</u></span>"
  })

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
