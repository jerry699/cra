import AppKit

/// The selection's translation, shown as a small dark card near the top of the page's window:
/// multi-line (unlike ShinyToast's one-liner), click to dismiss, gone after 10 s. The local
/// model's answer for W1 — nothing leaves the Mac.
@MainActor
enum TranslationHUD {
    private static var panel: NSPanel?
    private static var dismissTimer: Timer?

    static func show(_ translation: String, original: String, in window: NSWindow) {
        dismiss()
        let width: CGFloat = min(480, window.frame.width - 48)
        let text = translation
        let font = NSFont.systemFont(ofSize: 14)
        let originalFont = NSFont.systemFont(ofSize: 11)
        let textHeight = (text as NSString).boundingRect(
            with: NSSize(width: width - 36, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
        let originalHeight = (original as NSString).boundingRect(
            with: NSSize(width: width - 36, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: originalFont]).height
        let height = min(textHeight + originalHeight + 74, window.frame.height - 80)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        // The HUD card is dark with white text: force dark appearance or a light-mode system
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
        label.string = text
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

        let hint = NSTextField(labelWithString: "点击任意处关闭")
        hint.frame = NSRect(x: 18, y: 14, width: width - 36, height: 16)
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        card.addSubview(hint)

        // Top-centre of the page's window, clear of the toolbar.
        let origin = NSPoint(x: window.frame.midX - width / 2,
                             y: window.frame.maxY - height - 60)
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
        panel.makeKey()
        panel.makeFirstResponder(label)
        self.panel = panel

        // Click anywhere dismisses; a local click monitor sees clicks outside too.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            dismiss()
            return event  // pass through: dismissing must not swallow the user's click
        }
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            dismiss()
        }
        clickMonitors = [monitor, globalMonitor]
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
            dismiss()
        }
    }

    private static var clickMonitors: [Any] = []

    static func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        for m in clickMonitors { NSEvent.removeMonitor(m) }
        clickMonitors = []
        panel?.orderOut(nil)
        panel = nil
    }
}
