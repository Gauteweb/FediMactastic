import Foundation
import Observation

/// En liste med innlegg som kortene kan endre (favoritt, deling, bokmerke, avstemning, sletting).
@MainActor
protocol StatusHost: AnyObject {
    var items: [Status] { get set }
}

@MainActor
extension StatusHost {
    private var api: ApiClient { AppState.shared.api }

    /// [updated] kan være en «wrapper» rundt et delt innlegg – da er det reblog som er originalen.
    func replaceStatus(_ updated: Status) {
        let orig = updated.reblog ?? updated
        items = items.map { s in
            if s.reblog?.id == orig.id {
                var c = s
                c.reblog = orig
                return c
            }
            return s.id == orig.id ? orig : s
        }
    }

    func toggleFavourite(_ s: Status) { act { self.replaceStatus(try await self.api.favourite(s.id, !s.favourited)) } }
    func toggleBoost(_ s: Status) { act { self.replaceStatus(try await self.api.reblog(s.id, !s.reblogged)) } }
    func toggleBookmark(_ s: Status) { act { self.replaceStatus(try await self.api.bookmark(s.id, !s.bookmarked)) } }

    func togglePin(_ s: Status) {
        act {
            self.replaceStatus(try await self.api.pin(s.id, !s.pinned))
            AppState.shared.toast(L(s.pinned ? "unpinned" : "pinned"))
        }
    }

    func vote(_ owner: Status, _ poll: Poll, _ choices: [Int]) {
        act {
            let updated = try await self.api.vote(pollId: poll.id, choices: choices)
            self.items = self.items.map { x in
                var inner = x.reblog ?? x
                guard inner.id == owner.id else { return x }
                inner.poll = updated
                if x.reblog != nil {
                    var c = x
                    c.reblog = inner
                    return c
                }
                return inner
            }
        }
    }

    func delete(_ s: Status) {
        act {
            try await self.api.deleteStatus(s.id)
            self.items.removeAll { $0.id == s.id || $0.reblog?.id == s.id }
        }
    }
}

struct Paging: Equatable {
    var loading = false
    var refreshing = false
    var endReached = false
    var error: String?
}

/// Liste med «hent flere»-paginering (max_id). Brukes for tidslinjer, lister, emneknagger og profiler.
@MainActor
@Observable
final class FeedModel: StatusHost {
    var items: [Status] = []
    var paging = Paging()

    @ObservationIgnored private let fetch: (String?) async throws -> [Status]
    /// Filter i appen. Luker det bort mye, hentes flere sider på rad (se [maxPages]).
    @ObservationIgnored var accept: (Status) -> Bool = { _ in true }
    /// Hvor mange sider som høyst hentes på rad for å fylle opp etter [accept].
    @ObservationIgnored var maxPages: () -> Int = { 1 }

    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var moreTask: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?

    private static let minPerLoad = 5

