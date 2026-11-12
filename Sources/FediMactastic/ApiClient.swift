import Foundation
import UniformTypeIdentifiers

struct ApiError: Error {
    let code: Int
    let message: String
}

/// Prosent-koding for en del av en adresse (bare A–Z, a–z, 0–9 og -._~ står urørt).
func urlEncode(_ s: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

/// Tynn klient mot Mastodon-kompatibelt API (Pleroma, Akkoma, GoToSocial, Mastodon …).
/// Instansen leses fra [SessionStore], så samme klient fungerer mot alle instanser.
@MainActor
final class ApiClient {
    static let redirectUri = "feditastic://oauth"
    static let website = "https://github.com/Gauteweb/Feditastic"
    static let scopes = "read write follow push"
    static let clientName = "FediMactastic"

    private let store: SessionStore
    private let http: URLSession

    init(store: SessionStore) {
        self.store = store
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 40
        config.timeoutIntervalForResource = 180
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        http = URLSession(configuration: config)
    }

    // MARK: Infrastruktur

    private func request(
        _ path: String, base: String? = nil, auth: Bool = true, method: String = "GET",
        accept: String = "application/json",
    ) throws -> URLRequest {
        guard let root = base ?? store.instance else { throw ApiError(code: 0, message: "Ingen instans valgt") }
        guard let url = URL(string: root + path) else { throw ApiError(code: 0, message: "Ugyldig adresse") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(accept, forHTTPHeaderField: "Accept")
        if auth, let t = store.token { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private func send(_ r: URLRequest) async throws -> (Data, Int) {
        let (data, resp) = try await http.data(for: r)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func exec(_ r: URLRequest) async throws -> Data {
        let (data, code) = try await send(r)
        guard (200..<300).contains(code) else {
            throw ApiError(code: code, message: errorMessage(data) ?? "HTTP \(code)")
        }
        return data
    }

    private func errorMessage(_ data: Data) -> String? {
        (try? J.parse(data))?["error"].string
    }

    private func get(_ path: String) async throws -> J {
        try J.parse(try await exec(try request(path)))
    }

    private func formBody(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\(urlEncode($0.0))=\(urlEncode($0.1))" }.joined(separator: "&").utf8)
    }

    private func post(_ path: String, form: [(String, String)] = [], base: String? = nil, auth: Bool = true) async throws -> J {
        var r = try request(path, base: base, auth: auth, method: "POST")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = formBody(form)
        return try J.parse(try await exec(r))
    }

    private func sendJSON(_ path: String, method: String, body: [String: Any], headers: [String: String] = [:]) async throws -> J {
        var r = try request(path, method: method)
        r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await exec(r)
        return (try? J.parse(data)) ?? J(nil)
    }

    private func withPaging(_ path: String, _ maxId: String?, limit: Int = 20) -> String {
        let sep = path.contains("?") ? "&" : "?"
        return path + sep + "limit=\(limit)" + (maxId.map { "&max_id=\(urlEncode($0))" } ?? "")
    }

    // MARK: Innlogging (OAuth)

    func normalizeInstance(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
            s = "https://" + (s.split(separator: "@").last.map(String.init) ?? s)
        }
        guard s.count > 8, s.contains("."), URL(string: s) != nil else { return nil }
        return s
    }

    func registerApp(base: String) async throws -> (clientId: String, clientSecret: String) {
        let j = try await post("/api/v1/apps", form: [
            ("client_name", Self.clientName),
            ("redirect_uris", Self.redirectUri),
            ("scopes", Self.scopes),
            ("website", Self.website),
        ], base: base, auth: false)
        guard let id = j["client_id"].string, let secret = j["client_secret"].string else {
            throw ApiError(code: 0, message: "Ugyldig svar fra instansen")
        }
        return (id, secret)
    }

    func authorizeUrl(base: String, clientId: String) -> URL? {
        var c = URLComponents(string: base + "/oauth/authorize")
        c?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectUri),
            URLQueryItem(name: "scope", value: Self.scopes),
            // Be om innloggingsskjema selv om nettleseren er innlogget fra før (ved «Legg til bruker»)
            URLQueryItem(name: "force_login", value: "true"),
        ]
        return c?.url
    }

    func exchangeToken(base: String, clientId: String, clientSecret: String, code: String) async throws -> String {
        let j = try await post("/oauth/token", form: [
            ("client_id", clientId),
            ("client_secret", clientSecret),
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", Self.redirectUri),
            ("scope", Self.scopes),
        ], base: base, auth: false)
        guard let token = j["access_token"].string else { throw ApiError(code: 0, message: "Fikk ikke token") }
        return token
    }

    // MARK: Instans og konto

    func instanceInfo() async throws -> InstanceInfo { InstanceInfo(try await get("/api/v1/instance")) }

    /// Innholdet Pleroma-FE viser på /about: panel-teksten og tjenestevilkårene (HTML).
    /// En side som mangler (404 o.l.) hoppes over, mens nettverksfeil kastes videre.
    func instanceAboutHtml() async throws -> [String] {
        var out: [String] = []
        for path in ["/instance/panel.html", "/static/terms-of-service.html"] {
            let r = try request(path, auth: false, accept: "text/html")
            let (data, code) = try await send(r)
            guard (200..<300).contains(code) else { continue }
            let html = htmlBody(String(decoding: data, as: UTF8.self))
            if !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(html) }
        }
        return out
    }

    /// Pleromas helsesjekk. En usunn tjener svarer med 503 men samme innhold, så det leses også.
    /// Gir nil når sjekken er slått av eller ikke finnes på tjeneren.
    func healthcheck() async throws -> Healthcheck? {
        let (data, code) = try await send(try request("/api/pleroma/healthcheck", auth: false))
        if (200..<300).contains(code) || code == 503 {
            guard let j = try? J.parse(data) else { return nil }
            let h = Healthcheck(j)
            return h.healthy == nil ? nil : h
        }
        if code == 404 { return nil }
        throw ApiError(code: code, message: errorMessage(data) ?? "HTTP \(code)")
    }

    /// Mastodons lange «Om»-tekst. Endepunkter instansen ikke har gir tomt svar.
    func extendedDescription() async throws -> String {
        do { return try await get("/api/v1/instance/extended_description")["content"].str() } catch is ApiError { return "" }
    }

    func instanceRules() async throws -> [InstanceRule] {
        do { return try await get("/api/v1/instance/rules").array.map(InstanceRule.init) } catch is ApiError { return [] }
    }

    /// Plukker ut innholdet i <body> når siden er et helt HTML-dokument.
    private func htmlBody(_ html: String) -> String {
        let re = try! NSRegularExpression(pattern: "<body[^>]*>(.*)</body>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = html as NSString
        if let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return html.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func verifyCredentials() async throws -> Account { Account(try await get("/api/v1/accounts/verify_credentials")) }
    func account(_ id: String) async throws -> Account { Account(try await get("/api/v1/accounts/\(urlEncode(id))")) }

    func relationship(_ id: String) async throws -> Relationship? {
        try await get("/api/v1/accounts/relationships?id%5B%5D=\(urlEncode(id))").array.first.map(Relationship.init)
    }

    func follow(_ id: String, _ on: Bool) async throws -> Relationship {
        Relationship(try await post("/api/v1/accounts/\(urlEncode(id))/\(on ? "follow" : "unfollow")"))
    }

    // MARK: Tidslinjer

    /// [onlyMedia] gjelder bare offentlige tidslinjer (hjemmetidslinjen støtter det ikke).
    func timeline(_ kind: TimelineKind, maxId: String?, onlyMedia: Bool = false) async throws -> [Status] {
        let path: String
        switch kind {
        case .home: path = "/api/v1/timelines/home"
        case .local: path = "/api/v1/timelines/public?local=true" + (onlyMedia ? "&only_media=true" : "")
        case .federated: path = "/api/v1/timelines/public" + (onlyMedia ? "?only_media=true" : "")
        }
        return try await get(withPaging(path, maxId)).array.map(Status.init)
    }

    func listTimeline(_ listId: String, maxId: String?) async throws -> [Status] {
        try await get(withPaging("/api/v1/timelines/list/\(urlEncode(listId))", maxId)).array.map(Status.init)
    }

    func tagTimeline(_ tag: String, maxId: String?) async throws -> [Status] {
        try await get(withPaging("/api/v1/timelines/tag/\(urlEncode(tag))", maxId)).array.map(Status.init)
    }

    /// [type] er «accounts» eller «hashtags». [resolve] ber tjeneren slå opp eksterne brukere.
    func search(_ q: String, type: String, resolve: Bool) async throws -> SearchResponse {
        SearchResponse(try await get("/api/v2/search?q=\(urlEncode(q))&type=\(type)&limit=20" + (resolve ? "&resolve=true" : "")))
    }

    /// Kontoer jeg følger som matcher [q] – brukes til forslag når man skriver «@navn».
    func searchFollowing(_ q: String, limit: Int = 8) async throws -> [Account] {
        try await get("/api/v1/accounts/search?q=\(urlEncode(q))&limit=\(limit)&following=true&resolve=false").array.map(Account.init)
    }

    func lists() async throws -> [MastoList] { try await get("/api/v1/lists").array.map(MastoList.init) }

    /// Listene (av mine) som en konto ligger i.
    func accountLists(_ accountId: String) async throws -> [MastoList] {
        try await get("/api/v1/accounts/\(urlEncode(accountId))/lists").array.map(MastoList.init)
    }

    func createList(_ title: String) async throws -> MastoList {
        MastoList(try await post("/api/v1/lists", form: [("title", title)]))
    }

    func setInList(_ listId: String, accountId: String, add: Bool) async throws {
        var r = try request("/api/v1/lists/\(urlEncode(listId))/accounts", method: add ? "POST" : "DELETE")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = formBody([("account_ids[]", accountId)])
        _ = try await exec(r)
    }

    func customEmojis() async throws -> [Emoji] { try await get("/api/v1/custom_emojis").array.map(Emoji.init) }

    /// [onlyMedia]: bare egne innlegg med vedlegg (ikke delte). Tjeneren filtrerer grovt, appen finfiltrerer.
    func accountStatuses(_ id: String, maxId: String?, onlyMedia: Bool = false) async throws -> [Status] {
        let path = "/api/v1/accounts/\(urlEncode(id))/statuses" + (onlyMedia ? "?only_media=true&exclude_reblogs=true" : "")
        return try await get(withPaging(path, maxId)).array.map(Status.init)
    }

    /// [onlyMentions] filtrerer på serveren. Pleroma bruker include_types[], Mastodon types[] – begge sendes.
    func notifications(maxId: String?, onlyMentions: Bool = false) async throws -> [AppNotification] {
        let path = onlyMentions
            ? "/api/v1/notifications?include_types%5B%5D=mention&types%5B%5D=mention"
            : "/api/v1/notifications"
        return try await get(withPaging(path, maxId)).array.map(AppNotification.init)
    }

    func status(_ id: String) async throws -> Status { Status(try await get("/api/v1/statuses/\(urlEncode(id))")) }
    func statusContext(_ id: String) async throws -> StatusContext {
        StatusContext(try await get("/api/v1/statuses/\(urlEncode(id))/context"))
    }

    // MARK: Handlinger på innlegg

    func favourite(_ id: String, _ on: Bool) async throws -> Status {
        Status(try await post("/api/v1/statuses/\(urlEncode(id))/\(on ? "favourite" : "unfavourite")"))
    }

    func reblog(_ id: String, _ on: Bool) async throws -> Status {
        Status(try await post("/api/v1/statuses/\(urlEncode(id))/\(on ? "reblog" : "unreblog")"))
    }

    /// Hvem som har delt (fremhevet) innlegget.
    func rebloggedBy(_ id: String) async throws -> [Account] {
        try await get("/api/v1/statuses/\(urlEncode(id))/reblogged_by?limit=80").array.map(Account.init)
    }

    /// Hvem som har stjernemerket innlegget.
    func favouritedBy(_ id: String) async throws -> [Account] {
        try await get("/api/v1/statuses/\(urlEncode(id))/favourited_by?limit=80").array.map(Account.init)
    }

    func bookmark(_ id: String, _ on: Bool) async throws -> Status {
        Status(try await post("/api/v1/statuses/\(urlEncode(id))/\(on ? "bookmark" : "unbookmark")"))
    }

    /// Fremhever (fester) et eget innlegg på profilen, eller fjerner fremhevingen.
    func pin(_ id: String, _ on: Bool) async throws -> Status {
        Status(try await post("/api/v1/statuses/\(urlEncode(id))/\(on ? "pin" : "unpin")"))
    }

    func deleteStatus(_ id: String) async throws {
        _ = try await exec(try request("/api/v1/statuses/\(urlEncode(id))", method: "DELETE"))
    }

    func vote(pollId: String, choices: [Int]) async throws -> Poll {
        Poll(try await sendJSON("/api/v1/polls/\(urlEncode(pollId))/votes", method: "POST", body: ["choices": choices]))
    }

    func postStatus(
        text: String, visibility: String, spoiler: String?, replyTo: String?,
        mediaIds: [String], contentType: String?, language: String?
    ) async throws -> Status {
        var body: [String: Any] = ["status": text, "visibility": visibility]
        if let language { body["language"] = language }
        if let spoiler, !spoiler.trimmingCharacters(in: .whitespaces).isEmpty { body["spoiler_text"] = spoiler }
        if let replyTo { body["in_reply_to_id"] = replyTo }
        if !mediaIds.isEmpty { body["media_ids"] = mediaIds }
        if let contentType { body["content_type"] = contentType }
        let s = Status(try await sendJSON("/api/v1/statuses", method: "POST", body: body,
                                          headers: ["Idempotency-Key": UUID().uuidString]))
        store.rememberPosted(s.id)
        return s
    }

    /// Pleroma: gir også mulighet til å endre alt-tekst etter at bildet er festet til et innlegg.
    func updateMedia(_ id: String, description: String) async throws {
        _ = try await sendJSON("/api/v1/media/\(urlEncode(id))", method: "PUT", body: ["description": description])
    }

    func statusSource(_ id: String) async throws -> StatusSource {
        StatusSource(try await get("/api/v1/statuses/\(urlEncode(id))/source"))
    }

    func editStatus(
        id: String, text: String, spoiler: String?, mediaIds: [String], contentType: String?, language: String?
    ) async throws -> Status {
        var body: [String: Any] = ["status": text, "spoiler_text": spoiler ?? "", "media_ids": mediaIds]
        if let language { body["language"] = language }
        if let contentType { body["content_type"] = contentType }
        return Status(try await sendJSON("/api/v1/statuses/\(urlEncode(id))", method: "PUT", body: body))
    }

    func uploadMedia(fileURL: URL) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        let ext = fileURL.pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let boundary = "FediMactastic-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"opplasting.\(ext.isEmpty ? "bin" : ext)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var r = try request("/api/v1/media", method: "POST")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        r.timeoutInterval = 180
        let j = try J.parse(try await exec(r))
        guard let id = j["id"].string else { throw ApiError(code: 0, message: "Ugyldig svar fra instansen") }
        return id
    }
}
