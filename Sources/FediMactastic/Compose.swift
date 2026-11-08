import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Hjelpefunksjoner for teksten (UTF-16-posisjoner, som i Android-appen)

/// Språkene som kan velges for et innlegg (ISO 639-1): Nynorsk, Bokmål og Engelsk.
let postLanguages = ["nn", "nb", "en"]

/// Gjør et språk fra serveren (f.eks. «nb-NO», «no», «EN») om til et av valgene, eller nil.
func normalizePostLanguage(_ code: String?) -> String? {
    guard let code else { return nil }
    let base = code.trimmingCharacters(in: .whitespaces).lowercased()
        .split(separator: "-").first.map(String.init)?
        .split(separator: "_").first.map(String.init) ?? ""
    let mapped = base == "no" ? "nb" : base
    return postLanguages.contains(mapped) ? mapped : nil
}

private func languageName(_ code: String) -> String {
    switch code {
    case "nn": return L("lang_nn")
    case "en": return L("lang_en")
    default: return L("lang_nb")
    }
}

private func visibilityLabel(_ v: String) -> String {
    switch v {
    case "unlisted": return L("vis_unlisted")
    case "private": return L("vis_private")
    case "direct": return L("vis_direct")
    default: return L("vis_public")
    }
}

/// «@navn» som er under skriving: [start] er posisjonen til @, [end] slutten av ordet, [query] teksten etter @.
struct MentionQuery: Equatable {
    let start: Int
    let end: Int
    let query: String
}

private func isHandleChar(_ c: unichar) -> Bool {
    guard let scalar = Unicode.Scalar(c) else { return false }
    if c == 95 || c == 46 || c == 45 || c == 64 { return true } // _ . - @
    return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
}

/// Finner nevnelsen markøren står i, f.eks. «@gau|» eller «@bob@mast|».
func mentionQueryAt(_ text: String, cursor: Int, selectionEnd: Int) -> MentionQuery? {
    let ns = text as NSString
    guard cursor == selectionEnd, cursor >= 0, cursor <= ns.length else { return nil }
    var start = cursor
    while start > 0 && isHandleChar(ns.character(at: start - 1)) { start -= 1 }
    var end = cursor
    while end < ns.length && isHandleChar(ns.character(at: end)) { end += 1 }
    guard start < ns.length, ns.character(at: start) == 64 else { return nil }
    // Ordet må starte med @, og vi søker først når noe er skrevet etter @
    let query = ns.substring(with: NSRange(location: start + 1, length: cursor - start - 1))
    if query.isEmpty || query.hasPrefix("@") { return nil }
    return MentionQuery(start: start, end: end, query: query)
}

/// Erstatter «@navn» under skriving med «@acct » og setter markøren etter mellomrommet.
func insertMention(_ text: String, _ q: MentionQuery, acct: String) -> (String, Int) {
    let ns = text as NSString
    let after = ns.substring(from: q.end)
    let insert = "@" + acct + (after.hasPrefix(" ") ? "" : " ")
    let newText = ns.substring(to: q.start) + insert + after
    let cursor = q.start + insert.utf16.count + (after.hasPrefix(" ") ? 1 : 0)
    return (newText, cursor)
}

/// Startteksten i et svar: nevnelsene øverst og markøren på linjen rett under dem. Har innlegget
/// emneknagger, kommer de nederst med en tom linje mellom markøren og knaggene.
func replyDraft(_ mentions: String?, _ tags: String?) -> (String, Int) {
    let head = (mentions ?? "").split(separator: " ").map { "@" + $0 }.joined(separator: " ")
    let tail = (tags ?? "").split(separator: " ").map { "#" + $0 }.joined(separator: " ")
    let before = head.isEmpty ? "" : head + "\n"
    let after = tail.isEmpty ? "" : "\n\n" + tail
    return (before + after, before.utf16.count)
}

/// Tekst og markør/markering etter at en Markdown-knapp er trykket.
struct MdEdit {
    let text: String
    let selStart: Int
    let selEnd: Int
}

