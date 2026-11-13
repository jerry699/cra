import AppKit
import CraCEF

/// The selection's translation, shown as Arc's find bubble: a light popover above the
/// selected text with a tail pointing at it, and the selection itself repainted yellow.
/// The yellow lands AT RIGHT-CLICK TIME (a transient ::selection style injected into the
/// page) and the bubble opens at once with "translating…" — the local model can take
/// dozens of seconds on a loaded Mac, and by then the user's selection may be gone, so
/// nothing may depend on it surviving. The bubble updates in place when the translation
/// arrives. Click outside / Esc dismisses (the dismiss also strips the yellow); the
/// finished bubble auto-dismisses after 12 s. W1 — nothing leaves the Mac.
@MainActor
enum TranslationHUD {
    private static var panel: NSPanel?
    private static var dismissTimer: Timer?
    private static var monitors: [Any] = []
    /// The page that got the yellow ::selection style; it comes off on dismiss.
    private static var page: CraBrowser?
    private static var anchor = NSPoint.zero
    private static var hostWindow: NSWindow?
    private static var originalText = ""
    /// Guard against a stale answer: a second selection while the first still translates
    /// replaces the bubble, and the first task's finish/fail must not touch it.
    private static var generation = 0

    private static let highlightOn = """
    (function(){var s=document.getElementById('cra-translate-highlight');\
    if(!s){s=document.createElement('style');s.id='cra-translate-highlight';}\
    s.textContent='::selection{background:rgba(255,196,0,.55)!important}';\
    document.head.appendChild(s);})()
    """
    private static let highlightOff = """
    (function(){var s=document.getElementById('cra-translate-highlight');if(s)s.remove();})()
    """

    /// Right-click time: the selection turns yellow and the pending bubble appears at once.
    /// Returns the token the finish/fail callbacks must carry.
    @discardableResult
    static func begin(original: String, near point: NSPoint, in window: NSWindow,
                      page selected: CraBrowser?) -> Int {
        dismiss()
        generation += 1
        page = selected
        selected?.executeJavaScript(highlightOn)
        anchor = point
        hostWindow = window
        originalText = original
        build(translation: nil, failed: false)
        return generation
    }

