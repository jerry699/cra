import AppKit

/// The distillation's live status card: a small dark panel at the screen's bottom-right that
/// stays up for the WHOLE run — the transcription of a long video takes minutes, and a toast
/// that vanished after three seconds read as "nothing happened" (the user's report). Phases
/// and a per-phase clock, the final state lingers 8 s and then the card leaves by itself.
@MainActor
enum DistillStatusHUD {
    private static var panel: NSPanel?
    private static var phaseLabel: NSTextField?
    private static var timeLabel: NSTextField?
    private static var timer: Timer?
    private static var phase = ""
    private static var started = Date()

    static func show(_ initial: String) {
        dismiss()
        phase = initial
        started = Date()
        build()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { update() }
        }
    }

    static func phase(_ name: String) {
        phase = name
        started = Date()
        update()
    }

    /// The run ended: `✓`/`✗` + the outcome, card self-dismisses.
    static func finish(_ message: String, failed: Bool = false) {
        timer?.invalidate()
        timer = nil
        phase = (failed ? "✗ " : "✓ ") + message
        update()
        Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
            MainActor.assumeIsolated { dismiss() }
        }
    }

    static func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        phaseLabel = nil
        timeLabel = nil
    }

    // MARK: - Panel

    private static func build() {
        let width: CGFloat = 240
        let height: CGFloat = 58
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        let card = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        card.material = .hudWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = true
        panel.contentView = card

        let phaseField = NSTextField(labelWithString: "")
        phaseField.frame = NSRect(x: 14, y: height - 26, width: width - 28, height: 18)
        phaseField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        phaseField.textColor = .white
        phaseField.lineBreakMode = .byTruncatingTail
        card.addSubview(phaseField)

        let timeField = NSTextField(labelWithString: "")
        timeField.frame = NSRect(x: 14, y: 10, width: width - 28, height: 14)
        timeField.font = NSFont.systemFont(ofSize: 11)
        timeField.textColor = .secondaryLabelColor
        card.addSubview(timeField)

        // Bottom-right of the main screen's visible area.
        let visible = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: visible.maxX - width - 24, y: visible.minY + 28))
        panel.orderFront(nil)

        self.panel = panel
        phaseLabel = phaseField
        timeLabel = timeField
        update()
    }

    private static func update() {
        phaseLabel?.stringValue = "蒸馏：\(phase)"
        let elapsed = max(0, Int(Date().timeIntervalSince(started)))
        timeLabel?.stringValue = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }
}