/// Omslutter markeringen med [marker]. Uten markering havner markøren mellom to tomme markører.
func wrapMarkdown(_ text: String, _ selStart: Int, _ selEnd: Int, _ marker: String) -> MdEdit {
    let ns = text as NSString
    let start = min(max(min(selStart, selEnd), 0), ns.length)
    let end = min(max(max(selStart, selEnd), 0), ns.length)
    let out = ns.substring(to: start) + marker + ns.substring(with: NSRange(location: start, length: end - start)) + marker + ns.substring(from: end)
    let m = marker.utf16.count
    return MdEdit(text: out, selStart: start + m, selEnd: end + m)
}

/// Setter [prefix] (f.eks. «> ») først på linjen(e) markøren eller markeringen står på.
/// For overskrift øker et nytt trykk nivået: «# » blir «## ».
func prefixLines(_ text: String, _ selStart: Int, _ selEnd: Int, _ prefix: String) -> MdEdit {
    let ns = text as NSString
    let start = min(max(min(selStart, selEnd), 0), ns.length)
    let end = min(max(max(selStart, selEnd), 0), ns.length)
    let heading = prefix.trimmingCharacters(in: .whitespaces) == "#"
    func indexOfNewline(from: Int) -> Int {
        guard from < ns.length else { return -1 }
        let r = ns.range(of: "\n", range: NSRange(location: from, length: ns.length - from))
        return r.location == NSNotFound ? -1 : r.location
    }
    func lastNewline(before: Int) -> Int {
        guard before >= 0 else { return -1 }
        let r = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: min(before + 1, ns.length)))
        return r.location == NSNotFound ? -1 : r.location
    }
    var lineStarts = [lastNewline(before: start - 1) + 1]
    var i = indexOfNewline(from: lineStarts[0])
    while i >= 0 && i + 1 < end {
        lineStarts.append(i + 1)
        i = indexOfNewline(from: i + 1)
    }
    let out = NSMutableString(string: text)
    var newStart = start
    var newEnd = end
    for ls in lineStarts.reversed() {
        let startsWithHash = ls < ns.length && ns.character(at: ls) == 35
        let insert = heading && startsWithHash ? "#" : prefix
        out.insert(insert, at: ls)
        let n = insert.utf16.count
        if ls <= newStart { newStart += n }
        if ls <= newEnd { newEnd += n }
    }
    return MdEdit(text: out as String, selStart: newStart, selEnd: newEnd)
}

/// Setter inn en Markdown-lenke: «[]()» med markøren i hakeparentesene, eller med markeringen som
/// lenketekst og markøren i parentesene, klar for adressen.
func insertLink(_ text: String, _ selStart: Int, _ selEnd: Int) -> MdEdit {
    let ns = text as NSString
    let start = min(max(min(selStart, selEnd), 0), ns.length)
    let end = min(max(max(selStart, selEnd), 0), ns.length)
    let label = ns.substring(with: NSRange(location: start, length: end - start))
    let out = ns.substring(to: start) + "[" + label + "]()" + ns.substring(from: end)
    let cursor = label.isEmpty ? start + 1 : start + label.utf16.count + 3
    return MdEdit(text: out, selStart: cursor, selEnd: cursor)
}

// MARK: - Skrivevinduet

/// Et vedlegg i innlegget – enten nylig lastet opp fra Macen eller eksisterende (ved redigering).
struct ComposeAttachment: Identifiable, Equatable {
    let key: String
    var localURL: URL?
    var previewUrl: String?
    var id: String?
    var description = ""

    var preview: String? { localURL?.absoluteString ?? previewUrl }
    var isLocalVideo: Bool {
        guard let u = localURL else { return false }
        return UTType(filenameExtension: u.pathExtension)?.conforms(to: .movie) == true
    }
}

private let visibilities = ["public", "unlisted", "private", "direct"]

struct ComposeView: View {
    let args: ComposeArgs
    let maxChars: Int
    let altLimit: Int
    let postFormats: [String]
    let onClose: () -> Void

