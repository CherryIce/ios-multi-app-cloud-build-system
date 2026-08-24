Multi-app versioning and artifact management

When managing multiple iOS apps from a centralized build system, consider the following strategies for versioning and artifacts:

1. Per-app semantic versioning
   - Maintain versions independently per app (CFBundleShortVersionString and CFBundleVersion) unless you intentionally coordinate releases.
   - Example: App A = 1.4.2, App B = 2.0.0

2. Build metadata and CI tag
   - Append CI build numbers to CFBundleVersion (e.g., 1402 for build number 1402) to ensure uniqueness across builds.
   - Use a consistent artifact naming scheme: <app>-<git-branch>-<short-sha>-<build-number>.ipa

3. Artifacts storage
   - Store built artifacts in a centralized artifact store (GitHub Releases, S3, or a dedicated binary store).
   - Keep release artifacts immutable and reference them by tag or release ID.

4. Release orchestration
   - Use CI to create logical release bundles that list the app versions included in a coordinated release.
   - Use metadata files (JSON/YAML) to describe which artifacts correspond to a release.

5. Clean-up and retention
   - Implement artifact retention policies to prune old builds and control storage costs.

6. Example workflow
   - CI builds each app, uploads artifacts to S3, then the pipeline writes a release manifest with app names, versions, artifact URLs, and checksums.
