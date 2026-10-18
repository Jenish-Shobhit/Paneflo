import PanefloCore
import SwiftUI

/// The Settings root: a 200 pt sidebar of icon tiles and a grouped form per pane. Pane switches are instant.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebar(model: model)
                .navigationSplitViewColumnWidth(PanefloWindowStyle.sidebarWidth)
        } detail: {
            SettingsDetail(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .transaction { $0.animation = nil }
    }
}

struct SettingsSidebar: View {
    @Bindable var model: SettingsModel

    private var selection: Binding<SettingsPane?> {
        Binding(get: { model.pane }, set: { if let pane = $0 { model.perform(.selectPane(pane)) } })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(SettingsPane.featurePanes) { item($0) }
            }
            Section {
                ForEach(SettingsPane.systemPanes) { item($0) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatus(model: model) }
    }

    private func item(_ pane: SettingsPane) -> some View {
        HStack(spacing: 8) {
            IconTile(symbol: pane.symbol, tint: pane.tint)
            Text(pane.title).font(.system(size: 13))
            Spacer(minLength: 0)
            if pane == .permissions, model.setupNeeded {
                Circle().fill(PanefloWindowStyle.attention).frame(width: 7, height: 7)
                    .accessibilityLabel("Setup needed")
            }
        }
        .tag(pane)
        .accessibilityElement(children: .combine)
    }
}

/// The pill pinned to the bottom of the sidebar: whether ⌘Tab works right now.
struct SidebarStatus: View {
    let model: SettingsModel

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
            switch model.appStatus {
            case .setupNeeded:
                Text("Setup needed").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Finish Setup…") { model.perform(.openSetup) }
                    .buttonStyle(.link).font(.system(size: 12))
            default:
                Text(model.appStatus.title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Paneflo status")
    }

    private var dot: Color {
        switch model.appStatus {
        case .ready: PanefloWindowStyle.granted
        case .setupNeeded: PanefloWindowStyle.attention
        case .starting, .paused: Color(nsColor: .systemGray)
        }
    }
}

struct SettingsDetail: View {
    let model: SettingsModel

    var body: some View {
        Group {
            switch model.pane {
            case .general: GeneralPane(model: model)
            case .help: HelpPane(model: model)
            case .tiling: TilingPane(model: model)
            case .overviewGesture: OverviewGesturePane(model: model)
            case .previews: PreviewsPane(model: model)
            case .desktop: DesktopPane(model: model)
            case .permissions: PermissionsPane(model: model)
            case .updates: UpdatesPane(model: model)
            case .about: AboutPane(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(model.pane.title)
    }
}

/// Hero + grouped form, the standard pane layout.
struct PaneForm<Content: View>: View {
    let pane: SettingsPane
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            PaneHero(pane: pane).padding(.horizontal, 30).padding(.top, 20).padding(.bottom, 0)
            Form { content() }
                .formStyle(.grouped)
        }
    }
}

/// A section footer in the spec's 11 pt secondary.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A toggle with a plain subtitle under its title (Margin pattern).
struct SubtitledToggle<Title: View>: View {
    let isOn: Binding<Bool>
    let subtitle: String?
    @ViewBuilder var title: () -> Title

    var body: some View {
        Toggle(isOn: isOn) {
            title()
            if let subtitle { Text(subtitle) }
        }
    }
}

extension SubtitledToggle where Title == Text {
    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.init(isOn: isOn, subtitle: subtitle) { Text(title) }
    }
}
