import CraCEF
import SwiftUI

/// Settings ▸ Advanced: Dia's Advanced pane (Automatically update, Address Bar routing, When
/// quitting) plus Arc's Advanced switches (sound effects, theme data, window dragging, Boosts)
/// and Cra's own (page engine, import and export, local agents). None of them changes how Cra
/// looks, so each is a plain row (name, what it does, control); About closes the pane.
struct AdvancedPane: View {
    let actions: SettingsActions
    private static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    @Environment(SidebarStore.self) private var store

    var body: some View {
        @Bindable var store = store
        @Bindable var updater = SoftwareUpdater.shared
        let newLittleWindow = KeyBindingRegistry.shared.action("newLittleWindow")?.primary?.display ?? "⌥⌘N"
        SettingsCardPane {
            // Arc's Advanced (Arc 1.172.2, GitHub #372): three cards of switches on coloured tiles, then buttons.
            // Its Shared Quotes switch isn't in Cra (the links it makes are arc.net's).
            SettingsCard {
                SettingsTileRow(L10n.tr("Play Cra sound effects"), symbol: "speaker.wave.2.fill", tile: .blue, isOn: $store.settings.soundEffects)
                SettingsCardDivider()
                SettingsTileRow(L10n.tr("Haptic feedback when reordering tabs"), symbol: "hand.tap.fill", tile: .blue, isOn: $store.settings.hapticFeedbackOnReorder)
            }
            SettingsCard {
                SettingsTileRow(L10n.tr("When opening Cra, restore windows from previous session"), symbol: "macwindow", tile: .green, isOn: $store.settings.restoreWindows)
                SettingsCardDivider()
                SettingsTileRow(L10n.tr("Allow window dragging from the top of webpages"), symbol: "rectangle.topthird.inset.filled", tile: .green, isOn: $store.settings.pageTopWindowDrag)
                SettingsCardDivider()
                SettingsTileRow(L10n.tr("Show full URL when Toolbar is enabled"), symbol: "ellipsis.rectangle", tile: .red, isOn: $store.settings.toolbarShowsFullURL)
            }
            .padding(.top, 9)
            SettingsCard {
                SettingsTileRow(L10n.tr("Enable Picture in Picture when you leave a video tab"), symbol: "play.square", tile: .purple, isOn: $store.settings.autoPictureInPicture)
                SettingsCardDivider()
                SettingsTileRow(L10n.tr("Allow websites to get your theme data"), symbol: "paintpalette.fill", tile: .purple, isOn: $store.settings.shareThemeWithWebsites)
                SettingsCardDivider()
                SettingsTileRow(L10n.tr("Enable Boosts on websites you visit"), symbol: "paintbrush.fill", tile: .purple, isOn: $store.settings.boostsEnabled)
            }
            .padding(.top, 9)
            HStack(spacing: 16) {
                Button(L10n.tr("More Settings…")) { actions.openURL("chrome://settings") }
                ResetTranslatedSitesButton(reset: actions.resetTranslatedSitePrompts)
                Spacer(minLength: 0)
            }
            .padding(.top, 14)

            SettingsHeader(L10n.tr("Cra")).padding(.top, 20)
            SettingsFeatureCard {
                // The switch is Arc's General ▸ "Automatically update my Arc".
                SettingsPlainRow(L10n.tr("Updates"),
                                 detail: L10n.tr("Cra downloads new versions in the background and installs them the next time it opens (General)."),
                                 trailing: { EmptyView() }) {
                    HStack(spacing: 8) {
                        Button(L10n.tr("Check for Updates…")) { updater.checkForUpdates(nil) }
                            .disabled(!updater.isAvailable)
                        Text(updater.lastCheckSummary).foregroundStyle(.secondary)
                    }
                }
                SettingsCardDivider()
                // GitHub #476, not in Arc: a version that breaks something stays on New until it's fixed.
                SettingsPlainRow(L10n.tr("Update channel"),
                                 detail: L10n.tr("New gets each version of Cra the day it comes out. Stable gets a version once it has held up on New."),
                                 trailing: {
                                     Picker(L10n.tr("Update channel"), selection: $updater.channel) {
                                         ForEach(UpdateChannel.allCases, id: \.self) { Text($0.title).tag($0) }
                                     }
                                     .labelsHidden().fixedSize()
                                     .disabled(!updater.isAvailable)
                                 }) {
                    // Sparkle never installs an older version: going back to Stable now is a download.
                    if let stable = updater.olderStable, let diskImage = stable.diskImageURL {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.tr("Stable is Cra %@. This Mac stays on 司南 %@ until Stable passes it, or you can install Stable now.", stable.version, Self.version))
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button(L10n.tr("Download 司南 \(stable.version)")) { actions.openURL(diskImage) }
                        }
                    }
                }
                .onAppear { updater.lookUpStable() }
                SettingsCardDivider()
                SettingsToggleRow(L10n.tr("Chrome engine for pages"),
                                  detail: L10n.tr("Pages run on Chromium, with Chrome extensions and Chrome DevTools. Takes effect when Cra restarts."),
                                  isOn: $store.settings.chromeEngine)
            }

