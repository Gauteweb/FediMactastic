import Foundation

// Modellene dekker Mastodon-kompatibelt API som Pleroma (og f.eks. Akkoma) implementerer.

enum TimelineKind { case home, local, federated }

struct Emoji: Hashable {
    var shortcode: String
    var url: String
    var staticUrl: String
    var category: String?
    var visibleInPicker: Bool

    init(_ j: J) {
        shortcode = j["shortcode"].str()
        url = j["url"].str()
        staticUrl = j["static_url"].str()
        category = j["category"].string
        visibleInPicker = j["visible_in_picker"].bool ?? true
    }
}

struct MastoList: Hashable, Identifiable {
    var id: String
    var title: String

    init(_ j: J) {
        id = j["id"].str()
        title = j["title"].str()
    }
}

/// Egendefinert profilfelt («metadata»), f.eks. «Nettside» → lenke. [value] er HTML.
struct AccountField: Hashable {
    var name: String
    var value: String
    var verifiedAt: String?

    init(_ j: J) {
        name = j["name"].str()
        value = j["value"].str()
        verifiedAt = j["verified_at"].string
    }
}

struct AccountRole: Hashable {
    var name: String
    /// Hex-farge, f.eks. «#ff3838», eller tom.
    var color: String

    init(_ j: J) {
        name = j["name"].str()
        color = j["color"].str()
    }
}

struct Account: Hashable, Identifiable {
    var id: String
    var username: String
    var acct: String
    var displayName: String
    var avatar: String
    var header: String
    var note: String
    var url: String
    var followersCount: Int
    var followingCount: Int
    var statusesCount: Int
    var emojis: [Emoji]
    var bot: Bool
    var locked: Bool
    var fields: [AccountField]
    /// Mastodon: roller instansen har valgt å vise på profilen.
    var roles: [AccountRole]
    /// Pleroma/Akkoma: admin-/moderatorflagg (bare med hvis brukeren viser rollen sin).
    var pleromaAdmin: Bool
    var pleromaModerator: Bool

    var name: String { displayName.trimmingCharacters(in: .whitespaces).isEmpty ? username : displayName }

    init(_ j: J) {
        id = j["id"].str()
        username = j["username"].str()
        acct = j["acct"].str()
        displayName = j["display_name"].str()
        avatar = j["avatar"].str()
        header = j["header"].str()
        note = j["note"].str()
        url = j["url"].str()
        followersCount = j["followers_count"].int ?? 0
        followingCount = j["following_count"].int ?? 0
        statusesCount = j["statuses_count"].int ?? 0
        emojis = j["emojis"].array.map(Emoji.init)
        bot = j["bot"].bool ?? false
        locked = j["locked"].bool ?? false
        fields = j["fields"].array.map(AccountField.init)
        roles = j["roles"].array.map(AccountRole.init)
        pleromaAdmin = j["pleroma"]["is_admin"].bool ?? false
        pleromaModerator = j["pleroma"]["is_moderator"].bool ?? false
    }
}

struct MediaAttachment: Hashable, Identifiable {
    var id: String
    var type: String
    var url: String
    var previewUrl: String?
    var description: String?
    /// Opprinnelig adresse for vedlegg fra andre tjenere (Pleroma viser ellers en proxy-adresse).
    var remoteUrl: String?
    /// Bredde/høyde-forhold hvis instansen oppgir det.
    var aspectRatio: Double?

    var isVideo: Bool { type == "video" || type == "gifv" }
    var isVisual: Bool { type == "image" || isVideo }

    init(_ j: J) {
        id = j["id"].str()
        type = j["type"].str("image")
        url = j["url"].str()
        previewUrl = j["preview_url"].string
        description = j["description"].string
        remoteUrl = j["remote_url"].string
        let o = j["meta"]["original"]
        if let a = o["aspect"].double, a > 0 {
            aspectRatio = a
        } else if let w = o["width"].double, let h = o["height"].double, w > 0, h > 0 {
            aspectRatio = w / h
        } else {
            aspectRatio = nil
        }
    }
}

struct Mention: Hashable {
    var id: String
    var username: String
    var acct: String
    var url: String

    init(_ j: J) {
        id = j["id"].str()
        username = j["username"].str()
        acct = j["acct"].str()
        url = j["url"].str()
    }
}

struct PollOption: Hashable {
    var title: String
    var votesCount: Int?

    init(_ j: J) {
        title = j["title"].str()
        votesCount = j["votes_count"].int
    }
}

