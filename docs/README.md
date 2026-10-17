# Docs

- `index.html` is the download page, published with GitHub Pages. It has no build step and no external scripts; it asks the GitHub API for the latest release and links `Paneflo-<version>.zip`, falling back to the releases page.
- `specs/` and `status.md` are the product and engineering specifications and the implementation status.
- `.nojekyll` keeps Pages from running Jekyll over this folder.

## Enabling the site

Settings → Pages → Build and deployment → Source: **Deploy from a branch**, Branch: **main**, Folder: **/docs**. The site is then at `https://jenish-shobhit.github.io/Paneflo/`. Everything in this folder becomes public with it, so keep private development material under the ignored `dev_acrtifacts/`.

## Releasing

Add a `## <version> — <date>` section to `CHANGELOG.md`, commit it on `main`, then run `scripts/release.sh <version>`. It needs the "Paneflo Dev" signing identity (so installed copies accept the update), the `gh` CLI signed in, and a clean `main`.
