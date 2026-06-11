import AppKit
import ApplicationServices

/// Reads the frontmost app's on-screen UI through the Accessibility tree and
/// flattens it into compact text the model can reason over. This is Biscuit's
/// "eyes" — no screenshots, fully local.
enum PerceptionService {

    struct Element {
        let role: String
        let label: String
        let center: CGPoint
        let index: Int
    }

    static var hasPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts for Accessibility access (System Settings → Privacy).
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Snapshot of the frontmost app: a numbered list of actionable elements
    /// plus the click targets keyed by that number. The model picks a number,
    /// we map it back to coordinates.
    static func snapshot() -> (text: String, targets: [Int: CGPoint]) {
        guard hasPermission else {
            return ("(Screen reading unavailable — grant Accessibility in System Settings.)", [:])
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ("(No frontmost application.)", [:])
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var elements: [Element] = []
        var counter = 0
        walk(appElement, depth: 0, counter: &counter, into: &elements)

        let appName = app.localizedName ?? "App"
        guard !elements.isEmpty else {
            return ("Frontmost app: \(appName). No readable UI elements (this app may not expose accessibility info — a screenshot fallback would be needed).", [:])
        }

        var targets: [Int: CGPoint] = [:]
        var lines = ["Frontmost app: \(appName)", "On-screen elements (use the [number] with click_element):"]
        for element in elements.prefix(80) {
            targets[element.index] = element.center
            let label = element.label.isEmpty ? "(no label)" : element.label
            lines.append("[\(element.index)] \(element.role): \(label)")
        }
        return (lines.joined(separator: "\n"), targets)
    }

    // MARK: - Tree walk

    private static let interestingRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField",
        "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuButton", "AXPopUpButton",
        "AXTab", "AXRow", "AXCell", "AXStaticText", "AXComboBox", "AXSlider", "AXDisclosureTriangle",
    ]

    private static func walk(_ element: AXUIElement, depth: Int, counter: inout Int, into out: inout [Element]) {
        if depth > 22 || out.count > 400 { return }

        let role = string(element, kAXRoleAttribute) ?? ""
        if interestingRoles.contains(role), let frame = frame(of: element) {
            let label = bestLabel(element, role: role)
            // Skip empty static text and off-screen / zero-size noise.
            if !(role == "AXStaticText" && label.isEmpty), frame.width > 1, frame.height > 1 {
                counter += 1
                out.append(Element(
                    role: shortRole(role),
                    label: String(label.prefix(120)),
                    center: CGPoint(x: frame.midX, y: frame.midY),
                    index: counter
                ))
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                walk(child, depth: depth + 1, counter: &counter, into: &out)
            }
        }
    }

    private static func bestLabel(_ element: AXUIElement, role: String) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
            if let value = string(element, attr), !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func shortRole(_ role: String) -> String {
        role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        if let s = ref as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = ref as? NSNumber { return n.stringValue }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}
