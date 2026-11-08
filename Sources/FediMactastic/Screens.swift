import AppKit
import SwiftUI

/// Største bredde på innholdet når vinduet er bredt (kortene blir ellers urimelig brede).
let contentMaxWidth: CGFloat = 720

/// Ruller til toppen (dobbeltklikk på toppfeltet) og laster på nytt (dobbeltklikk på fanen / ⌘R),
/// men bare for skjermen som vises.
private struct FeedSignals: ViewModifier {
    let proxy: ScrollViewProxy
    var onRefresh: (() -> Void)?
    @Environment(\.screenActive) private var active
    @Environment(\.signalScope) private var scope

    private var targeted: Bool {
        let s = AppState.shared.signalScope
        return active && (s == nil || s == scope)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: AppState.shared.scrollTopTick) {
                if targeted { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("top", anchor: .top) } }
            }
            .onChange(of: AppState.shared.refreshTick) {
                if targeted { onRefresh?() }
            }
    }
}

/// Tidslinje/profil-liste med automatisk «hent flere».
struct StatusFeedView<Header: View>: View {
    let model: FeedModel
    let actions: StatusActions
    var emptyText = L("empty_timeline")
    var mediaCards = false
    let header: Header

    init(model: FeedModel, actions: StatusActions, emptyText: String = L("empty_timeline"), mediaCards: Bool = false,
         @ViewBuilder header: () -> Header) {
        self.model = model
        self.actions = actions
        self.emptyText = emptyText
        self.mediaCards = mediaCards
        self.header = header()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    Color.clear.frame(height: 0).id("top")
                    header
                    if let e = model.paging.error, model.items.isEmpty {
                        ErrorPanel(message: e) { model.refresh() }
                    } else if model.items.isEmpty && !model.paging.refreshing {
                        MessagePanel(text: emptyText)
                    }
                    if model.paging.refreshing { LoadingRow() }
                    ForEach(model.items) { s in
                        Group {
                            if mediaCards {
                                MediaPostCard(status: s, actions: actions)
                            } else {
                                StatusCard(status: s, actions: actions)
                            }
                        }
                        .onAppear { model.appeared(s.id) }
                    }
                    if model.paging.loading { LoadingRow() }
                }
                .padding(8)
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .modifier(FeedSignals(proxy: proxy, onRefresh: { model.refresh() }))
        }
        .task { model.ensureLoaded() }
    }
}

extension StatusFeedView where Header == EmptyView {
    init(model: FeedModel, actions: StatusActions, emptyText: String = L("empty_timeline"), mediaCards: Bool = false) {
        self.init(model: model, actions: actions, emptyText: emptyText, mediaCards: mediaCards) { EmptyView() }
    }
}

// MARK: - Tråd

struct ThreadView: View {
    let model: ThreadModel
    let actions: StatusActions
    @ViewState private var scrolled = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    Color.clear.frame(height: 0).id("top")
                    if let e = model.error, model.items.isEmpty {
                        ErrorPanel(message: e) { model.reload() }
                    }
                    ForEach(model.items) { s in
                        let isFocus = (s.reblog ?? s).id == model.statusId
                        StatusCard(status: s, actions: actions, highlighted: isFocus, clickable: !isFocus)
                            .id(s.id)
                    }
                    if model.loading { LoadingRow() }
                }
                .padding(8)
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .modifier(FeedSignals(proxy: proxy, onRefresh: { model.reload() }))
            .onChange(of: model.items.count) {
                // Innlegget som ble åpnet, vises øverst (med svarene det svarer på over)
                guard !scrolled, !model.items.isEmpty else { return }
                scrolled = true
                if let focus = model.items.first(where: { ($0.reblog ?? $0).id == model.statusId }), focus.id != model.items.first?.id {
                    DispatchQueue.main.async { proxy.scrollTo(focus.id, anchor: .top) }
                }
            }
        }
        .task { model.load() }
    }
}

// MARK: - Varsler

