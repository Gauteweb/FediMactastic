import Foundation

/// Liten, tilgivende JSON-leser. Alle modellene har standardverdier slik at avvikende
/// instanser (Pleroma, Akkoma, GoToSocial, Mastodon …) ikke knekker parsingen.
struct J {
    let raw: Any?

    init(_ raw: Any?) {
        self.raw = raw is NSNull ? nil : raw
    }

    static func parse(_ data: Data) throws -> J {
        J(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    subscript(_ key: String) -> J {
        J((raw as? [String: Any])?[key])
    }

    var exists: Bool { raw != nil }
    var isObject: Bool { raw is [String: Any] }

    private static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber, !J.isBool(n) { return n.stringValue }
        return nil
    }

    func str(_ fallback: String = "") -> String { string ?? fallback }

    var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    var bool: Bool? {
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String { return s == "true" }
        return nil
    }

    var array: [J] {
        (raw as? [Any])?.map(J.init) ?? []
    }

    var objectEntries: [(String, J)] {
        guard let o = raw as? [String: Any] else { return [] }
        return o.map { ($0.key, J($0.value)) }
    }

    var strings: [String] {
        array.compactMap(\.string)
    }
}