    @ViewState private var text = ""
    @ViewState private var selection = NSRange(location: 0, length: 0)
    @ViewState private var cwOn = false
    @ViewState private var cw = ""
    @ViewState private var visibility = "public"
    @ViewState private var markdown = false
    // Språk: nye innlegg starter med sist brukte valg. Ved redigering brukes innleggets eget språk
    // (nil hvis det er et annet språk enn de tre vi tilbyr – da endres det ikke).
    @ViewState private var language: String?
    @ViewState private var originalLanguage: String?
    @ViewState private var sending = false
    @ViewState private var loadingEdit = false
    @ViewState private var emojiOpen = false
    @ViewState private var altSaving = 0
    @ViewState private var attachments: [ComposeAttachment] = []
    @ViewState private var suggestions: [Account] = []
    @ViewState private var initialized = false

    private var app: AppState { AppState.shared }
    private var editing: Bool { args.editId != nil }
    private var markdownSupported: Bool { postFormats.contains("text/markdown") }
    private var length: Int { text.unicodeScalars.count }
    private var over: Bool { length > maxChars }
    private var uploading: Bool { attachments.contains { $0.id == nil } }
    private var canSend: Bool {
        !sending && !loadingEdit && !over && !uploading && altSaving == 0 &&
            (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }
    private var mentionQuery: MentionQuery? {
        mentionQueryAt(text, cursor: selection.location, selectionEnd: selection.location + selection.length)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if loadingEdit {
                Spacer()
                Spinner(size: 32)
                Spacer()
            } else {
                editorArea
            }
            if mentionQuery != nil && !suggestions.isEmpty {
                MentionSuggestions(accounts: suggestions) { acc in
                    guard let q = mentionQuery else { return }
                    let (t, c) = insertMention(text, q, acct: acc.acct)
                    text = t
                    selection = NSRange(location: c, length: 0)
                    suggestions = []
                }
            }
            if emojiOpen { EmojiPicker(onPick: insertEmoji) }
            bottomBar
        }
        .onAppear(perform: setup)
        .task { await loadEdit() }
        .task(id: mentionQuery?.query) { await searchMentions() }
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls.filter(\.isFileURL))
            return true
        }
    }

    private func setup() {
        guard !initialized else { return }
        initialized = true
        let (t, c) = replyDraft(args.replyMentions, args.replyTags)
        text = t
        selection = NSRange(location: c, length: 0)
        visibility = args.replyVisibility ?? "public"
        language = editing ? nil : app.store.language
        loadingEdit = editing
    }

    // MARK: Deler av skjermen

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L(editing ? "compose_edit_title" : args.replyId != nil ? "compose_reply_title" : "compose_title"))
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(PT.topBarText)
                Spacer()
                // Hjelp til Markdown vises bare når Markdown er slått på
                if markdown && markdownSupported {
                    TopIconButton(icon: "info.circle.fill", help: L("markdown_help_button")) {
                        app.present(MarkdownHelpDialog())
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            PDivider()
        }
        .background(PT.topBar.ignoresSafeArea(edges: .top))
    }

    private var editorArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if cwOn {
                PField(placeholder: L("compose_cw_label"), text: $cw)
            }
            if markdown && markdownSupported { markdownButtons }
            ComposeEditor(text: $text, selection: $selection, placeholder: L("compose_hint"), focusOnAppear: !editing)
                .frame(minHeight: 140, maxHeight: .infinity)
                .background(PT.fg.opacity(0.85))
                .pBorder(PT.border)
            HStack {
                Spacer()
                // Boks i samme stil som «Skriv»-knappen, så telleren synes uansett bakgrunnsbilde
                Text(L("char_counter", length, maxChars))
                    .font(.system(size: PF.body, weight: over ? .bold : .regular))
                    .foregroundStyle(PT.fg)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(over ? PT.orange : PT.link)
                    .pBorder(PT.border)
            }
            if !attachments.isEmpty { attachmentRow }
        }
        .padding(8)
        .frame(maxWidth: contentMaxWidth, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Knapper som setter inn Markdown-koder der markøren står.
    private var markdownButtons: some View {
        HStack(spacing: 6) {
            mdButton("#", "md_btn_heading") { prefixLines($0, $1, $2, "# ") }
            mdButton("**", "md_bold") { wrapMarkdown($0, $1, $2, "**") }
            mdButton("*", "md_italic") { wrapMarkdown($0, $1, $2, "*") }
            mdButton("~~", "md_strike") { wrapMarkdown($0, $1, $2, "~~") }
            mdButton("`", "md_code") { wrapMarkdown($0, $1, $2, "`") }
            mdButton(">", "md_quote") { prefixLines($0, $1, $2, "> ") }
            PButton(text: "", icon: "link", help: L("md_link"), expand: true) { applyMarkdown(insertLink) }
        }
    }

    private func mdButton(_ label: String, _ helpKey: String, _ edit: @escaping (String, Int, Int) -> MdEdit) -> some View {
        PButton(text: label, help: L(helpKey), expand: true) { applyMarkdown(edit) }
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    ZStack {
                        RemoteImage(url: a.preview, fill: true, maxPixel: 400, videoFrame: a.isLocalVideo)
                        if a.id == nil { Spinner(size: 24) }
                        // ALT-merke: grønt når alt-tekst er satt, oransje «+ ALT» når den mangler
                        let hasAlt = !a.description.trimmingCharacters(in: .whitespaces).isEmpty
                        Text(L(hasAlt ? "alt_badge" : "alt_add_badge"))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(hasAlt ? PT.fg : PT.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(hasAlt ? PT.topBarText : PT.fg.opacity(0.85))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .allowsHitTesting(false)
                        Button { attachments.removeAll { $0.key == a.key } } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(PT.text)
                                .frame(width: 24, height: 24)
                                .background(PT.fg.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help(L("compose_remove_attachment"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                    .frame(width: 96, height: 96)
                    .background(PT.fg)
                    .pBorder(PT.border)
                    .clipped()
                    .contentShape(Rectangle())
                    // Klikk på bildet for å legge inn alt-tekst
                    .onTapGesture { if a.id != nil { editAlt(a) } }
                    .help(a.description)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            PDivider()
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    PButton(text: "", icon: "photo", enabled: attachments.count < 4 && !loadingEdit, help: L("compose_attach")) {
                        pickFiles()
                    }
                    PButton(text: "", icon: "exclamationmark.triangle.fill", filled: cwOn, help: L("compose_cw_toggle")) {
                        cwOn.toggle()
                    }
                    PButton(text: "", icon: "face.smiling", filled: emojiOpen, help: L("compose_emoji")) {
                        emojiOpen.toggle()
                    }
                    PButton(
                        text: language?.uppercased() ?? "–", icon: "character.bubble",
                        enabled: !loadingEdit,
                        help: L("language_label") + (language.map { ": " + languageName($0) } ?? "")
                    ) {
                        showMenu(postLanguages.map { code in
                            .item(languageName(code) + " (\(code))", checked: code == language) { language = code }
                        })
                    }
                    // Synlighet kan ikke endres når man redigerer et eksisterende innlegg
                    PButton(
                        text: "", icon: visibilityIcon(visibility), enabled: !editing,
                        help: L("visibility") + ": " + visibilityLabel(visibility)
                    ) {
                        showMenu(visibilities.map { v in
                            .item(visibilityLabel(v), icon: visibilityIcon(v), checked: v == visibility) { visibility = v }
                        })
                    }
                    if markdownSupported {
                        PButton(text: L("compose_markdown"), filled: markdown) { markdown.toggle() }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: contentMaxWidth)
            HStack(spacing: 8) {
                PButton(text: L("cancel"), expand: true, action: onClose)
                PButton(text: L(editing ? "compose_update" : "compose_publish"), filled: true, enabled: canSend,
                        help: L("publish_shortcut_hint"), expand: true, action: send)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding([.horizontal, .bottom], 8)
            .frame(maxWidth: contentMaxWidth)
        }
        .frame(maxWidth: .infinity)
        .background(PT.fg)
    }

    // MARK: Handlinger

    /// Redigering: hent innleggets kildetekst og eksisterende vedlegg.
    private func loadEdit() async {
        guard let editId = args.editId else { return }
        do {
            let st = try await app.api.status(editId)
            let src = try? await app.api.statusSource(editId)
            let body = src?.text ?? parseHtml(st.content).text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = body
            selection = NSRange(location: body.utf16.count, length: 0)
            cw = src?.spoilerText ?? st.spoilerText
            cwOn = !cw.trimmingCharacters(in: .whitespaces).isEmpty
            visibility = st.visibility
            markdown = src?.contentType == "text/markdown"
            originalLanguage = normalizePostLanguage(st.language)
            language = originalLanguage
            attachments = st.mediaAttachments.map {
                ComposeAttachment(key: $0.id, previewUrl: $0.previewUrl ?? $0.url, id: $0.id, description: $0.description ?? "")
            }
            loadingEdit = false
        } catch is CancellationError {
        } catch {
            app.toast(userMessage(error))
            onClose()
        }
    }

    /// Forslag når man skriver «@navn»: søker blant kontoer jeg følger (litt forsinket).
    private func searchMentions() async {
        guard let q = mentionQuery?.query else {
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        suggestions = (try? await app.api.searchFollowing(q)) ?? []
    }

    /// Setter inn :kortkode: der markøren står, med mellomrom rundt slik at instansen gjenkjenner den.
    private func insertEmoji(_ e: Emoji) {
        let ns = text as NSString
        let start = min(max(selection.location, 0), ns.length)
        let end = min(start + selection.length, ns.length)
        let needsSpace = start > 0 && !(ns.substring(with: NSRange(location: start - 1, length: 1)).first?.isWhitespace ?? true)
        let insert = (needsSpace ? " " : "") + ":\(e.shortcode): "
        text = ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: insert)
        selection = NSRange(location: start + insert.utf16.count, length: 0)
    }

    private func applyMarkdown(_ edit: (String, Int, Int) -> MdEdit) {
        let r = edit(text, selection.location, selection.location + selection.length)
        text = r.text
        selection = NSRange(location: r.selStart, length: r.selEnd - r.selStart)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        panel.begin { response in
            if response == .OK { addFiles(panel.urls) }
        }
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            guard attachments.count < 4 else { break }
            let key = UUID().uuidString
            attachments.append(ComposeAttachment(key: key, localURL: url))
            Task {
                do {
                    let id = try await app.api.uploadMedia(fileURL: url)
                    if let i = attachments.firstIndex(where: { $0.key == key }) { attachments[i].id = id }
                } catch {
                    attachments.removeAll { $0.key == key }
                    app.toast(L("compose_upload_failed") + ": " + userMessage(error))
                }
            }
        }
    }

    private func editAlt(_ a: ComposeAttachment) {
        let binding = $attachments
        let saving = $altSaving
        let api = app.api
        app.present(AltTextDialog(attachment: a, limit: altLimit) { description in
            if let i = binding.wrappedValue.firstIndex(where: { $0.key == a.key }) {
                binding.wrappedValue[i].description = description
            }
            guard let id = a.id else { return }
            saving.wrappedValue += 1
            Task {
                do {
                    try await api.updateMedia(id, description: description)
                } catch {
                    AppState.shared.toast(L("alt_update_failed") + ": " + userMessage(error))
                }
                saving.wrappedValue -= 1
            }
        })
    }

    private func send() {
        guard canSend else { return }
        sending = true
        Task {
            do {
                let contentType: String? = postFormats.isEmpty ? nil : (markdown && markdownSupported ? "text/markdown" : "text/plain")
                let mediaIds = attachments.compactMap(\.id)
                if let editId = args.editId {
                    _ = try await app.api.editStatus(
                        id: editId, text: text, spoiler: cwOn ? cw : nil, mediaIds: mediaIds, contentType: contentType,
                        // Språk sendes bare hvis brukeren har endret det
                        language: language != originalLanguage ? language : nil
                    )
                    app.toast(L("compose_updated"))
                } else {
                    _ = try await app.api.postStatus(
                        text: text, visibility: visibility, spoiler: cwOn ? cw : nil, replyTo: args.replyId,
                        mediaIds: mediaIds, contentType: contentType, language: language
                    )
                    if let language { app.store.language = language }
                    app.toast(L("compose_published"))
                }
                app.notifyPosted()
                sending = false
                onClose()
            } catch {
                app.toast(userMessage(error))
                sending = false
            }
        }
    }
}

// MARK: - Tekstfeltet

final class ComposeTextView: NSTextView {
    var placeholder = ""
    var placeholderColor = NSColor.gray

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = textContainerOrigin
        let pad = textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(
            at: NSPoint(x: origin.x + pad, y: origin.y),
            withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: placeholderColor]
        )
    }
}

/// Flerlinjet tekstfelt med tilgang til markøren (for Markdown-knapper, emojier og @-forslag).
/// Temaet bruker monospace i inndatafelt.
struct ComposeEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let placeholder: String
    var focusOnAppear = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = ComposeTextView(usingTextLayoutManager: false)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.placeholder = placeholder
        tv.delegate = context.coordinator
        // Filer som slippes på feltet legges ved innlegget (ikke inn som tekst)
        tv.unregisterDraggedTypes()
        scroll.documentView = tv
        context.coordinator.textView = tv

        if focusOnAppear {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ComposeTextView else { return }
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        tv.textColor = PT.c.text.ns
        tv.insertionPointColor = PT.c.link.ns
        tv.placeholderColor = Tone.muted.hex.ns
        tv.selectedTextAttributes = [.backgroundColor: PT.c.link.ns.withAlphaComponent(0.35)]
        if tv.string != text {
            tv.string = text
            tv.needsDisplay = true
        }
        let len = (tv.string as NSString).length
        let sel = NSRange(location: min(selection.location, len), length: min(selection.length, max(0, len - min(selection.location, len))))
        if tv.selectedRange() != sel {
            tv.setSelectedRange(sel)
            tv.scrollRangeToVisible(sel)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeEditor
        weak var textView: NSTextView?
        var updating = false

        init(_ parent: ComposeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView, !updating else { return }
            parent.text = tv.string
            parent.selection = tv.selectedRange()
            tv.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView, !updating else { return }
            let r = tv.selectedRange()
            if parent.selection != r {
                DispatchQueue.main.async { self.parent.selection = r }
            }
        }
    }
}

// MARK: - Forslag, emojier og dialoger

/// Forslagsliste over kontoer jeg følger, vist rett over verktøylinjen i skrivevinduet.
private struct MentionSuggestions: View {
    let accounts: [Account]
    let onPick: (Account) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PDivider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(accounts) { acc in
                        HStack(spacing: 10) {
                            Avatar(url: acc.avatar, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                EmojiText(text: acc.name, emojis: acc.emojis, tone: .fgText, bold: true, maxLines: 1,
                                          onTap: { onPick(acc) })
                                Text("@" + acc.acct).font(.system(size: PF.small)).foregroundStyle(PT.muted).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(acc) }
                    }
                }
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: accounts.count <= 4)
        }
        .background(PT.fg)
    }
}

