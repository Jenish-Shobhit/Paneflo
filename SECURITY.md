# Security policy

## Supported versions

Only the [latest release](https://github.com/Jenish-Shobhit/Paneflo/releases/latest) gets fixes. Please update before reporting.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through GitHub:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**, or go straight to [the advisory form](https://github.com/Jenish-Shobhit/Paneflo/security/advisories/new).
3. Describe the problem, the Paneflo and macOS versions, and how to reproduce it.

You'll get a reply on the advisory. Please allow time for a fix and a release before you disclose anything publicly.

## What Paneflo accesses

Paneflo is a local app with no analytics, telemetry or accounts. Its only network requests are update checks. It is not sandboxed: it needs macOS permissions to do its job, and asks for each one only when you grant it.

| What | Why |
|---|---|
| **Accessibility** | Find, focus, move and resize other apps' windows (switching and tiling). |
| **Input Monitoring** | Listen for the Tab, tiling and gesture input that starts those features. Paneflo does not record or store keystrokes. |
| **Screen Recording** (optional) | Window pictures in the switcher and Overview. Without it the cards show icons. |
| **Network** | Update checks against the GitHub releases API, and the release download when you choose to update. Nothing about you, your Mac or your windows is sent. |

## Updates

An update is accepted only if the downloaded app has a valid code signature and satisfies the designated requirement of the copy that is running, that is, the same bundle ID signed by the same certificate. Releases are signed with a self-signed certificate and are not notarized, so this pins continuity with the copy you installed; the first download is trusted the way any download from the releases page is. A copy built from source and signed ad hoc refuses updates.
