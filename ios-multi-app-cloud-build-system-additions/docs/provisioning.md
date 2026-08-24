# Provisioning and Signing

This document describes an optional Fastlane signing adapter. It is a pseudocode draft, not the production path implemented by the root composite action.

1. Use fastlane match for centralized signing
   - Store certificates and provisioning profiles in a private git repository (encrypted by match).
   - Configure `MATCH_GIT_URL` and `MATCH_PASSWORD` as CI secrets.
   - Use `readonly: true` in CI to avoid accidental changes.

2. App Store Connect API (recommended for automation)
   - Use App Store Connect API keys for tasks that require App Store interactions (TestFlight uploads, metadata updates).
   - Store the `.p8`, Key ID, and Issuer ID independently in the CI secret store.
   - Fastlane must explicitly call `app_store_connect_api_key(key_id:, issuer_id:, key_filepath:)` or pass `api_key_path:` to `pilot`. Environment-variable names alone do not configure Fastlane authentication.
   - If Bitrise Apple Service connection supplies the key, document that external dependency instead of implying the repository contains the credential wiring.

3. Protect secrets
   - Do not commit provisioning profiles, certificates, private keys, or API keys to the repository.
   - Use your CI provider's secret storage (GitHub Actions Secrets, Bitrise Secrets, etc.).
   - Decode the `.p8` only for the upload step and delete it afterwards.

4. Per-app vs Shared signing
   - For teams where apps share a signing identity, a shared match repo works well.
   - For apps that require separate teams or accounts, maintain separate match repos or separate keychains per app.

5. Local development
   - Document how developers should obtain the necessary certs and profiles (e.g., `fastlane match development` with appropriate access).

6. Rotation and audit
   - Rotate certificates periodically and maintain a record of changes in the match git repository.
