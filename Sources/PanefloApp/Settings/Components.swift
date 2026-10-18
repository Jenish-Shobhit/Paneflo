import AppKit
import PanefloCore
import SwiftUI

// Shared SwiftUI pieces for Settings and the setup window (design spec §6.3, §7.3).

/// A white SF Symbol on a rounded color tile, System Settings style. Decorative: hidden from VoiceOver.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = PanefloWindowStyle.sidebarTile

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(tint)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// The top of every pane: icon tile, title, one-sentence description.
struct PaneHero: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: pane.symbol, tint: pane.tint, size: PanefloWindowStyle.heroTile)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title).font(.system(size: 15, weight: .semibold))
                Text(pane.summary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "Experimental" capsule next to a section header or toggle.
struct ExperimentalTag: View {
    var body: some View {
        Text("Experimental")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(nsColor: .systemOrange))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(Color(nsColor: .systemOrange).opacity(0.18)))
    }
}

/// "Required" / "Optional" capsule on a permission row.
struct RequirementTag: View {
    let text: String
    let required: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(required ? .secondary : .tertiary)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(PanefloWindowStyle.fill))
    }
}

/// One keycap: 22 pt tall, radius 5, quaternary fill with a hairline border (1 pt with Increase Contrast).
struct Keycap: View {
    let text: String
    var height: CGFloat = PanefloWindowStyle.keycapHeight
    var fontSize: CGFloat = 11
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, height * 0.3)
            .frame(minWidth: height, minHeight: height)
            .background(RoundedRectangle(cornerRadius: PanefloWindowStyle.keycapRadius * height / 22).fill(PanefloWindowStyle.fill))
            .overlay(RoundedRectangle(cornerRadius: PanefloWindowStyle.keycapRadius * height / 22)
                .strokeBorder(contrast == .increased ? Color(nsColor: .secondaryLabelColor) : PanefloWindowStyle.separator,
                              lineWidth: contrast == .increased ? 1 : 0.5))
    }
}

/// Label left, keycaps right. Read-only (shortcut recording is out of scope). VoiceOver reads the keys by name.
struct KeycapRow: View {
    let label: String
    let keys: [String]

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) { ForEach(Array(keys.enumerated()), id: \.offset) { Keycap(text: $0.element) } }
        } label: {
            Text(label)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(keys.map(KeyNames.spoken).joined(separator: ", "))
    }
}

/// Spoken names for key glyphs.
enum KeyNames {
    static func spoken(_ glyphs: String) -> String {
        switch glyphs {
        case "esc": return "Escape"
        case "Space": return "Space"
        default: break
        }
        let names: [Character: String] = ["⌘": "Command", "⌃": "Control", "⌥": "Option", "⇧": "Shift", "⇥": "Tab",
                                          "←": "Left Arrow", "→": "Right Arrow", "↑": "Up Arrow", "↓": "Down Arrow",
                                          "↩": "Return"]
        var parts: [String] = []
        var rest = ""
        for character in glyphs {
            if let name = names[character] {
                if !rest.isEmpty { parts.append(rest); rest = "" }
                parts.append(name)
            } else if character != " " {
                rest.append(character)
            }
        }
        if !rest.isEmpty { parts.append(rest == "Space" ? "Space" : rest) }
        return parts.joined(separator: " ")
    }
}

extension SetupTone {
    var color: Color {
        switch self {
        case .granted: PanefloWindowStyle.granted
        case .attention: PanefloWindowStyle.attention
        case .neutral: Color(nsColor: .secondaryLabelColor)
        }
    }

    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .neutral: "circle.dashed"
        }
    }
}

/// Symbol, title, secondary detail, optional trailing control. Color is never the only signal: each tone has its own
/// symbol.
struct StatusRow<Trailing: View>: View {
    let tone: SetupTone
    var symbol: String?
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol ?? tone.symbol)
                .foregroundStyle(tone.color)
                .font(.system(size: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension StatusRow where Trailing == EmptyView {
    init(tone: SetupTone, symbol: String? = nil, title: String, detail: String? = nil) {
        self.init(tone: tone, symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

/// An accent-wash box for the restart and stuck-permission notes.
struct Callout<Content: View>: View {
    var tint: Color = .accentColor
    @ViewBuilder var content: () -> Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .center, spacing: 10, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PanefloWindowStyle.calloutRadius).fill(tint.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: PanefloWindowStyle.calloutRadius)
                .strokeBorder(tint.opacity(contrast == .increased ? 0.8 : 0), lineWidth: 1))
    }
}

/// One permission: status symbol, title with Required/Optional tag, purpose, live status line, Grant….
/// Shared by the setup window and Settings › Permissions; every string comes from `SetupRow` in Core.
struct PermissionRow: View {
    let row: SetupRow
    let prominent: Bool
    /// Settings only: a granted row offers "Open Settings" to review it in System Settings.
    var offersReview = false
    let onGrant: () -> Void
    var onReview: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.symbolName)
                .font(.system(size: 22))
                .foregroundStyle(row.tone.color)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.permission.title).font(.system(size: 13, weight: .semibold))
                    RequirementTag(text: row.tag, required: row.required)
                }
                Text(row.permission.purpose)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(row.status == .granted ? PanefloWindowStyle.granted
                                     : row.status == .needsRestart ? PanefloWindowStyle.attention : Color.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(row.permission.title), \(row.tag)")
            .accessibilityValue(row.statusText)
            .accessibilityHint(row.permission.purpose)
            Spacer(minLength: 8)
            if row.showsGrant {
                Button("Grant…", action: onGrant)
                    .modifier(ProminentIf(prominent))
                    .accessibilityLabel("Grant \(row.permission.title)")
            } else if offersReview {
                Button("Open Settings", action: onReview)
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Open \(row.permission.title) in System Settings")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: PanefloWindowStyle.rowRadius)
            .fill(reduceTransparency ? Color(nsColor: .controlBackgroundColor) : PanefloWindowStyle.fill))
        .overlay(RoundedRectangle(cornerRadius: PanefloWindowStyle.rowRadius)
            .strokeBorder(PanefloWindowStyle.separator.opacity(contrast == .increased ? 1 : 0.5), lineWidth: contrast == .increased ? 1 : 0.5))
        .animation(PanefloWindowStyle.statusAnimation(reduceMotion: reduceMotion), value: row.status)
    }
}

/// `.borderedProminent` for the one prominent button, `.bordered` otherwise.
struct ProminentIf: ViewModifier {
    let prominent: Bool
    init(_ prominent: Bool) { self.prominent = prominent }
    func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}