struct Poll: Hashable {
    var id: String
    var expired: Bool
    var multiple: Bool
    var votesCount: Int
    var options: [PollOption]
    var voted: Bool

    init(_ j: J) {
        id = j["id"].str()
        expired = j["expired"].bool ?? false
        multiple = j["multiple"].bool ?? false
        votesCount = j["votes_count"].int ?? 0
        options = j["options"].array.map(PollOption.init)
        voted = j["voted"].bool ?? false
    }
}

/// Forhåndsvisning av en lenke (Open Graph), laget av instansen.
struct Card: Hashable {
    var url: String
    var title: String
    var description: String
    var image: String?
    var providerName: String?

    init(_ j: J) {
        url = j["url"].str()
        title = j["title"].str()
        description = j["description"].str()
        image = j["image"].string
        providerName = j["provider_name"].string
    }
}

/// Appen innlegget ble postet fra (finnes typisk bare for lokale innlegg).
struct AppInfo: Hashable {
    var name: String

    /// Eldre innlogginger fra Android-appen er registrert under det gamle navnet «Pleromastisk».
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.caseInsensitiveCompare("Pleromastisk") == .orderedSame ? "Feditastic" : n
    }
}

struct Status: Hashable, Identifiable {
    var id: String
    var createdAt: String
    var inReplyToId: String?
    var sensitive: Bool
    var spoilerText: String
    var visibility: String
    var uri: String
    var url: String?
    var repliesCount: Int
    var reblogsCount: Int
    var favouritesCount: Int
    var content: String
    private var reblogBox: [Status]
    var account: Account
    var mediaAttachments: [MediaAttachment]
    var mentions: [Mention]
    /// Emneknagger (navnet uten «#»).
    var tags: [String]
    var emojis: [Emoji]
    var favourited: Bool
    var reblogged: Bool
    var bookmarked: Bool
    /// Fremhevet (festet) på profilen. Oppgis bare for brukerens egne innlegg.
    var pinned: Bool
    var poll: Poll?
    var card: Card?
    var editedAt: String?
    var application: AppInfo?
    var language: String?
    var inReplyToAccountId: String?

    var reblog: Status? {
        get { reblogBox.first }
        set { reblogBox = newValue.map { [$0] } ?? [] }
    }

    init(_ j: J) {
        id = j["id"].str()
        createdAt = j["created_at"].str()
        inReplyToId = j["in_reply_to_id"].string
        sensitive = j["sensitive"].bool ?? false
        spoilerText = j["spoiler_text"].str()
        visibility = j["visibility"].str("public")
        uri = j["uri"].str()
        url = j["url"].string
        repliesCount = j["replies_count"].int ?? 0
        reblogsCount = j["reblogs_count"].int ?? 0
        favouritesCount = j["favourites_count"].int ?? 0
        content = j["content"].str()
        reblogBox = j["reblog"].isObject ? [Status(j["reblog"])] : []
        account = Account(j["account"])
        mediaAttachments = j["media_attachments"].array.map(MediaAttachment.init)
        mentions = j["mentions"].array.map(Mention.init)
        tags = j["tags"].array.compactMap { $0["name"].string ?? $0.string }
        emojis = j["emojis"].array.map(Emoji.init)
        favourited = j["favourited"].bool ?? false
        reblogged = j["reblogged"].bool ?? false
        bookmarked = j["bookmarked"].bool ?? false
        pinned = j["pinned"].bool ?? false
        poll = j["poll"].isObject ? Poll(j["poll"]) : nil
        card = j["card"].isObject ? Card(j["card"]) : nil
        editedAt = j["edited_at"].string
        application = j["application"].isObject ? AppInfo(name: j["application"]["name"].str()) : nil
        language = j["language"].string
        inReplyToAccountId = j["in_reply_to_account_id"].string
    }

    /// Svarer eller nevner kontoen [userId] (og er ikke skrevet av den selv).
    func addresses(_ userId: String?) -> Bool {
        guard let userId, account.id != userId else { return false }
        return inReplyToAccountId == userId || mentions.contains { $0.id == userId }
    }

    /// Har minst ett bilde eller én video (ikke bare lyd eller ukjente vedlegg).
    var hasVisualMedia: Bool { mediaAttachments.contains { $0.isVisual } }

    /// Mastodon og Pleroma lar bare offentlige og ulistede innlegg fremheves.
    var pinnable: Bool { visibility == "public" || visibility == "unlisted" }
}

struct StatusSource {
    var text: String
    var spoilerText: String
    var contentType: String?