    init(fetch: @escaping (String?) async throws -> [Status]) {
        self.fetch = fetch
        observer = NotificationCenter.default.addObserver(forName: AppState.postedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, !self.items.isEmpty { self.refresh() }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Henter én eller flere sider fra [from]. Gir innleggene som slapp gjennom, og om enden er nådd.
    private func fetchFiltered(_ from: String?) async throws -> ([Status], Bool) {
        var out: [Status] = []
        var maxId = from
        for _ in 0..<max(1, maxPages()) {
            let page = try await fetch(maxId)
            if page.isEmpty { return (out, true) }
            maxId = page.last?.id
            cursor = maxId
            out += page.filter(accept)
            if out.count >= Self.minPerLoad { return (out, false) }
        }
        return (out, false)
    }

    func ensureLoaded() {
        if items.isEmpty && !paging.refreshing { refresh() }
    }

    func refresh() {
        refreshTask?.cancel()
        moreTask?.cancel()
        paging.refreshing = true
        paging.loading = false
        paging.error = nil
        refreshTask = Task {
            do {
                let (page, end) = try await fetchFiltered(nil)
                if Task.isCancelled { return }
                items = page
                paging = Paging(endReached: end)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                paging.refreshing = false
                paging.error = userMessage(error)
            }
        }
    }

    func loadMore() {
        guard let from = cursor, !paging.loading, !paging.refreshing, !paging.endReached else { return }
        paging.loading = true
        moreTask = Task {
            do {
                let (page, end) = try await fetchFiltered(from)
                if Task.isCancelled { return }
                let known = Set(items.map(\.id))
                items += page.filter { !known.contains($0.id) }
                paging.loading = false
                paging.endReached = end
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                paging.loading = false
                paging.error = userMessage(error)
            }
        }
    }

    /// Kalles når et kort vises: nær slutten av listen hentes flere.
    func appeared(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if i >= items.count - 4 { loadMore() }
    }
}

/// Brukerens egne lister (vises som meny i toppen av «Hjem»).
@MainActor
@Observable
final class ListsModel {
    var lists: [MastoList] = []

    func refresh() {
        Task {
            // Lister er en bonus – feil her skal ikke forstyrre resten av appen.
            if let l = try? await AppState.shared.api.lists() {
                lists = l.sorted { $0.title.lowercased() < $1.title.lowercased() }
            }
        }
    }
}

struct ListMembership {
    var lists: [MastoList]
    var memberOf: Set<String>
}

@MainActor
@Observable
final class AccountModel {
    let accountId: String
    var account: Account?
    var relationship: Relationship?
    /// «Kun media»: bare brukerens egne innlegg med bilde eller video.
    var mediaOnly = false
    /// Mine lister og hvilke av dem kontoen ligger i (nil til de er hentet).
    var lists: ListMembership?
    @ObservationIgnored var feed: FeedModel!

    init(accountId: String) {
        self.accountId = accountId
        let feed = FeedModel { [weak self] maxId in
            guard let self else { return [] }
            return try await AppState.shared.api.accountStatuses(accountId, maxId: maxId, onlyMedia: self.mediaOnly)
        }
        // Lyd og delte innlegg kan slippe gjennom tjenerens filter; de lukes bort her.
        feed.accept = { [weak self] s in !(self?.mediaOnly ?? false) || (s.reblog == nil && s.hasVisualMedia) }
        feed.maxPages = { [weak self] in (self?.mediaOnly ?? false) ? 5 : 1 }
        self.feed = feed
    }

    func setMediaOnly(_ on: Bool) {
        guard mediaOnly != on else { return }
        mediaOnly = on
        feed.items = []
        feed.refresh()
    }

    func loadHeader(isMe: Bool) {
        act {
            self.account = try await AppState.shared.api.account(self.accountId)
            if !isMe { self.relationship = try await AppState.shared.api.relationship(self.accountId) }
        }
    }

    func toggleFollow() {
        act {
            let following = self.relationship.map { $0.following || $0.requested } ?? false
            self.relationship = try await AppState.shared.api.follow(self.accountId, !following)
            self.account = try await AppState.shared.api.account(self.accountId)
        }
    }

    func loadLists() {
        lists = nil
        act {
            async let all = AppState.shared.api.lists()
            async let mine = AppState.shared.api.accountLists(self.accountId)
            let (a, m) = try await (all, mine)
            self.lists = ListMembership(
                lists: a.sorted { $0.title.lowercased() < $1.title.lowercased() },
                memberOf: Set(m.map(\.id))
            )
        }
    }

    func setInList(_ listId: String, add: Bool) {
        act {
            try await AppState.shared.api.setInList(listId, accountId: self.accountId, add: add)
            if add { self.lists?.memberOf.insert(listId) } else { self.lists?.memberOf.remove(listId) }
        }
    }

    func createListAndAdd(_ title: String) {
        act {
            let list = try await AppState.shared.api.createList(title.trimmingCharacters(in: .whitespaces))
            try await AppState.shared.api.setInList(list.id, accountId: self.accountId, add: true)
            if var m = self.lists {
                m.lists = (m.lists + [list]).sorted { $0.title.lowercased() < $1.title.lowercased() }
                m.memberOf.insert(list.id)
                self.lists = m
            }
        }
    }
}

@MainActor
@Observable
final class ThreadModel: StatusHost {
    let statusId: String
    var items: [Status] = []
    var loading = true
    var error: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(statusId: String) {
        self.statusId = statusId
        observer = NotificationCenter.default.addObserver(forName: AppState.postedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, self.started { self.reload() }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func load() {
        if started { return }
        started = true
        reload()
    }

    func reload() {
        loading = true
        error = nil
        Task {
            do {
                async let st = AppState.shared.api.status(statusId)
                async let ctx = AppState.shared.api.statusContext(statusId)
                let (s, c) = try await (st, ctx)
                items = c.ancestors + [s] + c.descendants
            } catch {
                started = false
                self.error = userMessage(error)
            }
            loading = false
        }
    }
}

enum NotificationFilter { case all, replies }

@MainActor
@Observable
final class NotificationsModel {
    /// Brukeren varslene gjelder. «Sett» lagres på den.
    @ObservationIgnored private let accountKey = AppState.shared.store.activeKey

    var items: [AppNotification] = []
    var paging = Paging()
    var filter = NotificationFilter.all
    /// Varsler som er nyere enn det øverste brukeren hadde sett sist hen forlot varselsiden.
    var newCount = 0

    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var moreTask: Task<Void, Never>?

    /// Kalles når brukeren går vekk fra varselsiden: alt som vises nå regnes som sett.
    func markSeen() {
        if filter == .all, let top = items.first, let key = accountKey {
            AppState.shared.store.updateAccount(key) { $0.lastSeenNotification = top.id }
        }
        newCount = 0
    }

    private func countNew(_ list: [AppNotification]) -> Int {
        guard filter == .all,
              let seen = AppState.shared.store.accounts.first(where: { $0.key == accountKey })?.lastSeenNotification
        else { return 0 } // aldri vært her før
        return list.firstIndex { $0.id == seen } ?? list.count
    }

    /// Sikkerhetsnett: viser bare svar/omtaler selv om en tjener skulle ignorere filteret.
    private func matches(_ n: AppNotification, _ f: NotificationFilter) -> Bool {
        f == .all || n.type == "mention"
    }

    func setFilter(_ f: NotificationFilter) {
        guard f != filter else { return }
        filter = f
        items = []
        cursor = nil
        paging = Paging()
        refresh()
    }

    func ensureLoaded() {
        if items.isEmpty && !paging.refreshing { refresh() }
    }

    func refresh() {
        refreshTask?.cancel()
        moreTask?.cancel()
        let f = filter
        paging.refreshing = true
        paging.loading = false
        paging.error = nil
        refreshTask = Task {
            do {
                let raw = try await AppState.shared.api.notifications(maxId: nil, onlyMentions: f == .replies)
                if Task.isCancelled { return }
                cursor = raw.last?.id
                let fresh = raw.filter { matches($0, f) }
                items = fresh
                newCount = countNew(fresh)
                paging = Paging(endReached: raw.isEmpty)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                paging.refreshing = false
                paging.error = userMessage(error)
            }
        }
    }

    func loadMore() {
        guard let from = cursor, !paging.loading, !paging.refreshing, !paging.endReached else { return }
        let f = filter
        paging.loading = true
        moreTask = Task {
            do {
                let raw = try await AppState.shared.api.notifications(maxId: from, onlyMentions: f == .replies)
                if Task.isCancelled { return }
                cursor = raw.last?.id ?? from
                let known = Set(items.map(\.id))
                items += raw.filter { matches($0, f) && !known.contains($0.id) }
                paging.loading = false
                paging.endReached = raw.isEmpty
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                paging.loading = false
                paging.error = userMessage(error)
            }
        }
    }

    func appeared(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if i >= items.count - 4 { loadMore() }
    }
}

struct SearchState {
    var query = ""
    var loading = false
    var accounts: [Account] = []
    var hashtags: [String] = []
    var error: String?
    var searched = false
}

/// Når brukeren skriver «#navn», skal «#navn» alltid være første treff.
func withTypedTag(_ typed: String, _ found: [String]) -> [String] {
    let t = typed.trimmingCharacters(in: .whitespaces)
    guard re("^[\\p{L}\\p{N}_]+$").test(t) else { return found }
    let rest = found.filter { $0.caseInsensitiveCompare(t) != .orderedSame }
    let exact = found.first { $0.caseInsensitiveCompare(t) == .orderedSame } ?? t
    return [exact] + rest
}

/// Søk etter brukere og emneknagger: «@navn» bare brukere, «#navn» bare emneknagger, ellers begge.
@MainActor
@Observable
final class SearchModel {
    var state = SearchState()
    @ObservationIgnored private var task: Task<Void, Never>?

    func onQueryChange(_ q: String) {
        guard q != state.query else { return }
        state.query = q
        task?.cancel()
        if q.trimmingCharacters(in: .whitespaces).isEmpty {
            state = SearchState()
            return
        }
        task = Task {
            try? await Task.sleep(for: .milliseconds(450)) // vent litt mens brukeren skriver
            if Task.isCancelled { return }
            await run(q)
        }
    }

    func submit() {
        let q = state.query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        task?.cancel()
        task = Task { await run(q) }
    }

    func clear() {
        task?.cancel()
        state = SearchState()
    }

    private func run(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespaces)
        let wantUsers = !q.hasPrefix("#")
        let wantTags = !q.hasPrefix("@")
        var term = q
        if term.hasPrefix("@") || term.hasPrefix("#") { term.removeFirst() }
        term = term.trimmingCharacters(in: .whitespaces)
        if term.isEmpty {
            state.loading = false
            state.accounts = []
            state.hashtags = []
            state.searched = false
            return
        }
        state.loading = true
        state.error = nil
        let term2 = term
        do {
            let api = AppState.shared.api
            async let users: SearchResponse? = wantUsers ? api.search(term2, type: "accounts", resolve: term2.contains("@")) : nil
            async let tags: SearchResponse? = wantTags ? api.search(term2, type: "hashtags", resolve: false) : nil
            let (u, t) = try await (users, tags)
            if Task.isCancelled { return }
            var tagNames = t?.tagNames ?? []
            if q.hasPrefix("#") { tagNames = withTypedTag(term, tagNames) }
            state.loading = false
            state.accounts = u?.accounts ?? []
            state.hashtags = tagNames
            state.searched = true
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            state.loading = false
            state.error = userMessage(error)
        }
    }
}
