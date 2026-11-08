import Foundation

/// Enkel HTML-tolker for innholdet instansene sender (Markdown som serveren har gjort om til HTML).
/// Direkte overført fra Android-appen (HtmlParse.kt). Posisjonene er i UTF-16-enheter.
enum HtmlMark: Equatable {
    case bold, italic, strike, underline, code, codeBlock, quote
    /// Listepunkt, nummer og sitatstrek.
    case marker
    case sup, sub
    case heading(Int)
    case link(String)
}

struct MarkRange {
    let mark: HtmlMark
    let start: Int
    var end: Int
}

/// Innrykk for én linje i em: [first] for første visuelle linje, [rest] for linjer som brytes.
struct LineIndent {
    let start: Int
    var end: Int
    let first: Double
    let rest: Double
}

struct ParsedHtml {
    let text: String
    let marks: [MarkRange]
    let indents: [LineIndent]
}

// MARK: Regulære uttrykk

func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: options)
}

extension NSRegularExpression {
    func all(_ s: String) -> [NSTextCheckingResult] {
        matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    func first(_ s: String) -> NSTextCheckingResult? {
        firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    func test(_ s: String) -> Bool { first(s) != nil }

    func replace(_ s: String, with template: String) -> String {
        stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}

extension NSTextCheckingResult {
    func group(_ i: Int, in s: String) -> String? {
        let r = range(at: i)
        return r.location == NSNotFound ? nil : (s as NSString).substring(with: r)
    }
}

private let tokenRegex = re(#"<!--.*?-->|<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:[^>"']|"[^"]*"|'[^']*')*)>"#, [.dotMatchesLineSeparators])
private let attrRegex = re(#"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
private let entityRegex = re(#"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);"#)
// Som Javas \s: bare vanlige mellomromstegn (ikke hardt mellomrom)
private let whitespace = re("[ \\t\\n\\u000B\\f\\r]+")

private let namedEntities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»",
    "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®",
    "trade": "™", "times": "×", "middot": "·", "bull": "•", "shy": "\u{00AD}",
    "zwj": "\u{200D}", "zwnj": "\u{200C}",
]

func decodeEntities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    let ns = s as NSString
    var out = ""
    var last = 0
    for m in entityRegex.all(s) {
        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        let e = ns.substring(with: m.range(at: 1))
        var rep: String?
        if e.hasPrefix("#x") || e.hasPrefix("#X") {
            rep = Int(e.dropFirst(2), radix: 16).flatMap(codePoint)
        } else if e.hasPrefix("#") {
            rep = Int(e.dropFirst()).flatMap(codePoint)
        } else {
            rep = namedEntities[e]
        }
        out += rep ?? ns.substring(with: m.range)
        last = m.range.location + m.range.length
    }
    out += ns.substring(from: last)
    return out
}

private func codePoint(_ cp: Int) -> String? {
    guard cp >= 1, cp <= 0x10FFFF, !(0xD800...0xDFFF).contains(cp), let u = Unicode.Scalar(cp) else { return nil }
    return String(Character(u))
}

/// Mellomrom etter listemarkøren (en-space, alltid 0,5 em bred).
private let markerGap = "\u{2002}"
private let bulletEm = 0.85
/// Innrykk før markøren for hvert listenivå.
private let levelEm = 0.9
private let quoteBar = "▍ "
private let quoteEm = 0.9

private func numberEm(_ label: String) -> Double { 0.56 * Double(label.count - 1) + 0.75 }

private final class ListCtx {
    let ordered: Bool
    var counter: Int
    /// Bredden på markøren til gjeldende punkt, brukt som hengende innrykk.
    var markerEm = bulletEm
    init(ordered: Bool, counter: Int) {
        self.ordered = ordered
        self.counter = counter
    }
}

private final class OpenMark {
    let tag: String
    let mark: HtmlMark?
    var start: Int
    init(_ tag: String, _ mark: HtmlMark?) {
        self.tag = tag
        self.mark = mark
        start = -1
    }
}

private let newlineChar: unichar = 10

private final class HtmlBuilder {
    let out = NSMutableString()
    var marks: [MarkRange] = []
    var indents: [LineIndent] = []

    private var open: [OpenMark] = []
    private var lists: [ListCtx] = []
    private var liDepth = 0
    private var quoteDepth = 0
    private var preDepth = 0
    private var pendingBreak = 0
    private var pendingSpace = false
    private var pendingMarker: String?
    private var atLineStart = true
    private var lineStart = 0
    private var lineFirst = 0.0
    private var lineRest = 0.0
    private var skipPreNewline = false
    private var skipDepth = 0

    func text(_ raw: String) {
        if skipDepth > 0 { return }
        var s = decodeEntities(raw)
        if preDepth > 0 {
            if skipPreNewline {
                skipPreNewline = false
                if s.hasPrefix("\r") { s.removeFirst() }
                if s.hasPrefix("\n") { s.removeFirst() }
            }
            let parts = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            for (i, part) in parts.enumerated() {
                if i > 0 {
                    flushBreak()
                    if atLineStart && out.length > 0 { beginLine() }
                    newline()
                }
                if !part.isEmpty { write(part) }
            }
            return
        }
        s = whitespace.replace(s, with: " ")
        if s.isEmpty { return }
        if s.hasPrefix(" ") {
            pendingSpace = true
            s.removeFirst()
        }
        let trailing = s.hasSuffix(" ")
        if trailing { s.removeLast() }
        if !s.isEmpty { write(s) }
        if trailing { pendingSpace = true }
    }

    func startTag(_ tag: String, _ attrs: [String: String]) {
        if skipDepth > 0 {
            if tag == "script" || tag == "style" { skipDepth += 1 }
            return
        }
        switch tag {
        case "script", "style": skipDepth += 1
        case "br": lineBreak()
        case "p", "div": requestBreak(blockGap())
        case "h1", "h2", "h3", "h4", "h5", "h6":
            requestBreak(blockGap())
            push(tag, .heading(Int(String(tag.last!)) ?? 1))
        case "ul", "ol":
            requestBreak(liDepth > 0 ? 1 : blockGap())
            let start = tag == "ol" ? (attrs["start"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1) : 1
            lists.append(ListCtx(ordered: tag == "ol", counter: start))
        case "li":
            requestBreak(1)
            let list = lists.last
            let label: String
            if let list {
                if list.ordered {
                    label = "\(list.counter)."
                    list.counter += 1
                } else {
                    label = lists.count % 2 == 0 ? "◦" : "•"
                }
                list.markerEm = list.ordered ? numberEm(label) : bulletEm
            } else {
                label = "•"
            }
            pendingMarker = label + markerGap
            liDepth += 1
        case "blockquote":
            requestBreak(blockGap())
            quoteDepth += 1
            push(tag, .quote)
        case "pre":
            requestBreak(blockGap())
            preDepth += 1
            skipPreNewline = true
            push(tag, .codeBlock)
        case "hr":
            requestBreak(blockGap())
            write("──────────", extra: .marker)
            requestBreak(blockGap())
        case "img":
            if let alt = attrs["alt"], !alt.trimmingCharacters(in: .whitespaces).isEmpty { text(alt) }
        case "a": push(tag, attrs["href"].map { .link(decodeEntities($0)) })
        case "b", "strong": push(tag, .bold)
        case "i", "em", "cite", "var", "dfn": push(tag, .italic)
        case "s", "del", "strike": push(tag, .strike)
        case "u", "ins": push(tag, .underline)
        case "code", "tt", "kbd", "samp": push(tag, preDepth > 0 ? nil : .code)
        case "sup": push(tag, .sup)
        case "sub": push(tag, .sub)
        default: break
        }
    }

    func endTag(_ tag: String) {
        if skipDepth > 0 {
            if tag == "script" || tag == "style" { skipDepth -= 1 }
            return
        }
        switch tag {
        case "p", "div": requestBreak(blockGap())
        case "h1", "h2", "h3", "h4", "h5", "h6":
            pop(tag)
            requestBreak(blockGap())
        case "ul", "ol":
            if !lists.isEmpty { lists.removeLast() }
            pendingMarker = nil
            requestBreak(liDepth > 0 ? 1 : blockGap())
        case "li":
            if liDepth > 0 { liDepth -= 1 }
            pendingMarker = nil
            requestBreak(1)
        case "blockquote":
            pop(tag)
            requestBreak(blockGap())
            if quoteDepth > 0 { quoteDepth -= 1 }
        case "pre":
            pop(tag)
            if preDepth > 0 { preDepth -= 1 }
            skipPreNewline = false
            requestBreak(blockGap())
        default: pop(tag)
        }
    }

    func finish() -> ParsedHtml {
        if !atLineStart { recordLine(out.length) }
        while let m = open.popLast() { close(m) }
        // Som Kotlins trimEnd(): fjerner mellomrom og linjeskift på slutten
        var len = out.length
        while len > 0 {
            let c = out.character(at: len - 1)
            if c == 32 || c == 10 || c == 9 || c == 13 || c == 11 || c == 12 { len -= 1 } else { break }
        }
        let text = out.substring(to: len)
        let m = marks.compactMap { r -> MarkRange? in
            var x = r
            x.end = min(r.end, len)
            return x.end > x.start ? x : nil
        }
        let ind = indents.compactMap { r -> LineIndent? in
            var x = r
            x.end = min(r.end, len)
            return x.end > x.start ? x : nil
        }
        return ParsedHtml(text: text, marks: m, indents: ind)
    }

    /// Avstand mellom blokker: tom linje, unntatt inne i lister der det holder med linjeskift.
    private func blockGap() -> Int { liDepth > 0 ? 1 : 2 }

    private func requestBreak(_ n: Int) {
        pendingSpace = false
        if n > pendingBreak { pendingBreak = n }
    }

    private func lineBreak() {
        flushBreak()
        if out.length == 0 && pendingMarker == nil { return }
        if atLineStart { beginLine() }
        newline()
    }

    private func push(_ tag: String, _ mark: HtmlMark?) {
        open.append(OpenMark(tag, mark))
    }

    private func pop(_ tag: String) {
        guard let i = open.lastIndex(where: { $0.tag == tag }) else { return }
        // Lukker også tagger som ble stående åpne inni (feilnøstet HTML)
        while open.count > i { close(open.removeLast()) }
    }

    private func close(_ m: OpenMark) {
        if let mark = m.mark, m.start >= 0, out.length > m.start {
            marks.append(MarkRange(mark: mark, start: m.start, end: out.length))
        }
    }

    private func flushBreak() {
        if pendingBreak == 0 { return }
        if out.length == 0 {
            pendingBreak = 0
            return
        }
        var existing = 0
        while existing < out.length && out.character(at: out.length - 1 - existing) == newlineChar { existing += 1 }
        if !atLineStart {
            newline()
            existing = 1
        }
        if pendingBreak - existing > 0 {
            for _ in 0..<(pendingBreak - existing) { newline() }
        }
        pendingBreak = 0
    }

    private func write(_ s: String, extra: HtmlMark? = nil) {
        flushBreak()
        if atLineStart {
            beginLine()
        } else if pendingSpace {
            out.append(" ")
        }
        pendingSpace = false
        for m in open where m.start < 0 { m.start = out.length }
        let from = out.length
        out.append(s)
        if let extra { marks.append(MarkRange(mark: extra, start: from, end: out.length)) }
    }

    /// Starter en ny linje: innrykk for lister, sitatstreker og eventuelt listemarkør.
    private func beginLine() {
        atLineStart = false
        pendingSpace = false
        lineStart = out.length
        // Innrykk fra overordnede listepunkter; gjeldende punkt teller bare når linjen ikke har markør
        let ancestors = lists.dropLast().reduce(0.0) { $0 + levelEm + $1.markerEm }
        let current = lists.last
        var first = ancestors + (current != nil ? levelEm : 0)
        if let current, pendingMarker == nil, liDepth > 0 { first += current.markerEm }
        var rest = first
        for _ in 0..<quoteDepth {
            let s = out.length
            out.append(quoteBar)
            marks.append(MarkRange(mark: .marker, start: s, end: out.length))
            rest += quoteEm
        }
        if let marker = pendingMarker {
            let s = out.length
            out.append(marker)
            marks.append(MarkRange(mark: .marker, start: s, end: out.length))
            rest += current?.markerEm ?? bulletEm
            pendingMarker = nil
        }
        lineFirst = first
        lineRest = rest
    }

    private func newline() {
        if !atLineStart { recordLine(out.length) }
        out.append("\n")
        atLineStart = true
        pendingSpace = false
    }

    private func recordLine(_ end: Int) {
        if lineFirst > 0 || lineRest > 0 {
            indents.append(LineIndent(start: lineStart, end: end, first: lineFirst, rest: lineRest))
        }
    }
}

private let voidTags: Set<String> = ["br", "hr", "img"]

func parseHtml(_ html: String) -> ParsedHtml {
    let b = HtmlBuilder()
    let ns = html as NSString
    var last = 0
    for m in tokenRegex.all(html) {
        if m.range.location > last {
            b.text(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
        }
        last = m.range.location + m.range.length
        guard let rawName = m.group(2, in: html), !rawName.isEmpty else { continue } // kommentar
        let name = rawName.lowercased()
        if m.group(1, in: html) == "/" {
            b.endTag(name)
        } else {
            let attrText = m.group(3, in: html) ?? ""
            var attrs: [String: String] = [:]
            for a in attrRegex.all(attrText) {
                let key = (a.group(1, in: attrText) ?? "").lowercased()
                attrs[key] = a.group(2, in: attrText) ?? a.group(3, in: attrText) ?? a.group(4, in: attrText) ?? ""
            }
            b.startTag(name, attrs)
            let trimmed = attrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("/") && !voidTags.contains(name) { b.endTag(name) }
        }
    }
    if last < ns.length { b.text(ns.substring(from: last)) }
    return b.finish()
}

// MARK: - Emneknagger, lenkekort og nedkorting

private let tagPath = re(#"/(?:tags?|hashtag)/([^/?#]+)"#, [.caseInsensitive])

/// Hvis lenken er en emneknagg-lenke (teksten starter med «#» og adressen har /tag/ eller /tags/),
/// returneres navnet på emneknaggen – ellers nil.
func hashtagFromLink(_ url: String, label: String) -> String? {
    guard label.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { return nil }
    guard let m = tagPath.all(url).last, let raw = m.group(1, in: url) else { return nil }
    let decoded = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
    return decoded.trimmingCharacters(in: .whitespaces).isEmpty ? nil : decoded
}

private let htmlTag = re("<[^>]+>")
// «#» som ikke står inni et ord, en adresse eller en HTML-entitet (&#39;)
private let hashtagInText = re(#"(?<![\p{L}\p{N}_/&#])#([\p{L}\p{N}_]+)"#)

/// Emneknaggene i et innlegg, i rekkefølgen de står i teksten og med skrivemåten forfatteren brukte.
/// [known] er instansens liste; knagger der som ikke ble funnet i teksten legges til sist.
func hashtagsIn(_ html: String, known: [String]) -> [String] {
    let text = htmlTag.replace(html, with: "")
    let knownLower = Set(known.map { $0.lowercased() })
    let found = hashtagInText.all(text).compactMap { $0.group(1, in: text) }
        .filter { name in name.contains { !$0.isNumber } }
        .filter { knownLower.isEmpty || knownLower.contains($0.lowercased()) }
    var seen = Set<String>()
    return (found + known.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        .filter { seen.insert($0.lowercased()).inserted }
}

private let anchorRegex = re(#"<a\b[^>]*?\bhref=["']([^"']+)["'][^>]*>.*?</a>"#, [.dotMatchesLineSeparators, .caseInsensitive])
private let beforeOk = re(#"(?:^|<p>|<br\s*/?>)\s*$"#, [.caseInsensitive])
private let afterOk = re(#"^\s*(?:</p>|<br\s*/?>|$)"#, [.caseInsensitive])
private let trailingBr = re(#"(?:\s*<br\s*/?>)+\s*(?=</p>|$)"#, [.caseInsensitive])
private let emptyP = re(#"<p>\s*</p>"#, [.caseInsensitive])
private let leadingBr = re(#"^(?:\s*<br\s*/?>)+"#, [.caseInsensitive])
private let anyTag = re("<[^>]*>")

private func normUrl(_ u: String) -> String {
    var s = u.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespaces)
    while s.hasSuffix("/") { s.removeLast() }
    return s
}

/// Skjuler lenken som forhåndsvisningskortet viser – men kun når lenken står alene på sin
/// egen linje/avsnitt. Står den midt i en setning, beholdes den.
func stripCardLink(_ html: String, cardUrl: String) -> String {
    let target = normUrl(cardUrl)
    let ns = html as NSString
    for m in anchorRegex.all(html) {
        guard normUrl(m.group(1, in: html) ?? "") == target else { continue }
        let before = ns.substring(to: m.range.location)
        let after = ns.substring(from: m.range.location + m.range.length)
        if !beforeOk.test(before) || !afterOk.test(after) { return html }
        var out = trailingBr.replace(before + after, with: "")
        out = emptyP.replace(out, with: "")
        out = leadingBr.replace(out, with: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return html
}

/// True hvis HTML-en ikke inneholder synlig tekst.
func isBlankHtml(_ html: String) -> Bool {
    anyTag.replace(html, with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Grensen for når innlegg kortes ned med «Vis alt».
let collapseChars = 750

/// Hvor en tekst lengre enn [limit] tegn skal kuttes: ved siste linjeskift eller mellomrom før
/// grensen (så ord og emojikoder ikke deles), eller nil når teksten er kort nok. UTF-16-posisjoner.
func collapsePoint(_ text: String, limit: Int) -> Int? {
    let ns = text as NSString
    guard ns.length > limit else { return nil }
    func lastIndex(of ch: String) -> Int {
        let r = ns.range(of: ch, options: .backwards, range: NSRange(location: 0, length: limit + 1))
        return r.location == NSNotFound ? -1 : r.location
    }
    func trimmedLen(_ i: Int) -> Int {
        (ns.substring(to: i) as String).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression).utf16.count
    }
    let nl = lastIndex(of: "\n")
    if nl >= limit * 2 / 3 { return trimmedLen(nl) }
    let sp = lastIndex(of: " ")
    return sp >= limit / 2 ? trimmedLen(sp) : limit
}

/// Finner omtalen en lenke peker på: først på adresse, deretter på «@navn» / «@navn@domene».
func mentionFor(_ url: String, linkText: String, mentions: [Mention]) -> Mention? {
    if let m = mentions.first(where: { $0.url == url }) { return m }
    var name = linkText.trimmingCharacters(in: .whitespaces)
    if name.hasPrefix("@") { name.removeFirst() }
    if name.isEmpty { return nil }
    if let m = mentions.first(where: { $0.acct.caseInsensitiveCompare(name) == .orderedSame }) { return m }
    let user = name.split(separator: "@").first.map(String.init) ?? name
    let candidates = mentions.filter { $0.username.caseInsensitiveCompare(user) == .orderedSame }
    return candidates.count == 1 ? candidates[0] : nil
}
