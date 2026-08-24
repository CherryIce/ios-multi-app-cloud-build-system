# Contributing

Thanks for your interest in contributing to this repository. The project aims to provide reproducible, secure, and maintainable multi-app cloud build workflows for iOS projects. Please follow the guidelines below to help keep the repository healthy.

- Bug reports and feature requests: open an issue describing the problem or improvement, including steps to reproduce and expected behavior.
- Code changes: open a pull request. PRs should include a clear description, the motivation for the change, and any relevant testing instructions.
- Branching model: use feature branches off of `main` named like `feat/<short-description>` or `fix/<short-description>`.
- Commit messages: prefer concise, imperative-style messages; reference issues when applicable (e.g., `Fix: handle missing provisioning profile (#12)`).
- Tests and verification: include or update any scripts that exercise the changed logic. For pipeline or template changes, include sample commands to validate locally.
- Secrets: never commit secrets, certificates, provisioning profiles, or private keys to the repo. Use your CI provider's secret store (GitHub Actions Secrets, Bitrise Secrets, or environment vaults).
- Reviews: at least one approving review is required before merging. Use draft PRs for work-in-progress.

If you want to propose larger changes to the architecture (for example, switching signing strategy or changing pipeline providers), open an issue first to discuss the plan.
