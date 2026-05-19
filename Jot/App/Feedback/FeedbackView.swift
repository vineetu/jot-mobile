//
//  FeedbackView.swift
//  Jot
//

import SwiftUI

struct FeedbackView: View {
    /// Submission state for the form. Mirrors the four phases described in
    /// the design: idle (typing), sending (request in flight), sent (success
    /// with the server-assigned id), error (inline failure message).
    private enum SubmissionState: Equatable {
        case idle
        case sending
        case sent(Int)
        case error(String)
    }

    @State private var message: String = ""
    @State private var state: SubmissionState = .idle
    @FocusState private var editorFocused: Bool

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var submitDisabled: Bool {
        // Empty (after trim) AND not currently sending → disabled.
        if case .sending = state { return false }
        return trimmedMessage.isEmpty
    }

    var body: some View {
        ZStack {
            WallpaperBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heading
                    subhead
                    editorCard
                    statusRow
                    submitButton
                    if case .sent = state {
                        sendAnotherButton
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Send feedback")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Auto-focus the editor on first appear so the user can start
            // typing immediately. Gated to idle so re-appearing after a
            // successful send doesn't re-steal focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if case .idle = state {
                    editorFocused = true
                }
            }
        }
    }

    // MARK: - Pieces

    private var heading: some View {
        Text("Tell us anything.")
            .font(.system(size: 38, weight: .regular, design: .serif).italic())
            .tracking(-1.4)
            .foregroundStyle(Color.jotPageInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var subhead: some View {
        Text("We read every message.")
            .font(.system(size: 15))
            .foregroundStyle(Color.jotPageInkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var editorCard: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $message)
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 220)
                .font(.system(size: 16))
                .foregroundStyle(Color.jotPageInk)
                .tint(Color.jotBlueBottom)

            if message.isEmpty {
                Text("Bugs, ideas, or anything else…")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.jotPageInkSecondary.opacity(0.7))
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(16)
        .modifier(JotDesign.Surface.regular.modifier(cornerRadius: 18))
    }

    @ViewBuilder
    private var statusRow: some View {
        switch state {
        case .idle:
            EmptyView()
        case .sending:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Sending…")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.jotPageInkSecondary)
            }
        case .sent(let id):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Sent. Thank you. (#\(id))")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.jotPageInkSecondary)
            }
        case .error(let msg):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var submitButton: some View {
        Button {
            submit()
        } label: {
            HStack(spacing: 8) {
                switch state {
                case .sending:
                    ProgressView().tint(.white)
                case .sent:
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Sent")
                default:
                    Text("Send feedback")
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                LinearGradient(
                    colors: [Color.jotBlueTop, Color.jotBlueBottom],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 27, style: .continuous)
            )
            .opacity(submitDisabled ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(submitDisabled)
    }

    private var sendAnotherButton: some View {
        Button {
            message = ""
            state = .idle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                editorFocused = true
            }
        } label: {
            Text("Send another")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.jotBlueBottom)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Submit

    private func submit() {
        let messageSnapshot = message
        state = .sending
        editorFocused = false

        Task {
            do {
                let id = try await FeedbackClient.shared.submit(message: messageSnapshot)
                await MainActor.run {
                    state = .sent(id)
                }
            } catch let err as FeedbackError {
                await MainActor.run {
                    state = .error(err.errorDescription ?? "Something went wrong. Please try again.")
                }
            } catch {
                await MainActor.run {
                    state = .error(error.localizedDescription)
                }
            }
        }
    }
}
