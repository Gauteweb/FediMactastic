import AppKit
import SwiftUI

/// Hva som skjer når man klikker på #emneknagger og @omtaler i tekst.
struct LinkHandler {
    var openTag: (String) -> Void = { _ in }
    /// Konto-ID hvis den er kjent, ellers lenken (slås opp via instansen).
    var openProfile: (String?, String) -> Void = { _, url in openExternal(url) }
}

private struct LinkHandlerKey: EnvironmentKey {
    static let defaultValue = LinkHandler()
}

extension EnvironmentValues {
    var linkHandler: LinkHandler {
        get { self[LinkHandlerKey.self] }
        set { self[LinkHandlerKey.self] = newValue }
    }
}

/// Fargen på en tekst, slått opp i temaet når den tegnes.
enum Tone: String {
    case text, muted, fgText, topBarText, link

    var hex: HexColor {
        let c = PT.c
        switch self {
        case .text: return c.text
        case .muted: return HexColor((c.fgText.argb & 0x00FFFFFF) | 0xA6000000)
        case .fgText: return c.fgText
        case .topBarText: return c.topBarText
        case .link: return c.link
        }
    }
}

private let emojiRegex = re(":([A-Za-z0-9_\\-]+):")

/// Bygger tekst med stiler, lenker og egendefinerte emojier.
@MainActor
enum RichBuilder {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 600
        return c
    }()

    static func emojiStamp(_ text: String, _ emojis: [Emoji]) -> Int {
        emojis.filter { text.contains(":\($0.shortcode):") && ImageCache.shared.cached(emojiUrl($0), maxPixel: 128) != nil }.count
    }

    static func emojiUrl(_ e: Emoji) -> String { e.url.isEmpty ? e.staticUrl : e.url }

    private static func paragraph(_ size: CGFloat) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = size * 0.22
        return p
    }

    /// HTML fra et innlegg eller en profil.
    static func html(_ html: String, emojis: [Emoji], mentions: [Mention], size: CGFloat, tone: Tone, bold: Bool = false) -> NSAttributedString {
        let key = "h|\(ThemeManager.shared.theme.rawValue)|\(size)|\(tone.rawValue)|\(bold)|\(emojiStamp(html, emojis))|\(mentions.map(\.url).joined(separator: ","))|\(html)" as NSString
        if let c = cache.object(forKey: key) { return c }
        let result = buildHtml(html, emojis: emojis, mentions: mentions, size: size, tone: tone, bold: bold)
        cache.setObject(result, forKey: key)
        return result
    }

    /// Vanlig tekst (f.eks. visningsnavn) som kan inneholde :emoji:-koder.
    static func plain(_ text: String, emojis: [Emoji], size: CGFloat, tone: Tone, bold: Bool = false) -> NSAttributedString {
        let key = "p|\(ThemeManager.shared.theme.rawValue)|\(size)|\(tone.rawValue)|\(bold)|\(emojiStamp(text, emojis))|\(text)" as NSString
        if let c = cache.object(forKey: key) { return c }
        let font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: tone.hex.ns, .paragraphStyle: paragraph(size),
        ])
        insertEmojis(attr, emojis: emojis, size: size)
        cache.setObject(attr, forKey: key)
        return attr
    }

    private static func buildHtml(_ html: String, emojis: [Emoji], mentions: [Mention], size: CGFloat, tone: Tone, bold: Bool) -> NSAttributedString {
        var cleaned = re("<span class=\"invisible\">.*?</span>", [.dotMatchesLineSeparators]).replace(html, with: "")
        cleaned = re("<span class=\"ellipsis\">(.*?)</span>", [.dotMatchesLineSeparators]).replace(cleaned, with: "$1…")
        let parsed = parseHtml(cleaned)
        let plain = parsed.text as NSString
        let baseFont = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        let linkColor = PT.c.link.ns
        let attr = NSMutableAttributedString(string: parsed.text, attributes: [
            .font: baseFont, .foregroundColor: tone.hex.ns, .paragraphStyle: paragraph(size),
        ])
        let full = attr.length

        func valid(_ s: Int, _ e: Int) -> NSRange? {
            guard s >= 0, e <= full, e > s else { return nil }
            return NSRange(location: s, length: e - s)
        }

        for ind in parsed.indents {
            guard let r = valid(ind.start, ind.end) else { continue }
            let p = paragraph(size)
            p.firstLineHeadIndent = CGFloat(ind.first) * size
            p.headIndent = CGFloat(ind.rest) * size
            attr.addAttribute(.paragraphStyle, value: p, range: r)
        }

        func addTrait(_ trait: NSFontTraitMask, _ r: NSRange) {
            attr.enumerateAttribute(.font, in: r) { value, sub, _ in
                let f = (value as? NSFont) ?? baseFont
                attr.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: trait), range: sub)
            }
        }

        for m in parsed.marks {
            guard let r = valid(m.start, m.end) else { continue }
            switch m.mark {
            case .link(let url):
                let linkText = plain.substring(with: r)
                let tag = hashtagFromLink(url, label: linkText)
                var target: URL?
                if tag == nil && (linkText.hasPrefix("@") || mentions.contains { $0.url == url }) {
                    // @omtaler åpner profilen i appen (via egen instans) i stedet for nettsiden
                    let id = mentionFor(url, linkText: linkText, mentions: mentions)?.id ?? ""
                    target = URL(string: "fmprofile://open?id=\(urlEncode(id))&url=\(urlEncode(url))")
                } else if let tag {
                    // Emneknagger åpnes i appen i stedet for i nettleseren
                    target = URL(string: "fmtag://open?tag=\(urlEncode(tag))")
                } else {
                    target = URL(string: url) ?? URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
                }
                if let target { attr.addAttribute(.link, value: target, range: r) }
            case .bold: addTrait(.boldFontMask, r)
            case .italic, .quote: addTrait(.italicFontMask, r)
            case .strike: attr.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .underline: attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .code, .codeBlock:
                attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular), range: r)
                attr.addAttribute(.backgroundColor, value: linkColor.withAlphaComponent(0.14), range: r)
            case .marker:
                attr.addAttribute(.foregroundColor, value: linkColor, range: r)
                addTrait(.boldFontMask, r)
            case .sup:
                attr.addAttribute(.font, value: NSFont.systemFont(ofSize: size * 0.75), range: r)
                attr.addAttribute(.baselineOffset, value: size * 0.35, range: r)
            case .sub:
                attr.addAttribute(.font, value: NSFont.systemFont(ofSize: size * 0.75), range: r)
                attr.addAttribute(.baselineOffset, value: -size * 0.2, range: r)
            case .heading(let level):
                let mult: CGFloat = level == 1 ? 1.3 : level == 2 ? 1.2 : level == 3 ? 1.1 : 1
                attr.addAttribute(.font, value: NSFont.systemFont(ofSize: size * mult, weight: .bold), range: r)
            }
        }
        insertEmojis(attr, emojis: emojis, size: size)
        return attr
    }

    /// Bytter :kortkode: ut med instansens emojibilde (når det er hentet).
    private static func insertEmojis(_ attr: NSMutableAttributedString, emojis: [Emoji], size: CGFloat) {
        guard !emojis.isEmpty else { return }
        var byCode: [String: Emoji] = [:]
        for e in emojis { byCode[e.shortcode] = e }
        let text = attr.string
        for m in emojiRegex.all(text).reversed() {
            guard let code = m.group(1, in: text), let e = byCode[code] else { continue }
            let h = size * 1.3
            let att = NSTextAttachment()
            if let img = ImageCache.shared.cached(emojiUrl(e), maxPixel: 128) {
                att.image = img.nsImage
                let w = min(h * CGFloat(img.aspect), h * 3)
                att.bounds = CGRect(x: 0, y: -size * 0.3, width: w, height: h)
            } else {
                att.image = NSImage(size: NSSize(width: h, height: h))
                att.bounds = CGRect(x: 0, y: -size * 0.3, width: h, height: h)
            }
            var attrs = attr.attributes(at: m.range.location, effectiveRange: nil)
            attrs[.attachment] = att
            let replacement = NSMutableAttributedString(attributedString: NSAttributedString(attachment: att))
            replacement.addAttributes(attrs, range: NSRange(location: 0, length: replacement.length))
            attr.replaceCharacters(in: m.range, with: replacement)
        }
    }

    /// Henter emojibildene som trengs for [text]. Gir true hvis noe nytt ble hentet.
    static func loadEmojis(_ text: String, _ emojis: [Emoji]) async -> Bool {
        var loaded = false
        for e in emojis where text.contains(":\(e.shortcode):") {
            let url = emojiUrl(e)
            if ImageCache.shared.cached(url, maxPixel: 128) == nil, await ImageCache.shared.load(url, maxPixel: 128) != nil {
                loaded = true
            }
        }
        return loaded
    }
}

