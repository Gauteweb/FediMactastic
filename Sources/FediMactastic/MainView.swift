import AppKit
import SwiftUI

/// Fanene i bunnmenyen, i samme rekkefølge som knappene.
enum MainTab: Int, CaseIterable, Hashable {
    case home, media, notifications, search, profile

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .media: return "photo.fill"
        case .notifications: return "bell.fill"
        case .search: return "magnifyingglass"
        case .profile: return "person.fill"
        }
    }

    var label: String {
        switch self {
        case .home: return L("nav_home")
        case .media: return L("nav_media")
        case .notifications: return L("nav_notifications")
        case .search: return L("nav_search")
        case .profile: return L("nav_profile")
        }
    }
}

/// Sider som legges oppå en fane.
enum Route: Hashable {
    case thread(String)
    case account(String)
    case tag(String)
    case instanceAbout
    case chat

    var cacheKey: String? {
        switch self {
        case .thread(let id): return "thr_" + id
        case .account(let id): return "acc_" + id
        case .tag(let t): return "tag_" + t
        default: return nil
        }
    }
}

struct ComposeArgs: Equatable {
    var replyId: String?
    var replyMentions: String?
    var replyTags: String?
    var replyVisibility: String?
    var editId: String?
}

/// Spesialverdier for «valgt feed» i Hjem og Bilder (kolliderer ikke med liste-ID-er).
let localFeed = "__local__"
let federatedFeed = "__federated__"

@MainActor
@Observable
final class NavState {
    var tab: MainTab = .home
    var stacks: [MainTab: [Route]] = [:]
    var visited: Set<MainTab> = [.home]
    var compose: ComposeArgs?
    /// Valgt feed i «Hjem» og «Bilder», hver for seg (nil = vanlig hjemmetidslinje).
    var selectedListId: String?
    var mediaListId: String?

    var top: Route? { stacks[tab]?.last }

    func push(_ r: Route) {
        stacks[tab, default: []].append(r)
    }

    /// Fjerner øverste side. Gir siden som ble fjernet.
    @discardableResult
    func pop() -> Route? {
        guard var s = stacks[tab], !s.isEmpty else { return nil }
        let r = s.removeLast()
        stacks[tab] = s
        return r
    }

    /// Klikk på en fane: bytter til den (med sidene den hadde), eller går til toppen av den aktive.
    func go(_ t: MainTab) {
        if t == tab {
            stacks[t] = []
        } else {
            tab = t
            visited.insert(t)
        }
    }

    func isOpen(_ r: Route) -> Bool { stacks.values.contains { $0.contains(r) } }
}

/// ViewModels for skjermene, slik at de overlever fanebytter (tilsvarer viewModel(key = …)).
@MainActor
final class ModelCache {
    private var models: [String: AnyObject] = [:]

    func get<T: AnyObject>(_ key: String, _ make: () -> T) -> T {
        if let m = models[key] as? T { return m }
        let m = make()
        models[key] = m
        return m
    }

    func remove(_ key: String) { models[key] = nil }
}

/// Skjermen er den som vises nå (ikke skjult bak en annen side eller fane).
private struct ScreenActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var screenActive: Bool {
        get { self[ScreenActiveKey.self] }
        set { self[ScreenActiveKey.self] = newValue }
    }
}

private struct StackEntry: Hashable {
    let index: Int
    let route: Route
}

/// Hovedvinduet for en innlogget bruker: toppfelt, sidene og bunnmenyen.
struct MainView: View {
    let auth: AuthModel

    @ViewState private var nav = NavState()
    @ViewState private var cache = ModelCache()
    @ViewState private var listsModel = ListsModel()
    @ViewState private var healthAvailable = false
    @ViewState private var lastTap: (tab: MainTab, at: Date)?
    @ViewState private var width: CGFloat = 0

    /// Vinduet er bredt nok til at varslene vises i en egen kolonne til høyre.
    private var wide: Bool { width >= wideThreshold }
    private let wideThreshold: CGFloat = 1000
    /// Varselkolonnens andel av bredden.
    private let sideFraction: CGFloat = 0.3
    private var mainWidth: CGFloat { (width * (1 - sideFraction)).rounded() }

