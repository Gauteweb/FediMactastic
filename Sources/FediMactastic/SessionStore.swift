import Foundation

/// En innlogget bruker: instans, OAuth-klient, token og det appen husker om instansen.
struct SavedAccount: Codable, Identifiable, Equatable {
    /// Lokal nøkkel, uavhengig av instans og bruker-ID.
    var key: String
    var instance: String
    var clientId: String
    var clientSecret: String
    var token: String
    /// Fylles inn når innloggingen er bekreftet (verify_credentials).
    var userId: String?
    var acct: String = ""
    var displayName: String = ""
    var avatar: String = ""
    var maxChars: Int = SessionStore.defaultMaxChars
    var postFormats: [String] = []
    var altLimit: Int = SessionStore.defaultAltLimit
    var features: [String] = []
    var lastSeenNotification: String?
    /// Om instansen er Pleroma; nil til det er sjekket.
    var isPleroma: Bool?
    /// Fargetemaet brukeren har valgt; nil = sist valgte tema i appen.
    var theme: String?

    var id: String { key }

    init(key: String, instance: String, clientId: String, clientSecret: String, token: String, theme: String?) {
        self.key = key
        self.instance = instance
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.token = token
        self.theme = theme
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        instance = try c.decode(String.self, forKey: .instance)
        clientId = try c.decode(String.self, forKey: .clientId)
        clientSecret = try c.decode(String.self, forKey: .clientSecret)
        token = try c.decode(String.self, forKey: .token)
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
        acct = try c.decodeIfPresent(String.self, forKey: .acct) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar) ?? ""
        maxChars = try c.decodeIfPresent(Int.self, forKey: .maxChars) ?? SessionStore.defaultMaxChars
        postFormats = try c.decodeIfPresent([String].self, forKey: .postFormats) ?? []
        altLimit = try c.decodeIfPresent(Int.self, forKey: .altLimit) ?? SessionStore.defaultAltLimit
        features = try c.decodeIfPresent([String].self, forKey: .features) ?? []
        lastSeenNotification = try c.decodeIfPresent(String.self, forKey: .lastSeenNotification)
        isPleroma = try c.decodeIfPresent(Bool.self, forKey: .isPleroma)
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
    }

    /// «navn@instans», også for lokale brukere der instansen ikke står i acct.
    var handle: String {
        let host = instance.replacingOccurrences(of: "https://", with: "")
        if acct.isEmpty { return host }
        if acct.contains("@") { return acct }
        return acct + "@" + host
    }
}

/// Lagrer brukerne lokalt (UserDefaults, kun lesbar for brukeren). Én bruker er aktiv om gangen,
/// og egenskapene [instance], [token], [maxChars] osv. gjelder den aktive brukeren.
@MainActor
final class SessionStore {
    nonisolated static let defaultMaxChars = 5000
    nonisolated static let defaultAltLimit = 1500

    private let defaults = UserDefaults.standard
    private var cache: [SavedAccount]?

    // MARK: Brukere

    var accounts: [SavedAccount] {
        if let cache { return cache }
        let list = defaults.data(forKey: "accounts")
            .flatMap { try? JSONDecoder().decode([SavedAccount].self, from: $0) } ?? []
        cache = list
        return list
    }

    private func saveAccounts(_ list: [SavedAccount]) {
        cache = list
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: "accounts")
        }
    }

    var activeKey: String? {
        get {
            guard let k = defaults.string(forKey: "active_account"), accounts.contains(where: { $0.key == k }) else { return nil }
            return k
        }
        set { defaults.set(newValue, forKey: "active_account") }
    }

    var active: SavedAccount? {
        guard let k = activeKey else { return nil }
        return accounts.first { $0.key == k }
    }

    func updateAccount(_ key: String, _ change: (inout SavedAccount) -> Void) {
        saveAccounts(accounts.map { a in
            guard a.key == key else { return a }
            var copy = a
            change(&copy)
            return copy
        })
    }

    /// Legger til en ny bruker og gjør den aktiv.
    func addAccount(instance: String, clientId: String, clientSecret: String, token: String) -> SavedAccount {
        // En ny bruker starter med temaet som er i bruk nå
        let account = SavedAccount(
            key: UUID().uuidString, instance: instance, clientId: clientId,
            clientSecret: clientSecret, token: token, theme: theme,
        )
        saveAccounts(accounts + [account])
        activeKey = account.key
        return account
    }

    /// Fjerner andre lagrede innlogginger for samme bruker på samme instans som [key].
    func removeDuplicates(of key: String) {
        guard let me = accounts.first(where: { $0.key == key }), let uid = me.userId else { return }
        saveAccounts(accounts.filter { $0.key == key || $0.instance != me.instance || $0.userId != uid })
    }

    /// Fjerner brukeren. Var den aktiv, blir den første gjenværende brukeren aktiv.
    func removeAccount(_ key: String) {
        let rest = accounts.filter { $0.key != key }
        saveAccounts(rest)
        if defaults.string(forKey: "active_account") == key { activeKey = rest.first?.key }
    }

    // MARK: Den aktive brukeren

    var instance: String? { active?.instance }
    var token: String? { active?.token }

    // MARK: Felles for alle brukere

    private lazy var postedHere: [String] = defaults.stringArray(forKey: "posted_ids") ?? []

    /// Husker at dette innlegget ble postet fra appen (vises som «via FediMactastic»).
    func rememberPosted(_ id: String) {
        postedHere.removeAll { $0 == id }
        postedHere.append(id)
        if postedHere.count > 300 { postedHere.removeFirst(postedHere.count - 300) }
        defaults.set(postedHere, forKey: "posted_ids")
    }

    func wasPostedHere(_ id: String) -> Bool { postedHere.contains(id) }

    /// Sist valgte språk for nye innlegg (nb, nn eller en). Første gang: systemets språk.
    var language: String {
        get {
            if let l = defaults.string(forKey: "language") { return l }
            let sys = Locale.preferredLanguages.first?.lowercased() ?? "en"
            if sys.hasPrefix("nn") { return "nn" }
            if sys.hasPrefix("nb") || sys.hasPrefix("no") { return "nb" }
            return "en"
        }
        set { defaults.set(newValue, forKey: "language") }
    }

    /// Sist valgte fargetema. Brukes på innloggingsskjermen og for brukere uten eget valg.
    var theme: String? {
        get { defaults.string(forKey: "theme") }
        set { defaults.set(newValue, forKey: "theme") }
    }

    /// Temaet for den aktive brukeren, eller det sist valgte hvis brukeren ikke har valgt noe.
    var activeTheme: String? { active?.theme ?? theme }

    /// Lagrer temaet på den aktive brukeren, og som sist valgte tema.
    func saveTheme(_ id: String) {
        theme = id
        if let k = activeKey { updateAccount(k) { $0.theme = id } }
    }
}