/// Behandler et klikk på en lenke i teksten.
@MainActor
func handleLink(_ url: URL, _ links: LinkHandler) {
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    func q(_ name: String) -> String? { comps?.queryItems?.first { $0.name == name }?.value }
    switch url.scheme {
    case "fmtag":
        if let tag = q("tag") { links.openTag(tag) }
    case "fmprofile":
        let id = q("id").flatMap { $0.isEmpty ? nil : $0 }
        links.openProfile(id, q("url") ?? "")
    default:
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Visning

final class RichNSTextView: NSTextView {
    var onTap: (() -> Void)?
    var onLink: ((URL) -> Void)?
    var shown: NSAttributedString?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let url = link(at: p) {
            onLink?(url)
            return
        }
        guard let onTap else {
            super.mouseDown(with: event)
            return
        }
        // Dra for å markere tekst; et vanlig klikk åpner innlegget (som et trykk på kortet)
        super.mouseDown(with: event)
        if selectedRange().length == 0 && event.clickCount == 1 { onTap() }
    }

    private func link(at p: NSPoint) -> URL? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let pt = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        var frac: CGFloat = 0
        let idx = lm.characterIndex(for: pt, in: tc, fractionOfDistanceBetweenInsertionPoints: &frac)
        guard idx < storage.length else { return nil }
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: idx, length: 1), actualCharacterRange: nil)
        guard lm.boundingRect(forGlyphRange: glyphs, in: tc).contains(pt) else { return nil }
        return storage.attribute(.link, at: idx, effectiveRange: nil) as? URL
    }
}

