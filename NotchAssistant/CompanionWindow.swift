import AppKit
import SwiftUI

/// Tiny always-on-top window in the bottom-right corner hosting the pixel
/// dog. Clicking the dog toggles the assistant. Never steals focus.
final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CompanionWindowController {

    private static let panelSize = NSSize(width: 240, height: 180)

    private var panel: CompanionPanel?
    private let appState: AppState

    /// Set by the app delegate: fired when the dog is clicked.
    var onTap: (@MainActor () -> Void)?

    init(appState: AppState) {
        self.appState = appState
    }

    private var customOrigin: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var snoozeTask: Task<Void, Never>?

    func show() {
        snoozeTask?.cancel()
        if panel == nil {
            panel = makePanel()
        }
        position()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Move out of the way

    func dragChanged(_ translation: CGSize) {
        guard let panel else { return }
        if dragStartOrigin == nil { dragStartOrigin = panel.frame.origin }
        guard let start = dragStartOrigin else { return }
        // SwiftUI y grows down, AppKit y grows up.
        panel.setFrameOrigin(NSPoint(x: start.x + translation.width, y: start.y - translation.height))
    }

    func dragEnded() {
        customOrigin = panel?.frame.origin
        dragStartOrigin = nil
    }

    func moveToCorner(left: Bool) {
        guard let screen = NSScreen.main, let panel else { return }
        let visible = screen.visibleFrame
        let x = left ? visible.minX + 16 : visible.maxX - panel.frame.width - 16
        let origin = NSPoint(x: x, y: visible.minY + 16)
        customOrigin = origin
        panel.setFrameOrigin(origin)
    }

    func snooze(minutes: Int) {
        hide()
        snoozeTask?.cancel()
        snoozeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            let stillWanted = UserDefaults.standard.object(forKey: SettingsKeys.showCompanion) as? Bool ?? true
            if stillWanted { self?.show() }
        }
    }

    private func makePanel() -> CompanionPanel {
        let panel = CompanionPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        let view = CompanionView(actions: CompanionActions(
            tap: { [weak self] in self?.onTap?() },
            dragChanged: { [weak self] in self?.dragChanged($0) },
            dragEnded: { [weak self] in self?.dragEnded() },
            moveLeft: { [weak self] in self?.moveToCorner(left: true) },
            moveRight: { [weak self] in self?.moveToCorner(left: false) },
            nap: { [weak self] in self?.snooze(minutes: 30) },
            hideForever: { UserDefaults.standard.set(false, forKey: SettingsKeys.showCompanion) }
        ))
        .environmentObject(appState)
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }

    private func position() {
        guard let screen = NSScreen.main, let panel else { return }
        let visible = screen.visibleFrame
        if let customOrigin {
            // Keep a user-chosen spot, clamped on-screen.
            let x = min(max(customOrigin.x, visible.minX), visible.maxX - panel.frame.width)
            let y = min(max(customOrigin.y, visible.minY), visible.maxY - panel.frame.height)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 16,
                y: visible.minY + 16
            ))
        }
    }
}

struct CompanionActions {
    var tap: () -> Void
    var dragChanged: (CGSize) -> Void
    var dragEnded: () -> Void
    var moveLeft: () -> Void
    var moveRight: () -> Void
    var nap: () -> Void
    var hideForever: () -> Void
}

// MARK: - Animated pixel dog

struct CompanionView: View {
    @EnvironmentObject private var appState: AppState
    var actions: CompanionActions
    @State private var petting = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let bubble = bubbleText {
                Text(bubble)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
            }
            TimelineView(.periodic(from: .now, by: 0.45)) { context in
                let frame = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 2
                ZStack {
                    Circle()
                        .fill(auraColor.opacity(auraColor == .clear ? (petting ? 0.25 : 0) : 0.4))
                        .blur(radius: 12)
                        .frame(width: 78, height: 78)
                    PixelArtView(map: displayFrames[frame])
                        .frame(width: 80, height: 80)
                        .offset(y: bounceOffset(frame))
                    if petting {
                        Text("♥")
                            .font(.system(size: 18))
                            .foregroundStyle(Color(red: 0.90, green: 0.42, blue: 0.54))
                            .offset(x: 30, y: frame == 0 ? -42 : -50)
                            .opacity(frame == 0 ? 1 : 0.5)
                        Text("♥")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.90, green: 0.42, blue: 0.54))
                            .offset(x: -28, y: frame == 0 ? -34 : -44)
                            .opacity(frame == 0 ? 0.6 : 1)
                    }
                }
                .frame(width: 96, height: 96)
            }
        }
        .frame(width: 240, height: 180, alignment: .bottomTrailing)
        .contentShape(Rectangle())
        .onHover { petting = $0 }
        .gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .global)
                .onChanged { actions.dragChanged($0.translation) }
                .onEnded { _ in actions.dragEnded() }
        )
        .onTapGesture { actions.tap() }
        .contextMenu {
            Button("Move to left corner") { actions.moveLeft() }
            Button("Move to right corner") { actions.moveRight() }
            Divider()
            Button("Nap for 30 minutes") { actions.nap() }
            Button("Hide (re-enable in Settings)") { actions.hideForever() }
        }
        .animation(.easeInOut(duration: 0.2), value: bubbleText)
        .animation(.easeInOut(duration: 0.2), value: petting)
        .help("Click to talk · drag to move · right-click for options")
    }

    /// Petting an idle dog makes him perk up.
    private var displayFrames: [[String]] {
        if petting, appState.state == .idle {
            return PixelDog.frames(for: .listening)
        }
        return PixelDog.frames(for: appState.state)
    }

    /// Live feedback while everything happens in the background.
    private var bubbleText: String? {
        switch appState.state {
        case .idle:
            return nil
        case .listening:
            let text = appState.inputText
            return text.isEmpty ? "Listening…" : text
        case .processing:
            return "Working…"
        case .responding:
            return nil
        case .error(let message):
            return message
        }
    }

    private var auraColor: Color {
        switch appState.state {
        case .idle: .clear
        case .listening: .green
        case .processing: .orange
        case .responding: .blue
        case .error: .red
        }
    }

    private func bounceOffset(_ frame: Int) -> CGFloat {
        switch appState.state {
        case .listening, .processing, .responding: frame == 0 ? 0 : -4
        default: 0
        }
    }
}

