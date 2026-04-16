import AppKit
import SwiftUI

@MainActor
public final class NotificationBubble: NSObject {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var viewModel: BubbleViewModel?

    public override init() { super.init() }

    public func show(
        title: String = "Claude Code",
        message: String,
        relativeTo button: NSStatusBarButton?,
        duration: TimeInterval = 7.0
    ) {
        dismiss()

        let vm = BubbleViewModel()
        let bubbleView = GlassNotificationView(title: title, message: message, viewModel: vm)
        let hostingView = NSHostingView(rootView: bubbleView)
        hostingView.setFrameSize(hostingView.fittingSize)

        let w = min(max(hostingView.fittingSize.width, 240), 380)
        let contentH = min(max(hostingView.fittingSize.height, 40), 200)
        let h = min(contentH + 20, 220)

        let panel = makePanel(relativeTo: button, width: w, contentHeight: contentH, panelHeight: h)
        panel.ignoresMouseEvents = true
        panel.contentView = hostingView

        panel.orderFrontRegardless()
        self.panel = panel
        self.viewModel = vm

        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                vm.isVisible = true
            }
        }

        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.animateOut()
            }
        }
    }

    public func showPermission(
        title: String = "Claude Code",
        message: String,
        relativeTo button: NSStatusBarButton?,
        duration: TimeInterval = 20.0,
        onAllow: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) {
        dismiss()

        let vm = BubbleViewModel()
        let bubbleView = GlassPermissionView(
            title: title,
            message: message,
            viewModel: vm,
            onAllow: { [weak self] in
                onAllow()
                self?.dismiss()
            },
            onDeny: { [weak self] in
                onDeny()
                self?.dismiss()
            }
        )
        let hostingView = NSHostingView(rootView: bubbleView)
        hostingView.setFrameSize(hostingView.fittingSize)

        let w = min(max(hostingView.fittingSize.width, 260), 420)
        let contentH = min(max(hostingView.fittingSize.height, 90), 260)
        let h = min(contentH + 20, 280)

        let panel = makePanel(relativeTo: button, width: w, contentHeight: contentH, panelHeight: h)
        panel.ignoresMouseEvents = false
        panel.contentView = hostingView

        panel.orderFrontRegardless()
        self.panel = panel
        self.viewModel = vm

        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.35, bounce: 0.12)) {
                vm.isVisible = true
            }
        }

        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.animateOut()
            }
        }
    }

    private func makePanel(relativeTo button: NSStatusBarButton?, width: CGFloat, contentHeight: CGFloat, panelHeight: CGFloat) -> NSPanel {
        let windowRect: NSRect
        if let button, let buttonWindow = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(buttonRect)
            let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            var x = screenRect.midX - width / 2
            var y = screenRect.minY - panelHeight - 8
            if let frame = screenFrame {
                x = min(max(x, frame.minX + 8), frame.maxX - width - 8)
                y = max(frame.minY + 8, y)
            }
            windowRect = NSRect(x: x, y: y, width: width, height: panelHeight)
        } else if let screenFrame = NSScreen.main?.visibleFrame {
            windowRect = NSRect(
                x: screenFrame.maxX - width - 24,
                y: screenFrame.maxY - panelHeight - 24,
                width: width,
                height: panelHeight
            )
        } else {
            windowRect = NSRect(x: 100, y: 100, width: width, height: panelHeight)
        }

        let panel = NSPanel(
            contentRect: windowRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovable = false
        panel.level = .statusBar
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }

    private func animateOut() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let vm = viewModel, let panel = panel else { return }
        withAnimation(.easeIn(duration: 0.25)) {
            vm.isVisible = false
        }
        let panelRef = panel
        self.panel = nil
        self.viewModel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            panelRef.orderOut(nil)
        }
    }

    public func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
        viewModel = nil
    }
}

private final class BubbleViewModel: ObservableObject, @unchecked Sendable {
    @Published var isVisible = false
}

private struct GlassBubbleBase<Content: View>: View {
    @ObservedObject var viewModel: BubbleViewModel
    let content: Content

    init(viewModel: BubbleViewModel, @ViewBuilder content: () -> Content) {
        self.viewModel = viewModel
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .opacity(viewModel.isVisible ? 1 : 0)
            .offset(y: viewModel.isVisible ? 0 : -14)
    }
}

private struct GlassNotificationView: View {
    let title: String
    let message: String
    @ObservedObject var viewModel: BubbleViewModel

    var body: some View {
        GlassBubbleBase(viewModel: viewModel) {
            VStack(alignment: .leading, spacing: 2) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(6)
            }
            .frame(minWidth: 240, maxWidth: 380, maxHeight: 220)
        }
    }
}

private struct GlassPermissionView: View {
    let title: String
    let message: String
    @ObservedObject var viewModel: BubbleViewModel
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        GlassBubbleBase(viewModel: viewModel) {
            VStack(alignment: .leading, spacing: 10) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(6)

                HStack(spacing: 8) {
                    Button("Deny") { onDeny() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.large)
                        .frame(minWidth: 84, minHeight: 34)

                    Button("Allow") { onAllow() }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.large)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(minWidth: 260, maxWidth: 420, maxHeight: 260, alignment: .leading)
        }
    }
}
