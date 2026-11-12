import AppKit

/// The selection's translation, shown as a small dark card beside the selected text:
/// multi-line (unlike ShinyToast's one-liner), the translation is selectable and lands in
/// the clipboard, click outside / Esc / 12 s dismisses it. The local model's answer for W1
/// — nothing leaves the Mac.
@MainActor
enum TranslationHUD {
    private static var panel: NSPanel?
    private static var dismissTimer: Timer?
    private static var monitors: [Any] = []

    static func show(_ translation: String, original: String, near anchor: NSPoint, in window: NSWindow) {
        dismiss()
        let screen = (NSScreen.screens.first { $0.frame.contains(anchor) }) ?? window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? window.frame

        let width: CGFloat = min(480, visible.width - 32)
        let font = NSFont.systemFont(ofSize: 14)
        let originalFont = NSFont.systemFont(ofSize: 11)
        let textHeight = (translation as NSString).boundingRect(
            with: NSSize(width: width - 36, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
        let originalHeight = (original as NSString).boundingRect(
            with: NSSize(width: width - 36, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: originalFont]).height
        let height = min(textHeight + originalHeight + 74, visible.height - 24)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The card is dark with white text: force dark appearance or a light-mode system
        // renders the material light and the white text vanishes.
        panel.appearance = NSAppearance(named: .darkAqua)

        let card = NSVisualEffectView(frame: NSRect(origin: .zero, size: panel.frame.size))
        card.material = .hudWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.masksToBounds = true
        panel.contentView = card

        let label = NSTextView(frame: NSRect(x: 18, y: height - textHeight - 30,
                                             width: width - 36, height: textHeight + 4))
        label.string = translation
        label.font = font
        label.textColor = .white
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = true
        card.addSubview(label)

        let originalLabel = NSTextField(labelWithString: original)
        originalLabel.frame = NSRect(x: 18, y: 40, width: width - 36, height: originalHeight + 4)
        originalLabel.font = originalFont
        originalLabel.textColor = .secondaryLabelColor
        originalLabel.lineBreakMode = .byTruncatingTail
        originalLabel.maximumNumberOfLines = 2
        card.addSubview(originalLabel)

        let hint = NSTextField(labelWithString: "点击卡片外关闭 · 译文已复制")
        hint.frame = NSRect(x: 18, y: 14, width: width - 36, height: 16)
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        card.addSubview(hint)

        // Beside the selected text: below the anchor when it fits, else above; clamped to
        // the screen's visible frame.
        var origin = NSPoint(x: anchor.x - width / 2,
                             y: anchor.y - height - 10)
        if origin.y < visible.minY + 8 { origin.y = anchor.y + 10 }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - width - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - height - 8))
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
        self.panel = panel

        // Clicks outside the card dismiss it (events pass through); clicks inside let the
        // user select the translation. Esc dismisses too.
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            // NSEvent.mouseLocation is always in global screen coordinates, panel frame too.
            if screenContains(NSEvent.mouseLocation), panel.frame.contains(NSEvent.mouseLocation) {
                return event  // inside the card: let the click through (text selection)
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
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { _ in
            dismiss()
        }
    }

    private static func screenContains(_ location: NSPoint) -> Bool {
        NSScreen.screens.contains { $0.frame.contains(location) }
    }

    static func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }
}
