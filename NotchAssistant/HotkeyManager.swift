import AppKit
import Carbon.HIToolbox

/// Global hold-to-talk hotkey: hold Control+Fn (Globe) to listen, release to send.
///
/// Fn is a modifier, so this needs a CGEvent tap on flagsChanged — which
/// requires the Input Monitoring permission. When that permission is missing
/// we request it (takes effect after relaunch) and meanwhile register a
/// Carbon fallback hotkey (⌃⌥K, toggle-style) that needs no permission.
final class HotkeyManager {

    /// Fired on the main queue when Control+Fn goes down / comes up.
    var onHoldBegan: (() -> Void)?
    var onHoldEnded: (() -> Void)?
    /// Fired by the no-permission fallback hotkey (⌃⌥K).
    var onFallbackToggle: (() -> Void)?

    private(set) var usingEventTap = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonHandlerRef: EventHandlerRef?
    private var holdActive = false
    private var retryTask: Task<Void, Never>?

    func start() {
        usingEventTap = startEventTap()
        if !usingEventTap {
            // Shows up in System Settings → Privacy & Security → Input Monitoring.
            _ = CGRequestListenEventAccess()
            startCarbonFallback()
            // Poll until the user grants Input Monitoring so ⌃+Fn starts
            // working without a relaunch.
            retryTask = Task { [weak self] in
                while true {
                    try? await Task.sleep(for: .seconds(10))
                    guard let self, !Task.isCancelled else { return }
                    if self.usingEventTap { return }
                    let activated = await MainActor.run { self.startEventTap() }
                    if activated {
                        self.usingEventTap = true
                        NSLog("HotkeyManager: Input Monitoring granted — hold ⌃+Fn now live")
                        return
                    }
                }
            }
        }
    }

    func stopMonitoring() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        if let carbonHotKeyRef {
            UnregisterEventHotKey(carbonHotKeyRef)
        }
        if let carbonHandlerRef {
            RemoveEventHandler(carbonHandlerRef)
        }
        carbonHotKeyRef = nil
        carbonHandlerRef = nil
    }

    // MARK: - CGEvent tap (Control+Fn hold)

    private func startEventTap() -> Bool {
        guard CGPreflightListenEventAccess() else {
            NSLog("HotkeyManager: Input Monitoring not granted — using ⌃⌥K Carbon fallback until granted + relaunch")
            return false
        }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if type == .flagsChanged, let refcon {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                    manager.handleFlagsChanged(event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("HotkeyManager: CGEvent tap creation failed — using ⌃⌥K Carbon fallback")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("HotkeyManager: hold ⌃+Fn active (event tap)")
        return true
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let flags = event.flags
        let active = flags.contains(.maskControl) && flags.contains(.maskSecondaryFn)
        if active && !holdActive {
            holdActive = true
            DispatchQueue.main.async { [weak self] in self?.onHoldBegan?() }
        } else if !active && holdActive {
            holdActive = false
            DispatchQueue.main.async { [weak self] in self?.onHoldEnded?() }
        }
    }

    // MARK: - Carbon fallback (⌃⌥K toggle)

    private func startCarbonFallback() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onFallbackToggle?() }
            return noErr
        }, 1, &eventType, selfPointer, &carbonHandlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E544348), id: 1) // 'NTCH'
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_K),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &carbonHotKeyRef
        )
        if status == noErr {
            NSLog("HotkeyManager: Carbon fallback hotkey registered (⌃⌥K)")
        } else {
            NSLog("HotkeyManager: Carbon hotkey registration failed (status \(status))")
        }
    }
}
