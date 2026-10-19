# Docs

## Guides

| Guide | What it covers |
|---|---|
| [User guide](user-guide.md) | Every feature and setting |
| [Keyboard shortcuts](shortcuts.md) | The complete reference, including custom tiling shortcuts |
| [Troubleshooting](troubleshooting.md) | Opening, permissions, shortcuts, the gesture, previews and updates |
| [Architecture](architecture.md) | Modules, threads and performance invariants |
| [Building](building.md) | Build, test, sign, release and benchmarks |
| [Manual QA](QA.md) | Release acceptance checklist |
| [Status](status.md) | Verification record and known limits |
| [Product spec](specs/000-product.md) and [engineering spec](specs/001-engineering.md) | Requirements, architecture and capability gates |

## Site files

Everything in this folder is public and is served when GitHub Pages is on.

| Path | What it is |
|---|---|
| `index.html` | The download page. One self-contained file: inline CSS and JavaScript, no frameworks, web fonts or external scripts. It asks the GitHub API for the latest release to link `Paneflo-<version>.zip` with its version and size, and falls back to the releases page. |
| `404.html` | The Pages not-found page. |
| `favicon.png`, `icon.png`, `og.png`, `assets/` | Icons and the social preview image. |
| `images/` | Illustrations for the README, drawn from synthetic mockups (no real windows or desktops). |
| `specs/`, `status.md` | The product and engineering specifications and the verification record. |
| `.nojekyll` | Keeps Pages from running Jekyll over this folder. |

Keep private material (research, captures, machine traces, local window titles) under the ignored `dev_acrtifacts/`, never in `docs/`.

## Enabling the site

Settings › Pages › Build and deployment › Source: **Deploy from a branch**, Branch: **main**, Folder: **/docs**. The site is then at `https://jenish-shobhit.github.io/Paneflo/`.

## Releasing

Add a `## <version> — <date>` section to `CHANGELOG.md` (replace `Unreleased` with the date), commit it on `main`, then run `scripts/release.sh <version>`. It needs the "Paneflo Dev" signing identity (so installed copies accept the update), the `gh` CLI signed in, and a clean `main`.