    init(_ j: J) {
        text = j["text"].str()
        spoilerText = j["spoiler_text"].str()
        contentType = j["content_type"].string
    }
}

struct StatusContext {
    var ancestors: [Status]
    var descendants: [Status]

    init(_ j: J) {
        ancestors = j["ancestors"].array.map(Status.init)
        descendants = j["descendants"].array.map(Status.init)
    }
}

struct AppNotification: Hashable, Identifiable {
    var id: String
    var type: String
    var createdAt: String
    var account: Account
    var status: Status?
    var emoji: String?

    init(_ j: J) {
        id = j["id"].str()
        type = j["type"].str()
        createdAt = j["created_at"].str()
        account = Account(j["account"])
        status = j["status"].isObject ? Status(j["status"]) : nil
        emoji = j["emoji"].string
    }
}

struct Relationship: Hashable {
    var following: Bool
    var followedBy: Bool
    var requested: Bool

    init(_ j: J) {
        following = j["following"].bool ?? false
        followedBy = j["followed_by"].bool ?? false
        requested = j["requested"].bool ?? false
    }
}

/// Svar fra /api/v2/search. Emneknagger tolkes defensivt (objekter eller rene tekststrenger).
struct SearchResponse {
    var accounts: [Account]
    var tagNames: [String]

    init(_ j: J) {
        accounts = j["accounts"].array.map(Account.init)
        tagNames = j["hashtags"].array
            .compactMap { $0.isObject ? $0["name"].string : $0.string }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// /api/v1/instance – både Mastodon-formatet og Pleromas utvidelser.
struct InstanceInfo {
    var title: String
    /// Pleroma oppgir f.eks. «2.7.2 (compatible; Pleroma 2.6.3)».
    var version: String
    /// Kort beskrivelse (Mastodon: ren tekst, GoToSocial: HTML).
    var description: String
    var email: String
    var contactAccount: Account?
    var maxTootChars: Int?
    var descriptionLimit: Int?
    var maxCharacters: Int?
    /// Tekstformater (GoToSocial, glitch-soc), f.eks. text/plain og text/markdown.
    var supportedMimeTypes: [String]?
    /// Pleroma: tekstformater og funksjoner fra metadata.
    var postFormats: [String]?
    var features: [String]
    var hasPleromaBlock: Bool

    /// Pleroma (eller en forgrening som Akkoma), ikke Mastodon e.l.
    var isPleroma: Bool { hasPleromaBlock || version.lowercased().contains("pleroma") }

    init(_ j: J) {
        title = j["title"].str()
        version = j["version"].str()
        description = j["description"].str()
        email = j["email"].str()
        let contact = j["contact_account"]
        contactAccount = contact.isObject ? Account(contact) : nil
        maxTootChars = j["max_toot_chars"].int
        descriptionLimit = j["description_limit"].int
        let statuses = j["configuration"]["statuses"]
        maxCharacters = statuses["max_characters"].int
        supportedMimeTypes = statuses["supported_mime_types"].exists ? statuses["supported_mime_types"].strings : nil
        let meta = j["pleroma"]["metadata"]
        postFormats = meta["post_formats"].exists ? meta["post_formats"].strings : nil
        features = meta["features"].strings
        hasPleromaBlock = j["pleroma"].exists
    }
}

/// Én serverregel fra /api/v1/instance/rules. [hint] er en valgfri utdypning.
struct InstanceRule {
    var text: String
    var hint: String

    init(_ j: J) {
        text = j["text"].str()
        hint = j["hint"].str()
    }
}

/// /api/pleroma/healthcheck: Pleromas egen helsesjekk.
struct Healthcheck {
    var healthy: Bool?
    var active: Int
    var idle: Int
    var poolSize: Int?
    var memoryUsed: Double?
    var processedJobs: Int?
    var queues: [(name: String, stats: JobStats)]

    init(_ j: J) {
        healthy = j["healthy"].bool
        active = j["active"].int ?? 0
        idle = j["idle"].int ?? 0
        poolSize = j["pool_size"].int
        memoryUsed = j["memory_used"].double
        let jobs = j["job_queue_stats"]
        processedJobs = jobs.exists ? (jobs["processed_jobs"].int ?? 0) : nil
        queues = jobs["queues"].objectEntries.map { (name: $0.0, stats: JobStats($0.1)) }
    }
}

struct JobStats {
    var success: Int
    var failure: Int
    var processedJobs: Int

    init(_ j: J) {
        success = j["success"].int ?? 0
        failure = j["failure"].int ?? 0
        processedJobs = j["processed_jobs"].int ?? 0
    }
}
