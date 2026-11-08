import AppKit
import SwiftUI

/// Alt et kort kan gjøre – skjermene kobler dette til sin ViewModel/navigasjon.
struct StatusActions {
    var myId: String?
    var openStatus: (Status) -> Void
    var openProfile: (Account) -> Void
    var reply: (Status) -> Void
    var boost: (Status) -> Void
    var favourite: (Status) -> Void
    var bookmark: (Status) -> Void
    var vote: (Status, Poll, [Int]) -> Void
    var delete: (Status) -> Void
    var canEdit = false
    var edit: (Status) -> Void = { _ in }
    /// Fremhev / fjern fremheving. Bare satt på brukerens egen profilside.
    var pin: ((Status) -> Void)?
}

func visibilityIcon(_ v: String) -> String {
    switch v {
    case "unlisted": return "lock.open.fill"
    case "private": return "lock.fill"
    case "direct": return "envelope.fill"
    default: return "globe"
    }
}

private func isBlank(_ s: String?) -> Bool {
    (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// «X delte» øverst på delte innlegg.
private struct BoostedRow: View {
    let account: Account
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.2.squarepath").font(.system(size: 13, weight: .semibold)).foregroundStyle(PT.green)
            EmojiText(text: L("boosted_by", account.name), emojis: account.emojis, size: PF.feedSmall, tone: .muted, maxLines: 1)
        }
        .padding(.bottom, 6)
    }
}

/// Innholdsvarsel med «Vis»/«Skjul».
private struct SpoilerRow: View {
    let s: Status
    @Binding var revealed: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PT.orange)
            EmojiText(text: s.spoilerText, emojis: s.emojis, size: PF.feedBody, tone: .text, bold: true)
            PButton(text: L(revealed ? "show_less" : "show_more")) { revealed.toggle() }
        }
        .padding(.bottom, 6)
    }
}

struct StatusCard: View {
    let status: Status
    let actions: StatusActions
    var highlighted = false
    var clickable = true

    @ViewState private var revealedState: Bool?

    var body: some View {
        let s = status.reblog ?? status
        let revealed = Binding(
            get: { revealedState ?? isBlank(s.spoilerText) },
            set: { revealedState = $0 }
        )
        // Avsender-app: serverens opplysning først, ellers appnavnet for innlegg postet herfra.
        let appName = s.application.map(\.displayName).flatMap { $0.isEmpty ? nil : $0 }
            ?? (AppState.shared.store.wasPostedHere(s.id) ? L("app_name") : nil)
        // Pleroma gjør lenkeforhåndsvisninger fra nyere Mastodon om til «unknown»-vedlegg som peker på
        // nettsiden. Lenken står allerede i teksten, så slike vedlegg hoppes over.
        let attachments = s.mediaAttachments.filter { m in
            !(m.type == "unknown" && !isBlank(m.remoteUrl) && s.content.contains(m.remoteUrl!))
        }
        // Lenkeforhåndsvisning (laget av instansen). Vises ikke sammen med medier eller avstemning.
        let card = s.card.flatMap { c -> Card? in
            c.url.hasPrefix("http") && (!isBlank(c.title) || !isBlank(c.image)) && attachments.isEmpty && s.poll == nil ? c : nil
        }
        let contentHtml = card.map { stripCardLink(s.content, cardUrl: $0.url) } ?? s.content
        let open: (() -> Void)? = clickable ? { actions.openStatus(s) } : nil

        VStack(alignment: .leading, spacing: 0) {
            if status.reblog != nil { BoostedRow(account: status.account) }
            if actions.pin != nil && status.reblog == nil && s.pinned {
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill").font(.system(size: 13)).foregroundStyle(PT.link)
                    Text(L("pinned_label")).font(.system(size: PF.feedSmall)).foregroundStyle(PT.muted)
                }
                .padding(.bottom, 6)
            }

            HStack(alignment: .center, spacing: 10) {
                Avatar(url: s.account.avatar, size: 44) { actions.openProfile(s.account) }
                VStack(alignment: .leading, spacing: 1) {
                    EmojiText(text: s.account.name, emojis: s.account.emojis, size: PF.feedBody, tone: .text, bold: true, maxLines: 1, onTap: open)
                    Text("@" + s.account.acct)
                        .font(.system(size: PF.feedSmall)).foregroundStyle(PT.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: visibilityIcon(s.visibility)).font(.system(size: 12)).foregroundStyle(PT.muted)
                        Text(relativeTime(s.createdAt) + (isBlank(s.editedAt) ? "" : " · " + L("edited")))
                            .font(.system(size: PF.feedSmall)).foregroundStyle(PT.muted)
                    }
                    // «via <app>» når instansen oppgir hvilken app innlegget ble postet fra
                    if let appName {
                        Text(L("via_app", appName))
                            .font(.system(size: 12)).foregroundStyle(PT.muted)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: 140, alignment: .trailing)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            Spacer().frame(height: 8)

            if !isBlank(s.spoilerText) { SpoilerRow(s: s, revealed: revealed) }

            if revealed.wrappedValue {
                if !isBlank(contentHtml) && !isBlankHtml(contentHtml) {
                    RichText(
                        html: contentHtml, emojis: s.emojis, mentions: s.mentions, size: PF.feedBody, tone: .text,
                        // Innlegget som er åpnet i en tråd vises alltid i sin helhet
                        collapseAfter: highlighted ? nil : collapseChars, onTap: open
                    )
                }
                MediaGrid(items: attachments, sensitive: s.sensitive)
                if let poll = s.poll { PollView(owner: s, poll: poll, actions: actions) }
                if let card { LinkCard(card: card) }
            }

            ActionRow(s: s, actions: actions)
        }
        .padding(10)
        .panel(
            border: highlighted ? PT.topBarText : PT.border,
            // Svar og nevnelser til meg skiller seg ut med egen bakgrunn
            background: s.addresses(AppState.shared.store.active?.userId) ? PT.mentionBg : PT.fg
        )
        .contentShape(Rectangle())
        .onTapGesture { open?() }
    }
}

