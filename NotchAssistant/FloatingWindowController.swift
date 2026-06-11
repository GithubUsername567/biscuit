import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats near the top-center of the
/// main screen. Deliberately positioned below the menu bar — not inside the
/// physical notch.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingWindowController {

    private static let panelSize = NSSize(width: 520, height: 400)

    private var panel: FloatingPanel?
    private let appState: AppState
    private var resignObserver: NSObjectProtocol?
    private var lastHide = Date.distantPast

    init(appState: AppState) {
        self.appState = appState
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible {
            hide()
        } else if Date().timeIntervalSince(lastHide) > 0.5 {
            // Clicking the status item makes the panel resign key, which hides
            // it just before this fires — don't immediately re-show it.
            show()
        }
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        guard isVisible else { return }
        lastHide = Date()
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false

        let hostingView = NSHostingView(rootView: AssistantPanelView().environmentObject(appState))
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = hostingView

        // Spotlight-style: clicking anywhere else dismisses the panel.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.appState.showSettings else { return }
                self.hide()
            }
        }
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame // excludes menu bar
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 12
        )
        panel.setFrameOrigin(origin)
    }
}
