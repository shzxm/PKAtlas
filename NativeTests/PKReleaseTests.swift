import XCTest
import Foundation
import CryptoKit
@testable import PKAtlas

final class PKReleaseTests: XCTestCase {
    private func signedFixture() throws -> (release: PKNativeRelease, envelope: PKNativeReleaseEnvelope,
                                            publicKey: Data) {
        let signer = Curve25519.Signing.PrivateKey()
        let original = PKNativeRelease(schemaVersion: 1, version: "2.7", build: 11,
            fileName: "PKAtlas-iOS27.2-v2.7-build11-unsigned.ipa",
            ipaSHA256: String(repeating: "a", count: 64),
            releaseNotes: "Release test", publishedAt: "2026-11-17T00:00:00Z",
            distribution: "github-releases")
        let raw = try JSONEncoder().encode(original)
        let signature = try signer.signature(for:
            Data("PKATLAS-NATIVE-RELEASE-v1\n".utf8) + raw)
        let envelope = PKNativeReleaseEnvelope(schemaVersion: 1,
            keyId: "pkatlas-ed25519-2026-11-1", payloadBase64: raw.base64EncodedString(),
            signatureBase64: signature.base64EncodedString())
        return (original, envelope, signer.publicKey.rawRepresentation)
    }

    func testSignedGithubBodyAssetAndVersion() throws {
        let fixture = try signedFixture()
        let signed = try JSONEncoder().encode(fixture.envelope).base64EncodedString()
        let json: [String: Any] = [
          "tag_name": "v2.7.0", "body": "Release\n\nPKATLAS_SIGNED_RELEASE_V1=" + signed,
          "draft": false, "prerelease": false,
          "html_url": "https://github.com/shzxm/PKAtlas/releases/tag/v2.7.0",
          "assets": [[
            "name": fixture.release.fileName,
            "state": "uploaded", "size": 950000,
            "digest": "sha256:" + fixture.release.ipaSHA256,
            "browser_download_url": "https://github.com/shzxm/PKAtlas/releases/download/v2.7.0/" + fixture.release.fileName
          ]]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: json)
        let release = try JSONDecoder().decode(PKGitHubReleaseSnapshot.self, from: bytes)
        XCTAssertEqual(try PKGitHubReleaseParser.validatedRelease(release,
            trustedKey: fixture.publicKey).build, 11)
        XCTAssertTrue(PKReleaseVerifier.newer(fixture.release, than: "2.6", localBuild: 10))
        XCTAssertFalse(PKReleaseVerifier.newer(fixture.release, than: "2.7", localBuild: 11))
    }

    func testGithubUpdateIsAnonymousAndNoPrivateEndpoint() {
        let request = PKPrivateReleaseClient.unsignedRequest()
        XCTAssertEqual(request.url?.absoluteString,
            "https://api.github.com/repos/shzxm/PKAtlas/releases/latest")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        let names = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        for header in ["cookie", "authorization", "x-device-id", "x-real-ip",
                       "cf-connecting-ip", "x-forwarded-for", "origin", "referer"] {
            XCTAssertFalse(names.contains(header))
        }
    }

    func testSignerCannotRedirectAssetsOrTamper() throws {
        let fixture = try signedFixture()
        XCTAssertNoThrow(try PKReleaseVerifier.verify(fixture.envelope,
            trustedKey: fixture.publicKey))
        let wrong = PKNativeReleaseEnvelope(schemaVersion: 1, keyId: fixture.envelope.keyId,
            payloadBase64: fixture.envelope.payloadBase64 + "A",
            signatureBase64: fixture.envelope.signatureBase64)
        XCTAssertThrowsError(try PKReleaseVerifier.verify(wrong,
            trustedKey: fixture.publicKey))
    }

    func testPersonalServerOptInRejectsIPsAndCredentials() {
        XCTAssertNil(PKBackendConfiguration.validatedOrigin("https://127.0.0.1"))
        XCTAssertNil(PKBackendConfiguration.validatedOrigin("http://example.org"))
        XCTAssertNil(PKBackendConfiguration.validatedOrigin("https://example.invalid"))
        XCTAssertNil(PKBackendConfiguration.validatedOrigin("https://test:password@example.org"))
        XCTAssertNotNil(PKBackendConfiguration.validatedOrigin("https://example.org"))
    }
}
