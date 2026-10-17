# Changelog

All notable changes to Paneflo are listed here. Versions follow [Semantic Versioning](https://semver.org); releases before 1.0.0 are 0.x milestones.

## 0.1.0 — Unreleased

### Added

- First tagged developer preview of Paneflo.
- Check for Updates… in the menu bar, with an optional daily automatic check (on by default, never while the switcher or Overview is showing). A newer release's `Paneflo-<version>.zip` is downloaded and verified (size, SHA-256, bundle ID, version, code signature and the same signing certificate as the running copy) before Paneflo quits, replaces itself, and reopens. The old copy goes to the Trash.
- A download page (`docs/index.html`, for GitHub Pages) and `scripts/release.sh` to publish a release.
