//
//  FeedbackView.swift
//  Jot
//

import PhotosUI
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

    /// PhotosPicker's selection model. Re-encodes whenever it changes.
    @State private var pickerItems: [PhotosPickerItem] = []
    /// Successfully loaded + JPEG-encoded screenshots ready to send.
    @State private var processedImages: [FeedbackImageEncoder.EncodedImage] = []
    /// `true` while loading + encoding picker selections off-main.
    @State private var isProcessingImages: Bool = false
    /// Non-nil if encoding failed (size cap exceeded, item load failed).
    @State private var imageError: String?
    /// In-flight encode Task. Held so a new selection can cancel the prior
    /// encode before spawning its replacement — otherwise a slow earlier
    /// encode can land AFTER a fast later one and overwrite
    /// `processedImages` with stale data (the "user picked 4 huge images,
    /// then quickly switched to 1 small one" race).
    @State private var encodeTask: Task<Void, Never>?

    /// Opt-in: append the recent diagnostic event log to the message body
    /// so support can correlate the user's report with what the app was
    /// doing. Default OFF — users have to explicitly choose to share
    /// even though the events themselves contain no transcript content
    /// or personal text.
    @State private var includeLogs: Bool = false

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var totalEncodedMB: Double {
        let bytes = processedImages.reduce(0) { $0 + $1.encodedBytes }
        return Double(bytes) / (1024 * 1024)
    }

    private var submitDisabled: Bool {
        // Disable during in-flight send so spam-tapping doesn't fire N
        // duplicate network requests before the first one returns. (The
        // post-send form clear handles the POST-success spam vector;
        // this guard handles the DURING-send vector.)
        if case .sending = state { return true }
        // Don't let the user submit while images are still being
        // encoded — the snapshot would either be empty (if the user
        // races us) or stale-partial (if we re-rendered mid-encode).
        if isProcessingImages { return true }
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
                    attachmentsRow
                    includeLogsRow
                    statusRow
                    submitButton
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
        .onChange(of: pickerItems) { _, newItems in
            // Re-encode whenever the selection changes. Cancel any prior
            // in-flight encode FIRST — a bare `Task {}` per change doesn't
            // self-cancel by reassigning state, so without this guard a
            // slow earlier encode (e.g. 4 huge images) can land after a
            // fast later one (e.g. 1 small image) and overwrite
            // `processedImages` with stale data the user thought they'd
            // de-selected. Combined with `Task.checkCancellation()` before
            // the MainActor write, this guarantees only the most recent
            // selection's result reaches the UI / submit path.
            encodeTask?.cancel()
            imageError = nil
            guard !newItems.isEmpty else {
                processedImages = []
                isProcessingImages = false
                encodeTask = nil
                return
            }
            isProcessingImages = true
            encodeTask = Task {
                do {
                    let encoded = try await FeedbackImageEncoder.process(newItems)
                    try Task.checkCancellation()
                    await MainActor.run {
                        processedImages = encoded
                        isProcessingImages = false
                    }
                } catch is CancellationError {
                    // Newer selection superseded this one — leave state to the
                    // replacement task. Don't flip `isProcessingImages` here
                    // because the replacement already set it true.
                    return
                } catch let err as FeedbackImageEncoder.EncodingError {
                    await MainActor.run {
                        imageError = err.errorDescription
                        processedImages = []
                        isProcessingImages = false
                    }
                } catch {
                    await MainActor.run {
                        imageError = error.localizedDescription
                        processedImages = []
                        isProcessingImages = false
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    private var heading: some View {
        Text("Tell us anything.")
            .font(.system(size: 38, weight: .bold, design: .default))
            .tracking(-1.4)
            .foregroundStyle(Color.jotPageInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var subhead: some View {
        Text("Attach screenshots if you're reporting a bug — they help us see what went wrong.")
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
    private var attachmentsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: FeedbackImageEncoder.maxImages,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 14, weight: .semibold))
                        Text(processedImages.isEmpty ? "Add screenshots" : "Change screenshots")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(Color.jotBlueBottom)
                }
                .disabled(isProcessingImages)

                Spacer(minLength: 0)

                if isProcessingImages {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Processing…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.jotPageInkSecondary)
                    }
                } else if !processedImages.isEmpty {
                    Text("\(processedImages.count)/\(FeedbackImageEncoder.maxImages) · \(String(format: "%.1f", totalEncodedMB)) MB")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.jotPageInkSecondary)
                }
            }

            if !processedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(processedImages) { item in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: item.thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                                    )

                                Button {
                                    removeImage(id: item.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.black.opacity(0.6))
                                        .font(.system(size: 18))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 6, y: -6)
                                .accessibilityLabel("Remove screenshot")
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            if let imageError {
                Text(imageError)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Build the diagnostic-log appendix when the user opts in. Returns
    /// an empty string if the log is empty or if the user's message has
    /// already eaten most of the 10 KB message cap. Newest entries first,
    /// truncated to fit whatever space is left.
    ///
    /// The data shape is intentionally compact and human-readable so the
    /// recipient can skim it inline in the feedback dashboard without
    /// parsing JSON. Each line: `[ISO timestamp] source/category — message {k=v, …}`.
    /// No transcript text or user-typed strings appear here — only
    /// `DiagnosticsCategory` enum values + structured metadata that
    /// `DiagnosticsLog.record(...)` callers passed (variant tags,
    /// boolean flags, character counts, reason codes).
    private func formattedDiagnosticsAppendix() -> String {
        let entries = DiagnosticsLog.readAll()
        guard !entries.isEmpty else { return "" }

        let totalCap = 10_240
        let header = "--- Diagnostic logs ---\n"
        let separator = "\n\n"
        let userBytes = message.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
        let available = totalCap - userBytes - separator.utf8.count - header.utf8.count
        guard available > 200 else { return "" }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]

        var lines: [String] = []
        var usedBytes = 0
        for entry in entries.reversed() {
            var line = "[\(formatter.string(from: entry.timestamp))] \(entry.source)/\(entry.category.rawValue) — \(entry.message)"
            if let meta = entry.metadata, !meta.isEmpty {
                let kv = meta.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
                line += " {\(kv)}"
            }
            let lineBytes = (line + "\n").utf8.count
            if usedBytes + lineBytes > available { break }
            lines.append(line)
            usedBytes += lineBytes
        }

        guard !lines.isEmpty else { return "" }
        return header + lines.joined(separator: "\n")
    }

    /// Remove a single attachment. Because PhotosPicker drives the
    /// re-encode via `.onChange(of: pickerItems)`, we drop the matching
    /// `PhotosPickerItem` and let the chain re-run with the new selection.
    /// The picker's internal selection state stays consistent — next time
    /// the user opens it, the dropped image is no longer pre-selected.
    private func removeImage(id: FeedbackImageEncoder.EncodedImage.ID) {
        guard let index = processedImages.firstIndex(where: { $0.id == id }),
              index < pickerItems.count else { return }
        pickerItems.remove(at: index)
        // processedImages is rewritten by the onChange handler.
    }

    private var includeLogsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $includeLogs) {
                Text("Include diagnostic logs")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.jotPageInk)
            }
            .toggleStyle(.switch)
            .tint(Color.jotBlueBottom)

            Text("No personal info or transcripts — just anonymous app events (recording start/stop, paste outcomes, memory warnings) to help us track down bugs.")
                .font(.system(size: 12))
                .foregroundStyle(Color.jotPageInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                default:
                    // .sent transitions to a cleared form (message + images
                    // wiped on success), so the button reverts to the default
                    // "Send feedback" label and is disabled by `submitDisabled`
                    // because the trimmed message is empty. The transient
                    // "Sent. Thank you." confirmation lives in `statusRow`
                    // and auto-clears after 15s — see submit() success path.
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

    // MARK: - Submit

    private func submit() {
        let bodySnapshot: String
        if includeLogs {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let appended = formattedDiagnosticsAppendix()
            bodySnapshot = appended.isEmpty ? trimmed : "\(trimmed)\n\n\(appended)"
        } else {
            bodySnapshot = message
        }
        let messageSnapshot = bodySnapshot
        let imagesSnapshot = processedImages.map { $0.dataURI }
        state = .sending
        editorFocused = false

        Task {
            do {
                let id = try await FeedbackClient.shared.submit(
                    message: messageSnapshot,
                    images: imagesSnapshot
                )
                await MainActor.run {
                    // Clear the form on success so the user can't tap Send
                    // repeatedly and send N duplicates of the same message.
                    // submitDisabled becomes true (empty trimmed message) the
                    // moment this runs; the green-check status row carries the
                    // confirmation by itself for the next 15 seconds.
                    state = .sent(id)
                    message = ""
                    pickerItems = []
                    processedImages = []
                    imageError = nil
                    includeLogs = false
                    editorFocused = false
                }
                // Auto-clear the success indicator after 15s so the form
                // returns to a clean idle state. Gate on the **specific**
                // submission id — if the user submitted again within the
                // 15s window and state is now `.sent(otherID)`, this
                // timer is stale and must leave the newer confirmation
                // alone. Matching `case .sent = state` (any payload) would
                // wrongly clobber the newer indicator.
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await MainActor.run {
                    if case .sent(let currentID) = state, currentID == id {
                        state = .idle
                    }
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
