import SwiftUI
import AppKit

struct AssistantPanelView: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            header
            Divider().opacity(0.3)
            conversation
            if case .error(let message) = appState.state {
                errorBanner(message)
            }
            inputBar
        }
        .padding(16)
        .frame(width: 520, height: 400)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
        .sheet(isPresented: $appState.showSettings) {
            SettingsView().environmentObject(appState)
        }
        .onAppear { inputFocused = true }
        .onExitCommand { appState.hidePanel() }
        .onChange(of: appState.inputText) { _, _ in
            appState.cancelAutoHide()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            StatusIndicator(state: appState.state)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if isBusy {
                Button {
                    appState.cancel()
                } label: {
                    Label("Cancel", systemImage: "stop.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Stop recording, inference, or speech")
            }
            Button {
                appState.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button {
                appState.hidePanel()
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide panel")
        }
    }

    private var isBusy: Bool {
        switch appState.state {
        case .listening, .processing, .responding: true
        default: false
        }
    }

    private var statusText: String {
        switch appState.state {
        case .idle: "Ready"
        case .listening: "Listening…"
        case .processing: "Thinking…"
        case .responding: "Responding…"
        case .error: "Error"
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if appState.messages.isEmpty {
                        Text("Hold ⌃+Fn and speak — release to send. Or type below, or click the dog.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(appState.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .onChange(of: appState.messages) { _, newMessages in
                if let last = newMessages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
            Button {
                appState.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button {
                appState.toggleVoice()
            } label: {
                Image(systemName: appState.state == .listening ? "mic.fill" : "mic")
                    .font(.title3)
                    .foregroundStyle(appState.state == .listening ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help("Voice input (hold ⌃+Fn)")

            TextField(appState.state == .listening ? "Listening…" : "Ask anything…",
                      text: $appState.inputText)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { appState.sendCurrentInput() }

            Button {
                appState.sendCurrentInput()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send")
        }
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var canSend: Bool {
        !appState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Message bubble with markdown-lite rendering

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .tool {
            Text(message.content)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            Text(attributedContent)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    message.role == .user ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            if message.role != .user { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    /// Bold and inline code render via Foundation's markdown parser; falls
    /// back to plain text on malformed input.
    private var attributedContent: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: message.content, options: options))
            ?? AttributedString(message.content)
    }
}

// MARK: - Animated status indicator

struct StatusIndicator: View {
    let state: AssistantState

    private var color: Color {
        switch state {
        case .idle: .gray
        case .listening: .green
        case .processing: .orange
        case .responding: .blue
        case .error: .red
        }
    }

    private var animates: Bool {
        switch state {
        case .listening, .processing, .responding: true
        default: false
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .shadow(color: color.opacity(0.6), radius: 4)
            .phaseAnimator([false, true]) { view, phase in
                view
                    .scaleEffect(animates && phase ? 1.4 : 1.0)
                    .opacity(animates && phase ? 0.55 : 1.0)
            } animation: { _ in
                .easeInOut(duration: 0.6)
            }
            .animation(.easeInOut(duration: 0.25), value: state)
    }
}

// MARK: - Blur background

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