    /// The model answered: swap the pending row for the translation, copy it, start the clock.
    static func finish(_ translation: String, token: Int) {
        guard token == generation, panel != nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translation, forType: .string)
        build(translation: translation, failed: false)
        armTimer()
    }

    static func fail(token: Int) {
        guard token == generation, panel != nil else { return }
        build(translation: nil, failed: true)
        armTimer()
    }

    // MARK: - Bubble construction

    /// (Re)builds the bubble at the stored anchor. `translation` nil means pending, or the
    /// failure message when `failed`.
    private static func build(translation: String?, failed: Bool) {
        removeMonitors()
        panel?.orderOut(nil)

        let screen = (NSScreen.screens.first { $0.frame.contains(anchor) }) ?? hostWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? hostWindow?.frame ?? .zero

        let width: CGFloat = min(460, visible.width - 32)
        let resultFont = NSFont.systemFont(ofSize: 14)
        let statusFont = NSFont.systemFont(ofSize: 13, weight: .regular)
        let originalFont = NSFont.systemFont(ofSize: 11)

        let mainText: String
        let mainFont: NSFont
        let mainColor: NSColor
        switch (translation, failed) {
        case (.some(let t), _):
            mainText = t; mainFont = resultFont; mainColor = .labelColor
        case (nil, true):
            mainText = "翻译失败——本地模型没有给出译文"; mainFont = statusFont; mainColor = .secondaryLabelColor
        case (nil, false):
            mainText = "正在翻译…"; mainFont = statusFont; mainColor = .tertiaryLabelColor
        }
        let textHeight = ceil((mainText as NSString).boundingRect(
            with: NSSize(width: width - 36, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: mainFont]).height)
        let originalHeight = ceil((originalText as NSString).boundingRect(
            with: NSSize(width: width - 36, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: originalFont]).height)
        let hintHeight: CGFloat = 14
        let tailHeight: CGFloat = 7
        let height = min(textHeight + originalHeight + hintHeight + 52 + tailHeight, visible.height - 24)

        let bubble = BubbleView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bubble.tailHeight = min(tailHeight, height)
        let inner = bubble.bodyRect

        if let translation {  // the result is selectable text; status rows are plain labels
            let label = NSTextView(frame: NSRect(x: 18, y: inner.maxY - textHeight - 8,
                                                 width: width - 36, height: textHeight + 4))
            label.string = translation
            label.font = mainFont
            label.textColor = mainColor
            label.drawsBackground = false
            label.isEditable = false
            label.isSelectable = true
            bubble.addSubview(label)
        } else {
            let label = NSTextField(labelWithString: mainText)
            label.frame = NSRect(x: 18, y: inner.maxY - textHeight - 8, width: width - 36, height: textHeight + 4)
            label.font = mainFont
            label.textColor = mainColor
            bubble.addSubview(label)
        }

        let originalLabel = NSTextField(labelWithString: originalText)
        originalLabel.frame = NSRect(x: 18, y: inner.minY + hintHeight + 12, width: width - 36,
                                     height: originalHeight + 4)
        originalLabel.font = originalFont
        originalLabel.textColor = .secondaryLabelColor
        originalLabel.lineBreakMode = .byTruncatingTail
        originalLabel.maximumNumberOfLines = 2
        bubble.addSubview(originalLabel)

        let hint = NSTextField(labelWithString: failed ? "点卡片外或按 Esc 关闭"
                               : translation == nil ? "译文就绪后会自动替换这一行"
                               : "点击卡片外关闭 · 译文已复制")
        hint.frame = NSRect(x: 18, y: inner.minY + 6, width: width - 36, height: hintHeight)
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        bubble.addSubview(hint)

        let newPanel = NSPanel(contentRect: NSRect(origin: .zero, size: bubble.frame.size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false  // the bubble draws its own, shaped to the tail
        newPanel.level = .floating
        newPanel.isMovableByWindowBackground = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentView = bubble

        // Above the selection with the tail pointing at it (Arc's find bubble); when the
        // top of the screen is too close, below it with the tail flipped up.
        let tailX = width / 2
        var origin = NSPoint(x: anchor.x - tailX, y: anchor.y + 10)
        if origin.y + height > visible.maxY - 8 {  // flip below
            bubble.tailBelow = false
            origin.y = anchor.y - 10 - height
        }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - width - 8))
        bubble.tailX = max(18, min(anchor.x - origin.x, width - 18))
        newPanel.setFrameOrigin(origin)
        newPanel.orderFront(nil)
        panel = newPanel

        // Clicks outside the bubble dismiss it (events pass through); clicks inside let the
        // user select the translation. Esc dismisses too.
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if screenContains(NSEvent.mouseLocation), newPanel.frame.contains(NSEvent.mouseLocation) {
                return event  // inside the bubble: let the click through (text selection)
            }
            dismiss()
            return event
        }
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }  // Esc
            dismiss()
            return nil
        }
        monitors = [localMonitor, keyMonitor]
    }

    private static func armTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { _ in
            dismiss()
        }
    }

    private static func screenContains(_ location: NSPoint) -> Bool {
        NSScreen.screens.contains { $0.frame.contains(location) }
    }

    private static func removeMonitors() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }

    static func dismiss() {
        removeMonitors()
        page?.executeJavaScript(highlightOff)
        page = nil
        hostWindow = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// One filled shape: rounded bubble + tail, so there is no seam where they meet. Adapts
/// to appearance (controlBackgroundColor: white in light, dark grey in dark).
private final class BubbleView: NSView {
    var tailBelow = true   // bubble sits above the selection: tail on the bottom edge
    var tailX: CGFloat = 40 { didSet { needsDisplay = true } }
    var tailHeight: CGFloat = 7
    private let corner: CGFloat = 12

    /// The rounded-rect part (everything but the tail), for laying out subviews.
    var bodyRect: NSRect {
        NSRect(x: 0, y: tailBelow ? tailHeight : 0, width: frame.width, height: frame.height - tailHeight)
    }

    private func path() -> NSBezierPath {
        let body = bodyRect
        let x = max(corner, min(tailX, frame.width - corner))
        let half: CGFloat = 7
        let path = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)
        if tailBelow {
            path.move(to: NSPoint(x: x - half, y: body.minY))
            path.line(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x + half, y: body.minY))
        } else {
            path.move(to: NSPoint(x: x - half, y: body.maxY))
            path.line(to: NSPoint(x: x, y: frame.height))
            path.line(to: NSPoint(x: x + half, y: body.maxY))
        }
        path.close()
        return path
    }

    override func viewDidMoveToWindow() {
        wantsLayer = true
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 9
        layer?.shadowColor = NSColor.black.cgColor
    }
    override func layout() {
        super.layout()
        layer?.shadowOffset = NSSize(width: 0, height: tailBelow ? -3 : 3)
        layer?.shadowPath = path().cgPath
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = path()
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        layer?.shadowPath = shape.cgPath
    }
}