struct PixelArtView: View {
    let map: [String]

    var body: some View {
        Canvas { context, size in
            let rows = map.count
            let cols = map.map(\.count).max() ?? 1
            let cell = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
            for (y, row) in map.enumerated() {
                for (x, character) in row.enumerated() {
                    guard let color = PixelDog.palette[character] else { continue }
                    // +0.5 overlap hides hairline seams between cells.
                    let rect = CGRect(
                        x: CGFloat(x) * cell,
                        y: CGFloat(y) * cell,
                        width: cell + 0.5,
                        height: cell + 0.5
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}

/// 16×16 pixel shiba. '.' = transparent, B = body, D = dark outline,
/// W = cream, K = black (eyes/nose), P = pink (tongue).
enum PixelDog {

    static let palette: [Character: Color] = [
        "B": Color(red: 0.79, green: 0.54, blue: 0.29),
        "D": Color(red: 0.29, green: 0.18, blue: 0.10),
        "W": Color(red: 0.95, green: 0.89, blue: 0.82),
        "K": Color(red: 0.11, green: 0.11, blue: 0.12),
        "P": Color(red: 0.90, green: 0.42, blue: 0.54),
    ]

    static func frames(for state: AssistantState) -> [[String]] {
        switch state {
        case .listening: [earsUpTailDown, earsUpTailUp]
        case .responding: [speakingClosed, speakingTongue]
        case .error: [earsDown, earsDown]
        default: [baseTailDown, baseTailUp]
        }
    }

    static let baseTailDown: [String] = [
        "................",
        "..D.........D...",
        "..DD.......DD...",
        "..DBD.....DBD...",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWBBBWWBD.D.",
        "..DBWWBBBWWBDD..",
        "..DDDDDDDDDDD...",
        "................",
    ]

    static let baseTailUp: [String] = [
        "................",
        "..D.........D...",
        "..DD.......DD...",
        "..DBD.....DBD...",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD..D.",
        "..DBBBBBBBBBD.D.",
        "..DBWWBBBWWBDD..",
        "..DBWWBBBWWBD...",
        "..DDDDDDDDDDD...",
        "................",
    ]

    static let earsUpTailDown: [String] = [
        "..D.........D...",
        "..DD.......DD...",
        "..DBD.....DBD...",
        "..DBBD...DBBD...",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWBBBWWBD.D.",
        "..DBWWBBBWWBDD..",
        "..DDDDDDDDDDD...",
        "................",
    ]

    static let earsUpTailUp: [String] = [
        "..D.........D...",
        "..DD.......DD...",
        "..DBD.....DBD...",
        "..DBBD...DBBD...",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD..D.",
        "..DBBBBBBBBBD.D.",
        "..DBWWBBBWWBDD..",
        "..DBWWBBBWWBD...",
        "..DDDDDDDDDDD...",
        "................",
    ]

    static let speakingClosed = baseTailUp

    static let speakingTongue: [String] = [
        "................",
        "..D.........D...",
        "..DD.......DD...",
        "..DBD.....DBD...",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "...DBBWPWBBD....",
        "....DBBPBBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWBBBWWBD.D.",
        "..DBWWBBBWWBDD..",
        "..DDDDDDDDDDD...",
        "................",
    ]

    static let earsDown: [String] = [
        "................",
        "................",
        "..DD.......DD...",
        "..DBDD...DDBD...",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWBBBWWBD...",
        "..DBWWBBBWWBD...",
        "..DDDDDDDDDDD...",
        "................",
    ]
}
