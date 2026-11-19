# PKAtlas · 药时（开源 iOS 版）

> **Current public source snapshot: v2.25 Build 31 (2026-11-19).** It includes native SwiftUI dose/history/chart/inverse and confirmed-planned-state flows. The sanitized source uses placeholder origins and bundle IDs. The production unsigned IPA is private; this public repository only carries source code. Model signing and optional cloud endpoints need to be configured for each deployment.


Local-first pharmacokinetic modeling, visualization and mathematical inverse-scenario exploration. The public build does **not** include any personal server domain, origin IP, session token, HealthKit data or private backend credentials.

## Features

- Local medication and meal records, offline curve and equivalent-dose models, optional Apple Health read-only import where HealthKit entitlements are available.
- Graphs with draggable time cursor; inverse-model scenarios with configurable numerical constraints.
- Per-device encrypted local records; optional self-hosted account sync using the backend **you configure explicitly**.
- Version check from **GitHub Releases** only, with a separate Ed25519-signed release notice. No automatic binary installation. Latest release contains a user-signable IPA and SHA-256 digest.
- Signed remote formula/model updates *only when a custom HTTPS backend and its corresponding Ed25519 public key are manually configured*.

## Build

Requires macOS, compatible Xcode (originally built with Xcode 27.2), XcodeGen and the iOS SDK.

```bash
brew install xcodegen
./Scripts/build-unsigned.sh
```

The script never fetches private source or contacts a developer origin server. If iCloud Drive/Downloads exists on your Mac, the unsigned IPA is stored there; otherwise it goes to `dist/`. Install only after signing with your own provisioning profile. This package is not submitted to the App Store.

**Public app identity:** `org.pkatlas.open`, URL callback scheme `pkatlasopen://` (custom backend must use this callback for PKCE). It is intentionally different from any personal deployment. Do not expect a separately signed private build's Keychain items or app data to migrate automatically. Export/import your data carefully.

## Optional backend

The open-source build works offline without configuration. In **My → Optional cloud sync**, add an HTTPS host you control and, if needed, its Ed25519 signing public key. Only then can the app talk to that backend, and private login will be performed at that host. No preconfigured origin addresses or credentials are included. The backend protocol and implementations are separate; this repository publishes the native client, not operational secrets or actual patient data.

## Releases

Go to <https://github.com/shzxm/PKAtlas/releases/latest>. The App uses GitHub's public Releases API without sending cookies, credentials, medication records, device identifiers or a private backend URL. **GitHub will still observe the network connection's public egress IP.** For network anonymity use a trustworthy VPN/Tor policy as appropriate; source code obfuscation is not an IP-anonymity mechanism.

The `PKATLAS_SIGNED_RELEASE_V1` notice in the GitHub Release body is Ed25519 authenticated. The App verifies it, matches tag/version and the asset's SHA-256 digest before showing an update. It does not silently install unsigned code.

## Important limitations

Models are group-level estimates, not personal blood measurements or clinical treatment recommendations. Never use inverse-model outputs to determine real-world doses. HealthKit permissions depend on the signer's entitlements; read-only access is not guaranteed merely by compiling the app. Dynamic executable-code downloading is not guaranteed to comply with App Store Review Guideline 2.5.2.

Read [SECURITY.md](SECURITY.md), [PRIVACY.md](PRIVACY.md) and [LICENSE](LICENSE) before deploying or redistributing. Please do not add origin hosts, personal network ranges, user data, signing keys or secrets to issues, commits, CI logs or release assets.

## November 19, 2026 · superseded adopted-plan hotfix

When a new accepted adjustment replaces an old mathematical model, only the current revision may show actionable dose-confirmation nodes. Stale iOS local notification requests are cancelled and rebuilt from the verified cloud event set; previously entered actual dose records are never deleted.
