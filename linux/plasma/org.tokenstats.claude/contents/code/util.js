.pragma library

function fmtTokens(n) {
    if (n >= 1e6) return (n / 1e6).toFixed(1) + " M"
    if (n >= 1e3) return Math.round(n / 1e3) + " k"
    return String(n)
}

function fmtMoney(v) {
    return v.toLocaleString(Qt.locale(), "f", 2) + " $"
}

function duration(secs) {
    secs = Math.floor(secs)
    var d = Math.floor(secs / 86400), h = Math.floor(secs % 86400 / 3600), m = Math.floor(secs % 3600 / 60)
    if (d) return h ? d + " d " + h + " h" : d + " d"
    return h ? h + " h " + m + " min" : m + " min"
}

function limitState(l) {
    // elapsed share of the window, and the gap between used share and elapsed share in seconds
    var left = l.reset ? (Date.parse(l.reset) - Date.now()) / 1000 : -1
    if (left < 0) return { elapsed: -1, gap: 0, left: 0 }
    var elapsed = 1 - left / l.window
    return { elapsed: elapsed, gap: (l.pct / 100 - elapsed) * l.window, left: left }
}

// usage: [{date, models:[{model,in,out,cache,value}]}] (oldest first, last = today); n = number of days
function aggregate(usage, n, locale) {
    var days = usage.slice(Math.max(0, usage.length - n))
    var perModel = {}, series = [], total = 0, cache = 0, value = 0, unpriced = false
    for (var i = 0; i < days.length; i++) {
        var d = days[i], dayTokens = 0
        for (var j = 0; j < d.models.length; j++) {
            var m = d.models[j]
            var acc = perModel[m.model] || (perModel[m.model] = { model: m.model, in: 0, out: 0, cache: 0, value: 0, priced: true })
            acc.in += m.in; acc.out += m.out; acc.cache += m.cache
            if (m.value === null) { acc.priced = false; unpriced = true } else { acc.value += m.value; value += m.value }
            dayTokens += m.in + m.out + m.cache
            total += m.in + m.out + m.cache
            cache += m.cache
        }
        var dt = new Date(d.date + "T12:00:00")
        series.push({ label: n <= 7 ? locale.dayName(dt.getDay(), 1).substring(0, 2) : String(dt.getDate()),
                      tokens: dayTokens, last: i === days.length - 1 })
    }
    var models = Object.keys(perModel).map(function (k) { return perModel[k] })
    models.sort(function (a, b) { return (b.in + b.out + b.cache) - (a.in + a.out + a.cache) })
    return { total: total, cache: cache, value: value, unpriced: unpriced, models: models, series: series }
}

// Monospace-Befehl -> Zeilen mit höchstens maxChars Zeichen, Folgezeilen um indent Leerzeichen eingerückt
// (zählt mit). Bruch am letzten passenden Leerzeichen, sonst nach dem letzten „=“, sonst nach dem letzten „/“,
// sonst nach „- _ . :“, sonst hart. Ein „.“, mit dem ein Ordnername beginnt (am Tokenanfang oder direkt nach
// „/“, „=“, „~“), ist kein Bruchpunkt. Dieselbe Regel wie wrap_command in backend.py und gtk/tokenstats.py
// (linux/tests prüft beide gleich).
var COMMAND_BREAK_RANKS = ["=", "/", "-_.:"]

function commandBreak(text, limit) {
    for (var r = 0; r < COMMAND_BREAK_RANKS.length; r++) {
        for (var i = Math.min(limit, text.length) - 1; i >= 0; i--) {
            var c = text[i]
            if (COMMAND_BREAK_RANKS[r].indexOf(c) >= 0 && !(c === "." && (i === 0 || "/=~ ".indexOf(text[i - 1]) >= 0)))
                return i + 1
        }
    }
    return limit
}

function wrapCommand(command, maxChars, indent) {
    if (indent === undefined) indent = 2
    var text = String(command).split(/\s+/).filter(function (t) { return t.length > 0 }).join(" ")
    maxChars = Math.max(1, Math.floor(maxChars) || 1)
    indent = Math.max(0, Math.min(indent, maxChars - 1))
    var pad = new Array(indent + 1).join(" ")
    var lines = [], first = true
    while (text.length) {
        var limit = first ? maxChars : maxChars - indent
        var line
        if (text.length <= limit) {
            line = text; text = ""
        } else {
            var cut = text.lastIndexOf(" ", limit)
            if (cut > 0) {
                line = text.substring(0, cut); text = text.substring(cut + 1)
            } else {
                cut = commandBreak(text, limit)
                line = text.substring(0, cut); text = text.substring(cut)
            }
        }
        lines.push(first ? line : pad + line)
        text = text.replace(/^ +/, "")
        first = false
    }
    return lines
}

// Text-Teil mit Segmenten aus inline_parts (backend.py): kurze Befehle stehen im Satz in Monospace.
function hasMono(segments) {
    if (!segments) return false
    for (var i = 0; i < segments.length; i++)
        if (segments[i].mono) return true
    return false
}

function segmentsRich(segments) {
    return segments.map(function (seg) {
        var text = String(seg.text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        return seg.mono ? '<span style="font-family: monospace">' + text + "</span>" : text
    }).join(" ")
}
