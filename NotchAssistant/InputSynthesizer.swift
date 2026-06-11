import AppKit
import Carbon.HIToolbox

/// Synthesizes mouse and keyboard input via CGEvent — Biscuit's "hands".
/// Requires the Accessibility permission (posting events to other apps).
enum InputSynthesizer {

    private static let source = CGEventSource(stateID: .combinedSessionState)

    @MainActor
    static func click(at point: CGPoint) {
        // Move first so the target app registers hover state, then click.
        post(.mouseMoved, point, button: .left)
        usleep(40_000)
        post(.leftMouseDown, point, button: .left)
        usleep(40_000)
        post(.leftMouseUp, point, button: .left)
    }

    private static func post(_ type: CGEventType, _ point: CGPoint, button: CGMouseButton) {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    @MainActor
    static func type(_ text: String) {
        for chunk in text.unicodeScalars.chunked(into: 20) {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            var utf16 = Array(String(String.UnicodeScalarView(chunk)).utf16)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    @MainActor
    static func pressKey(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = modifiers
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = modifiers
        down?.post(tap: .cghidEventTap)
        usleep(20_000)
        up?.post(tap: .cghidEventTap)
    }

    static func keyCode(for key: String) -> CGKeyCode? {
        switch key.lowercased() {
        case "return", "enter": return 36
        case "tab": return 48
        case "space": return 49
        case "escape", "esc": return 53
        case "delete", "backspace": return 51
        case "up": return 126
        case "down": return 125
        case "left": return 123
        case "right": return 124
        default:
            guard key.count == 1, let code = letterCode[key.lowercased()] else { return nil }
            return code
        }
    }

    static func modifiers(from string: String) -> CGEventFlags {
        var flags: CGEventFlags = []
        for token in string.lowercased().split(whereSeparator: { $0 == " " || $0 == "+" }) {
            switch token {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt", "opt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    private static let letterCode: [String: CGKeyCode] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
        "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6, "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    ]
}

private extension Collection {
    func chunked(into size: Int) -> [[Element]] {
        var result: [[Element]] = []
        var chunk: [Element] = []
        for element in self {
            chunk.append(element)
            if chunk.count == size { result.append(chunk); chunk = [] }
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}
