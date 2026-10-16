# Paneflo

Every window. In its place.

Paneflo is a proposed native macOS menu-bar app with three connected functions:

- **Switch:** replace Command–Tab with individual-window switching, immediate cached previews, and one selected live preview.
- **Arrange:** snap, resize, swap, and restore desktop window layouts with bounded undo.
- **Overview:** open an organized Mission Control-style overlay whose chosen window positions remain stable across openings.

One shared window engine connects the three modules. Recent-use switch order and persistent overview positions remain independent.

## Project status

The project is in specification. There is no native application, build target, release, or measured performance result yet. Native implementation begins after the product and engineering requirements are reviewed.

The goal is reliable interaction with bounded resource use. Being faster or using less RAM than native macOS, AltTab, or Rectangle remains a hypothesis to benchmark, not an achieved result. The overview is a custom Paneflo surface, not a promised patch to Apple's Mission Control.

## Specifications

- [Product scope and acceptance criteria](docs/specs/000-product.md)
- [Native architecture and engineering acceptance criteria](docs/specs/001-engineering.md)
- [Contributor workflow](AGENTS.md)

The local interactive concept, comprehensive working spec, and private development material live in **`dev_acrtifacts/`**, which is intentionally gitignored. A fresh checkout will not include them. The directory name preserves the owner's requested spelling.

## Technical direction

Swift, AppKit, and Core Animation for the input and presentation path; SwiftUI may host settings. Begin with one process and modular subsystems. Use a shared event-driven window registry, bounded Accessibility work, and one cost-accounted preview cache. The minimum supported macOS version, shortcut integration, distribution/signing model, and project license remain open decisions.

No build instructions are available until the first native target is introduced.
