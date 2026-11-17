import Foundation

/// Server URLs are user-entered runtime configuration, never baked into public
/// sources, the IPA, log output or GitHub Releases. Nil = offline-only.
enum PKBackendConfiguration {
    private static let storageKey = "PKAtlasOptionalServerOrigin"
    private static let publicKeyStorageKey = "PKAtlasOptionalServerSigningKey"

    static var baseURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return nil }
        return validatedOrigin(raw)
    }

    static func validatedOrigin(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 180,
              let parts = URLComponents(string: trimmed), parts.scheme == "https",
              let host = parts.host?.lowercased(), host.count <= 130,
              host.contains("."), !host.hasSuffix(".local"),
              !host.hasSuffix(".invalid"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !host.contains(":"),
              host.first?.isNumber != true,
              parts.user == nil, parts.password == nil,
              parts.port == nil, parts.path.isEmpty || parts.path == "/",
              parts.query == nil, parts.fragment == nil,
              let url = parts.url else { return nil }
        return url
    }

    static func configure(_ origin: String) -> Bool {
        let cleaned = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return true
        }
        guard let url = validatedOrigin(cleaned) else { return false }
        UserDefaults.standard.set(url.absoluteString, forKey: storageKey)
        return true
    }

    static var trustedKeyHex: String {
        UserDefaults.standard.string(forKey: publicKeyStorageKey) ?? ""
    }

    static func setTrustedKeyHex(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.isEmpty || (clean.count == 64 && clean.allSatisfy({ $0.isHexDigit })) else { return false }
        if clean.isEmpty { UserDefaults.standard.removeObject(forKey: publicKeyStorageKey) }
        else { UserDefaults.standard.set(clean, forKey: publicKeyStorageKey) }
        return true
    }
}
