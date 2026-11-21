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

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: SpaceMenuTitle.Value, enabled: Bool = true, on: Bool? = nil,
                            _ run: @escaping () -> Void) -> NSMenuItem {
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

    /// UserDefaults key: "Never show me this again." was ticked on the share warning.
    static let skipsShareWarningKey = "skipsShareLinkWarning"

    /// Arc asks before it makes a share link (AppDialog.shareLink): Copy Link to Folder goes on,
    /// Cancel or Escape stops; ticking "Never show me this again." and going on skips it from then on.
    private static func confirmShare(over window: NSWindow?, kind: String = "Folder", _ share: @escaping () -> Void) {
        guard !UserDefaults.standard.bool(forKey: skipsShareWarningKey), let window = window ?? AppDialog.parentWindow else { share(); return }
        let dialog = AppDialog.shareLink(kind: kind)
        dialog.present(over: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if dialog.isSuppressed { UserDefaults.standard.set(true, forKey: skipsShareWarningKey) }
            share()
        }
    }

    // MARK: Tab groups

    /// Arc's Tab Group Context Menu: "Remove header" (the tabs stay, loose) — plus the
    /// fork's "Rename…": the model misnames groups sometimes, and converting to a folder
    /// just to rename was the only way (the user's report).
    static func tabGroup(_ id: UUID, list: SpaceListView) -> NSMenu {
        let store = list.store, ui = list.ui
        let menu = menu()
        add(menu, action: "renameTab", L10n.tr("Rename…")) { ui.renamingID = id }
        add(menu, L10n.tr("Remove header")) { store.removeGroupHeader(id) }
        return menu
    }

    // MARK: Tabs

    /// Arc 1.173.1's tab menu, read live 19 Nov 2026 (#600), on Today, pinned and folder rows:
    /// Copy Link, Share ▸ | Change Icon…, Rename…, Mute, Customize Page… (the open tab), Edit Pinned
    /// Page ▸ (pinned) | Add/Open in Split View, Duplicate, Move to ▸ | Archive Tab (⌥ Archive Other
    /// Tabs), Archive Tabs Below (⌥ Archive Tabs Above) on Today, Remove Pin on a pinned tab.
    /// Cra keeps Use Site Icon and Use Page Title, which have no other way in, beside their rows.
    static func tab(_ m: TabRowModel, list: SpaceListView) -> NSMenu {
        let store = list.store, ui = list.ui, actions = list.actions
        let id = m.id
        let menu = menu()
        if list.closeGroup(for: id).count > 1 { return picked(ui.group(for: id, in: store), clicked: id, list: list) }
        guard let item = store.item(id), let tab = item.tab else { return menu }
<<<<<<< HEAD
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
        // P5: no matching group exists? The user creates their own — the move teaches it.
        add(menu, L10n.tr("New Group with This Tab")) {
            if let sid = store.spaceID(ofItem: id),
               let gid = store.createTabGroup(with: [id], in: sid) {
                ui.renamingID = gid
            }
        }
        if item.title != nil { add(menu, L10n.tr("Use Page Title")) { store.rename(id, to: nil) } }
=======
        let open = store.isSelected(id, window: ui.windowID)
        add(menu, action: "copyURL", "Copy Link") { copy(CleanURL.withoutTrackers(tab.url)) }
        let web = URL(string: CleanURL.withoutTrackers(tab.url)).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        if let web { SharePicker.addMenu(to: menu, url: web) }
        menu.addItem(.separator())
        changeIconItems(menu, id, custom: tab.customIconKey, list: list)
        add(menu, action: "renameTab", "Rename…") { ui.renamingID = id }
        if item.title != nil { add(menu, "Use Page Title") { store.rename(id, to: nil) } }
        muteItem(menu, id, tab, ui: ui, store: store, actions: actions)
        if open, web?.host != nil { add(menu, "Customize Page…") { actions.performAction("newBoost") } }
>>>>>>> origin/main
        if m.pinned, tab.liveItemURL == nil { pinnedURLItems(menu, id, navigatedAway: m.navigatedAway, store: store, actions: actions) }
        menu.addItem(.separator())
        // Arc: "Add Split View" on the open tab, "Open in Split View" on any other.
<<<<<<< HEAD
        if store.isSelected(id, window: ui.windowID) {
            add(menu, action: "addSplitView", L10n.tr("Add Split View")) { actions.performAction("addSplitView") }
=======
        if open {
            add(menu, action: "addSplitView", "Add Split View") { actions.performAction("addSplitView") }
>>>>>>> origin/main
        } else if store.selectedTabID(window: ui.windowID) != nil, store.spaceID(ofItem: id) == store.focusedSpaceID(window: ui.windowID) {
            add(menu, L10n.tr("Open in Split View")) { actions.performAction("openInSplit:\(id.uuidString)") }
        }
<<<<<<< HEAD
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
=======
        add(menu, action: "duplicateTab", "Duplicate") { store.duplicateTab(id, window: ui.windowID) }
        moveToItems(menu, [id], list: list)
        menu.addItem(.separator())
        if m.pinned {
            // Arc's Remove Pin archives the tab (StorableArchiveItems, reason manual).
            add(menu, "Remove Pin") { store.archiveTab(id, reason: .manual) }
        } else {
            let archive = add(menu, action: "closeTab", "Archive Tab") { actions.closeTab(id) }
            alternate(add(menu, "Archive Other Tabs", enabled: store.hasTodayTabs(above: id) || store.hasTodayTabs(below: id)) {
                store.archiveOtherTabs(id)
            }, of: archive)
            let below = add(menu, "Archive Tabs Below", enabled: store.hasTodayTabs(below: id)) { store.archiveTabsBelow(id) }
            alternate(add(menu, "Archive Tabs Above", enabled: store.hasTodayTabs(above: id)) { store.archiveTabsAbove(id) }, of: below)
        }
        return menu
    }

    /// Change Icon… (Arc's Emoji | Icon picker, with a picture too; #640), and Use Site Icon while it has
    /// one: Cra's way back from it beside the picker's Remove.
    static func changeIconItems(_ menu: NSMenu, _ id: UUID, custom: String?, list: SpaceListView) {
        add(menu, "Change Icon…") { [weak list] in list?.showTabIconPicker(id) }
        if let custom {
            let store = list.store, favicons = list.favicons
            add(menu, "Use Site Icon") {
                store.setCustomIcon(nil, for: id)
                favicons.removeCustomIcon(custom)
            }
        }
    }

    /// Mute / Unmute. Arc dims Mute while the tab makes no sound (#600): it is on while the page
    /// plays, and Unmute while the tab is muted.
    static func muteItem(_ menu: NSMenu, _ id: UUID, _ tab: TabData, ui: SidebarUIState, store: SidebarStore, actions: SidebarActions) {
        add(menu, action: "muteTab", tab.muted ? "Unmute" : "Mute", enabled: tab.muted || ui.audibleTabIDs.contains(id)) {
            store.setMuted(id, !tab.muted)
            actions.performAction("muteTab:\(id)")
        }
    }

    /// Arc's ⌥ row: shown in place of `primary` while ⌥ is held.
    private static func alternate(_ item: NSMenuItem, of primary: NSMenuItem) {
        item.keyEquivalent = primary.keyEquivalent
        item.keyEquivalentModifierMask = primary.keyEquivalentModifierMask.union(.option)
        item.isAlternate = true
    }

    /// Arc's Move to ▸: every space, ✓ on the tab's own, ──, New Space… (which takes the tabs along).
    private static func moveToItems(_ menu: NSMenu, _ ids: [UUID], list: SpaceListView) {
        let store = list.store, ui = list.ui, actions = list.actions
        let sub = submenu(menu, "Move to")
        let own = ids.first.flatMap { store.spaceID(ofItem: $0) }
        for s in store.orderedSpaces {
            add(sub, SpaceMenuTitle.plain(s.labeled), on: s.id == own) {
                guard s.id != own else { return }
                for id in ids { store.moveTab(id, toSpace: s.id, window: ui.windowID) }
>>>>>>> origin/main
            }
        }
        sub.addItem(.separator())
        add(sub, "New Space…") { actions.newSpaceWith(ids) }
    }

    /// The menu on a tab that is one of several picked with ⌘/⇧-click (#356): Arc's rows for every
    /// pick at once, from PickedTabsMenu. `ids` are the picks in sidebar order, `clicked` the row.
    static func picked(_ ids: [UUID], clicked: UUID, list: SpaceListView) -> NSMenu {
        let store = list.store, ui = list.ui, actions = list.actions
        let menu = menu()
        let tabs = ids.compactMap { id in store.item(id)?.tab.map { (id, $0) } }
        let picks = PickedTabsMenu.Picks(count: ids.count, anyEasel: tabs.contains { Easel.id(fromURL: $0.1.url) != nil },
                                         clickedInToday: !store.isPinned(clicked),
                                         allMuted: !tabs.isEmpty && tabs.allSatisfy { $0.1.muted },
                                         anySound: tabs.contains { $0.1.muted || ui.audibleTabIDs.contains($0.0) },
                                         anyInSplit: ids.contains { store.splitContaining($0) != nil },
                                         paneLimit: store.splitPaneLimit)
        for (i, section) in PickedTabsMenu.shown(for: picks).enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for row in section {
                let title = PickedTabsMenu.title(row, for: picks), enabled = PickedTabsMenu.isEnabled(row, for: picks)
                switch row {
                case "copyLinks":
                    // What ⇧⌘C copies with tabs picked (#322): each link without trackers, one per line.
                    add(menu, title) {
                        copy(CleanURL.links(tabs.map { $0.1.url }))
                        actions.showToast(L10n.tr("Copied item links"))
                    }
                case "share":
                    // Arc's Share N Items… copied an arc.net folder link ("Copied Folder URL"); Cra's link
                    // carries the picks after its #, as Share Folder… does (FolderShareLink, #357).
                    let link = FolderShareLink.url(for: FolderShareLink.picked(ids.compactMap(store.item)))
                    add(menu, title, enabled: link != nil) {
                        guard let link else { return }
                        confirmShare(over: list.window) {
                            copy(link)
                            actions.showToast(L10n.tr("Copied Folder URL"))
                        }
                    }
                case "mute":
                    add(menu, title, enabled: enabled) {
                        for (id, _) in tabs {
                            store.setMuted(id, !picks.allMuted)
                            actions.performAction("muteTab:\(id)")
                        }
                    }
                case "openInSplitView":
                    add(menu, title, enabled: enabled) {
                        guard let split = store.createSplit(with: ids) else { return }
                        ui.clearPicks()
                        store.selectTab(store.paneID(for: ids[0], in: split) ?? ids[0], window: ui.windowID)
                    }
                case "duplicate":
                    add(menu, title) { for id in ids { store.duplicateTab(id, window: ui.windowID) } }
                case "moveTo":
                    // Arc: the spaces, the picks' own checked, then New Space… (which takes them along).
                    let sub = submenu(menu, title)
                    let own = store.spaceID(ofItem: ids[0])
                    for s in store.orderedSpaces {
                        add(sub, SpaceMenuTitle.plain(s.labeled), on: s.id == own) {
                            guard s.id != own else { return }
                            for id in ids { store.moveTab(id, toSpace: s.id, window: ui.windowID) }
                            ui.clearPicks()
                        }
                    }
                    sub.addItem(.separator())
                    add(sub, L10n.tr("New Space…")) { actions.newSpaceWith(ids) }
                case "newFolder":
                    add(menu, title) {
                        store.withPinningWindow(ui.windowID) {
                            ui.renamingID = store.createFolder(with: ids).id
                        }
                    }
                case "archive":
                    // Arc archives every pick, pinned ones too, without asking; a Today tab goes as ⌘W does.
                    add(menu, title) {
                        let open = store.selectedTabID(window: ui.windowID)
                        for id in ids.filter({ $0 != open }) + ids.filter({ $0 == open }) {
                            if store.isPinned(id) { store.archiveTab(id, reason: .manual) } else { actions.closeTab(id) }
                        }
                        ui.clearPicks()
                    }
                default:
                    // Change Icon… and Archive Tabs Below: dimmed, as Arc draws them for several tabs.
                    add(menu, title, enabled: enabled) {}
                }
            }
        }
        return menu
    }

    /// Arc's Edit Pinned Page ▸ on pinned tabs and favorites: Replace Pinned URL with Current (dim
    /// while the tab is on its pinned page) and Edit… (#54; flat rows from PR #55 until #600).
    static func pinnedURLItems(_ menu: NSMenu, _ id: UUID, navigatedAway: Bool, store: SidebarStore, actions: SidebarActions) {
<<<<<<< HEAD
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
=======
        let sub = submenu(menu, "Edit Pinned Page")
        add(sub, "Replace Pinned URL with Current", enabled: navigatedAway) { store.setPinnedHomeToCurrent(id) }
        add(sub, "Edit…") { actions.editPinnedURL(id) }
>>>>>>> origin/main
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
        // Arc's Share Folder… copied an arc.net link ("Copied Folder URL"); Cra's link carries the
        // folder after its #, so nothing is stored anywhere (FolderShareLink, #357).
        let link = FolderShareLink.url(for: FolderShareLink.folder(item) { store.children(of: $0) })
        let toast = list.actions.showToast
        add(menu, L10n.tr("Share Folder…"), enabled: link != nil) {
            guard let link else { return }
            confirmShare(over: list.window) {
                copy(link)
                toast(L10n.tr("Copied Folder URL"))
            }
        }
        moveToItems(menu, [id], list: list)
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
        let entry = LiveFolderPluginStore.shared.entry(for: live)
        let requests = submenu(menu, entry?.presentation.menuTitle ?? item.title ?? L10n.tr("Live Folder"), image: entry?.icon)
        note(requests, manager.refreshing.contains(id) ? L10n.tr("Updating…") : LiveFolderText.lastUpdate(live))
        if let detail = live.plugin?.detailLabel { note(requests, detail) }
        add(requests, L10n.tr("Refresh")) { manager.refresh(id) }
        requests.addItem(.separator())
        for filter in entry?.presentation.filters ?? [] {
            let on = live.plugin?.filters.contains(filter.id) == true
            add(requests, filter.title, on: on) {
                store.updateLiveFolder(id) { live in
                    if on { live.plugin?.filters.removeAll { $0 == filter.id } }
                    else { live.plugin?.filters.append(filter.id) }
                }
                manager.refresh(id, force: true)
            }
        }
        let repos = store.liveRepositories(id, fetched: manager.repositories[id])
        if !repos.isEmpty, let groups = entry?.presentation.groups {
            requests.addItem(.separator())
            let sub = submenu(requests, groups.title)
            note(sub, groups.description)
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
        if live.lastError == .notSignedIn, let signIn = live.plugin?.signIn {
            requests.addItem(.separator())
            add(requests, signIn.title) { actions.openURL(signIn.url) }
        } else if let snapshot = live.plugin?.snapshot, !snapshot.actions.isEmpty {
            requests.addItem(.separator())
            if let message = snapshot.actionMessage { note(requests, message) }
            for action in snapshot.actions { add(requests, action.title) { actions.openURL(action.url) } }
        }
        menu.addItem(.separator())
        let spaces = submenu(menu, L10n.tr("Move to"))
        for space in store.orderedSpaces {
            let current = store.isInSpace(id, space.id)
            add(spaces, SpaceMenuTitle.plain(space.labeled), on: current) {
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

    static func addLiveFolderPlugins(to menu: NSMenu, space: UUID, store: SidebarStore, window: NSWindow?) {
        let registry = LiveFolderPluginStore.shared
        for entry in registry.entries.values.sorted(by: { $0.package.manifest.name < $1.package.manifest.name }) {
            let existing = store.liveFolders.filter { store.isInSpace($0.id, space) && $0.liveFolder?.plugin?.id == entry.package.manifest.id }
                .sorted { ($0.liveFolder?.plugin?.instanceLabel ?? "") < ($1.liveFolder?.plugin?.instanceLabel ?? "") }
            if entry.presentation.setup == nil {
                add(menu, entry.package.manifest.name, enabled: !store.isStandalone(space: space), on: !existing.isEmpty) {
                    if let folder = existing.first { confirmDeleteLiveFolder(folder, store: store, in: window) }
                    else { addPluginFolder(entry, space: space, store: store, window: window) }
                }
            } else {
                for folder in existing {
                    add(menu, folder.liveFolder?.plugin?.instanceLabel ?? entry.package.manifest.name, on: true) {
                        confirmDeleteLiveFolder(folder, store: store, in: window)
                    }
                }
                add(menu, entry.package.manifest.name + "…", enabled: !store.isStandalone(space: space) && window != nil) {
                    addPluginFolder(entry, space: space, store: store, window: window)
                }
            }
        }

    }

    static func addPluginFolder(_ entry: LiveFolderPluginStore.Entry, space: UUID, store: SidebarStore, window: NSWindow?) {
        func create(_ settings: [String: String]) {
            Task {
                do {
                    var configuration = try LiveFolderManager.configuration(entry: entry, settings: settings,
                        filters: entry.presentation.filters.filter(\.enabledByDefault).map(\.id))
                    try await LiveFolderManager.shared.updateSignIn(&configuration, entry: entry)
                    guard let folder = store.createPluginFolder(configuration, title: entry.presentation.folderTitle, inSpace: space,
                        legacySource: entry.package.manifest.legacySource) else { return }
                    store.setExpanded(folder.id, true)
                    LiveFolderManager.shared.refresh(folder.id, force: true)
                } catch { AppDialog(title: L10n.tr("Could not add live folder"), message: error.localizedDescription).runModal(over: window) }
            }
        }
        guard let setup = entry.presentation.setup else { create([:]); return }
        guard let window else { return }
        let dialog = AppDialog(title: setup.title, message: setup.message,
            actions: [DialogAction(L10n.tr("Add Folder")), .cancel], input: "", placeholder: setup.placeholder,
            icon: .none, width: 496, buttonSpacing: 30, buttonOutset: 0)
        dialog.present(over: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let input = (dialog.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let address = LiveFolderPluginConfiguration.normalizedAddress(input.isEmpty ? setup.defaultValue : input) else {
                DispatchQueue.main.async { AppDialog(title: setup.invalidTitle, message: setup.invalidMessage).runModal(over: window) }
                return
            }
            create([setup.key: address])
        }
    }

    /// Arc 1.173.1's split menu, read live 19 Nov 2026 (#600): Share Split View… | Separate All Tabs,
    /// Add Tab…, Convert to Vertical/Horizontal Split View | Tab Options, a submenu per pane | Reset
    /// Name and Icon (named or with an icon), Change Icon…, Rename… | Duplicate, Move to ▸ | in Today
    /// Archive Item (⌥ Archive Other Tabs) and Archive Tabs Below (⌥ Archive Tabs Above), pinned
    /// Archive Item and Close while it's open. It is pinned with Pin Tab (⌘D) or by dragging.
    static func split(_ m: SplitRowModel, list: SpaceListView) -> NSMenu {
        split(m.id, panes: m.cells.map { ($0.id, $0.title) }, open: m.selected, store: list.store, ui: list.ui, actions: list.actions,
              window: list.window, changeIcon: { [weak list] in list?.showSplitIconPicker(m.id) })
    }

    /// A split's menu, from its sidebar row or its favorite tile. `changeIcon` shows the icon picker
    /// where the split is drawn; a favorite tile has no such row.
    static func split(_ id: UUID, panes: [(id: UUID, title: String)], open: Bool, store: SidebarStore, ui: SidebarUIState,
                      actions: SidebarActions, window: NSWindow? = nil, changeIcon: (() -> Void)? = nil,
                      leading: (NSMenu) -> Void = { _ in }) -> NSMenu {
        let menu = menu()
        leading(menu)
        let children = panes.map(\.id)
<<<<<<< HEAD
        add(menu, L10n.tr("Separate All Tabs")) { store.separateAll(id) }
        // Arc greys it out while the split is closed (no pane to add next to).
        add(menu, action: "addSplitView", L10n.tr("Add Tab…"), enabled: open && children.count < 4) {
=======
        // Arc stores the split on arc.net; Cra's link carries the panes after its #, as Share Folder… does.
        let link = FolderShareLink.url(for: FolderShareLink.picked(children.compactMap(store.item)))
        add(menu, "Share Split View…", enabled: link != nil) {
            guard let link else { return }
            confirmShare(over: window, kind: "Split View") {
                copy(link)
                actions.showToast("Copied Folder URL")
            }
        }
        menu.addItem(.separator())
        add(menu, "Separate All Tabs") { store.separateAll(id) }
        // Arc greys it out while the split is closed (no pane to add next to).
        add(menu, action: "addSplitView", "Add Tab…", enabled: open && children.count < store.splitPaneLimit) {
>>>>>>> origin/main
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
            paneItems(submenu(menu, c.title), c.id, store: store, ui: ui, actions: actions)
        }
        menu.addItem(.separator())
<<<<<<< HEAD
        // Arc's way back to the panes from a renamed split.
        if store.item(id)?.title != nil { add(menu, L10n.tr("Reset Name and Icon")) { store.rename(id, to: nil) } }
        add(menu, L10n.tr("Rename…")) { ui.renamingID = id }
        menu.addItem(.separator())
        let spaces = submenu(menu, L10n.tr("Move to"))
=======
        // Arc's way back to the panes from a renamed split or one with an icon.
        if store.item(id)?.title != nil || store.item(id)?.split?.icon != SpaceIcon.none {
            add(menu, "Reset Name and Icon") { store.resetSplitNameAndIcon(id) }
        }
        if let changeIcon { add(menu, "Change Icon…") { changeIcon() } }
        add(menu, "Rename…") { ui.renamingID = id }
        menu.addItem(.separator())
        add(menu, "Duplicate") { store.duplicateSplit(id, window: ui.windowID) }
        let spaces = submenu(menu, "Move to")
>>>>>>> origin/main
        for s in store.orderedSpaces {
            let current = store.isInSpace(id, s.id)
            add(spaces, SpaceMenuTitle.plain(s.labeled), on: current) {
                if !current { store.moveTab(id, toSpace: s.id, window: ui.windowID) }
            }
        }
        spaces.addItem(.separator())
        add(spaces, "New Space…") { actions.newSpaceWith([id]) }
        menu.addItem(.separator())
<<<<<<< HEAD
        add(menu, L10n.tr("Archive Item")) { for c in children { store.archiveTab(c, reason: .manual) } }
=======
        let archive = add(menu, "Archive Item") { for c in children { store.archiveTab(c, reason: .manual) } }
        if store.isPinned(id) {
            if open, let pane = children.first { add(menu, "Close") { actions.closeTab(pane) } }
        } else if let pane = children.first {
            alternate(add(menu, "Archive Other Tabs", enabled: store.hasTodayTabs(above: pane) || store.hasTodayTabs(below: pane)) {
                store.archiveOtherTabs(pane)
            }, of: archive)
            let below = add(menu, "Archive Tabs Below", enabled: store.hasTodayTabs(below: pane)) { store.archiveTabsBelow(pane) }
            alternate(add(menu, "Archive Tabs Above", enabled: store.hasTodayTabs(above: pane)) { store.archiveTabsAbove(pane) }, of: below)
        }
>>>>>>> origin/main
        return menu
    }

    /// One pane's submenu under "Tab Options" (Arc: childItem(id, …)): Separate from Split View |
    /// Share ▸, Mute (dimmed while silent), Copy Link, Copy link as Markdown | Archive Item.
    private static func paneItems(_ menu: NSMenu, _ id: UUID, store: SidebarStore, ui: SidebarUIState, actions: SidebarActions) {
        guard let tab = store.item(id)?.tab else { return }
        // No shortcut glyphs: every pane has this submenu, and the keys act on the focused one.
        add(menu, L10n.tr("Separate from Split View")) { store.separateFromSplit(id) }
        menu.addItem(.separator())
<<<<<<< HEAD
        add(menu, tab.muted ? L10n.tr("Unmute") : L10n.tr("Mute")) {
            store.setMuted(id, !tab.muted)
            actions.performAction("muteTab:\(id)")
        }
        add(menu, L10n.tr("Copy Link")) { copy(tab.url) }
        add(menu, L10n.tr("Copy Link as Markdown")) { copy("[\(store.item(id)?.displayTitle ?? tab.savedTitle)](\(tab.url))") }
=======
        if let url = URL(string: CleanURL.withoutTrackers(tab.url)), url.scheme?.hasPrefix("http") == true {
            SharePicker.addMenu(to: menu, url: url)
        }
        add(menu, tab.muted ? "Unmute" : "Mute", enabled: tab.muted || ui.audibleTabIDs.contains(id)) {
            store.setMuted(id, !tab.muted)
            actions.performAction("muteTab:\(id)")
        }
        add(menu, "Copy Link") { copy(tab.url) }
        add(menu, "Copy link as Markdown") { copy("[\(store.item(id)?.displayTitle ?? tab.savedTitle)](\(tab.url))") }
>>>>>>> origin/main
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
        addLiveFolderPlugins(to: liveFolders, space: space, store: store, window: list.window)
        menu.addItem(.separator())
        if let s = store.space(space), !store.children(of: s.todayContainerID).isEmpty {
            add(menu, action: "clearToday") { store.clearToday(space, playing: list.ui.audibleTabIDs) }
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
