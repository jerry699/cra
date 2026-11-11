import AppKit

/// The tab list's context menus (the SwiftUI rows' .contextMenu, item for item).
@MainActor
enum SidebarMenus {
    private static func menu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        return m
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, enabled: Bool = true, on: Bool? = nil, _ run: @escaping () -> Void) -> NSMenuItem {
        MenuItems.add(menu, title, enabled: enabled, on: on, run)
    }

    /// A row for a KeyBindings command, with its shortcut (MenuItems.add(_:action:)).
    @discardableResult
    private static func add(_ menu: NSMenu, action id: String, _ title: String? = nil, enabled: Bool = true, on: Bool? = nil,
                            _ run: @escaping () -> Void) -> NSMenuItem {
        MenuItems.add(menu, action: id, title: title, enabled: enabled, on: on, run)
    }

    private static func note(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private static func submenu(_ menu: NSMenu, _ title: String, image: NSImage? = nil) -> NSMenu {
        let sub = Self.menu()
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let image {
            let icon = image.copy() as! NSImage
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        item.submenu = sub
        menu.addItem(item)
        return sub
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: Tab groups

    /// Arc's Tab Group Context Menu: one item, "Remove header" (the tabs stay, loose).
    static func tabGroup(_ id: UUID, list: SpaceListView) -> NSMenu {
        let menu = menu()
        add(menu, L10n.tr("Remove header")) { list.store.removeGroupHeader(id) }
        return menu
    }

    // MARK: Tabs

    static func tab(_ m: TabRowModel, list: SpaceListView) -> NSMenu {
        let store = list.store, ui = list.ui, actions = list.actions
        let id = m.id
        let menu = menu()
        let group = list.closeGroup(for: id)
        if group.count > 1 {
            folderItems(menu, ui.group(for: id, in: store), list: list)
            menu.addItem(.separator())
            add(menu, L10n.tr("Close %d Tabs", group.count)) { list.closeTabs(group) }
            add(menu, L10n.tr("Deselect All")) { ui.clearPicks() }
            return menu
        }
        guard let item = store.item(id), let tab = item.tab else { return menu }
        if m.pinned {
            add(menu, action: "pinTab", L10n.tr("Unpin Tab")) { store.unpinTab(id) }
        } else {
            add(menu, action: "pinTab", L10n.tr("Pin Tab")) { store.pinTab(id) }
        }
        if store.isFavorite(id) {
            add(menu, action: "favoriteTab", L10n.tr("Remove from Favorites")) { store.removeFromFavorites(id) }
        } else {
            add(menu, action: "favoriteTab", L10n.tr("Add to Favorites")) { store.addToFavorites(id) }
        }
        menu.addItem(.separator())
        // Arc's Today and pinned tab menus: Change Icon…, as Favorites have it.
        let favicons = list.favicons
        add(menu, L10n.tr("Change Icon…")) {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.prompt = L10n.tr("Use Icon")
            panel.message = L10n.tr("Choose an image for %@.", item.displayTitle)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard let key = favicons.importCustomIcon(from: url) else { NSSound.beep(); return }
            let old = store.item(id)?.tab?.customIconKey
            store.setCustomIcon(key, for: id)
            if let old { favicons.removeCustomIcon(old) }
        }
        if let key = tab.customIconKey {
            add(menu, L10n.tr("Use Site Icon")) {
                store.setCustomIcon(nil, for: id)
                favicons.removeCustomIcon(key)
            }
        }
        add(menu, action: "renameTab", L10n.tr("Rename…")) { ui.renamingID = id }
        if item.title != nil { add(menu, L10n.tr("Use Page Title")) { store.rename(id, to: nil) } }
        if m.pinned, tab.liveItemURL == nil { pinnedURLItems(menu, id, navigatedAway: m.navigatedAway, store: store, actions: actions) }
        // Arc: "Add Split View" on the open tab, "Open in Split View" on any other.
        if store.isSelected(id, window: ui.windowID) {
            add(menu, action: "addSplitView", L10n.tr("Add Split View")) { actions.performAction("addSplitView") }
        } else if store.selectedTabID(window: ui.windowID) != nil, store.spaceID(ofItem: id) == store.focusedSpaceID(window: ui.windowID) {
            add(menu, L10n.tr("Open in Split View")) { actions.performAction("openInSplit:\(id.uuidString)") }
        }
        add(menu, action: "duplicateTab", L10n.tr("Duplicate")) { _ = store.duplicateTab(id) }
        add(menu, action: "copyURL", L10n.tr("Copy Link")) { copy(CleanURL.withoutTrackers(tab.url)) }
        if let url = URL(string: CleanURL.withoutTrackers(tab.url)), url.scheme?.hasPrefix("http") == true {
            SharePicker.addMenu(to: menu, url: url)
        }
        add(menu, action: "muteTab", tab.muted ? L10n.tr("Unmute") : L10n.tr("Mute")) {
            store.setMuted(id, !tab.muted)
            actions.performAction("muteTab:\(id)")
        }
        if m.pinned, m.navigatedAway {
            menu.addItem(.separator())
            add(menu, action: "resetTab", L10n.tr("Back to Pinned Page")) { actions.resetPinnedTab(id) }
        }
        menu.addItem(.separator())
        let spaces = submenu(menu, L10n.tr("Move to Space"))
        for s in store.orderedSpaces {
            add(spaces, s.labeled, enabled: !store.isInSpace(id, s.id)) { store.moveTab(id, toSpace: s.id, window: ui.windowID) }
        }
        folderItems(menu, [id], list: list)
        menu.addItem(.separator())
        if m.pinned {
            if store.isSelected(id, window: ui.windowID) || ui.loadedTabIDs.contains(id) {
                add(menu, action: "closeTab", L10n.tr("Close and Keep Pinned")) { actions.closeTab(id) }
            }
            add(menu, L10n.tr("Archive Tab")) { store.archiveTab(id, reason: .manual) }
        } else {
            add(menu, action: "closeTab", L10n.tr("Archive")) { actions.closeTab(id) }
            // Arc's Today tab menu: Archive Tab, Archive Tabs Below.
            if let parent = item.parentID, let rows = store.item(parent)?.children, rows.last != id,
               store.spaceID(ofItem: id).flatMap(store.space)?.todayContainerID == parent {
                add(menu, L10n.tr("Archive Tabs Below")) { store.archiveTabsBelow(id) }
            }
        }
        return menu
    }

    /// The pinned URL's items on pinned tabs and favorites (#54), beside Rename… since they edit
    /// the same item. Arc puts them in an Edit Pinned Page submenu; Cra lists them flat, as
    /// Anoninz suggested on PR #55. Replace is greyed out while the tab is on its pinned page.
    static func pinnedURLItems(_ menu: NSMenu, _ id: UUID, navigatedAway: Bool, store: SidebarStore, actions: SidebarActions) {
        add(menu, L10n.tr("Edit Pinned URL…")) { actions.editPinnedURL(id) }
        add(menu, L10n.tr("Replace Pinned URL with Current"), enabled: navigatedAway) { store.setPinnedHomeToCurrent(id) }
    }

    /// Move to Folder / New Folder for this tab, or for every picked tab.
    private static func folderItems(_ menu: NSMenu, _ ids: [UUID], list: SpaceListView) {
        let store = list.store, ui = list.ui
        let folders = store.children(of: store.focusedSpace(window: ui.windowID).pinnedContainerID).filter { $0.isFolder && !$0.isLiveFolder }
        if !folders.isEmpty {
            let sub = submenu(menu, ids.count > 1 ? L10n.tr("Move %d Tabs to Folder", ids.count) : L10n.tr("Move to Folder"))
            for f in folders {
                add(sub, f.title ?? L10n.tr("Folder"), enabled: !ids.allSatisfy { store.item($0)?.parentID == f.id }) {
                    store.moveItems(ids, to: f.id, index: nil)
                }
            }
        }
        add(menu, ids.count > 1 ? L10n.tr("New Folder with %d Tabs", ids.count) : L10n.tr("New Folder with Tab")) {
            ui.renamingID = store.createFolder(with: ids).id
        }
    }

    // MARK: Folders

    private static func iconColor(_ menu: NSMenu, _ item: SidebarItem, list: SpaceListView) {
        let sub = submenu(menu, L10n.tr("Icon Color"))
        let id = item.id
        for (title, style) in [(L10n.tr("Auto"), FolderIconStyle?.none), (L10n.tr("White"), .white), (L10n.tr("Black"), .black)] {
            add(sub, title, on: item.folderIcon == style) { list.store.setFolderIcon(style, for: id) }
        }
    }

    static func folder(_ item: SidebarItem, list: SpaceListView) -> NSMenu {
        let store = list.store, ui = list.ui
        let id = item.id
        let menu = menu()
        add(menu, L10n.tr("Change Icon…")) { list.showFolderIconPicker(id) }
        add(menu, L10n.tr("Rename…")) { ui.renamingID = id }
        add(menu, L10n.tr("New Folder Inside")) {
            let f = store.createFolder(named: L10n.tr("New Folder"), in: id, index: 0)
            store.setExpanded(id, true)
            ui.renamingID = f.id
        }
        iconColor(menu, item, list: list)
        menu.addItem(.separator())
        add(menu, L10n.tr("Delete Folder (archives tabs)")) { store.deleteFolder(id) }
        return menu
    }

    /// The live folder's menu (Arc: SidebarMenu+ListContextMenu liveFolderContextMenu).
    static func liveFolder(_ item: SidebarItem, list: SpaceListView) -> NSMenu {
        let store = list.store, ui = list.ui, actions = list.actions
        let manager = LiveFolderManager.shared
        let id = item.id
        let live = item.liveFolder ?? LiveFolderData()
        let menu = menu()
        let requests = submenu(menu, live.source == .gitlab ? L10n.tr("Merge Requests") : L10n.tr("Pull Requests"),
                               image: live.source == .gitlab ? GitLabMark.image : GitHubMark.image)
        note(requests, manager.refreshing.contains(id) ? L10n.tr("Updating…") : LiveFolderText.lastUpdate(live))
        if live.source == .gitlab, let server = live.serverURL { note(requests, GitLabLiveClient.serverLabel(server)) }
        add(requests, L10n.tr("Refresh")) { manager.refresh(id) }
        requests.addItem(.separator())
        let filters: [(String, GitHubLiveFilter.Attributes)] = live.source == .gitlab
            ? GitLabLiveCategory.allCases.map { ($0.title, $0.attribute) }
            : [(L10n.tr("Created by Me"), .authored), (L10n.tr("Review Requests"), .reviewRequests), (L10n.tr("Team Review Requests"), .teamReviewRequests)]
        for (title, attribute) in filters {
            let on = live.filter.attributes.contains(attribute)
            add(requests, title, on: on) {
                store.updateLiveFolder(id) { l in
                    if on { l.filter.attributes.remove(attribute) } else { l.filter.attributes.insert(attribute) }
                }
                manager.refresh(id, force: true)
            }
        }
        let repos = store.liveRepositories(id, fetched: manager.repositories[id])
        if !repos.isEmpty {
            requests.addItem(.separator())
            let sub = submenu(requests, live.source == .gitlab ? L10n.tr("Projects") : L10n.tr("Repositories"))
            note(sub, live.source == .gitlab ? L10n.tr("Projects with active merge requests.") : L10n.tr("This list is generated based on your currently active pull requests."))
            sub.addItem(.separator())
            for repo in repos {
                let shown = !live.filter.isRepositoryHidden(repo)
                add(sub, repo, on: shown) {
                    store.updateLiveFolder(id) { l in
                        l.filter.setRepository(repo, hidden: shown)
                    }
                    manager.refresh(id, force: true)
                }
            }
        }
        if live.lastError == .notSignedIn {
            requests.addItem(.separator())
            add(requests, L10n.tr("Sign In to %@…", live.source.title)) { actions.openURL(live.signInURL) }
        } else if !live.ssoOrganizations.isEmpty {
            requests.addItem(.separator())
            note(requests, L10n.tr("SSO ensures all of your organizations’ PRs appear"))
            for org in live.ssoOrganizations {
                add(requests, L10n.tr("Sign In to %@ with SSO…", org)) { actions.openURL("https://github.com/orgs/\(org)/sso") }
            }
        }
        menu.addItem(.separator())
        let spaces = submenu(menu, L10n.tr("Move to"))
        for space in store.orderedSpaces {
            let current = store.isInSpace(id, space.id)
            add(spaces, space.labeled, on: current) {
                if !current { store.moveTab(id, toSpace: space.id, window: ui.windowID) }
            }
        }
        menu.addItem(.separator())
        iconColor(menu, item, list: list)
        add(menu, L10n.tr("Rename…")) { ui.renamingID = id }
        add(menu, L10n.tr("Copy All Links as Markdown"), enabled: !item.children.isEmpty) {
            let lines = store.tabs(under: id).compactMap { c in c.tab.map { "- [\(c.displayTitle)](\($0.liveItemURL ?? $0.url))" } }
            copy(lines.joined(separator: "\n"))
        }
        menu.addItem(.separator())
        let window = list.window
        add(menu, L10n.tr("Delete Live Folder")) { confirmDeleteLiveFolder(item, store: store, in: window) }
        return menu
    }

    /// Arc asks first ("Delete your %@ Live Folder?") and says how to get it back, in its own words.
    static func confirmDeleteLiveFolder(_ item: SidebarItem, store: SidebarStore, in window: NSWindow? = nil) {
        let alert = AppDialog(title: L10n.tr("Delete your %@ Live Folder?", item.title ?? L10n.tr("Pull Requests")),
                              message: L10n.tr("You can restore this folder at any time by right-clicking the sidebar."),
                              actions: [DialogAction(L10n.tr("Delete Folder"), role: .destructive), .cancel])
        let id = item.id
        if let window = window ?? AppDialog.parentWindow {
            alert.present(over: window) { if $0 == .alertFirstButtonReturn { store.deleteFolder(id) } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            store.deleteFolder(id)
        }
    }

    // MARK: Splits

    /// Live Folders ▸ in the sidebar's and the space header's menus, after GitHub: the GitLab folders like
    /// the GitHub one (✓ while there, a click asks to delete it; one per instance), then GitLab… to add one.
    static func addGitLabFolders(to menu: NSMenu, space: UUID, store: SidebarStore, window: NSWindow?) {
        let gitlabs = store.liveFolders.filter { $0.liveFolder?.source == .gitlab && store.isInSpace($0.id, space) }
            .sorted { ($0.liveFolder?.serverURL ?? "") < ($1.liveFolder?.serverURL ?? "") }
        for folder in gitlabs {
            let server = folder.liveFolder?.serverURL.map(GitLabLiveClient.serverLabel) ?? ""
            add(menu, L10n.tr("GitLab (%@)", server), on: true) { confirmDeleteLiveFolder(folder, store: store, in: window) }
        }
        add(menu, L10n.tr("GitLab…"), enabled: !store.isStandalone(space: space) && window != nil) {
            if let window { newGitLabFolder(space: space, store: store, window: window) }
        }
    }

    /// GitLab…: Arc has no GitLab folder, so this asks for the instance in Arc's text-input dialog (the
    /// Rename Profile sheet's shape) and adds a folder like its GitHub one. Empty means gitlab.com.
    private static func newGitLabFolder(space: UUID, store: SidebarStore, window: NSWindow) {
        let dialog = AppDialog(title: L10n.tr("Add a GitLab Live Folder"),
                               message: L10n.tr("Enter your GitLab’s address, or leave it empty for GitLab.com. The folder signs in with this Space’s Profile."),
                               actions: [DialogAction(L10n.tr("Add Folder")), .cancel], input: "", placeholder: "https://gitlab.com",
                               icon: .none, width: 496, buttonSpacing: 30, buttonOutset: 0)
        dialog.present(over: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let address = (dialog.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let server = GitLabLiveClient.serverURL(address.isEmpty ? "https://gitlab.com" : address) else {
                DispatchQueue.main.async {
                    AppDialog(title: L10n.tr("That isn’t a GitLab address"),
                              message: L10n.tr("Use the address you open GitLab at, like https://gitlab.example.com.")).runModal(over: window)
                }
                return
            }
            guard let folder = store.createLiveFolder(.gitlab, inSpace: space, serverURL: server) else { return }
            store.setExpanded(folder.id, true)
            LiveFolderManager.shared.refresh(folder.id, force: true)
        }
    }

    /// Arc 1.171's split menu, item for item where Cra has the feature (no Share or Change Icon).
    /// It is pinned by dragging it into Pinned or with Pin Tab (⌘D), not from here.
    static func split(_ m: SplitRowModel, list: SpaceListView) -> NSMenu {
        split(m.id, panes: m.cells.map { ($0.id, $0.title) }, open: m.selected, store: list.store, ui: list.ui, actions: list.actions)
    }

    /// A split's menu, from its sidebar row or its favorite tile.
    static func split(_ id: UUID, panes: [(id: UUID, title: String)], open: Bool, store: SidebarStore, ui: SidebarUIState,
                      actions: SidebarActions, leading: (NSMenu) -> Void = { _ in }) -> NSMenu {
        let menu = menu()
        leading(menu)
        let children = panes.map(\.id)
        add(menu, L10n.tr("Separate All Tabs")) { store.separateAll(id) }
        // Arc greys it out while the split is closed (no pane to add next to).
        add(menu, action: "addSplitView", L10n.tr("Add Tab…"), enabled: open && children.count < 4) {
            if let first = children.first {
                actions.focusPane(first)
                actions.performAction("addSplitView")
            }
        }
        add(menu, action: "flipSplitOrientation",
            store.item(id)?.split?.orientation == .vertical ? L10n.tr("Convert to Horizontal Split View") : L10n.tr("Convert to Vertical Split View")) {
            store.flipSplitOrientation(id)
        }
        menu.addItem(.separator())
        note(menu, L10n.tr("Tab Options"))
        for c in panes {
            paneItems(submenu(menu, c.title), c.id, store: store, actions: actions)
        }
        menu.addItem(.separator())
        // Arc's way back to the panes from a renamed split.
        if store.item(id)?.title != nil { add(menu, L10n.tr("Reset Name and Icon")) { store.rename(id, to: nil) } }
        add(menu, L10n.tr("Rename…")) { ui.renamingID = id }
        menu.addItem(.separator())
        let spaces = submenu(menu, L10n.tr("Move to"))
        for s in store.orderedSpaces {
            let current = store.isInSpace(id, s.id)
            add(spaces, s.labeled, on: current) { if !current { store.moveTab(id, toSpace: s.id, window: ui.windowID) } }
        }
        menu.addItem(.separator())
        add(menu, L10n.tr("Archive Item")) { for c in children { store.archiveTab(c, reason: .manual) } }
        return menu
    }

    /// One pane's submenu under "Tab Options" (Arc: childItem(id, …)).
    private static func paneItems(_ menu: NSMenu, _ id: UUID, store: SidebarStore, actions: SidebarActions) {
        guard let tab = store.item(id)?.tab else { return }
        // No shortcut glyphs: every pane has this submenu, and the keys act on the focused one.
        add(menu, L10n.tr("Separate from Split View")) { store.separateFromSplit(id) }
        menu.addItem(.separator())
        add(menu, tab.muted ? L10n.tr("Unmute") : L10n.tr("Mute")) {
            store.setMuted(id, !tab.muted)
            actions.performAction("muteTab:\(id)")
        }
        add(menu, L10n.tr("Copy Link")) { copy(tab.url) }
        add(menu, L10n.tr("Copy Link as Markdown")) { copy("[\(store.item(id)?.displayTitle ?? tab.savedTitle)](\(tab.url))") }
        menu.addItem(.separator())
        add(menu, L10n.tr("Archive Item")) { store.archiveTab(id, reason: .manual) }
    }

    // MARK: The list

    static func spaceList(_ list: SpaceListView) -> NSMenu {
        let store = list.store, actions = list.actions
        let space = list.spaceID
        let menu = menu()
        // Arc's sidebar menu starts with the space's look, as the header's does (#170).
        if let s = store.space(space) {
            if let header = list.header, !store.hidesSpaceHeader(space) {
                add(menu, L10n.tr("Change Space Icon…")) { [weak header] in if let header { actions.changeSpaceIcon(s, header) } }
                add(menu, L10n.tr("Rename Space…")) { [weak header] in header?.beginRename() }
            }
            add(menu, L10n.tr("Edit Theme Color…")) { actions.editSpaceTheme(s) }
            menu.addItem(.separator())
        }
        add(menu, action: "newTab", L10n.tr("New Tab")) { actions.openCommandBar(.newTab) }
        add(menu, action: "newFolder") { actions.performAction("newFolder") }
        let liveFolders = submenu(menu, L10n.tr("Live Folders"))
        let github = store.liveFolder(.github, inSpace: space)
        add(liveFolders, action: "newGitHubLiveFolder", L10n.tr("GitHub"),
            enabled: !store.isStandalone(space: space), on: github != nil) {
            if let github { confirmDeleteLiveFolder(github, store: store, in: list.window) }
            else { actions.performAction("newGitHubLiveFolder") }
        }
        addGitLabFolders(to: liveFolders, space: space, store: store, window: list.window)
        menu.addItem(.separator())
        if let s = store.space(space), !store.children(of: s.todayContainerID).isEmpty {
            add(menu, action: "clearToday") { store.clearToday(space) }
        }
        if let s = store.space(space) {
            add(menu, action: "editSpace") { actions.editSpace(s) }
        }
        // With the header hidden (one space), its menu items live here.
        if store.hidesSpaceHeader(space) {
            add(menu, L10n.tr("Show Space Header")) { store.settings.showSpaceHeaderOnSingleSpace = true }
        }
        return menu
    }
}