private func notificationText(_ n: AppNotification) -> String {
    let name = n.account.name
    switch n.type {
    case "mention": return L("notif_mention", name)
    case "reblog": return L("notif_reblog", name)
    case "favourite": return L("notif_favourite", name)
    case "follow": return L("notif_follow", name)
    case "follow_request": return L("notif_follow_request", name)
    case "poll": return L("notif_poll")
    case "status": return L("notif_status", name)
    case "update": return L("notif_update", name)
    case "pleroma:emoji_reaction": return L("notif_reaction", name, n.emoji ?? "")
    default: return L("notif_other", name, n.type)
    }
}

struct NotificationsView: View {
    let model: NotificationsModel
    let openStatus: (String) -> Void
    let openProfile: (Account) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Filterlinje øverst: Alle / Svar
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    PButton(text: L("notif_filter_all"), filled: model.filter == .all, expand: true) { model.setFilter(.all) }
                    PButton(text: L("notif_filter_replies"), filled: model.filter == .replies, expand: true) { model.setFilter(.replies) }
                }
                .frame(maxWidth: contentMaxWidth)
                .padding(8)
                .frame(maxWidth: .infinity)
                PDivider()
            }
            .background(PT.fg.opacity(0.92))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Color.clear.frame(height: 0).id("top")
                        if let e = model.paging.error, model.items.isEmpty {
                            ErrorPanel(message: e) { model.refresh() }
                        } else if model.items.isEmpty && !model.paging.refreshing {
                            MessagePanel(text: L(model.filter == .replies ? "empty_replies" : "empty_notifications"))
                        }
                        if model.paging.refreshing { LoadingRow() }
                        ForEach(model.items) { n in
                            row(n).onAppear { model.appeared(n.id) }
                        }
                        if model.paging.loading { LoadingRow() }
                    }
                    .padding(8)
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
                .modifier(FeedSignals(proxy: proxy, onRefresh: { model.refresh() }))
                .onChange(of: model.filter) { proxy.scrollTo("top", anchor: .top) }
            }
        }
        .task { model.ensureLoaded() }
    }

    private func row(_ n: AppNotification) -> some View {
        let target = n.status?.reblog ?? n.status
        let open = {
            if let target { openStatus(target.id) } else { openProfile(n.account) }
        }
        let isMention = n.type == "mention"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Avatar(url: n.account.avatar, size: 36) { openProfile(n.account) }
                Spacer().frame(width: 10)
                Image(systemName: notifIcon(n.type))
                    .font(.system(size: 15))
                    .foregroundStyle(notifColor(n.type))
                Spacer().frame(width: 6)
                EmojiText(text: notificationText(n), emojis: n.account.emojis, size: PF.feedBody, tone: .text, maxLines: 2, onTap: open)
                Spacer().frame(width: 6)
                Text(relativeTime(n.createdAt)).font(.system(size: PF.feedSmall)).foregroundStyle(PT.muted)
            }
            if let target, !target.content.isEmpty, n.type != "poll" {
                // Svar/nevnelser i samme størrelse og farge som innlegg ellers; resten dempet
                RichText(
                    html: target.content, emojis: target.emojis, mentions: target.mentions,
                    size: isMention ? PF.feedBody : PF.feedSmall, tone: isMention ? .text : .muted,
                    maxLines: isMention ? 0 : 4, onTap: open
                )
            }
        }
        .padding(10)
        .panel()
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    private func notifIcon(_ type: String) -> String {
        switch type {
        case "reblog": return "arrow.2.squarepath"
        case "favourite": return "star.fill"
        case "pleroma:emoji_reaction": return "heart.fill"
        default: return "person.fill"
        }
    }

    private func notifColor(_ type: String) -> Color {
        switch type {
        case "reblog": return PT.green
        case "favourite": return PT.orange
        case "pleroma:emoji_reaction": return PT.red
        default: return PT.blue
        }
    }
}

// MARK: - Profil

struct AccountView: View {
    let model: AccountModel
    let isMe: Bool
    let actions: StatusActions
    let onLogout: () -> Void
    let onSwitchAccount: () -> Void

