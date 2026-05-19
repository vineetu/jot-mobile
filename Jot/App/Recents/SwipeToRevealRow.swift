import SwiftUI

struct SwipeToRevealRow<Content: View>: View {
    private enum DragAxis: Equatable {
        case undecided
        case horizontal
        case vertical
    }

    private let revealedWidth: CGFloat
    private let onDelete: () -> Void
    private let content: () -> Content

    @Binding private var isSelectionMode: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offsetX: CGFloat = 0
    @State private var isRevealed = false
    @State private var dragAxis: DragAxis = .undecided
    @State private var dragActivated = false
    @State private var dragActivationResetTask: Task<Void, Never>?

    init(
        revealedWidth: CGFloat = 80,
        isSelectionMode: Binding<Bool> = .constant(false),
        onDelete: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.revealedWidth = revealedWidth
        self._isSelectionMode = isSelectionMode
        self.onDelete = onDelete
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            content()
                .offset(x: offsetX)
                .allowsHitTesting(!dragActivated)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(dragGesture)
        .overlay(alignment: .trailing) {
            deleteButton
                .frame(width: revealedWidth)
                .offset(x: max(0, revealedWidth + offsetX))
                .allowsHitTesting(isRevealed && !isSelectionMode)
        }
        .overlay {
            if isRevealed && !isSelectionMode {
                collapseTapSurface
            }
        }
        .clipped()
        .onChange(of: isSelectionMode) { _, isSelectionMode in
            if isSelectionMode {
                collapse(animated: false)
                resetDragActivation()
            }
        }
        .onDisappear {
            dragActivationResetTask?.cancel()
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            collapse()
            onDelete()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                Text("Delete")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .frame(width: revealedWidth)
            .frame(maxHeight: .infinity)
            .background(Color(.systemRed))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete")
        .accessibilityAddTraits(.isButton)
    }

    private var collapseTapSurface: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    collapse()
                }
                .simultaneousGesture(dragGesture)

            Color.clear
                .frame(width: revealedWidth)
                .allowsHitTesting(false)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !isSelectionMode else { return }

                let dx = value.translation.width
                let dy = value.translation.height
                let absX = abs(dx)
                let absY = abs(dy)

                switch dragAxis {
                case .undecided:
                    guard absX > 10 || absY > 10 else { return }
                    if absX > absY && absX > 10 {
                        dragAxis = .horizontal
                    } else {
                        dragAxis = .vertical
                        return
                    }
                case .vertical:
                    return
                case .horizontal:
                    break
                }

                let baseOffset = isRevealed ? -revealedWidth : 0
                let nextOffset = min(0, max(-revealedWidth, baseOffset + dx))
                offsetX = nextOffset

                if abs(nextOffset) > 10 || absX > 10 {
                    activateHorizontalDrag()
                }
            }
            .onEnded { value in
                defer {
                    if dragAxis == .horizontal {
                        scheduleDragActivationReset()
                    } else {
                        resetDragActivation()
                    }
                    dragAxis = .undecided
                }
                guard dragAxis == .horizontal else { return }

                let baseOffset = isRevealed ? -revealedWidth : 0
                let projectedOffset = min(
                    0,
                    max(-revealedWidth, baseOffset + value.predictedEndTranslation.width)
                )
                let shouldReveal = offsetX <= -revealedWidth * 0.5
                    || projectedOffset <= -revealedWidth * 0.45

                setRevealed(shouldReveal)
            }
    }

    private func activateHorizontalDrag() {
        dragActivationResetTask?.cancel()
        dragActivationResetTask = nil
        dragActivated = true
    }

    private func scheduleDragActivationReset() {
        dragActivationResetTask?.cancel()
        dragActivationResetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            dragActivated = false
            dragActivationResetTask = nil
        }
    }

    private func resetDragActivation() {
        dragActivationResetTask?.cancel()
        dragActivationResetTask = nil
        dragActivated = false
    }

    private func collapse(animated: Bool = true) {
        setRevealed(false, animated: animated)
    }

    private func setRevealed(_ revealed: Bool, animated: Bool = true) {
        let updates = {
            isRevealed = revealed
            offsetX = revealed ? -revealedWidth : 0
        }

        if animated && !reduceMotion {
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.86)) {
                updates()
            }
        } else {
            updates()
        }
    }
}
