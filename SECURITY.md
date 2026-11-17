# Security guidance

- This public repository is a **fresh sanitized source export**, not a mirror of personal development Git history.
- Before committing or releasing, scan both source and unsigned IPA payload for secrets, private hostnames, IPs and local absolute paths. `strings` on the executable and a full archive text scan are required.
- Never commit signing credentials: `.p8`, `.p12`, provisioning profiles, SSH keys, service tokens or any actual cloud configuration.
- Public release metadata is Ed25519 signed. If you fork, use your own release signing key and replace `Resources/Model/github-release-public-key.txt`. Never publish the private half.
- A configured custom backend is the user's security responsibility. HTTPS and signing are mandatory; an arbitrary URL cannot be assumed secure.
- No obfuscation or GitHub proxy is a substitute for a trusted CDN, correctly secured origin firewall or network privacy proxy.
- File a security report without disclosing personal data or exploitable credentials in public issues.

The local release script strips embedded developer paths and runs `Scripts/audit-release.py` on both source and the actual `.app` payload before publishing an unsigned IPA. This is not a substitute for manual review.