            // The search engine and its suggestions are in Profiles, where Arc has them.
            SettingsHeader(L10n.tr("Command bar")).padding(.top, 20)
            SettingsFeatureCard {
                // GitHub #457, not in Arc: Arc's bar stays neutral, with the site in the pill and a short wash.
                SettingsSwitchRow("Fill the command bar with the site’s color",
                                  detail: "When Tab starts a search on a site, like YouTube or GitHub, the command bar takes that site’s color until you leave the search.",
                                  isOn: $store.settings.commandBarSiteColor) { SettingsArt.commandBarSiteColor }
                SettingsCardDivider()
                // GitHub #307, not in Arc: ⌘T finds tabs in the window's space only.
                SettingsToggleRow(L10n.tr("Only this space’s tabs"),
                                  detail: L10n.tr("The command bar finds open tabs in the space you’re in, not in all your spaces."),
                                  isOn: $store.settings.commandBarCurrentSpaceOnly)
                    .settingsTextColumn()
            }

            SettingsHeader(L10n.tr("Opening and quitting")).padding(.top, 20)
            SettingsFeatureCard {
                // Not in Arc (X DM 7 Nov 2026): Arc opens on the tab in use last.
                SettingsToggleRow(L10n.tr("Start on a new tab"),
                                  detail: L10n.tr("When Cra opens, it starts on a new tab instead of the tab you used last."),
                                  isOn: $store.settings.startOnNewTab)
                SettingsCardDivider()
                // GitHub #231, not in Arc: ⌘Q puts Cra in the menu bar instead of quitting.
                SettingsToggleRow(L10n.tr("Keep Cra in the menu bar"),
                                  detail: L10n.tr("⌘Q closes Cra’s windows and pages but leaves it running in the menu bar, so %@ opens a Little Window at once. Quit it from the menu bar.", newLittleWindow),
                                  isOn: $store.settings.keepInMenuBar)
            }

            SettingsHeader(L10n.tr("Your data")).padding(.top, 20)
            SettingsFeatureCard {
                SettingsPlainRow(L10n.tr("Import from another browser"),
                                   detail: importDetail,
                                   trailing: { Button(L10n.tr("Import…")) { actions.importData() } })
                SettingsCardDivider()
                SettingsPlainRow(L10n.tr("Export spaces and pinned tabs"),
                                   detail: L10n.tr("Save every space’s favorites, pinned tabs and folders as a bookmarks file that Chrome, Safari, Firefox and other browsers can import."),
                                   trailing: { Button(L10n.tr("Export…")) { SidebarExport.run(store, in: NSApp.keyWindow) } })
            }

