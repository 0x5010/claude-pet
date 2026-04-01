import AppKit
import SwiftUI

public final class NotificationBubble: NSObject {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var viewModel: BubbleViewModel?

    public override init() { super.init() }

    public func show(
        title: String = "Claude Code",
        message: String,
        relativeTo button: NSStatusBarButton?,
        duration: TimeInterval = 4.0
    ) {
        dismiss()

        guard let button = button, let buttonWindow = button.window else { return }

        let vm = BubbleViewModel()
        let bubbleView = GlassBubbleView(title: title, message: message, viewModel: vm)
        let hostingView = NSHostingView(rootView: bubbleView)
        hostingView.setFrameSize(hostingView.fittingSize)

        let w = max(hostingView.fittingSize.width, 200)
        let contentH = max(hostingView.fittingSize.height, 40)
        let h = contentH + 20

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let windowRect = NSRect(
            x: screenRect.midX - w / 2,
            y: screenRect.minY - contentH - 30,
            width: w,
            height: h
        )

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
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
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
            self?.animateOut()
        }
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

// MARK: - SwiftUI Views

@available(macOS 26.0, *)
private struct GlassBubbleContent: View {
    let title: String
    let message: String
    @ObservedObject var viewModel: BubbleViewModel

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 2) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minWidth: 180, maxWidth: 260)
            .glassEffect(.clear, in: .rect(cornerRadius: 14))
        }
        .opacity(viewModel.isVisible ? 1 : 0)
        .offset(y: viewModel.isVisible ? 0 : -14)
    }
}

private struct GlassBubbleFallback: View {
    let title: String
    let message: String
    @ObservedObject var viewModel: BubbleViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: 180, maxWidth: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .opacity(viewModel.isVisible ? 1 : 0)
        .offset(y: viewModel.isVisible ? 0 : -14)
    }
}

private struct GlassBubbleView: View {
    let title: String
    let message: String
    @ObservedObject var viewModel: BubbleViewModel

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassBubbleContent(title: title, message: message, viewModel: viewModel)
        } else {
            GlassBubbleFallback(title: title, message: message, viewModel: viewModel)
        }
    }
}
