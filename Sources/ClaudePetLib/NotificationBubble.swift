import AppKit
import SwiftUI

@MainActor
public final class NotificationBubble: NSObject {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var viewModel: BubbleViewModel?
    private var isShowingPermission = false

    public override init() { super.init() }

    public func show(
        title: String = "Claude Code",
        message: String,
        relativeTo button: NSStatusBarButton?,
        duration: TimeInterval = 7.0
    ) {
        guard !isShowingPermission else { return }

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
        toolInput: String = "",
        relativeTo button: NSStatusBarButton?,
        onAllow: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) {
        dismiss()
        isShowingPermission = true

        let vm = BubbleViewModel()
        let bubbleView = GlassPermissionView(
            title: title,
            message: message,
            toolInput: toolInput,
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

        let lineCount = toolInput.isEmpty ? 0 : toolInput.components(separatedBy: "\n").count
        let w: CGFloat = 360
        let baseUIHeight: CGFloat = 100
        let commandHeight = toolInput.isEmpty ? 0 : min(120, max(60, CGFloat(min(lineCount, 5)) * 14 + 40))
        let initialH = baseUIHeight + commandHeight + 40
        let h = initialH + 20

        let panel = makePanel(relativeTo: button, width: w, contentHeight: initialH, panelHeight: h)
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
    }

    public func dismissPermission() {
        guard isShowingPermission else { return }
        animateOut()
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
        isShowingPermission = false
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
        isShowingPermission = false
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
    let toolInput: String
    @ObservedObject var viewModel: BubbleViewModel
    let onAllow: () -> Void
    let onDeny: () -> Void

    @State private var isExpanded = false

    private var lineCount: Int {
        toolInput.isEmpty ? 0 : toolInput.components(separatedBy: "\n").count
    }

    private var canExpand: Bool {
        lineCount > 5
    }

    private var collapsedHeight: CGFloat {
        guard !toolInput.isEmpty else { return 0 }
        return max(60, min(120, CGFloat(min(lineCount, 5)) * 14 + 40))
    }

    private var expandedHeight: CGFloat {
        guard !toolInput.isEmpty else { return 0 }
        return max(120, min(300, CGFloat(lineCount) * 14 + 60))
    }

    private var displayText: String {
        guard !toolInput.isEmpty else { return "" }
        if isExpanded || lineCount <= 5 {
            return toolInput
        }
        return toolInput.components(separatedBy: "\n").prefix(5).joined(separator: "\n") + "\n..."
    }

    var body: some View {
        GlassBubbleBase(viewModel: viewModel) {
            VStack(alignment: .leading, spacing: 8) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if !toolInput.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Button(action: {
                            withAnimation(.snappy(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(canExpand ? "Command (\(lineCount) lines)" : "Command")
                                    .font(.system(size: 10, weight: .medium))
                                Spacer()
                                if canExpand && !isExpanded {
                                    Text("+\(lineCount - 5) more")
                                        .font(.system(size: 9, weight: .regular))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        ScrollView {
                            Text(displayText)
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: isExpanded ? expandedHeight : collapsedHeight)
                        .padding(6)
                        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                HStack(spacing: 8) {
                    Button(action: onDeny) {
                        Text("Deny")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(Color.red)
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)

                    Button(action: onAllow) {
                        Text("Allow")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(Color.green)
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: 320)
        }
    }
}