            SettingsHeader(L10n.tr("Agents")).padding(.top, 20)
            SettingsFeatureCard {
                SettingsToggleRow(L10n.tr("Allow local agents to control Cra"),
                                  detail: L10n.tr("AI agents on this Mac can read pages and act using your signed-in sessions, through MCP."),
                                  isOn: Binding(get: { MCPServer.shared.enabled }, set: { MCPServer.shared.setEnabled($0) })) {
                    Text(MCPServer.shared.status)
                    if MCPServer.shared.enabled {
                        Text(L10n.tr("Last tool: %@", MCPServer.shared.lastTool.isEmpty ? "None" : MCPServer.shared.lastTool))
                            .foregroundStyle(.secondary)
                    }
                }
                if MCPServer.shared.enabled {
                    SettingsCardDivider()
                    MCPAgentTiles()
                    SettingsCardDivider()
                    SettingsCardRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("Let agents run JavaScript in pages")).font(.system(size: 13))
                            Text(L10n.tr("A script can read anything a page holds, including passwords Cra fills in."))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } trailing: {
                        Toggle(L10n.tr("Let agents run JavaScript in pages"), isOn: Binding(
                            get: { MCPServer.shared.allowsScripts }, set: { MCPServer.shared.allowsScripts = $0 }))
                            .toggleStyle(.arcSwitch).labelsHidden()
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        Text(L10n.tr("Let agents read your history")).font(.system(size: 13))
                    } trailing: {
                        Toggle(L10n.tr("Let agents read your history"), isOn: Binding(
                            get: { MCPServer.shared.allowsHistory }, set: { MCPServer.shared.allowsHistory = $0 }))
                            .toggleStyle(.arcSwitch).labelsHidden()
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("Let agents upload local files")).font(.system(size: 13))
                            Text(L10n.tr("An agent could hand any file on this Mac (like ~/.ssh/id_rsa) to a web page. Off unless you truly need it."))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } trailing: {
                        Toggle(L10n.tr("Let agents upload local files"), isOn: Binding(
                            get: { MCPServer.shared.allowsUploads }, set: { MCPServer.shared.allowsUploads = $0 }))
                            .toggleStyle(.arcSwitch).labelsHidden()
                    }
                    ForEach(MCPServer.shared.agents) { agent in
                        SettingsCardDivider()
                        SettingsCardRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.via.isEmpty ? agent.name : L10n.tr("%@ in %@", agent.name, agent.via)).font(.system(size: 13))
                                Text(agent.allowed ? L10n.tr("Allowed") : L10n.tr("Not allowed")).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        } trailing: {
                            Button(L10n.tr("Forget")) { MCPServer.shared.forget(agent) }
                        }
                    }
                }
            }

            SettingsHeader(L10n.tr("About")).padding(.top, 20)
            SettingsFeatureCard {
                HStack(spacing: 14) {
                    BrandMark(size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        // A click copies the version with its build and engine, for a bug report (GitHub #461).
                        Button(action: actions.copyVersion) {
                            Text(L10n.tr("Cra %@", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.tr("Copy the Cra version"))
                        .editorPointer(.link)
                        Text(EngineVersion.label(chromium: CraCEFRuntime.chromiumVersion(), cef: CraCEFRuntime.cefVersion()))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(AppPaths.supportDir.path).font(.system(size: 11)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
        }
    }

    private var importDetail: String {
        let names = ImportSource.allCases.filter { $0.kind != .safari && $0.isAvailable }.map(\.name)
        return names.isEmpty
            ? L10n.tr("Bring bookmarks, open tabs, passwords and sign-ins over from Safari.")
            : L10n.tr("Bring spaces, tabs, folders, favorites, passwords, sign-ins and extensions over from %@, Safari and more.", names.joined(separator: ", "))
    }
}

/// Chromium's default search engine, the one chrome://settings/searchEngines sets (Arc: Settings ▸
/// Profiles ▸ Default Search Engine, beside "Search Settings"): its built-in engines and whichever is
/// the default. The page adds, edits and removes the rest.
struct SearchEnginePicker: View {
    let store: SidebarStore
    @State private var engines: [ChromiumSearchEngine] = []
    @State private var selected = ""

    var body: some View {
        Picker(L10n.tr("Search engine"), selection: Binding(get: { selected }, set: pick)) {
            ForEach(engines, id: \.keyword) { Text($0.name).tag($0.keyword) }
        }
        .labelsHidden()
        .fixedSize()
        .onAppear(perform: reload)
    }

    private func reload() {
        let current = SearchEngines.shared.defaultEngine(profilePath: nil, legacy: store.settings.searchEngine)
        var list = SearchEngines.shared.keywords(profilePath: nil).filter(\.isBuiltIn)
        if !list.contains(where: { $0.keyword == current.keyword }) { list.insert(current, at: 0) }
        engines = list
        selected = current.keyword
    }

    private func pick(_ keyword: String) {
        guard let engine = engines.first(where: { $0.keyword == keyword }) else { return }
        SearchEngines.shared.setDefault(engine, store: store)
        selected = keyword
    }
}

/// Arc's "Reset Translated-site Prompts", which says nothing when it is done: the label turns to "Done"
/// for two seconds instead.
private struct ResetTranslatedSitesButton: View {
    let reset: () -> Void
    @State private var done = false

    var body: some View {
        Button(done ? L10n.tr("Done") : L10n.tr("Reset Translated-site Prompts")) {
            reset()
            done = true
            Task { try? await Task.sleep(for: .seconds(2)); done = false }
        }
        .disabled(done)
    }
}