    private var app: AppState { AppState.shared }
    private var state: AuthState { auth.state }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        topBar
                        content
                    }
                    .frame(width: wide ? mainWidth : nil)
                    if wide {
                        Rectangle().fill(PT.border).frame(width: 1).ignoresSafeArea(edges: .top)
                        notificationsPanel
                    }
                }
                // Bunnmenyen går over hele vinduet, men knappene står under hovedkolonnen
                bottomBar
            }
            if let args = nav.compose {
                ZStack {
                    AppBackground()
                    ComposeView(
                        args: args, maxChars: state.maxChars, altLimit: state.altLimit,
                        postFormats: state.postFormats, onClose: { nav.compose = nil }
                    )
                }
                .transition(.opacity)
            }
        }
        .environment(\.linkHandler, linkHandler)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { width = g.size.width }
                .onChange(of: g.size.width) { _, w in width = w }
        })
        // Varslene har egen kolonne: fanen trengs ikke lenger
        .onChange(of: wide) { _, isWide in
            if isWide && nav.tab == .notifications { nav.go(.home) }
        }
        // I brede vinduer regnes varslene som sett når man går over til en annen app
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if wide { notificationsModel.markSeen() }
        }
        .task(id: state.activeKey) { listsModel.refresh() }
        // Ikke alle Pleroma-tjenere har helsesjekken slått på: knappen vises bare når den svarer med en status
        .task(id: "\(state.activeKey ?? "")|\(state.isPleroma)") {
            healthAvailable = false
            if state.isPleroma { healthAvailable = ((try? await app.api.healthcheck()) ?? nil) != nil }
        }
        .onChange(of: app.commandTick) { handle(app.command) }
        // Telleren for nye varsler nullstilles når man går vekk fra varselsiden
        .onChange(of: notificationsVisible) { _, visible in
            if !visible { notificationsModel.markSeen() }
        }
    }

    private var notificationsVisible: Bool {
        nav.compose == nil && (wide || (nav.tab == .notifications && nav.top == nil))
    }

    private var notificationsModel: NotificationsModel {
        cache.get("notifications") { NotificationsModel() }
    }

    private func handle(_ c: AppCommand?) {
        switch c {
        case .compose: if nav.compose == nil { nav.compose = ComposeArgs() }
        case .tab(.notifications) where wide: app.signal(scroll: true, refresh: true, scope: .side)
        case .tab(let t): if nav.compose == nil { go(t) }
        case .refresh: app.signal(refresh: true)
        case .back: if nav.compose == nil { pop() }
        case nil: break
        }
    }

    private func go(_ t: MainTab) {
        if t == nav.tab { (nav.stacks[t] ?? []).forEach(forget) }
        nav.go(t)
    }

    private func pop() {
        if let r = nav.pop() { forget(r) }
    }

    /// En side som er lukket, får en ny ViewModel neste gang den åpnes (som i Android-appen).
    private func forget(_ r: Route) {
        if let k = r.cacheKey, !nav.isOpen(r) { cache.remove(k) }
    }

    // MARK: Lenker og handlinger

    private var linkHandler: LinkHandler {
        let nav = self.nav
        let api = app.api
        return LinkHandler(
            openTag: { tag in nav.push(.tag(tag)) },
            openProfile: { id, url in
                // Trykk på @omtale åpner profilen i appen. Ukjent konto slås opp via egen instans;
                // finnes den ikke der, åpnes lenken i nettleseren.
                if let id {
                    nav.push(.account(id))
                } else {
                    Task {
                        if let found = try? await api.search(url, type: "accounts", resolve: true).accounts.first {
                            nav.push(.account(found.id))
                        } else {
                            openExternal(url)
                        }
                    }
                }
            }
        )
    }

    /// [pin]: fremheving i «…»-menyen, bare på brukerens egen profilside.
    private func actions(_ host: StatusHost, pin: Bool = false) -> StatusActions {
        let nav = self.nav
        let myAcct = state.me?.acct
        return StatusActions(
            myId: state.me?.id,
            openStatus: { nav.push(.thread($0.id)) },
            openProfile: { nav.push(.account($0.id)) },
            reply: { nav.compose = replyArgs($0, myAcct: myAcct) },
            boost: { host.toggleBoost($0) },
            favourite: { host.toggleFavourite($0) },
            bookmark: { host.toggleBookmark($0) },
            vote: { host.vote($0, $1, $2) },
            delete: { host.delete($0) },
            canEdit: state.canEdit,
            edit: { nav.compose = ComposeArgs(editId: $0.id) },
            pin: pin ? { host.togglePin($0) } : nil
        )
    }

    // MARK: Innhold

    private var content: some View {
        ZStack {
            ForEach(MainTab.allCases.filter { nav.visited.contains($0) }, id: \.self) { t in
                let active = t == nav.tab
                let stack = nav.stacks[t] ?? []
                ZStack {
                    tabRoot(t).screen(visible: active && stack.isEmpty && nav.compose == nil)
                    ForEach(stack.enumerated().map { StackEntry(index: $0.offset, route: $0.element) }, id: \.self) { e in
                        routeView(e.route).screen(visible: active && e.index == stack.count - 1 && nav.compose == nil)
                    }
                }
                .opacity(active ? 1 : 0)
                .allowsHitTesting(active)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tabRoot(_ t: MainTab) -> some View {
        switch t {
        case .home:
            let key = nav.selectedListId ?? "home"
            let m = homeModel(nav.selectedListId)
            StatusFeedView(model: m, actions: actions(m)).id(key)
        case .media:
            let key = nav.mediaListId ?? "home"
            let m = mediaModel(nav.mediaListId)
            StatusFeedView(model: m, actions: actions(m), emptyText: L("empty_media"), mediaCards: true).id(key)
        case .notifications:
            NotificationsView(
                model: notificationsModel,
                openStatus: { nav.push(.thread($0)) },
                openProfile: { nav.push(.account($0.id)) }
            )
        case .search:
            SearchView(
                model: cache.get("search") { SearchModel() },
                openAccount: { nav.push(.account($0.id)) },
                openTag: { nav.push(.tag($0)) }
            )
        case .profile:
            if let me = state.me {
                let m = cache.get("me_" + me.id) { AccountModel(accountId: me.id) }
                AccountView(
                    model: m, isMe: true, actions: actions(m.feed, pin: true),
                    onLogout: { auth.logout() }, onSwitchAccount: showSwitcher
                )
            } else {
                VStack { LoadingRow(); Spacer() }
            }
        }
    }

    @ViewBuilder
    private func routeView(_ r: Route) -> some View {
        switch r {
        case .thread(let id):
            let m = cache.get("thr_" + id) { ThreadModel(statusId: id) }
            ThreadView(model: m, actions: actions(m))
        case .account(let id):
            let m = cache.get("acc_" + id) { AccountModel(accountId: id) }
            let isMe = id == state.me?.id
            AccountView(
                model: m, isMe: isMe, actions: actions(m.feed, pin: isMe),
                onLogout: { auth.logout() }, onSwitchAccount: showSwitcher
            )
        case .tag(let tag):
            let m = cache.get("tag_" + tag) { FeedModel { try await AppState.shared.api.tagTimeline(tag, maxId: $0) } }
            StatusFeedView(model: m, actions: actions(m))
        case .instanceAbout:
            InstanceAboutView(pleroma: state.isPleroma)
        case .chat:
            ChatView()
        }
    }

    private func homeModel(_ listId: String?) -> FeedModel {
        let api = app.api
        switch listId {
        case nil: return cache.get("tl_home") { FeedModel { try await api.timeline(.home, maxId: $0) } }
        case localFeed: return cache.get("tl_local") { FeedModel { try await api.timeline(.local, maxId: $0) } }
        case federatedFeed: return cache.get("tl_federated") { FeedModel { try await api.timeline(.federated, maxId: $0) } }
        case let id?: return cache.get("list_" + id) { FeedModel { try await api.listTimeline(id, maxId: $0) } }
        }
    }

    /// Samme feeder som i «Hjem», men bare innlegg med bilder/video.
    private func mediaModel(_ listId: String?) -> FeedModel {
        let api = app.api
        return cache.get("media_" + (listId ?? "home")) {
            let m = FeedModel { maxId in
                switch listId {
                case nil: return try await api.timeline(.home, maxId: maxId)
                case localFeed: return try await api.timeline(.local, maxId: maxId, onlyMedia: true)
                case federatedFeed: return try await api.timeline(.federated, maxId: maxId, onlyMedia: true)
                case let id?: return try await api.listTimeline(id, maxId: maxId)
                }
            }
            m.accept = { ($0.reblog ?? $0).hasVisualMedia }
            m.maxPages = { 5 }
            return m
        }
    }

    // MARK: Toppfelt

    private var atRoot: Bool { nav.top == nil }

    private var title: String {
        if let r = nav.top {
            switch r {
            case .thread: return L("title_thread")
            case .account: return L("title_account")
            case .tag(let t): return "#" + t
            case .instanceAbout: return L("instance_about_title")
            case .chat: return L("title_chat")
            }
        }
        switch nav.tab {
        case .home: return nav.selectedListId.flatMap(feedTitle) ?? L("title_home")
        case .media: return nav.mediaListId.flatMap(feedTitle) ?? L("title_media")
        case .notifications: return L("title_notifications")
        case .search: return L("title_search")
        case .profile: return L("title_profile")
        }
    }

    /// Navnet på en valgt feed i Hjem/Bilder, eller nil når listen ikke (lenger) finnes.
    private func feedTitle(_ id: String) -> String? {
        switch id {
        case localFeed: return L("menu_local_feed")
        case federatedFeed: return L("title_federated")
        default: return listsModel.lists.first { $0.id == id }?.title
        }
    }

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                if !atRoot {
                    TopIconButton(icon: "arrow.left", help: L("back")) { pop() }
                }
                if atRoot && (nav.tab == .home || nav.tab == .media) {
                    listMenuTitle
                } else {
                    Text(title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(PT.topBarText)
                        .lineLimit(1)
                        .padding(.leading, atRoot ? 10 : 2)
                }
                Spacer(minLength: 8)
                topActions
            }
            .padding(.horizontal, 6)
            .frame(height: 50)
            PDivider()
        }
        .background(PT.topBar.ignoresSafeArea(edges: .top))
        .contentShape(Rectangle())
        // Dobbeltklikk på tomt område i toppfeltet ruller listen på skjermen til toppen
        .onTapGesture(count: 2) { app.signal(scroll: true, scope: .main) }
    }

    /// «Hjem ▾» – klikk for å bytte mellom hjemmetidslinjen, lokal og føderert feed og egne lister.
    private var listMenuTitle: some View {
        Button {
            listsModel.refresh()
            showListMenu()
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 19, weight: .bold)).lineLimit(1)
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9))
            }
            .foregroundStyle(PT.topBarText)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("lists_choose"))
    }

    private func showListMenu() {
        let media = nav.tab == .media
        let selected = media ? nav.mediaListId : nav.selectedListId
        let select: (String?) -> Void = { id in
            if media { nav.mediaListId = id } else { nav.selectedListId = id }
        }
        var items: [MenuEntry] = [
            .item(L("title_home"), icon: "house.fill", checked: selected == nil) { select(nil) },
            .item(L("menu_local_feed"), icon: "person.2.fill", checked: selected == localFeed) { select(localFeed) },
            .item(L("title_federated"), icon: "globe", checked: selected == federatedFeed) { select(federatedFeed) },
            .separator,
            .header(L("lists_header")),
        ]
        if listsModel.lists.isEmpty { items.append(.disabled(L("lists_none"))) }
        for l in listsModel.lists {
            items.append(.item(l.title, icon: "list.bullet", checked: l.id == selected) { select(l.id) })
        }
        showMenu(items)
    }

    @ViewBuilder
    private var topActions: some View {
        if atRoot && nav.tab == .notifications {
            NewNotificationsBadge(model: notificationsModel)
        }
        if atRoot && nav.tab == .home && nav.selectedListId == localFeed {
            // Helsestatusen til tjeneren (/api/pleroma/healthcheck), bare på Pleroma med sjekken på
            if healthAvailable {
                TopIconButton(icon: "waveform.path.ecg", help: L("health_button")) { app.present(HealthDialog()) }
            }
            // «Om»-siden til instansen brukeren er logget inn på
            Button { nav.push(.instanceAbout) } label: {
                Text(L("instance_about_button"))
                    .font(.system(size: PF.body, weight: .medium))
                    .foregroundStyle(PT.topBarText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if atRoot && nav.tab == .home {
            TopIconButton(icon: "bubble.left.and.bubble.right.fill", help: L("chat_button")) { nav.push(.chat) }
        }
        if atRoot && nav.tab == .media {
            TopIconButton(icon: "info.circle.fill", help: L("media_info_button")) {
                app.present(InfoDialog(title: L("title_media"), text: L("media_info_text")))
            }
        }
        if nav.top == .chat {
            TopIconButton(icon: "info.circle.fill", help: L("chat_info_button")) {
                app.present(InfoDialog(title: L("title_chat"), text: L("chat_info_text")))
            }
        }
        if atRoot && nav.tab == .profile {
            TopIconButton(icon: "paintpalette.fill", help: L("theme_button")) { app.present(ThemePickerDialog()) }
            TopIconButton(icon: "info.circle.fill", help: L("about_button")) { app.present(AboutDialog()) }
        }
    }

    private func showSwitcher() {
        let auth = self.auth
        app.present(AccountSwitchDialog(
            auth: auth,
            onSelect: { key in AppState.shared.dismissDialog(); auth.switchTo(key) },
            onAdd: { AppState.shared.dismissDialog(); auth.startAddingAccount() }
        ))
    }

    // MARK: Varselkolonne

    /// Varslene i en smal kolonne til høyre når vinduet er bredt.
    private var notificationsPanel: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    Text(L("title_notifications"))
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(PT.topBarText)
                        .lineLimit(1)
                        .padding(.leading, 10)
                    Spacer(minLength: 8)
                    NewNotificationsBadge(model: notificationsModel)
                    // Oppdaterer varslene (snurrer mens de hentes)
                    if notificationsModel.paging.refreshing {
                        Spinner(size: 18).frame(width: 36, height: 36)
                    } else {
                        TopIconButton(icon: "arrow.clockwise", help: L("menu_refresh")) {
                            app.signal(scroll: true, scope: .side)
                            notificationsModel.refresh()
                        }
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 50)
                PDivider()
            }
            .background(PT.topBar.ignoresSafeArea(edges: .top))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { app.signal(scroll: true, scope: .side) }
            NotificationsView(
                model: notificationsModel,
                openStatus: { nav.push(.thread($0)) },
                openProfile: { nav.push(.account($0.id)) }
            )
            .environment(\.signalScope, .side)
            .environment(\.screenActive, nav.compose == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bunnmeny

    /// Bunnlinje: Hjem · Bilder · Varsler · Søk · [Skriv] · Profil
    private var bottomBar: some View {
        VStack(spacing: 0) {
            PDivider()
            HStack(spacing: 0) {
                navItem(.home)
                navItem(.media)
                if !wide { navItem(.notifications) }
                navItem(.search)
                // «Skriv nytt innlegg»: fremhevet knapp midt i linjen
                Button { nav.compose = ComposeArgs() } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(PT.fg)
                        .frame(width: 44, height: 44)
                        .background(PT.link)
                        .pBorder(PT.border)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("nav_compose"))
                .frame(maxWidth: .infinity)
                navItem(.profile)
            }
            .frame(height: 56)
            // Sentrert under innholdet i hovedkolonnen
            .frame(maxWidth: contentMaxWidth)
            .frame(width: wide ? mainWidth : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(PT.topBar)
    }

    private func navItem(_ t: MainTab) -> some View {
        let selected = nav.tab == t && atRoot
        return Button { tap(t) } label: {
            Image(systemName: t.icon)
                .font(.system(size: 19))
                .foregroundStyle(selected ? PT.navActive : PT.link)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t.label)
        .accessibilityLabel(t.label)
    }

    /// Første klikk navigerer med en gang; et nytt klikk på samme knapp like etter er et dobbeltklikk,
    /// som ruller til toppen og laster feeden på nytt.
    private func tap(_ t: MainTab) {
        let now = Date()
        let prev = lastTap
        go(t)
        if let prev, prev.tab == t, now.timeIntervalSince(prev.at) <= NSEvent.doubleClickInterval {
            lastTap = nil
            app.signal(scroll: true, refresh: true, scope: .main)
        } else {
            lastTap = (t, now)
        }
    }
}

private extension View {
    func screen(visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .environment(\.screenActive, visible)
    }
}

/// Startteksten i et svar: brukerne som skal nevnes og emneknaggene i innlegget.
func replyArgs(_ s: Status, myAcct: String?) -> ComposeArgs {
    var seen = Set<String>()
    let handles = ([s.account.acct] + s.mentions.map(\.acct))
        .filter { !$0.isEmpty && $0 != myAcct }
        .filter { seen.insert($0).inserted }
        .joined(separator: " ")
    let tags = hashtagsIn(s.content, known: s.tags).joined(separator: " ")
    return ComposeArgs(replyId: s.id, replyMentions: handles, replyTags: tags, replyVisibility: s.visibility)
}

struct TopIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(PT.topBarText)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// «X nye varsler» øverst til høyre på varselsiden, etter oppdatering.
private struct NewNotificationsBadge: View {
    let model: NotificationsModel
    var body: some View {
        if model.newCount > 0 {
            Text(Lp("new_notifications", model.newCount))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(PT.topBarText)
                .padding(.trailing, 8)
        }
    }
}

/// Bakgrunnsbildet med slør i temaets farge, så teksten alltid er lesbar.
struct AppBackground: View {
    private static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "bakgrunn", withExtension: "jpg") {
            return NSImage(contentsOf: url)
        }
        // Ved «swift run» fra kildekoden
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/bakgrunn.jpg")
        return NSImage(contentsOf: dev)
    }()

    var body: some View {
        ZStack {
            PT.bg
            if let img = Self.image {
                GeometryReader { geo in
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
            PT.overlay
        }
        .ignoresSafeArea()
    }
}

// MARK: - Menyer

/// Et punkt i en lokal meny (vises som vanlig macOS-meny der musepekeren står).
enum MenuEntry {
    case item(String, icon: String? = nil, checked: Bool = false, color: NSColor? = nil, action: () -> Void)
    case header(String)
    case disabled(String)
    case separator
}

private final class MenuTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

@MainActor
func showMenu(_ entries: [MenuEntry]) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    var targets: [MenuTarget] = []
    for e in entries {
        switch e {
        case let .item(title, icon, checked, color, action):
            let t = MenuTarget(action)
            targets.append(t)
            let item = NSMenuItem(title: title, action: #selector(MenuTarget.run), keyEquivalent: "")
            item.target = t
            item.representedObject = t
            if let icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
            if checked { item.state = .on }
            if let color {
                item.attributedTitle = NSAttributedString(string: title, attributes: [
                    .foregroundColor: color, .font: NSFont.menuFont(ofSize: 0),
                ])
            }
            menu.addItem(item)
        case .header(let title):
            menu.addItem(NSMenuItem.sectionHeader(title: title))
        case .disabled(let title):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .separator:
            menu.addItem(.separator())
        }
    }
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    _ = targets
}
