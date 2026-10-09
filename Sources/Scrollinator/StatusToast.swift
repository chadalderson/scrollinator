import AppKit
import SwiftUI

/// A small message near the top of the screen that fades away by itself, for confirming things
/// after the prompter is gone, like a recording having stopped. Clicking it runs its action.
@MainActor
final class StatusToast {
    static let shared = StatusToast()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(title: String, detail: String?, on screen: NSScreen?, action: (() -> Void)? = nil) {
        dismiss(animated: false)
        let host = ClickableHostingView(rootView: ToastView(title: title, detail: detail, hasAction: action != nil) { [weak self] in
            action?()
            self?.dismiss(animated: true)
        })
        let size = host.fittingSize
        guard let screen = screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let panel = NSPanel(
            contentRect: NSRect(x: (area.midX - size.width / 2).rounded(), y: area.maxY - size.height - 16,
                                width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        self.panel = panel

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.dismiss(animated: true)
        }
    }

    private func dismiss(animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel.animator().alphaValue = 0 }) {
            panel.orderOut(nil)
        }
    }
}

/// Takes the first click even though the panel never becomes active.
private final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct ToastView: View {
    var title: String
    var detail: String?
    var hasAction: Bool
    var tap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if hasAction {
                Text("Show in Finder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.red)
                    .padding(.leading, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .environment(\.colorScheme, .dark)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: tap)
    }
}