/// Velger for instansens egendefinerte emojier, gruppert etter kategori.
private struct EmojiPicker: View {
    let onPick: (Emoji) -> Void

    @ViewState private var emojis: [Emoji]? = AppState.shared.cachedEmojis()
    @ViewState private var error: String?
    @ViewState private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            PDivider()
            PField(placeholder: L("emoji_search"), text: $query).padding(8)
            Group {
                if let error {
                    Text(error).foregroundStyle(PT.orange).padding(12)
                } else if let list = emojis {
                    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
                    let shown = q.isEmpty ? list : list.filter { $0.shortcode.lowercased().contains(q) }
                    if shown.isEmpty {
                        Text(L("emoji_none")).foregroundStyle(PT.muted).padding(12)
                    } else {
                        grid(shown)
                    }
                } else {
                    Spinner(size: 28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 270)
        .background(PT.fg)
        .task {
            guard emojis == nil else { return }
            do { emojis = try await AppState.shared.loadEmojis() } catch { self.error = userMessage(error) }
        }
    }

    private func grid(_ shown: [Emoji]) -> some View {
        var order: [String] = []
        var groups: [String: [Emoji]] = [:]
        for e in shown {
            let c = e.category ?? ""
            if groups[c] == nil { order.append(c) }
            groups[c, default: []].append(e)
        }
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 48), spacing: 0)], alignment: .leading, spacing: 0) {
                ForEach(order, id: \.self) { category in
                    let title = category.hasPrefix("pack:") ? String(category.dropFirst(5)) : category
                    Section {
                        ForEach(groups[category] ?? [], id: \.shortcode) { e in
                            RemoteImage(url: RichBuilder.emojiUrl(e), fill: false, maxPixel: 128)
                                .frame(width: 32, height: 32)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(e) }
                                .help(":\(e.shortcode):")
                        }
                    } header: {
                        if !title.isEmpty {
                            Text(title)
                                .font(.system(size: PF.small, weight: .bold))
                                .foregroundStyle(PT.link)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

/// Dialog for alt-tekst: forhåndsvisning av bildet, tekstfelt og teller mot instansens grense.
struct AltTextDialog: View {
    let attachment: ComposeAttachment
    let limit: Int
    let onSave: (String) -> Void

    @ViewState private var value: String

    init(attachment: ComposeAttachment, limit: Int, onSave: @escaping (String) -> Void) {
        self.attachment = attachment
        self.limit = limit
        self.onSave = onSave
        _value = ViewState(initialValue: attachment.description)
    }

    var body: some View {
        let over = value.count > limit
        PDialog(L("alt_title"), buttons: [
            DialogButton(text: L("cancel")) { AppState.shared.dismissDialog() },
            DialogButton(text: L("alt_save"), enabled: !over) {
                AppState.shared.dismissDialog()
                onSave(value.trimmingCharacters(in: .whitespacesAndNewlines))
            },
        ]) {
            VStack(alignment: .leading, spacing: 10) {
                RemoteImage(url: attachment.preview, fill: false, videoFrame: attachment.isLocalVideo)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .background(PT.bg)
                    .pBorder(PT.border)
                ZStack(alignment: .topLeading) {
                    if value.isEmpty {
                        Text(L("alt_hint")).foregroundStyle(PT.muted).padding(.horizontal, 5).padding(.vertical, 8)
                    }
                    TextEditor(text: $value)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(PT.text)
                        .font(.system(size: PF.body))
                        .padding(.vertical, 8)
                }
                .frame(height: 120)
                .padding(.horizontal, 4)
                .background(PT.fg.opacity(0.85))
                .pBorder(PT.border.opacity(0.8))
                HStack {
                    Spacer()
                    Text(L("char_counter", value.count, limit))
                        .font(.system(size: PF.small))
                        .foregroundStyle(over ? PT.orange : PT.muted)
                }
            }
        }
    }
}

/// Oversikt over de vanligste Markdown-kodene.
struct MarkdownHelpDialog: View {
    private let items = [
        ("md_heading_syntax", "md_heading"), ("md_bold_syntax", "md_bold"), ("md_italic_syntax", "md_italic"),
        ("md_strike_syntax", "md_strike"), ("md_bullets_syntax", "md_bullets"), ("md_numbers_syntax", "md_numbers"),
        ("md_code_syntax", "md_code"), ("md_codeblock_syntax", "md_codeblock"), ("md_quote_syntax", "md_quote"),
        ("md_link_syntax", "md_link"),
    ]

    var body: some View {
        PDialog(L("markdown_help_title"), buttons: [.close(L("markdown_help_close"))]) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.0) { syntax, label in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(label)).font(.system(size: 11)).foregroundStyle(PT.muted)
                        Text(L(syntax))
                            .font(.system(size: PF.small, design: .monospaced))
                            .foregroundStyle(PT.fgText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PT.link.opacity(0.14))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
