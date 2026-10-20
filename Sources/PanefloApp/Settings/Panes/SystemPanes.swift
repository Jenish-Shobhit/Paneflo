import AppKit
import PanefloCore
import SwiftUI

struct PermissionsPane: View {
    let model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                PaneHero(pane: .permissions).padding(.bottom, 8)
                if let setup = model.setup {
                    ForEach(setup.rows, id: \.permission) { row in
                        PermissionRow(row: row, prominent: setup.prominentGrant == row.permission, offersReview: true,
                                      onGrant: { model.perform(.grant(row.permission)) },
                                      onReview: { model.perform(.openPermissionSettings(row.permission)) })
                    }
                    if setup.offersRestart {
                        Callout {
                            Image(systemName: "arrow.clockwise").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                            Text("Switched Paneflo on in System Settings? macOS applies Input Monitoring and Screen Recording after a restart.")
                                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button("Restart Paneflo") { model.perform(.restart) }.buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 4)
                    }
                    if let hint = setup.staleHintText {
                        Callout(tint: PanefloWindowStyle.attention) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(PanefloWindowStyle.attention)
                                .accessibilityHidden(true)
                            Text(hint).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                        Button("Permissions stuck? Reset and grant again…") { model.perform(.resetPermissions) }
                            .buttonStyle(.bordered)
                    }
                } else {
                    Text("Checking…").foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    if model.setup?.showsStaleHint != true {
                        Button("Permissions stuck? Reset and grant again…") { model.perform(.resetPermissions) }
                            .buttonStyle(.link)
                            .help(PermissionReset.explanation)
                    }
                    Button("Open Setup Guide…") { model.perform(.openSetup) }.buttonStyle(.link)
                }
                .font(.system(size: 12))
                .padding(.top, 8)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct UpdatesPane: View {
    let model: SettingsModel

    var body: some View {
        PaneForm(pane: .updates) {
            Section {
                LabeledContent("Version", value: model.versionText)
                SubtitledToggle("Check for updates automatically",
                                subtitle: "Once a day, from GitHub. Never while you’re switching. Nothing about you is sent.",
                                isOn: model.toggle(\.automaticUpdates, SettingsAction.toggleAutomaticUpdates))
                LabeledContent {
                    Button("Check Now") { model.perform(.checkForUpdates) }
                } label: {
                    Text(model.lastUpdateCheckText).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AboutPane: View {
    let model: SettingsModel

    static let website = URL(string: "https://jenish-shobhit.github.io/paneflo/")!
    static let source = URL(string: "https://github.com/Jenish-Shobhit/Paneflo")!
    static let issues = URL(string: "https://github.com/Jenish-Shobhit/Paneflo/issues/new")!

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 24)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Paneflo").font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text("Version \(model.versionText)").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Every window. In its place.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 2)
            HStack(spacing: 8) {
                Button("Website") { model.perform(.openURL(Self.website)) }
                Button("Source Code") { model.perform(.openURL(Self.source)) }
                Button("Report an Issue") { model.perform(.openURL(Self.issues)) }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .padding(.top, 12)
            Spacer(minLength: 24)
            VStack(spacing: 2) {
                Text("Free and open source under the MIT License. © 2026 Jenish Shobhit.")
                Text("No analytics. The only network use is checking GitHub for updates.")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}
