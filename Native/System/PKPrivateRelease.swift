import Foundation
import CryptoKit

/// A separately signed release notice carried inside the public GitHub Release
/// body. No private origin server is contacted for update checks.
struct PKNativeReleaseEnvelope: Codable {
    let schemaVersion: Int
    let keyId: String
    let payloadBase64: String
    let signatureBase64: String
}

struct PKNativeRelease: Codable, Equatable {
    let schemaVersion: Int
    let version: String
    let build: Int
    let fileName: String
    let ipaSHA256: String
    let releaseNotes: String
    let publishedAt: String
    let distribution: String

    var displayVersion: String { "\(version)（Build \(build)）" }
}

enum PKReleaseError: LocalizedError {
    case invalidSignature
    case invalidManifest
    case networkFailure

    var errorDescription: String? {
        switch self {
        case .invalidSignature: return "GitHub 版本声明数字签名无效，本次检查已拒绝。"
        case .invalidManifest: return "服务器版本信息不符合已知格式，本次更新检查已取消。"
        case .networkFailure: return "GitHub 版本检查暂不可用；当前 App 正常离线运行。"
        }
    }
}

enum PKReleaseVerifier {
    private static let prefix = Data("PKATLAS-NATIVE-RELEASE-v1\n".utf8)

    static var publicKeyData: Data? {
        guard let file = Bundle.main.url(forResource: "github-release-public-key", withExtension: "txt"),
              let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count == 64 else { return nil }
        var bytes = [UInt8]()
        for offset in stride(from: 0, to: hex.count, by: 2) {
            let a = hex.index(hex.startIndex, offsetBy: offset)
            let b = hex.index(a, offsetBy: 2)
            guard let value = UInt8(hex[a..<b], radix: 16) else { return nil }
            bytes.append(value)
        }
        return Data(bytes)
    }

    static func verify(_ envelope: PKNativeReleaseEnvelope,
                       trustedKey: Data? = publicKeyData) throws -> PKNativeRelease {
        guard envelope.schemaVersion == 1,
              envelope.keyId == "pkatlas-ed25519-2026-11-1",
              envelope.payloadBase64.utf8.count < 9_000,
              let payload = Data(base64Encoded: envelope.payloadBase64),
              !payload.isEmpty, payload.count < 6_000,
              let signature = Data(base64Encoded: envelope.signatureBase64),
              signature.count == 64,
              let trustedKey, trustedKey.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: trustedKey),
              key.isValidSignature(signature, for: prefix + payload)
        else { throw PKReleaseError.invalidSignature }
        guard let release = try? JSONDecoder().decode(PKNativeRelease.self, from: payload),
              release.schemaVersion == 1,
              release.distribution == "github-releases",
              versionParts(release.version) != nil,
              release.build > 0 && release.build <= 1_000_000,
              release.ipaSHA256.count == 64,
              release.ipaSHA256.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }),
              release.releaseNotes.count >= 1 && release.releaseNotes.count <= 1_200,
              release.publishedAt.count > 10 && release.publishedAt.count < 100,
              release.fileName.count < 130,
              release.fileName.range(of: #"^PKAtlas-iOS[0-9.]+-v[0-9.]+-build[0-9]+(?:-[0-9]{8}-[0-9]{6})?-unsigned\.ipa$"#,
                                         options: .regularExpression) != nil,
              release.fileName.contains("-v\(release.version)-build\(release.build)")
        else { throw PKReleaseError.invalidManifest }
        return release
    }

    static func versionParts(_ version: String) -> [Int]? {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(components.count) else { return nil }
        let integers = components.compactMap { text -> Int? in
            guard !text.isEmpty && text.count <= 7,
                  text.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            return Int(text)
        }
        return integers.count == components.count ? integers : nil
    }

    static func newer(_ remote: PKNativeRelease, than localVersion: String,
                      localBuild: Int) -> Bool {
        guard let remoteParts = versionParts(remote.version),
              let localParts = versionParts(localVersion) else { return false }
        for index in 0..<max(remoteParts.count, localParts.count) {
            let remoteValue = index < remoteParts.count ? remoteParts[index] : 0
            let localValue = index < localParts.count ? localParts[index] : 0
            if remoteValue != localValue { return remoteValue > localValue }
        }
        return remote.build > localBuild
    }
}

/// GitHub's official public Releases API. This channel has no credentials,
/// cookies, account identity, device identifiers, network data, or private URLs.
/// GitHub (and the user's network provider) CAN see the connection's egress IP.
struct PKGitHubReleaseSnapshot: Decodable {
    struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int
        let digest: String?
        let browser_download_url: String
    }
    let tag_name: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    let html_url: String
}

enum PKGitHubReleaseParser {
    private static let marker = "PKATLAS_SIGNED_RELEASE_V1="
    static func validatedRelease(_ release: PKGitHubReleaseSnapshot,
                                 trustedKey: Data? = PKReleaseVerifier.publicKeyData) throws -> PKNativeRelease {
        guard !release.draft && !release.prerelease,
              release.html_url.hasPrefix("https://github.com/shzxm/PKAtlas/releases/tag/"),
              let body = release.body, body.utf8.count < 40_000,
              let markerRange = body.range(of: marker) else {
            throw PKReleaseError.invalidManifest
        }
        let remaining = body[markerRange.upperBound...]
        let encoded = String(remaining.prefix(while: {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=")
        }))
        guard encoded.count < 16_000,
              let envelopeBytes = Data(base64Encoded: encoded),
              let envelope = try? JSONDecoder().decode(PKNativeReleaseEnvelope.self, from: envelopeBytes)
        else { throw PKReleaseError.invalidManifest }
        let verified = try PKReleaseVerifier.verify(envelope, trustedKey: trustedKey)
        guard release.tag_name == "v\(verified.version).0" ||
              release.tag_name == "v\(verified.version)",
              release.assets.contains(where: { asset in
                asset.name == verified.fileName && asset.state == "uploaded" &&
                asset.size > 1000 &&
                asset.digest == "sha256:\(verified.ipaSHA256)" &&
                asset.browser_download_url.hasPrefix(
                    "https://github.com/shzxm/PKAtlas/releases/download/\(release.tag_name)/")
              }) else { throw PKReleaseError.invalidManifest }
        return verified
    }
}

final class PKPrivateReleaseClient: NSObject, URLSessionTaskDelegate {
    static let shared = PKPrivateReleaseClient()
    private static let endpoint = URL(
        string: "https://api.github.com/repos/shzxm/PKAtlas/releases/latest")!
    private let session: URLSession

    override init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config)
        super.init()
    }

    static func unsignedRequest() -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PKAtlasUpdate/1", forHTTPHeaderField: "User-Agent")
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func fetch() async throws -> PKNativeRelease {
        let (bytes,response): (Data,URLResponse)
        do { (bytes,response) = try await session.data(for: Self.unsignedRequest()) }
        catch { throw PKReleaseError.networkFailure }
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host == "api.github.com",
              http.url?.path == "/repos/shzxm/PKAtlas/releases/latest",
              http.statusCode == 200, bytes.count < 200_000,
              let release = try? JSONDecoder().decode(PKGitHubReleaseSnapshot.self, from: bytes)
        else { throw PKReleaseError.invalidManifest }
        return try PKGitHubReleaseParser.validatedRelease(release)
    }
}
