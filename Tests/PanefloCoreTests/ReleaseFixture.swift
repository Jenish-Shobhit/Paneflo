import Foundation

/// A synthetic answer shaped like `GET /repos/Jenish-Shobhit/Paneflo/releases/latest` for v0.0.15: the keys the updater
/// reads, with the host's nesting, plus a few it ignores. The identifiers and the digest are made up.
let releaseFixtureJSON = #"""
{
  "url": "https://api.github.com/repos/Jenish-Shobhit/Paneflo/releases/1",
  "assets_url": "https://api.github.com/repos/Jenish-Shobhit/Paneflo/releases/1/assets",
  "html_url": "https://github.com/Jenish-Shobhit/Paneflo/releases/tag/v0.0.15",
  "id": 1,
  "author": { "login": "example", "id": 1, "type": "User", "site_admin": false },
  "tag_name": "v0.0.15",
  "target_commitish": "main",
  "name": "Paneflo 0.0.15",
  "draft": false,
  "immutable": false,
  "prerelease": false,
  "created_at": "2026-10-15T04:00:49Z",
  "updated_at": "2026-10-15T04:00:55Z",
  "published_at": "2026-10-15T04:00:55Z",
  "assets": [
    {
      "url": "https://api.github.com/repos/Jenish-Shobhit/Paneflo/releases/assets/2",
      "id": 2,
      "name": "Paneflo-0.0.15.zip",
      "label": "",
      "uploader": { "login": "example", "id": 1, "type": "User" },
      "content_type": "application/zip",
      "state": "uploaded",
      "size": 1945999,
      "digest": "sha256:44b912c434e492dc22663146ae38838d47371f9b30b23d1f8ca591ad861bc226",
      "download_count": 0,
      "created_at": "2026-10-15T04:00:54Z",
      "updated_at": "2026-10-15T04:00:55Z",
      "browser_download_url": "https://github.com/Jenish-Shobhit/Paneflo/releases/download/v0.0.15/Paneflo-0.0.15.zip"
    }
  ],
  "tarball_url": "https://api.github.com/repos/Jenish-Shobhit/Paneflo/tarball/v0.0.15",
  "zipball_url": "https://api.github.com/repos/Jenish-Shobhit/Paneflo/zipball/v0.0.15",
  "body": "## 0.0.15 — 2026-10-15\n\n### Fixed\n\n- The switcher kept the previous selection after a display change. It now starts from the frontmost window.\n- A tiling shortcut pressed while a window was minimized did nothing and gave no hint. It now says so in the menu.\n\n## 0.0.14 — 2026-10-15\n\n### Changed\n\n- The overview opens from the prepared window list without waiting for a scan.\n\n### Install\n\nDownload `Paneflo-0.0.15.zip`, unzip, and move **Paneflo.app** to `/Applications`. Not notarized yet: on first open, go to **System Settings › Privacy & Security › Open Anyway**. Requires macOS 26+ on Apple silicon.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n"
}
"""#
