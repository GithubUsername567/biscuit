import SwiftUI
import AppKit

@main
struct NotchAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No main window — the status item and floating panel own all UI.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let appState = AppState()
    private var windowController: FloatingWindowController!
    private var companionController: CompanionWindowController!
    private let hotkeyManager = HotkeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only; LSUIElement set too

        windowController = FloatingWindowController(appState: appState)
        appState.onRequestHide = { [weak self] in self?.windowController.hide() }

        companionController = CompanionWindowController(appState: appState)
        // Dog click: background listen toggle — no panel.
        companionController.onTap = { [weak self] in
            guard let self else { return }
            if self.appState.state == .listening {
                self.appState.finishListening()
            } else {
                self.appState.startListening()
            }
        }
        companionController.show()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Biscuit")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Hold ⌃+Fn: listen while held, send on release. Everything happens
        // in the background — the dog's bubble is the only feedback. The full
        // panel stays available via the menu bar icon.
        hotkeyManager.onHoldBegan = { [weak self] in
            Task { @MainActor in self?.appState.startListening() }
        }
        hotkeyManager.onHoldEnded = { [weak self] in
            Task { @MainActor in self?.appState.finishListening() }
        }
        // ⌃⌥K toggle until Input Monitoring is granted.
        hotkeyManager.onFallbackToggle = { [weak self] in
            Task { @MainActor in self?.hotkeyPressed() }
        }
        // Ask for Accessibility up front — needed to see and operate apps.
        if !PerceptionService.hasPermission {
            PerceptionService.requestPermission()
        }

        hotkeyManager.start()
        if !hotkeyManager.usingEventTap {
            appState.notify("Hold ⌃+Fn needs Input Monitoring (System Settings → Privacy). Until then: ⌃⌥K. It activates by itself once granted.")
        }

        // Real launch-at-login; defaults to on so Terminal is never needed.
        if UserDefaults.standard.object(forKey: SettingsKeys.launchAtLogin) == nil {
            UserDefaults.standard.set(true, forKey: SettingsKeys.launchAtLogin)
        }
        LaunchAtLogin.set(enabled: UserDefaults.standard.bool(forKey: SettingsKeys.launchAtLogin))

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncCompanionVisibility() }
        }
        syncCompanionVisibility()
    }

    private func syncCompanionVisibility() {
        let show = UserDefaults.standard.object(forKey: SettingsKeys.showCompanion) as? Bool ?? true
        show ? companionController.show() : companionController.hide()
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            windowController.toggle()
        }
    }

    @objc private func togglePanel() {
        windowController.toggle()
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "Show/Hide Assistant (hold ⌃+Fn)", action: #selector(togglePanel), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Biscuit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Attach the menu only for this click so left-click keeps toggling the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Fallback toggle (⌃⌥K): reveal the panel and toggle voice capture.
    private func hotkeyPressed() {
        if !windowController.isVisible {
            windowController.show()
        }
        appState.toggleVoice()
    }
}
