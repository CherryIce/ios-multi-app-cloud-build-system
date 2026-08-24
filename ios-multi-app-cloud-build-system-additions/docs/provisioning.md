Provisioning and Signing

This document outlines recommended approaches to manage provisioning profiles and signing certificates for a multi-app cloud build system.

1. Use fastlane match for centralized signing
   - Store certificates and provisioning profiles in a private git repository (encrypted by match).
   - Configure `MATCH_GIT_URL` and `MATCH_PASSWORD` as CI secrets.
   - Use `readonly: true` in CI to avoid accidental changes.

2. App Store Connect API (recommended for automation)
   - Use App Store Connect API keys for tasks that require App Store interactions (TestFlight uploads, metadata updates).
   - Store API key JSON in CI secrets and set APP_STORE_CONNECT_API_KEY and APP_STORE_CONNECT_API_ISSUER.

3. Protect secrets
   - Do not commit provisioning profiles, certificates, private keys, or API keys to the repository.
   - Use your CI provider's secret storage (GitHub Actions Secrets, Bitrise Secrets, etc.).

4. Per-app vs Shared signing
   - For teams where apps share a signing identity, a shared match repo works well.
   - For apps that require separate teams or accounts, maintain separate match repos or separate keychains per app.

5. Local development
   - Document how developers should obtain the necessary certs and profiles (e.g., `fastlane match development` with appropriate access).

6. Rotation and audit
   - Rotate certificates periodically and maintain a record of changes in the match git repository.