    var body: some View {
        // «Kun media» vises som bilde-feed, slik som fanen «Bilder og video»
        StatusFeedView(model: model.feed, actions: actions, mediaCards: model.mediaOnly) {
            if let a = model.account { header(a) }
            // Alle innlegg / Kun media – mellom profilen og innleggene
            HStack(spacing: 8) {
                PButton(text: L("profile_all_posts"), filled: !model.mediaOnly, expand: true) { model.setMediaOnly(false) }
                PButton(text: L("profile_media_only"), filled: model.mediaOnly, expand: true) { model.setMediaOnly(true) }
            }
            .padding(.vertical, 4)
        }
        .task(id: model.accountId) { model.loadHeader(isMe: isMe) }
    }

    private func header(_ a: Account) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !a.header.isEmpty {
                RemoteImage(url: a.header, fill: true)
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .background(PT.fg)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    // Klikk på profilbildet for å se det i stort format
                    Avatar(url: a.avatar, size: 64) { AppState.shared.present(AvatarDialog(account: a)) }
                    VStack(alignment: .leading, spacing: 2) {
                        EmojiText(text: a.name, emojis: a.emojis, size: PF.title, tone: .text, bold: true)
                        Text("@" + a.acct).font(.system(size: PF.small)).foregroundStyle(PT.muted).textSelection(.enabled)
                    }
                }
                RoleBadges(account: a)
                if !a.note.isEmpty {
                    RichText(html: a.note, emojis: a.emojis, tone: .text).padding(.top, 10)
                }
                if !a.fields.isEmpty {
                    FieldsTable(account: a).padding(.top, 12)
                }
                HStack(spacing: 18) {
                    counter(a.statusesCount, L("profile_posts"))
                    counter(a.followingCount, L("profile_following"))
                    counter(a.followersCount, L("profile_followers"))
                }
                .padding(.top, 12)
                Group {
                    if isMe {
                        HStack(spacing: 10) {
                            PButton(text: L("logout"), action: onLogout)
                            PButton(text: L("switch_account"), action: onSwitchAccount)
                        }
                    } else {
                        let r = model.relationship
                        let label = r?.following == true ? "profile_unfollow" : r?.requested == true ? "profile_requested" : "profile_follow"
                        HStack {
                            PButton(text: L(label), filled: r?.following != true && r?.requested != true, enabled: r != nil) {
                                model.toggleFollow()
                            }
                            Spacer()
                            // Legg til i liste – helt til høyre på samme linje som «Følg»
                            PButton(text: L("lists_button"), icon: "text.badge.plus") {
                                AppState.shared.present(ListMembershipDialog(model: model))
                            }
                        }
                    }
                }
                .padding(.top, 12)
            }
            .padding(12)
        }
        .panel()
    }

    private func counter(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.system(size: PF.body, weight: .bold)).foregroundStyle(PT.text)
            Text(label).font(.system(size: PF.small)).foregroundStyle(PT.muted)
        }
    }
}

/// Rollen brukeren har på instansen (admin, moderator e.l.) og om kontoen er automatisert.
private struct RoleBadges: View {
    let account: Account

    var body: some View {
        // Mastodon sender navngitte roller; Pleroma/Akkoma bare admin-/moderatorflagg
        var roles: [(String, Color?)] = account.roles.filter { !$0.name.isEmpty }.map { ($0.name, roleColor($0.color)) }
        if roles.isEmpty {
            if account.pleromaAdmin { roles.append((L("profile_role_admin"), nil)) }
            if account.pleromaModerator { roles.append((L("profile_role_moderator"), nil)) }
        }
        // Automatisert konto (Mastodon «bot», Pleroma/Akkoma «Service»-aktør)
        if account.bot { roles.append((L("profile_bot"), nil)) }
        return Group {
            if !roles.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(roles.enumerated()), id: \.offset) { _, r in
                        Text(r.0)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(r.1 ?? PT.text)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(PT.bg.opacity(0.35))
                            .pBorder(r.1 ?? PT.border)
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    /// «#rrggbb» → farge, ellers nil (tom eller ugyldig verdi).
    private func roleColor(_ hex: String) -> Color? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        guard h.hasPrefix("#") else { return nil }
        h.removeFirst()
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return HexColor(0xFF000000 | v).color
    }
}

/// Tabell med profilens egne felt: navn til venstre (34 %), verdi (med lenker) til høyre.
private struct FieldsTable: View {
    let account: Account
    @ViewState private var width: CGFloat = 0

