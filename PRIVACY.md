# Privacy and network trust boundary

**Default:** offline-only pharmacokinetic calculations and local encrypted data. An ordinary release check connects to `api.github.com` anonymously at the HTTP application layer. GitHub and intermediaries still see the user's network egress IP and may retain access logs; this app does not claim network anonymity.

**When optional cloud sync is configured:** the user-selected HTTPS server receives request metadata and account/medical record data submitted for syncing. That server and its CDN can see source IPs. Configure only servers you trust. No cloud server is bundled by default.

**Version checks:** unsigned GET with fixed User-Agent, without Authorization/Cookie/Origin/Referer, no device identifiers or medical data, no redirects. App checks GitHub releases/latest and validates the separately signed release body with embedded public key plus asset digest. Disable automatic checks in Settings to prevent automatic release lookups.

**Apple Health:** optional read-only HealthKit queries require entitlement and consent; no HealthKit data is sent to GitHub. Imported data becomes part of local PKAtlas records and can be synced only after you choose a cloud server and log in.

**Private backend signing:** a user who enables hot-updates must configure their backend's Ed25519 public key. Private keys stay on their own server and must never be committed.

**GitHub distribution:** release assets are public; do not upload any binary containing private addresses, absolute user paths, personalized certificates, credentials, session tokens or patient data.