/// Kort i «Bilder»-fanen, slik Pixelfed og Instagram viser innlegg: avsender øverst, så bildene
/// (eller videoen) i full bredde, knapperaden, og til slutt teksten.
struct MediaPostCard: View {
    let status: Status
    let actions: StatusActions

    @ViewState private var revealedState: Bool?

    var body: some View {
        let s = status.reblog ?? status
        let revealed = Binding(
            get: { revealedState ?? isBlank(s.spoilerText) },
            set: { revealedState = $0 }
        )
        let media = s.mediaAttachments.filter(\.isVisual)
        let open = { actions.openStatus(s) }
        // Innholdsvarsel skjuler også bildene, med varselteksten som etikett
        let hiddenLabel: String? = !isBlank(s.spoilerText)
            ? (revealed.wrappedValue ? nil : s.spoilerText)
            : (s.sensitive ? "" : nil)

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if status.reblog != nil { BoostedRow(account: status.account) }
                HStack(spacing: 8) {
                    Avatar(url: s.account.avatar, size: 34) { actions.openProfile(s.account) }
                    VStack(alignment: .leading, spacing: 1) {
                        EmojiText(text: s.account.name, emojis: s.account.emojis, size: PF.feedBody, tone: .text, bold: true, maxLines: 1, onTap: open)
                        Text("@" + s.account.acct).font(.system(size: PF.feedSmall)).foregroundStyle(PT.muted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: visibilityIcon(s.visibility)).font(.system(size: 12)).foregroundStyle(PT.muted)
                    Text(relativeTime(s.createdAt)).font(.system(size: PF.feedSmall)).foregroundStyle(PT.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            MediaCarousel(items: media, hiddenLabel: hiddenLabel) { revealed.wrappedValue = true }

            VStack(alignment: .leading, spacing: 0) {
                ActionRow(s: s, actions: actions)
                if !isBlank(s.spoilerText) { SpoilerRow(s: s, revealed: revealed) }
                if revealed.wrappedValue {
                    if !isBlank(s.content) && !isBlankHtml(s.content) {
                        RichText(html: s.content, emojis: s.emojis, mentions: s.mentions, size: PF.feedBody, tone: .text,
                                 collapseAfter: collapseChars, onTap: open)
                    }
                    if let poll = s.poll { PollView(owner: s, poll: poll, actions: actions) }
                }
                Spacer().frame(height: 10)
            }
            .padding(.horizontal, 10)
        }
        .panel()
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

// MARK: - Medier

/// Bilder åpnes i appens egen visning (med alt-tekst); annet åpnes i nettleseren.
@MainActor
private func openMedia(_ m: MediaAttachment, in items: [MediaAttachment]) {
    if m.type == "image" {
        let images = items.filter { $0.type == "image" }
        AppState.shared.openViewer(images, images.firstIndex(of: m) ?? 0)
    } else {
        openExternal(m.url)
    }
}

/// Play-knapp for vedlegg som åpnes i en annen app, og ALT-merke for vedlegg med alt-tekst.
private struct MediaOverlays: View {
    let m: MediaAttachment
    var body: some View {
        ZStack {
            if m.type != "image" && !m.isVideo {
                PlayIcon()
            }
            if !isBlank(m.description) {
                Text(L("alt_badge"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(PT.fg)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(PT.topBarText)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .help(m.description ?? "")
            }
        }
        .allowsHitTesting(!isBlank(m.description))
    }
}

struct PlayIcon: View {
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 24))
            .foregroundStyle(.white)
            .frame(width: 54, height: 54)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .allowsHitTesting(false)
    }
}

/// Adressen til bildet som vises for et vedlegg; [videoFrame] = hent et stillbilde fra videoen.
private func previewSource(_ m: MediaAttachment) -> (url: String?, videoFrame: Bool) {
    if m.type == "image" { return (m.url, false) }
    if m.isVideo {
        let p = m.previewUrl ?? ""
        let videoExt = [".mp4", ".webm", ".mov", ".m4v"].contains { p.lowercased().hasSuffix($0) }
        if p.isEmpty || p == m.url || videoExt { return (m.url.isEmpty ? nil : m.url, true) }
        return (p, false)
    }
    return (isBlank(m.previewUrl) ? nil : m.previewUrl, false)
}

private struct MediaGrid: View {
    let items: [MediaAttachment]
    let sensitive: Bool
    @ViewState private var shown = false

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 4) {
                if sensitive && !shown {
                    Text(L("sensitive_media"))
                        .foregroundStyle(PT.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .background(PT.fg)
                        .pBorder(PT.border)
                        .contentShape(Rectangle())
                        .onTapGesture { shown = true }
                } else if items.count == 1 {
                    // Ett bilde: full bredde, høyden følger bildets egne proporsjoner (ingen beskjæring).
                    MediaTile(m: items[0], single: true) { openMedia(items[0], in: items) }
                } else {
                    // Flere bilder: to kolonner. Hvert bilde vises helt (tilpasset en rute), ikke beskåret.
                    ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { i in
                        HStack(spacing: 4) {
                            MediaTile(m: items[i], single: false) { openMedia(items[i], in: items) }
                            if i + 1 < items.count {
                                MediaTile(m: items[i + 1], single: false) { openMedia(items[i + 1], in: items) }
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }
}

private struct MediaTile: View {
    let m: MediaAttachment
    let single: Bool
    let onOpen: () -> Void
    @ViewState private var measured: Double?

    var body: some View {
        let ratio: Double? = single ? (m.aspectRatio ?? measured).map { min(max($0, 0.4), 3) } : 1
        let src = previewSource(m)
        ZStack {
            if m.isVideo {
                InlineVideo(m: m, crop: false) { if measured == nil { measured = $0 } }
            } else if src.url != nil {
                RemoteImage(url: src.url, fill: false, videoFrame: src.videoFrame) { img in
                    if measured == nil { measured = img.aspect }
                }
            }
            MediaOverlays(m: m)
        }
        .frame(maxWidth: .infinity)
        .modifier(RatioFrame(ratio: ratio, maxHeight: single ? 560 : nil))
        .background(PT.fg)
        .pBorder(PT.border)
        .contentShape(Rectangle())
        .if(!m.isVideo) { $0.onTapGesture(perform: onOpen).handCursor() }
    }
}

/// Fast bredde/høyde-forhold når det er kjent, ellers en minstehøyde til bildet er målt.
private struct RatioFrame: ViewModifier {
    let ratio: Double?
    let maxHeight: CGFloat?

    func body(content: Content) -> some View {
        if let ratio {
            content
                .aspectRatio(ratio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: maxHeight)
        } else {
            content.frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120)
        }
    }
}

/// Bildene i et innlegg i full bredde. Flere bilder blas sidelengs, med «2/3» i hjørnet.
/// [hiddenLabel] ulik nil: bildene er skjult bak et klikkbart felt (tom tekst = «sensitivt innhold»).
private struct MediaCarousel: View {
    let items: [MediaAttachment]
    let hiddenLabel: String?
    let onReveal: () -> Void

    @ViewState private var shownSensitive = false
    @ViewState private var measured: Double?
    @ViewState private var current: String?
    @ViewState private var hovering = false

    var body: some View {
        if let first = items.first {
            // Høyden følger første bilde, innenfor Instagrams grenser (4:5 til 1,91:1)
            let ratio = (first.aspectRatio ?? measured).map { min(max($0, 0.8), 1.91) } ?? 1
            let index = items.firstIndex { $0.id == current } ?? 0
            ZStack {
                if let hiddenLabel, !(hiddenLabel.isEmpty && shownSensitive) {
                    Text(hiddenLabel.isEmpty ? L("sensitive_media") : hiddenLabel)
                        .foregroundStyle(PT.orange)
                        .multilineTextAlignment(.center)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { if hiddenLabel.isEmpty { shownSensitive = true } else { onReveal() } }
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(items) { m in
                                page(m, isFirst: m.id == first.id)
                                    .containerRelativeFrame(.horizontal)
                                    .id(m.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $current)
                    .scrollIndicators(.hidden)

                    if items.count > 1 {
                        Text("\(index + 1)/\(items.count)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .allowsHitTesting(false)
                        // Piler for mus (styreflaten kan også sveipe)
                        if hovering {
                            HStack {
                                if index > 0 { pageArrow("chevron.left", L("image_prev")) { current = items[index - 1].id } }
                                Spacer()
                                if index < items.count - 1 { pageArrow("chevron.right", L("image_next")) { current = items[index + 1].id } }
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(ratio, contentMode: .fit)
            .background(PT.bg)
            .clipped()
            .onHover { hovering = $0 }
        }
    }

    private func pageArrow(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.25)) { action() } } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func page(_ m: MediaAttachment, isFirst: Bool) -> some View {
        let src = previewSource(m)
        ZStack {
            if m.isVideo {
                InlineVideo(m: m, crop: true) { if isFirst && m.aspectRatio == nil { measured = $0 } }
            } else {
                // Fyller feltet helt; bilder utenfor 4:5–1,91:1 beskjæres som hos Instagram
                RemoteImage(url: src.url, fill: true, videoFrame: src.videoFrame) { img in
                    if isFirst && m.aspectRatio == nil { measured = img.aspect }
                }
                .contentShape(Rectangle())
                .onTapGesture { openMedia(m, in: items) }
            }
            MediaOverlays(m: m)
        }
        .clipped()
    }
}

// MARK: - Handlinger

private struct ActionRow: View {
    let s: Status
    let actions: StatusActions

    var body: some View {
        let canBoost = s.visibility == "public" || s.visibility == "unlisted" || s.reblogged
        HStack(spacing: 0) {
            ActionButton(icon: "arrowshape.turn.up.left.fill", help: L("action_reply"), count: s.repliesCount, tint: PT.fgText) {
                actions.reply(s)
            }
            Spacer(minLength: 0)
            ActionButton(icon: "arrow.2.squarepath", help: L("action_boost"), count: s.reblogsCount,
                         tint: s.reblogged ? PT.green : PT.muted, enabled: canBoost) { actions.boost(s) }
            Spacer(minLength: 0)
            ActionButton(icon: s.favourited ? "star.fill" : "star", help: L("action_favourite"), count: s.favouritesCount,
                         tint: s.favourited ? PT.orange : PT.muted) { actions.favourite(s) }
            Spacer(minLength: 0)
            ActionButton(icon: s.bookmarked ? "bookmark.fill" : "bookmark", help: L("action_bookmark"), count: nil,
                         tint: s.bookmarked ? PT.blue : PT.muted) { actions.bookmark(s) }
            Spacer(minLength: 0)
            ActionButton(icon: "ellipsis", help: L("action_more"), count: nil, tint: PT.muted, rotate: true) {
                moreMenu()
            }
        }
        .padding(.top, 6)
    }

    private func moreMenu() {
        let link = s.url ?? s.uri
        let mine = actions.myId != nil && actions.myId == s.account.id
        var items: [MenuEntry] = [
            .item(L("action_open_browser"), icon: "safari") { openExternal(link) },
            .item(L("action_copy_link"), icon: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                AppState.shared.toast(L("link_copied"))
            },
        ]
        if mine && actions.canEdit {
            items.append(.item(L("action_edit"), icon: "pencil") { actions.edit(s) })
        }
        if mine, let pin = actions.pin, s.pinnable {
            items.append(.item(L(s.pinned ? "action_unpin" : "action_pin"), icon: s.pinned ? "pin.slash" : "pin") { pin(s) })
        }
        if mine {
            let s = self.s
            let actions = self.actions
            items.append(.item(L("action_delete"), icon: "trash", color: PT.c.orange.ns) {
                AppState.shared.present(ConfirmDialog(
                    title: L("delete_confirm_title"), text: L("delete_confirm_text"),
                    confirm: L("action_delete"), onConfirm: { actions.delete(s) }
                ))
            })
        }
        showMenu(items)
    }
}

private struct ActionButton: View {
    let icon: String
    let help: String
    let count: Int?
    let tint: Color
    var enabled = true
    var rotate = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: PF.feedIcon))
                    .rotationEffect(.degrees(rotate ? 90 : 0))
                    .foregroundStyle(enabled ? tint : tint.opacity(0.4))
                if let count {
                    // Antall vises alltid: tydelig når > 0, dempet når 0.
                    Text("\(count)")
                        .font(.system(size: PF.feedCount, weight: count > 0 ? .medium : .regular))
                        .foregroundStyle(count == 0 ? PT.muted.opacity(0.55) : (tint == PT.muted ? PT.fgText : tint))
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Avstemning og lenkekort

private struct PollView: View {
    let owner: Status
    let poll: Poll
    let actions: StatusActions
    @ViewState private var selected = Set<Int>()

    var body: some View {
        let showResults = poll.voted || poll.expired
        let total = max(poll.options.reduce(0) { $0 + ($1.votesCount ?? 0) }, 1)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(poll.options.enumerated()), id: \.offset) { i, option in
                if showResults {
                    let pct = (option.votesCount ?? 0) * 100 / total
                    ZStack(alignment: .leading) {
                        GeometryReader { geo in
                            Rectangle().fill(PT.green.opacity(0.5)).frame(width: geo.size.width * CGFloat(pct) / 100)
                        }
                        HStack {
                            Text(option.title).foregroundStyle(PT.text).lineLimit(1)
                            Spacer()
                            Text("\(pct) %").foregroundStyle(PT.text)
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(height: 32)
                    .pBorder(PT.border.opacity(0.5))
                } else {
                    let on = selected.contains(i)
                    HStack(spacing: 8) {
                        Image(systemName: poll.multiple ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                            .font(.system(size: 16))
                            .foregroundStyle(PT.link)
                        Text(option.title).foregroundStyle(PT.text)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if poll.multiple {
                            if on { selected.remove(i) } else { selected.insert(i) }
                        } else {
                            selected = [i]
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if !showResults {
                    PButton(text: L("poll_vote"), enabled: !selected.isEmpty) {
                        actions.vote(owner, poll, selected.sorted())
                    }
                }
                Text(L("poll_votes", poll.votesCount) + (poll.expired ? " · " + L("poll_closed") : ""))
                    .font(.system(size: PF.feedSmall)).foregroundStyle(PT.muted)
            }
            .padding(.top, 2)
        }
        .font(.system(size: PF.feedBody))
        .padding(.top, 8)
    }
}

/// Forhåndsvisning av en lenke: bilde + sidetittel. Hele boksen er en lenke.
private struct LinkCard: View {
    let card: Card
    @ViewState private var ratio: Double?

    var body: some View {
        let host = card.providerName.flatMap { isBlank($0) ? nil : $0 } ?? URL(string: card.url)?.host ?? ""
        VStack(alignment: .leading, spacing: 0) {
            if let image = card.image, !isBlank(image) {
                RemoteImage(url: image, fill: false) { ratio = $0.aspect }
                    .aspectRatio(ratio ?? 1.91, contentMode: .fit)
                    .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 240)
                    .background(PT.bg)
                PDivider(color: PT.border.opacity(0.6))
            }
            VStack(alignment: .leading, spacing: 2) {
                if !host.isEmpty {
                    Text(host).font(.system(size: PF.feedSmall)).foregroundStyle(PT.link).lineLimit(1)
                }
                if !isBlank(card.title) {
                    Text(card.title).font(.system(size: PF.feedBody, weight: .bold)).foregroundStyle(PT.text).lineLimit(2)
                }
                if !isBlank(card.description) {
                    Text(card.description).font(.system(size: PF.feedSmall)).foregroundStyle(PT.muted).lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(PT.fg)
        .pBorder(PT.border)
        .contentShape(Rectangle())
        .onTapGesture { openExternal(card.url) }
        .handCursor()
        .help(card.url)
        .padding(.top, 8)
    }
}
