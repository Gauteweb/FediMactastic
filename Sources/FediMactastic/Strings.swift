import Foundation

/// Språket i grensesnittet: norsk (bokmål) når systemet bruker nb, nn eller no, ellers engelsk.
enum Lang {
    static let isNorwegian: Bool = {
        let first = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return first.hasPrefix("nb") || first.hasPrefix("nn") || first.hasPrefix("no")
    }()

    static var locale: Locale { Locale(identifier: isNorwegian ? "nb_NO" : "en_US") }
}

/// Tekster som bare finnes i Mac-utgaven (menyer o.l.).
private let macStringsNB: [String: String] = [
    "menu_go": "Gå",
    "menu_refresh": "Oppdater",
    "menu_new_post": "Nytt innlegg",
    "image_prev": "Forrige bilde",
    "image_next": "Neste bilde",
    "publish_shortcut_hint": "⌘↩ publiserer",
    "font_size": "Skriftstørrelse i feedene",
    "font_reset": "Standard",
    "boosted_by_title": "Delt av",
    "favourited_by_title": "Stjernemerket av",
    "nobody_boosted": "Ingen har delt dette innlegget ennå.",
    "nobody_favourited": "Ingen har stjernemerket dette innlegget ennå.",
    "who_hint": "Høyreklikk for å se hvem",
]

private let macStringsEN: [String: String] = [
    "menu_go": "Go",
    "menu_refresh": "Refresh",
    "menu_new_post": "New post",
    "image_prev": "Previous image",
    "image_next": "Next image",
    "publish_shortcut_hint": "⌘↩ publishes",
    "font_size": "Text size in feeds",
    "font_reset": "Default",
    "boosted_by_title": "Boosted by",
    "favourited_by_title": "Favourited by",
    "nobody_boosted": "Nobody has boosted this post yet.",
    "nobody_favourited": "Nobody has favourited this post yet.",
    "who_hint": "Right-click to see who",
]

/// Oversatt tekst. Formatkoder som i Android-ressursene (%1$@, %1$d).
func L(_ key: String, _ args: CVarArg...) -> String {
    let fmt: String
    if Lang.isNorwegian {
        fmt = stringsNB[key] ?? macStringsNB[key] ?? stringsEN[key] ?? macStringsEN[key] ?? key
    } else {
        fmt = stringsEN[key] ?? macStringsEN[key] ?? key
    }
    if args.isEmpty { return fmt }
    return String(format: fmt, locale: nil, arguments: args)
}

/// Flertallsform («1 nytt varsel» / «3 nye varsler»).
func Lp(_ key: String, _ count: Int) -> String {
    L(key + (count == 1 ? ".one" : ".other"), count)
}

/// Gjør feil om til meldinger brukeren kan forstå.
func userMessage(_ error: Error) -> String {
    if let e = error as? ApiError {
        if e.code == 401 { return L("error_session_expired") }
        return L("error_generic", e.message)
    }
    if error is URLError { return L("error_network") }
    return L("error_generic", error.localizedDescription)
}

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private let mediumDate: DateFormatter = {
    let f = DateFormatter()
    f.locale = Lang.locale
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
}()

func parseDate(_ iso: String) -> Date? {
    isoFractional.date(from: iso) ?? isoPlain.date(from: iso)
}

/// «nå», «5 min», «3 t», «2 d», ellers dato.
func relativeTime(_ iso: String) -> String {
    guard let date = parseDate(iso) else { return "" }
    let secs = max(0, Int(Date().timeIntervalSince(date)))
    switch secs {
    case ..<60: return L("time_now")
    case ..<3600: return L("time_min", secs / 60)
    case ..<86400: return L("time_hour", secs / 3600)
    case ..<(7 * 86400): return L("time_day", secs / 86400)
    default: return mediumDate.string(from: date)
    }
}
