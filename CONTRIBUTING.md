# Contributing to Paneflo

Thanks for helping. This page explains how to build and test Paneflo and what a good pull request looks like.

## Scope

Paneflo is one native Swift menu-bar app with independently enabled Switcher, Tiling and Overview modules that share one window list. Changes that make those faster, more reliable, clearer or more accessible are welcome.

**For anything bigger than a bug fix, open an issue first**, so we can agree it fits before you spend time on it. The specifications in [`docs/specs`](docs/specs) describe intended behaviour, and [`docs/status.md`](docs/status.md) records what is implemented and known limits. If your change alters behaviour they describe, say so in the PR.

## Setting up

You need macOS 26 or later on Apple silicon and the Xcode Command Line Tools (Swift 6.2 or later). Xcode itself isn't needed.

```sh
git clone https://github.com/Jenish-Shobhit/Paneflo.git
cd Paneflo
scripts/build.sh --install --run
```

[docs/building.md](docs/building.md) has the details, including the self-signed **Paneflo Dev** certificate (`scripts/make-signing-identity.sh`) that keeps the macOS permissions across rebuilds. Builds and tests can use a lot of memory; if your machine is tight, run them one at a time.

## Code guidelines

- Match the surrounding code: its naming, structure and comments that explain *why*.
- Prefer AppKit and Core Animation on the latency-sensitive path; Settings may use SwiftUI.
- The shortcut handler reads a prepared snapshot. It must not scan windows, capture frames or make Accessibility calls synchronously.
- Keep switching (MRU) order separate from Overview slot order, and freeze switch order during a session.
- At most one continuous live preview, for the selected window, while a switching surface is visible. Hidden surfaces have no live streams.
- Handle missing or revoked permissions, unresponsive apps, minimized or protected windows, display changes and shortcut recovery.
- Pure logic goes in `PanefloCore` with tests; windows, views and system integration stay in `PanefloApp`.
- No network code beyond update checks, and no analytics.

## Tests

```sh
scripts/test.sh
```

Tests use Swift Testing and live in `Tests/PanefloCoreTests/`. `scripts/test.sh` passes extra arguments through, for example `scripts/test.sh --filter Tiling`. Tests must not touch real system state: use temporary folders and throwaway `UserDefaults` suites.

Behaviour that only exists in the running app is checked by hand; list what you ran in the PR.

## Third-party code and claims

- Don't copy code whose license you haven't reviewed. Contributions must be compatible with the [MIT License](LICENSE); if you adapt something, name its source and license in the PR.
- Don't claim lower memory, lower latency or superiority over another product without comparable measurements.

## Privacy

Never commit or paste in issues and PRs: real window or app titles from your machine, screenshots or captured image payloads, signing keys, tokens, or personal machine traces. Local research and generated artifacts stay in the ignored `dev_acrtifacts/` directory.

## Commits and pull requests

Use [Conventional Commits](https://www.conventionalcommits.org): `feat(tiling): ...`, `fix(overview): ...`, `docs: ...`, with types `feat`, `fix`, `perf`, `refactor`, `test`, `docs` and `chore`. Keep each commit to one logical change that builds and passes `scripts/test.sh`. Never commit `.build/`, `build/`, `dist/`, `dev_acrtifacts/`, `*.app`, `*.zip`, certificates or keys.

Keep PRs small and focused. Describe user-visible changes in the PR; the maintainer writes the `CHANGELOG.md` entry when releasing, so don't bump versions.

## Reporting bugs and security issues

- **Bugs:** use the [bug report form](https://github.com/Jenish-Shobhit/Paneflo/issues/new?template=bug_report.yml).
- **Security vulnerabilities:** don't open a public issue. See [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE). By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