    var body: some View {
        let inner = max(width - 1, 100)
        VStack(spacing: 0) {
            ForEach(Array(account.fields.enumerated()), id: \.offset) { i, f in
                if i > 0 { PDivider(color: PT.border.opacity(0.35)) }
                HStack(spacing: 0) {
                    EmojiText(text: f.name, emojis: account.emojis, size: PF.small, tone: .link, bold: true)
                        .padding(8)
                        .frame(width: inner * 0.34, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .background(PT.bg.opacity(0.35))
                    Rectangle().fill(PT.border.opacity(0.35)).frame(width: 1)
                    HStack(spacing: 6) {
                        RichText(html: f.value, emojis: account.emojis, size: PF.small, tone: .text)
                        if !(f.verifiedAt ?? "").isEmpty {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(PT.green)
                                .help(L("profile_verified"))
                        }
                    }
                    .padding(8)
                    .frame(width: inner * 0.66, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { width = g.size.width }
                .onChange(of: g.size.width) { _, w in width = w }
        })
        .pBorder(PT.border.opacity(0.6))
    }
}

// MARK: - Søk

/// Søk etter brukere (@) og emneknagger (#). Vanlig tekst søker etter begge deler.
struct SearchView: View {
    let model: SearchModel
    let openAccount: (Account) -> Void
    let openTag: (String) -> Void

    @FocusState private var focused: Bool
    @Environment(\.screenActive) private var active

    var body: some View {
        let state = model.state
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    PField(
                        placeholder: L("search_hint"),
                        text: Binding(get: { model.state.query }, set: { model.onQueryChange($0) }),
                        icon: "magnifyingglass",
                        onSubmit: { model.submit() },
                        focused: $focused
                    )
                    if !state.query.isEmpty {
                        PButton(text: "", icon: "xmark", help: L("search_clear")) { model.clear() }
                    }
                }
                .frame(maxWidth: contentMaxWidth)
                .padding(8)
                .frame(maxWidth: .infinity)
                PDivider()
            }
            .background(PT.fg.opacity(0.92))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Color.clear.frame(height: 0).id("top")
                        let nothing = state.accounts.isEmpty && state.hashtags.isEmpty
                        if state.query.trimmingCharacters(in: .whitespaces).isEmpty {
                            MessagePanel(text: L("search_start"))
                        } else if let e = state.error {
                            ErrorPanel(message: e) { model.submit() }
                        } else if state.loading {
                            LoadingRow()
                        } else if state.searched && nothing {
                            MessagePanel(text: L("search_empty"))
                        }

                        if !state.accounts.isEmpty {
                            sectionHeader(L("search_users"))
                            ForEach(state.accounts) { acc in
                                HStack(spacing: 10) {
                                    Avatar(url: acc.avatar, size: 44)
                                    VStack(alignment: .leading, spacing: 1) {
                                        EmojiText(text: acc.name, emojis: acc.emojis, tone: .text, bold: true, maxLines: 1,
                                                  onTap: { openAccount(acc) })
                                        Text("@" + acc.acct).font(.system(size: PF.small)).foregroundStyle(PT.muted).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(10)
                                .panel()
                                .contentShape(Rectangle())
                                .onTapGesture { openAccount(acc) }
                            }
                        }

                        if !state.hashtags.isEmpty {
                            sectionHeader(L("search_tags"))
                            ForEach(state.hashtags, id: \.self) { tag in
                                HStack(spacing: 0) {
                                    Text("#").bold().foregroundStyle(PT.link)
                                    Text(tag).bold().foregroundStyle(PT.text)
                                }
                                .font(.system(size: PF.body))
                                .padding(14)
                                .panel()
                                .contentShape(Rectangle())
                                .onTapGesture { openTag(tag) }
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
                .modifier(FeedSignals(proxy: proxy, onRefresh: { model.submit() }))
            }
        }
        .onAppear { if model.state.query.isEmpty { focused = true } }
        .onChange(of: active) { _, isActive in if isActive && model.state.query.isEmpty { focused = true } }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: PF.small, weight: .bold))
            .foregroundStyle(PT.topBarText)
            .padding(.leading, 4)
            .padding(.top, 6)
    }
}