/// Tekst med stiler, lenker og emojier (TextKit), som kan markeres og kopieres.
struct RichTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    var maxLines = 0
    var onTap: (() -> Void)? = nil
    @Environment(\.linkHandler) private var links

    func makeNSView(context: Context) -> RichNSTextView {
        let tv = RichNSTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateNSView(_ tv: RichNSTextView, context: Context) {
        let links = self.links
        tv.onTap = onTap
        tv.onLink = { url in handleLink(url, links) }
        tv.linkTextAttributes = [
            .foregroundColor: PT.c.link.ns,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        if let tc = tv.textContainer {
            tc.maximumNumberOfLines = maxLines
            tc.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
        }
        if tv.shown !== attributed {
            tv.shown = attributed
            tv.textStorage?.setAttributedString(attributed)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: RichNSTextView, context: Context) -> CGSize? {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let w = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        tc.containerSize = NSSize(width: w ?? 100_000, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return CGSize(width: w ?? ceil(used.width), height: max(ceil(used.height), 1))
    }
}

/// HTML-innhold fra et innlegg eller en profil.
struct RichText: View {
    let html: String
    let emojis: [Emoji]
    var mentions: [Mention] = []
    var size: CGFloat = PF.body
    var tone: Tone = .fgText
    var maxLines = 0
    /// Tekst lengre enn dette kortes ned med en «Vis alt»-knapp (nil = vis alt).
    var collapseAfter: Int? = nil
    var onTap: (() -> Void)? = nil

    @ViewState private var expanded = false
    @ViewState private var emojiTick = 0

    var body: some View {
        let _ = emojiTick
        let full = RichBuilder.html(html, emojis: emojis, mentions: mentions, size: size, tone: tone)
        let cut = collapseAfter.flatMap { collapsePoint(full.string, limit: $0) }
        Group {
            if let cut {
                VStack(alignment: .leading, spacing: 6) {
                    RichTextView(attributed: expanded ? full : truncated(full, cut), onTap: onTap)
                    PButton(text: L(expanded ? "read_less" : "read_more")) { expanded.toggle() }
                }
            } else {
                RichTextView(attributed: full, maxLines: maxLines, onTap: onTap)
            }
        }
        .task(id: html) {
            if await RichBuilder.loadEmojis(html, emojis) { emojiTick += 1 }
        }
    }

    private func truncated(_ full: NSAttributedString, _ cut: Int) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: full.attributedSubstring(from: NSRange(location: 0, length: cut)))
        let attrs = cut > 0 ? full.attributes(at: cut - 1, effectiveRange: nil).filter { $0.key != .link && $0.key != .attachment } : [:]
        m.append(NSAttributedString(string: " …", attributes: attrs))
        return m
    }
}

/// Vanlig tekst (f.eks. visningsnavn) som kan inneholde :emoji:-koder.
struct EmojiText: View {
    let text: String
    let emojis: [Emoji]
    var size: CGFloat = PF.body
    var tone: Tone = .fgText
    var bold = false
    var maxLines = 0
    var onTap: (() -> Void)? = nil

    @ViewState private var emojiTick = 0

    var body: some View {
        let _ = emojiTick
        Group {
            if emojis.isEmpty || !text.contains(":") {
                // Uten emojier holder det med vanlig SwiftUI-tekst
                Text(text)
                    .font(.system(size: size, weight: bold ? .bold : .regular))
                    .foregroundStyle(tone.hex.color)
                    .lineLimit(maxLines > 0 ? maxLines : nil)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .if(onTap != nil) { $0.onTapGesture { onTap?() } }
            } else {
                RichTextView(
                    attributed: RichBuilder.plain(text, emojis: emojis, size: size, tone: tone, bold: bold),
                    maxLines: maxLines, onTap: onTap
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: text) {
            if await RichBuilder.loadEmojis(text, emojis) { emojiTick += 1 }
        }
    }
}
