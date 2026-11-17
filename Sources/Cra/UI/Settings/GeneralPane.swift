import SwiftUI

/// Arc's General tab, then what Cra adds. Arc's has four rows in two cards (Arc 1.172.2): "Automatically update my
/// Arc", "Warn before quitting", "Previews" with Previews Settings…, and a line sending the search engine, Auto-Archive
/// and downloads to Profile Settings…. After them come System integration (Dia asks for these in onboarding: default
/// browser, Dock, login) and the Tabs cards, which Arc has no tab for. Sync is the first tab and App Icon the Icon tab.
struct GeneralPane: View {
    let nav: SettingsNavigation
    @Environment(SidebarStore.self) private var store
    @State private var showsPreviews = false
    private let system = SystemIntegration.shared

    var body: some View {
        @Bindable var store = store
        @Bindable var updater = SoftwareUpdater.shared
        SettingsCardPane {
            SettingsCard {
                SettingsCardRow {
                    Text(L10n.tr("Automatically update Cra")).font(.system(size: 13))
                } trailing: {
                    Toggle(L10n.tr("Automatically update Cra"), isOn: $updater.automaticallyUpdates)
                        .toggleStyle(.arcSwitch).labelsHidden()
                        .disabled(!updater.isAvailable).opacity(updater.isAvailable ? 1 : 0.5)
                }
                SettingsCardDivider()
                SettingsCardRow {
                    Text(L10n.tr("Warn before quitting")).font(.system(size: 13))
                        .help(store.settings.keepInMenuBar ? L10n.tr("⌘Q doesn’t quit Cra while it stays in the menu bar (Advanced).") : L10n.tr("⌘Q asks “Quit Cra?” first."))
                } trailing: {
                    Toggle(L10n.tr("Warn before quitting"), isOn: $store.settings.warnBeforeQuitting)
                        .toggleStyle(.arcSwitch).labelsHidden()
                        .disabled(store.settings.keepInMenuBar).opacity(store.settings.keepInMenuBar ? 0.5 : 1)
                }
            }
            SettingsCard {
                SettingsCardRow {
                    Text(L10n.tr("Previews")).font(.system(size: 13))
                } trailing: {
                    Button(L10n.tr("Previews Settings…")) { showsPreviews = true }
                }
                SettingsCardDivider()
                SettingsCardRow {
                    Text(L10n.tr("Manage your default search engine, Auto-Archive, and downloads in Profile Settings."))
                        .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    Button(L10n.tr("Profile Settings…")) { nav.show(.profiles) }
                }
            }
            .padding(.top, 9)

            SettingsHeader(L10n.tr("System")).padding(.top, 20)
            SettingsFeatureCard {
                SettingsPlainRow(L10n.tr("Default browser"),
                                   detail: system.isDefaultBrowser
                                       ? L10n.tr("Links you click in other apps open in Cra.")
                                       : L10n.tr("Links you click in other apps open in %@. Cra works best as your default browser.", system.defaultBrowserName ?? L10n.tr("another browser")),
                                   trailing: {
                    if system.isDefaultBrowser {
                        Label(L10n.tr("Default"), systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        Button(system.isPromptingDefault ? L10n.tr("Confirm in the Dialog…") : L10n.tr("Make Default")) {
                            Task { await system.makeDefaultBrowser() }
                        }
                        .disabled(system.isPromptingDefault)
                    }
                })
                SettingsCardDivider()
                SettingsPlainRow(L10n.tr("Dock"),
                                   detail: system.isInDock ? L10n.tr("Cra is in the Dock.") : L10n.tr("Keep Cra in the Dock to open it with one click."),
                                   trailing: {
                    if system.isInDock {
                        Label(L10n.tr("In the Dock"), systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        Button(L10n.tr("Add to Dock")) { if !system.addToDock() { error = L10n.tr("Cra could not be added to the Dock.") } }
                    }
                })
                SettingsCardDivider()
                SettingsToggleRow(L10n.tr("Open Cra at login"),
                                  detail: L10n.tr("Cra opens by itself when you log in to your Mac."),
                                  isOn: Binding(get: { system.launchesAtLogin }, set: { error = system.setLaunchAtLogin($0) }))
                SettingsCardDivider()
                SettingsCardRow {
                    Text(L10n.tr("Language")).font(.system(size: 13))
                } trailing: {
                    Picker(L10n.tr("Language"), selection: Binding(get: { L10n.language },
                                                          set: { L10n.setLanguage($0) })) {
                        ForEach(L10n.available, id: \.code) { code, name in
                            Text(name).tag(code)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsCardDivider()
                SettingsCardRow {
                    Text(L10n.tr("Language")).font(.system(size: 13))
                } trailing: {
                    Picker(L10n.tr("Language"), selection: Binding(get: { L10n.language },
                                                          set: { L10n.setLanguage($0) })) {
                        ForEach(L10n.available, id: \.code) { code, name in
                            Text(name).tag(code)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if !system.isDefaultBrowser {
                SettingsFootnote(L10n.tr("Cra works best as your default browser."))
            }
            if let error { SettingsFootnote(error).foregroundStyle(.red) }
            TabsPane().settingsNested().padding(.top, 20)
        }
        .onAppear { system.refresh() }
        .sheet(isPresented: $showsPreviews) { PreviewsSheet().environment(store) }
    }

    @State private var error: String?
}

/// Arc's "Show Arc Previews:" sheet (422 wide, Arc 1.172.2): what shows when you hover a folder, a pinned tab or a
/// favorite. All seven of Arc's, in its order (GitHub #376); Outlook and Notion Calendar read with the page's own
/// sign-in, as the Google ones do, not Arc's Microsoft sign-in.
private struct PreviewsSheet: View {
    @Environment(SidebarStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("Show Previews:")).font(.system(size: 13, weight: .semibold))
            Text(L10n.tr("Save a click! Hover your mouse over a Folder, Pinned, or Favorited tab to quickly preview what you need from that site!"))
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L10n.tr("Folders"), isOn: $store.settings.folderPreviews)
                Toggle(L10n.tr("Google Calendar"), isOn: $store.settings.calendarHoverPreview)
                Toggle(L10n.tr("Google Mail"), isOn: $store.settings.favoritePreviews)
                Toggle(L10n.tr("Outlook Calendar"), isOn: $store.settings.outlookCalendarPreviews)
                Toggle(L10n.tr("Outlook Mail"), isOn: $store.settings.outlookMailPreviews)
                Toggle(L10n.tr("Recent pages on Linear, Notion, and Figma"), isOn: $store.settings.recentPagesPreviews)
                Toggle(L10n.tr("Notion Calendar"), isOn: $store.settings.notionCalendarPreviews)
            }
            .toggleStyle(.checkbox)
            .padding(.top, 4)
            HStack {
                Spacer()
                Button(L10n.tr("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(width: 422)
    }
}
