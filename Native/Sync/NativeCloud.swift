import Foundation

struct PKServerResponse: Decodable {
    var version: Int
    var state: PKCloudState
}
struct PKLastUploadRequest: Encodable {
    let version: Int
    let state: PKCloudState
    let syncPolicy = "last-upload-wins-v1"
    let operationId: String
}

struct PKAuthResponse: Decodable {
    var username: String
    var account: PKServerResponse?
}
struct PKMeResponse: Decodable { var username: String }
struct PKPushResponse: Decodable {
    struct Event: Decodable {
        var id: String
        var time: Double
    }
    var events: [Event]
}

struct PKHTTPError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

final class PKCloudAPI {
    static let shared = PKCloudAPI()
    private var base: URL? { PKBackendConfiguration.baseURL }
    // URLSession manages its own HttpOnly/Secure cookies. Never persist the
    // plaintext password, cookie token or API key in our SwiftUI state or disk.
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.httpCookieStorage = .shared
        config.timeoutIntervalForRequest = 18
        config.timeoutIntervalForResource = 25
        session = URLSession(configuration: config)
    }

    func request<T: Decodable>(_ endpoint: String, method: String = "GET",
                               body: Data? = nil) async throws -> T {
        guard let base,
              endpoint.hasPrefix("/api/"),
              !endpoint.contains(".."),
              let url = URL(string: endpoint, relativeTo: base),
              url.scheme == "https", url.host == base.host else {
            throw PKHTTPError(status: 0, message: "请求地址无效")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = method
        if endpoint != "/api/native/exchange", let token = PKSessionVault.load() {
            req.setValue("pk_atlas_session=\(token)", forHTTPHeaderField: "Cookie")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        if method != "GET" {
            req.setValue(base.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let body {
            req.httpBody = body
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https",
              http.url?.host == base.host else {
            throw PKHTTPError(status: 0, message: "服务器响应来源无法核实")
        }
        if endpoint == "/api/native/engine" && data.count > 1_600_000 {
            throw PKSignedEngineFailure.invalidPackage
        }
        if endpoint == "/api/native/model" && data.count > 900_000 {
            throw PKModelUpdateError.invalidDigest
        }
        guard (200...299).contains(http.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw PKHTTPError(status: http.statusCode,
                              message: error ?? "服务器请求失败（HTTP \(http.statusCode)）")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct NativeTokenExchange: Decodable {
        let username: String
        let sessionToken: String
        let sessionExpiresAt: Double
    }

    func exchangeNative(code: String, verifier: String, state: String) async throws -> NativeTokenExchange {
        let body = try JSONSerialization.data(withJSONObject: [
            "code": code, "verifier": verifier, "state": state
        ])
        return try await request("/api/native/exchange", method: "POST", body: body)
    }

    struct APNsRegistration: Decodable { let ok: Bool; let providerConfigured: Bool }

    func registerAPNs(token: String) async throws -> APNsRegistration {
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let data = try JSONSerialization.data(withJSONObject: [
            "deviceToken":token, "environment":environment
        ])
        return try await request("/api/native/apns/register", method: "POST", body: data)
    }

    func unregisterAPNs(token: String) async throws {
        struct Result: Decodable { let ok: Bool }
        let data = try JSONSerialization.data(withJSONObject: ["deviceToken":token])
        let _: Result = try await request("/api/native/apns/unregister",
                                          method: "POST", body: data)
    }

    func signedEnginePackage() async throws -> PKSignedEngineEnvelope {
        try await request("/api/native/engine")
    }

    func modelPackage() async throws -> PKRemoteModelPackage {
        try await request("/api/native/model")
    }

    func state() async throws -> PKServerResponse { try await request("/api/state") }

    func putSections(version: Int, sections: [String: PKJSON]) async throws {
        struct Result: Decodable { let version: Int }
        struct Body: Encodable { let version: Int; let sections: [String: PKJSON] }
        let body = try JSONEncoder().encode(Body(version: version, sections: sections))
        let _: Result = try await request("/api/state/sections", method: "PUT", body: body)
    }
    /// The server serializes successful full-snapshot commits. A request ID is
    /// reused after a lost response to avoid replaying an older snapshot over
    /// a later device upload. No wall-clock timestamp or device ID is sent.
    func putLastUploadSnapshot(version: Int, state: PKCloudState,
                               operationId: String) async throws -> Int {
        struct Ack: Decodable {
            let version: Int
            let syncPolicy: String?
        }
        let data = try JSONEncoder().encode(PKLastUploadRequest(
            version: version, state: state, operationId: operationId))
        let receipt: Ack = try await request("/api/state", method: "PUT", body: data)
        guard receipt.syncPolicy == "last-upload-wins-v1" else {
            throw PKHTTPError(status: 426, message: "服务器不支持最后上传优先同步，请先升级后端")
        }
        return receipt.version
    }


    func me() async throws -> PKMeResponse { try await request("/api/me") }

    func logout() async throws {
        struct Result: Decodable { var ok: Bool }
        let _: Result = try await request("/api/logout", method: "POST", body: Data("{}".utf8))
    }

    func reminderEvents() async throws -> [PKPushResponse.Event] {
        let payload: PKPushResponse = try await request("/api/push/pending")
        return payload.events
    }
}
