import AppKit
import SwiftUI

/// Settings ▸ General ▸ Sync: iCloud keeps the sidebar, the settings and the shortcuts the
/// same on the user's Macs (SettingsSyncService); a folder a provider syncs is the other way.
/// Off, the card is one switch and "Use a folder instead…"; on, the state and Stop Syncing.
/// The same bundle backs Export… and Import… for people with one Mac.
struct SyncSection: View {
    @Environment(SettingsSyncService.self) private var sync
    @State private var importing: (URL, SyncBundleSummary)?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .alert(L10n.tr("Use the sidebar from your other Mac?"), isPresented: Binding(get: { sync.pendingChoice != nil }, set: { _ in })) {
                Button(L10n.tr("Use That Sidebar")) { sync.useRemote() }
                Button(L10n.tr("Replace It with This Mac’s")) { sync.useLocal() }
                Button(L10n.tr("Cancel"), role: .cancel) { sync.disable() }
            } message: {
                if let found = sync.pendingChoice { Text(L10n.tr("%@ Using it replaces this Mac’s sidebar, settings and shortcuts.", Self.describe(found))) }
            }
            .alert(L10n.tr("Import these settings?"), isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } })) {
                Button(L10n.tr("Import")) {
                    if let (url, _) = importing { notice = sync.importBundle(from: url) ? L10n.tr("Settings imported.") : L10n.tr("The folder holds no Cra settings.") }
                }
                Button(L10n.tr("Cancel"), role: .cancel) {}
            } message: {
                if let (_, s) = importing { Text(L10n.tr("%@ Importing replaces this Mac’s sidebar, settings and shortcuts.", Self.describe(s))) }
            }
    }

    @ViewBuilder private var content: some View {
        SettingsHeader(L10n.tr("Sync"))
        SettingsFeatureCard {
            SettingsPlainRow(L10n.tr("Sync with iCloud"),
                               detail: sync.iCloudAvailable
                                   ? L10n.tr("Your spaces, pinned tabs, favorites, settings and shortcuts stay the same on every Mac signed in to this iCloud account.")
                                   : iCloudUnavailableReason,
                               trailing: {
                Toggle(L10n.tr("Sync with iCloud"), isOn: Binding(get: { sync.location == .iCloud }, set: { on in on ? enableICloud() : sync.disable() }))
                    .toggleStyle(.arcSwitch).labelsHidden()
                    .disabled(!sync.iCloudAvailable)
            }) {
                // macOS doesn't tell apps which Apple Account is signed in; System Settings shows it.
                Button(L10n.tr("iCloud Settings…")) { NSWorkspace.shared.open(Self.appleAccountSettings) }
            }
            if case .folder(let path)? = sync.location {
                SettingsCardDivider()
                SettingsCardRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("Sync folder")).font(.system(size: 13))
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                } trailing: {
                    Button(L10n.tr("Stop Syncing")) { sync.disable() }
                }
            } else if sync.location == nil {
                SettingsCardDivider()
                SettingsCardRow {
                    Text(L10n.tr("Or sync through a folder in Dropbox, OneDrive or a similar service")).font(.system(size: 13))
                } trailing: {
                    Button(L10n.tr("Use a Folder…")) { chooseFolder() }
                }
            }
            if sync.location != nil {
                SettingsCardDivider()
                SettingsCardRow {
                    Text(status).font(.system(size: 13)).foregroundStyle(sync.error == nil ? .secondary : Color.red)
                } trailing: {
                    if !sync.otherDevices.isEmpty {
                        Text(L10n.tr("Also on %@", sync.otherDevices.joined(separator: ", "))).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
            SettingsCardDivider()
            SettingsCardRow {
                Text(L10n.tr("Settings file")).font(.system(size: 13))
            } trailing: {
                Button(L10n.tr("Export…")) { exportBundle() }
                Button(L10n.tr("Import…")) { importBundle() }
            }
        }
        SettingsFootnote(notice ?? L10n.tr("Spaces, pinned tabs, favorites, folders, settings and shortcuts sync. Logins, cookies, history and extensions stay on each Mac."))
    }

    static let appleAccountSettings = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!

    private var iCloudUnavailableReason: String {
        FileManager.default.ubiquityIdentityToken == nil
            ? L10n.tr("Sign in to iCloud in System Settings to sync this way.")
            : L10n.tr("This build of Cra cannot use iCloud. The signed release can.")
    }

    private var status: String {
        if let error = sync.error { return error }
        if sync.awaitingDownload { return L10n.tr("Waiting for iCloud to download your other Mac’s sidebar…") }
        if sync.pendingChoice != nil { return L10n.tr("Waiting for your choice") }
        guard let date = sync.lastSync else { return L10n.tr("Not synced yet") }
        return L10n.tr("Synced %@", Self.relative.localizedString(for: date, relativeTo: Date()))
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static func describe(_ s: SyncBundleSummary) -> String {
        let when = s.writtenAt.formatted(date: .abbreviated, time: .shortened)
        return L10n.tr("%@ saved %d %@ and %d %@ on %@.", s.device, s.spaces, s.spaces == 1 ? L10n.tr("space") : L10n.tr("spaces"), s.tabs, s.tabs == 1 ? L10n.tr("tab") : L10n.tr("tabs"), when)
    }

    private func enableICloud() {
        notice = nil
        if case .failed(let reason) = sync.enableICloud() { notice = reason }
    }

    private func folderPanel(prompt: String, message: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        return panel
    }

    private func chooseFolder() {
        let panel = folderPanel(prompt: L10n.tr("Sync Here"), message: L10n.tr("Choose a folder your Macs share, in Dropbox, OneDrive or a similar service. Cra keeps its files in a “Cra” folder inside it."))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        notice = nil
        if case .failed(let reason) = sync.enable(folder: url) { notice = reason }
    }

    private func exportBundle() {
        let panel = folderPanel(prompt: L10n.tr("Export"), message: L10n.tr("Choose where to save a “Cra” folder with your sidebar, settings and shortcuts."))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        notice = sync.export(to: url).map { L10n.tr("Not exported: %@", $0) } ?? L10n.tr("Exported to %@/Cra.", (url.path as NSString).abbreviatingWithTildeInPath)
    }

    private func importBundle() {
        let panel = folderPanel(prompt: L10n.tr("Import"), message: L10n.tr("Choose the folder that holds the exported “Cra” folder, or that folder itself."))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let summary = sync.summary(ofBundleIn: url) { importing = (url, summary) } else { notice = L10n.tr("The folder holds no Cra settings.") }
    }
}
