import Foundation

/// The context menu of a download row, the same in the tray over the Library button and on
/// Library ▸ Downloads (#272). Arc 1.172's "Download Context Menu" (ContextMenus, read from its
/// binary on 9 Nov 2026): Open %@, Copy %@, Show in Finder, a separator, Cancel Download, a
/// separator, Hide from Arc, Move to Trash. %@ is the file's kind (`Kind`), or else its extension
/// as it is ("Open txt"). Pause Download and Resume Download are Cra's: Arc has a paused row
/// ("Paused") but no item that pauses one.
public enum DownloadMenu {
    public enum Action: Equatable, Sendable {
        case open, copy, showInFinder, pause, resume, cancel, hide, moveToTrash
    }

    /// The kinds Arc names a file by (ARCFoundationBase's URL+DownloadDestination), tested in
    /// this order: a zip is an archive too, and Arc says "Zip Archive".
    public enum Kind: CaseIterable, Equatable, Sendable {
        case image, diskImage, pdf, movie, audio, zip, archive

        public var name: String {
            switch self {
            // zh: 图像
            case .image: "Image"
            // zh: 磁盘映像
            case .diskImage: "Disk Image"
            case .pdf: "PDF"
            // zh: 影片
            case .movie: "Movie"
            // zh: 音频
            case .audio: "Audio"
            // zh: Zip 归档
            case .zip: "Zip Archive"
            // zh: 归档
            case .archive: "Archive"
            }
        }

        /// The first kind the file's type conforms to (the app asks UTType).
        public static func first(where conforms: (Kind) -> Bool) -> Kind? { allCases.first(where: conforms) }
    }

    /// The menu's groups, a separator between two. A finished file can be opened, copied, shown,
    /// hidden from the list or trashed; a running or paused one shown (once its file exists),
    /// paused or resumed and cancelled; a failed or cancelled one only hidden.
    public static func sections(for row: DownloadList.Listed, fileExists: (String) -> Bool) -> [[Action]] {
        switch row {
        case .finished(let e):
            guard fileExists(e.path) else { return [[.hide]] }
            return [[.open, .copy, .showInFinder], [.hide, .moveToTrash]]
        case .live(let l):
            guard l.running else { return [[.hide]] }
            let show: [[Action]] = !l.path.isEmpty && fileExists(l.path) ? [[.showInFinder]] : []
            return show + [[l.paused ? .resume : .pause, .cancel]]
        }
    }

    public static func title(_ action: Action, kind: Kind?, fileName: String) -> String {
        // zh: "File" → 文件
        let noun = kind?.name ?? { let ext = (fileName as NSString).pathExtension; return ext.isEmpty ? "File" : ext }()
        switch action {
        // zh: "Open \(noun)" → "打开\(noun)"（如 "打开 PDF"、"打开 txt"）
        case .open: return "Open \(noun)"
        // zh: "Copy \(noun)" → "拷贝\(noun)"
        case .copy: return "Copy \(noun)"
        // zh: 在访达中显示
        case .showInFinder: return "Show in Finder"
        // zh: 暂停下载
        case .pause: return "Pause Download"
        // zh: 继续下载
        case .resume: return "Resume Download"
        // zh: 取消下载
        case .cancel: return "Cancel Download"
        // zh: 从 Cra 中隐藏
        case .hide: return "Hide from Cra"
        // zh: 移到废纸篓
        case .moveToTrash: return "Move to Trash"
        }
    }
}

/// Asked before Cra quits. Arc 1.172 asks "Downloads in progress" while one runs ("There are
/// downloads in progress. Closing the application will cancel them.", Keep browsing / Close Arc),
/// in place of its usual "Quit Arc?" (#272). A restart into an update or another page engine asks
/// neither: the update's own Install and Relaunch asks about downloads before it starts.
public enum QuitPrompt: Equatable, Sendable {
    case none
    /// Settings ▸ Advanced ▸ Warn before quitting.
    case confirmQuit
    case downloadsInProgress

    public static func on(source: MenuBarMode.QuitSource, downloadsRunning: Bool, warnBeforeQuitting: Bool) -> QuitPrompt {
        guard source != .relaunch else { return .none }
        if downloadsRunning { return .downloadsInProgress }
        return warnBeforeQuitting ? .confirmQuit : .none
    }
}
