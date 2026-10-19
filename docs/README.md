# Docs

## Guides

- [User guide](user-guide.md): every feature and setting.
- [Keyboard shortcuts](shortcuts.md): the complete list.
- [Troubleshooting](troubleshooting.md): permissions, gestures, previews, updates.
- [Architecture](architecture.md): modules, threads, performance invariants.
- [Building](building.md): build, test, release and benchmarks.
- [Manual QA](QA.md): release acceptance checklist.
- [Status](status.md): verification record and known limits.
- [Specifications](specs/000-product.md) and [engineering spec](specs/001-engineering.md).

## Site files

What is public here (everything in this folder is served when GitHub Pages is on):

- `index.html` is the download page. It is self-contained (no external scripts), asks the GitHub API for the latest release and links `Paneflo-<version>.zip`, and falls back to the releases page.
- `specs/` holds the product and engineering specifications. They are public.
- `status.md` is the implementation status, verification record and known limits. It is public.
- `.nojekyll` keeps Pages from running Jekyll over this folder.

Keep private material (research, captures, machine traces, local window titles) under the ignored `dev_acrtifacts/`, never in `docs/`.

## Enabling the site

Settings → Pages → Build and deployment → Source: **Deploy from a branch**, Branch: **main**, Folder: **/docs**. The site is then at `https://jenish-shobhit.github.io/Paneflo/`.

## Releasing

Add a `## <version> — <date>` section to `CHANGELOG.md` (replace `Unreleased` with the date), commit it on `main`, then run `scripts/release.sh <version>`. It needs the "Paneflo Dev" signing identity (so installed copies accept the update), the `gh` CLI signed in, and a clean `main`.
