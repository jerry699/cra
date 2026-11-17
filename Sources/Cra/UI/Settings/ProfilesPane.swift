import AppKit
import CraCEF
import SwiftUI

/// Arc's Profiles tab (Arc 1.172.2, GitHub #372): a line on what a profile is, the list of profiles on the left
/// ("Your Profiles", how many Spaces use each, + − and rename under it) and the chosen profile's cards on the right:
/// its search engine, how long tabs stay before they are archived, the app "New …" documents open in (#375), where
/// downloads go, and "Your Data and Settings", which open Chromium's pages for that profile. Arc only deletes profiles no space uses, and never Default.
/// Cra adds the website languages and "Rebuild from Arc…" to the right-hand cards.
struct ProfilesPane: View {
    let nav: SettingsNavigation
    let actions: SettingsActions
    @Environment(SidebarStore.self) private var store
    /// The profile on the right; nil is Default.
    @State private var selected: UUID?

    var body: some View {
        @Bindable var store = store
        let current = store.profiles.contains { $0.id == selected } ? selected : nil
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.tr("Profiles help keep your data separate across Spaces — like history, logins, cookies, and extensions. You can use any Profile across one or more Spaces."))
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                list(current: current)
                    .frame(width: 205)
                ScrollView(.vertical) { detail(for: current).padding(.bottom, 1) }
                    .scrollIndicators(.automatic)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, SettingsMetrics.paneInset)
        .padding(.top, SettingsMetrics.paneTop)
        .padding(.bottom, SettingsMetrics.paneBottom)
    }

    // MARK: List

    private func list(current: UUID?) -> some View {
        let name = current == nil ? "Default" : (store.profile(current)?.name ?? "Default")
        return VStack(spacing: 0) {
            Text(L10n.tr("Your Profiles")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            Rectangle().fill(Color.settingsHairline).frame(height: 1)
            VStack(spacing: 0) {
                profileRow(L10n.tr("Default"), id: nil, current: current)
                ForEach(store.profiles) { profileRow($0.name, id: $0.id, current: current) }
            }
            .padding(.horizontal, 10).padding(.top, 10)
            Spacer(minLength: 0)
            Rectangle().fill(Color.settingsHairline).frame(height: 1)
            HStack(spacing: 0) {
                barButton("plus", help: L10n.tr("Create Profile…")) { actions.newProfile() }
                barDivider
                barButton("minus", help: current == nil ? L10n.tr("The Default Profile cannot be deleted.") : L10n.tr("Delete “%@”…", name)) {
                    if let p = store.profile(current) { delete(p) }
                }
                .disabled(current == nil || !store.spaces(usingProfile: current).isEmpty)
                barDivider
                barButton("rectangle.and.pencil.and.ellipsis", help: L10n.tr("Rename “%@”…", name)) {
                    if let p = store.profile(current) { rename(p) }
                }
                .disabled(current == nil)
                Spacer(minLength: 0)
            }
            .frame(height: 33)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: SettingsMetrics.cardCorner, style: .continuous).fill(Color(nsColor: SettingsPalette.card)))
        .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.cardCorner, style: .continuous).strokeBorder(Color.settingsHairline, lineWidth: 1))
    }

    private func profileRow(_ name: String, id: UUID?, current: UUID?) -> some View {
        let count = store.spaces(usingProfile: id).count
        let isCurrent = id == current
        return Button { selected = id } label: {
            HStack {
                Text(name).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 8)
                Text(count == 1 ? L10n.tr("1 Space") : L10n.tr("%d Spaces", count)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrent ? Color(nsColor: SettingsPalette.selectedRow) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: symbol == "plus" || symbol == "minus" ? 29 : 38, height: 33)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private var barDivider: some View { Rectangle().fill(Color.settingsHairline).frame(width: 1, height: 33) }

    // MARK: Detail

    private enum Archive: Hashable { case after(AutoArchiveThreshold), never }
    private enum DownloadChoice: Hashable { case folder, ask, other }

    @ViewBuilder private func detail(for profileID: UUID?) -> some View {
        @Bindable var store = store
        let path = store.profilePath(profile: profileID)
        let archive = Binding<Archive>(
            get: { store.settings.autoArchiveEnabled ? .after(store.settings.autoArchive) : .never },
            set: {
                switch $0 {
                case .never: store.settings.autoArchiveEnabled = false
                case .after(let t): store.settings.autoArchiveEnabled = true; store.settings.autoArchive = t
                }
            })
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                SettingsCardRow { Text(L10n.tr("Search engine")).font(.system(size: 13)) } trailing: { SearchEnginePicker(store: store) }
                SettingsCardDivider()
                SettingsCardRow { Text(L10n.tr("Manage search")).font(.system(size: 13)) } trailing: {
                    Button(L10n.tr("Search Settings…")) { actions.openProfilePage(SearchEngines.settingsPage, profileID) }
                }
                SettingsCardDivider()
                SettingsCardRow { Text(L10n.tr("Include search engine suggestions")).font(.system(size: 13)) } trailing: {
                    Toggle(L10n.tr("Include search engine suggestions"), isOn: $store.settings.searchSuggestions)
                        .toggleStyle(.arcSwitch).labelsHidden()
                }
            }
            SettingsCard {
                SettingsCardRow { Text(L10n.tr("Archive tabs after")).font(.system(size: 13)) } trailing: {
                    Picker(L10n.tr("Archive tabs after"), selection: archive) {
                        ForEach(AutoArchiveThreshold.allCases) { Text(L10n.tr($0.label)).tag(Archive.after($0)) }
                        Divider()
                        Text(L10n.tr("Never")).tag(Archive.never)
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsCardDivider()
                // Arc's "New documents": the app the command bar's "New …" command opens (#375).
                SettingsCardRow { Text(L10n.tr("New documents")).font(.system(size: 13)).fixedSize() } trailing: { documentPicker(profileID) }
                SettingsCardDivider()
                SettingsCardRow { Text(L10n.tr("Download location")).font(.system(size: 13)).fixedSize() } trailing: { downloadPicker(profileID) }
                SettingsCardDivider()
                // Not in Arc's card: the website languages are Chromium's, per profile (#209).
                languageRow(profileID: profileID)
            }
            .padding(.top, 9)

            SettingsHeader(L10n.tr("Your Data and Settings")).padding(.top, 14)
            SettingsCard {
                ForEach(Array(Self.dataPages.enumerated()), id: \.offset) { i, page in
                    if i > 0 { SettingsCardDivider() }
                    dataRow(page, profileID: profileID)
                }
            }
            if profileID == nil, ArcProfileRebuilder.isAvailable {
                // Spaces an Arc import left on Default, back on their Arc profiles (#131).
                Button(L10n.tr("Rebuild from Arc…")) { actions.rebuildArcProfiles() }
                    .help(L10n.tr("Put spaces imported from Arc back on the profiles they use in Arc, with their sign-ins and extensions."))
                    .padding(.top, 14)
            }
        }
        .id("\(profileID?.uuidString ?? "default")-\(nav.shown)")  // read again each time Settings comes up: Chromium's page may have changed them
        .disabled(path == nil && profileID != nil)
    }

    /// Arc's five rows, in its order, with the Chromium page each opens and the colour of its tile.
    static let dataPages: [(title: String, symbol: String, color: Color, url: String)] = [
        ("Privacy and Security", "lock.fill", Color(.sRGB, red: 0.20, green: 0.45, blue: 0.95), "chrome://settings/privacy"),
        ("Passwords", "key.fill", Color(.sRGB, red: 0.30, green: 0.72, blue: 0.35), "chrome://password-manager/passwords"),
        ("Credit Cards", "creditcard.and.123", Color(.sRGB, red: 0.90, green: 0.75, blue: 0.20), "chrome://settings/payments"),
        ("Notifications", "bell.fill", Color(.sRGB, red: 0.92, green: 0.55, blue: 0.25), "chrome://settings/content/notifications"),
        ("Clear Browsing Data", "trash.fill", Color(.sRGB, red: 0.90, green: 0.28, blue: 0.30), BrowsingDataClear.pageURL),
    ]

    private func dataRow(_ page: (title: String, symbol: String, color: Color, url: String), profileID: UUID?) -> some View {
        Button { actions.openProfilePage(page.url, profileID) } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol).font(.system(size: 12)).foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(page.color))
                Text(L10n.tr(page.title)).font(.system(size: 13))
                Spacer(minLength: 8)
                Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Color.settingsBlue)
            }
            .padding(.horizontal, SettingsMetrics.cardRowInset)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func downloadPicker(_ profileID: UUID?) -> some View {
        let location = store.settings.downloadLocation(profileID: profileID)
        let folder = DownloadDestinations.folder(profileID: profileID)
        let name = profileID == nil ? "Default" : (store.profile(profileID)?.name ?? "this Profile")
        let choice = Binding<DownloadChoice>(
            get: { location.askWhereToSave ? .ask : .folder },
            set: { picked in
                var l = store.settings.downloadLocation(profileID: profileID)
                switch picked {
                case .folder: l.askWhereToSave = false
                case .ask: l.askWhereToSave = true
                case .other:
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = folder
                    panel.prompt = L10n.tr("Select")
                    panel.message = L10n.tr("Choose where %@ saves downloaded files.", name)
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    l.folder = url.standardizedFileURL.path == DownloadDestinations.downloadsFolder.standardizedFileURL.path ? nil : url.path
                    l.askWhereToSave = false
                }
                store.settings.setDownloadLocation(l, profileID: profileID)
            })
        return Picker(L10n.tr("Download location"), selection: choice) {
            Label(FileManager.default.displayName(atPath: folder.path), systemImage: "folder").tag(DownloadChoice.folder)
            Text(L10n.tr("Other…")).tag(DownloadChoice.other)
            Divider()
            Text(L10n.tr("Ask Where to Save Each File")).tag(DownloadChoice.ask)
        }
        .labelsHidden()
        .fixedSize()
        .help(folder.path)
    }

    /// Arc's pop-up, "Default Document App": "——" (none), then its four apps.
    private func documentPicker(_ profileID: UUID?) -> some View {
        let app = Binding<NewDocumentApp?>(
            get: { store.settings.newDocumentApp(profileID: profileID) },
            set: { store.settings.setNewDocumentApp($0, profileID: profileID) })
        return Picker(L10n.tr("Default Document App"), selection: app) {
            Text("——").tag(NewDocumentApp?.none)
            ForEach(NewDocumentApp.allCases) { Text(L10n.tr($0.name)).tag(NewDocumentApp?.some($0)) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func languageRow(profileID: UUID?) -> some View {
        let summary = BrowserLanguages.summary(languages(profileID: profileID))
        let hasSpace = !store.spaces(usingProfile: profileID).isEmpty
        return SettingsCardRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("Website languages")).font(.system(size: 13))
                Text(summary.isEmpty ? L10n.tr("Chromium’s default languages") : summary)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .help(summary)
            }
        } trailing: {
            Button(L10n.tr("Change…")) { actions.openProfilePage(BrowserLanguages.settingsPage, profileID) }
                .disabled(!hasSpace)
                .help(hasSpace ? L10n.tr("Open Chromium’s language settings for this Profile.") : L10n.tr("Set this Profile on a Space first."))
        }
    }

    /// What Chromium holds for the profile now, else what its Preferences file saved (a profile no
    /// page has loaded in since launch).
    private func languages(profileID: UUID?) -> [String] {
        let path = store.profilePath(profile: profileID)
        if let json = CraCEFRuntime.preference(BrowserLanguages.pref, forProfile: path) {
            return BrowserLanguages.codes(json)
        }
        let folder = path.map { URL(fileURLWithPath: $0) } ?? AppPaths.chromiumCache.appendingPathComponent("Default")
        return (try? Data(contentsOf: folder.appendingPathComponent("Preferences")))
            .flatMap(BrowserLanguages.codes(preferencesFile:)) ?? []
    }

    private func rename(_ profile: BrowserProfile) {
        guard let window = AppDialog.parentWindow else { return }
        let dialog = AppDialog(title: L10n.tr("Rename your Profile"),
                               message: L10n.tr("This won’t affect the names of any of the Spaces associated with this Profile."),
                               actions: [DialogAction(L10n.tr("Save")), .cancel], input: profile.name, placeholder: L10n.tr("Profile name"), requiresInput: true,
                               icon: .none, width: 496, buttonSpacing: 30, buttonOutset: 0)
        dialog.present(over: window) { response in
            guard response == .alertFirstButtonReturn, let name = dialog.input else { return }
            store.renameProfile(profile.id, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func delete(_ profile: BrowserProfile) {
        guard let window = AppDialog.parentWindow else { return }
        let dialog = AppDialog(title: L10n.tr("Delete “%@”?", profile.name),
                               message: L10n.tr("Deleting this Profile will permanently remove any cookies, history, preferences, and logins that belong to it."),
                               actions: [DialogAction(L10n.tr("Delete Profile"), role: .destructive), .cancel])
        dialog.present(over: window) { response in
            if response == .alertFirstButtonReturn { store.deleteProfile(profile.id) }
        }
    }
}
