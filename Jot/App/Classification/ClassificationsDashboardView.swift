import SwiftUI
import SwiftData

/// Lab dashboard listing every transcript grouped by its classifier
/// category, with a per-row chip the user can tap to override.
///
/// Pushed from Settings → Lab features → "View classifications." Only
/// makes sense when the Lab toggle is on, but the view itself doesn't
/// re-check — Settings gates the row visibility, and dropping into a
/// stale dashboard via deep-link would still show empty buckets without
/// breaking anything.
///
/// Reads via `@Query` so SwiftData repopulates the list automatically
/// when:
/// - The BG task writes a category to a row (drains "Unclassified").
/// - The user changes a category via the chip (moves a row between
///   sections).
@available(iOS 26.0, *)
struct ClassificationsDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Transcript.createdAt, order: .reverse)
    private var transcripts: [Transcript]

    /// Mirror of the Lab toggle so the dashboard auto-dismisses when the
    /// user flips classification off while viewing. Without this, the
    /// pushed view stays alive (and mutating SwiftData via tapped chips)
    /// even though the entry point in Settings has hidden itself.
    @State private var classifierEnabled: Bool = AppGroup.defaults.bool(
        forKey: TranscriptClassifierTask.labKey
    )

    /// Live foreground-classification state. `nil` when no run is in
    /// flight. Set as `(current, total)` while a run is in progress so
    /// the header can render "Classifying 3 of 12…" + a Cancel button.
    @State private var classifyProgress: (current: Int, total: Int)?

    /// Handle for the foreground classification Task. Allows the Cancel
    /// button to break the in-flight loop. Set to nil when the run
    /// completes or is cancelled.
    @State private var classifyTask: Task<Void, Never>?

    /// Live memory readout (used + available MB). Refreshed every ~2s
    /// while the view is on-screen. Lets Vineet correlate the resident
    /// peak with classify behavior — and serves as visual confirmation
    /// that the pre-classify evicts actually drop weight before Qwen
    /// warms.
    @State private var memorySample: MemoryProbeSample?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerRow

                ForEach(bucketsInDisplayOrder, id: \.self) { bucket in
                    let rows = clusters[bucket] ?? []
                    if !rows.isEmpty {
                        bucketSection(label: bucket, rows: rows)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 32)
        }
        .background(
            WallpaperBackground().ignoresSafeArea()
        )
        .navigationTitle("Classifications")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Re-read the Lab toggle when defaults change. AppGroup posts
            // its own didChange when the toggle is flipped from Settings;
            // observing standard NotificationCenter catches both keys.
            let newValue = AppGroup.defaults.bool(forKey: TranscriptClassifierTask.labKey)
            if newValue != classifierEnabled {
                classifierEnabled = newValue
                if !newValue {
                    // User flipped Lab off while this view was pushed.
                    // Auto-pop so they can't keep mutating categories
                    // from a "stale" entry point. Cancel any running
                    // classification job so we don't leak it.
                    cancelClassify()
                    dismiss()
                }
            }
        }
        .onDisappear {
            // Stop any in-flight foreground classification when the user
            // navigates back. The Task captures `transcripts` (an array
            // of managed objects) and `modelContext`; letting it run
            // after the view is torn down would keep the chain alive
            // until completion, holding refs we no longer need.
            cancelClassify()
        }
        .task {
            // Cheap periodic poll for the memory readout in the header.
            // 2-second cadence is enough to see the pre-classify shed
            // and the post-classify return-to-baseline without burning
            // CPU on idle re-renders.
            memorySample = MemoryProbe.sample()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                memorySample = MemoryProbe.sample()
            }
        }
        // NOTE: we used to observe `UIApplication.didReceiveMemoryWarningNotification`
        // here and auto-cancel the classify run on the first warning.
        // Empirically that was too eager: iOS sends a memory warning
        // *during* Qwen's initial ~2.5 GB load (a routine event for any
        // model warm), so the observer fired before item 1 could even
        // complete — net effect: "tap Classify, nothing happens."
        // AI Rewrite works fine without this layer; it trusts iOS to
        // jetsam if it must and runs through. We do the same now.
        // Parakeet's own memory-warning handler still sheds independently
        // (`TranscriptionService.handleMemoryWarning`), which is the
        // load-bearing part of the safety net.
    }

    // MARK: - Header

    private var headerRow: some View {
        // Single pass over the array to compute total + classified +
        // unclassified counts — avoids the 3-pass version the prior
        // implementation had (filter+filter+grouping all re-running on
        // every body render). Re-renders happen frequently here:
        // `@Query` refreshes after every BG-task save during a drain.
        var total = 0
        var classified = 0
        var unclassifiedCount = 0
        for t in transcripts {
            total += 1
            if let cat = t.category, !cat.isEmpty {
                classified += 1
            } else {
                unclassifiedCount += 1
            }
        }

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(classified) of \(total) classified")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.jotPageInk)
                Text("Tap a chip to change a transcript's category. Manual changes stop the classifier from re-running on that row.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.jotPageInkSecondary)
            }

            memoryReadout

            classifyNowControl(unclassifiedCount: unclassifiedCount)
        }
        .padding(.top, 16)
    }

    /// Live "memory in use · available" caption + color-coded pressure
    /// dot. Refreshed every 2s by the `.task` higher up. Hidden until
    /// the first sample lands (typically <100ms post-mount) so we
    /// don't flash a "0 MB" stub.
    @ViewBuilder
    private var memoryReadout: some View {
        if let sample = memorySample {
            HStack(spacing: 8) {
                Circle()
                    .fill(memoryPressureColor(sample.pressure))
                    .frame(width: 8, height: 8)
                Text("Memory: \(Int(sample.usedMB)) MB used · \(Int(sample.availableMB)) MB available")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.jotPageInkSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.jotMuteWeak.opacity(0.10))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Memory \(Int(sample.usedMB)) megabytes used, \(Int(sample.availableMB)) megabytes available, pressure \(memoryPressureAccessibility(sample.pressure))"
            )
        }
    }

    private func memoryPressureColor(_ level: MemoryProbeSample.PressureLevel) -> Color {
        switch level {
        case .comfortable: return Color(red: 0.30, green: 0.70, blue: 0.40)
        case .tight:       return Color(red: 0.95, green: 0.65, blue: 0.20)
        case .critical:    return Color(red: 0.90, green: 0.25, blue: 0.25)
        }
    }

    private func memoryPressureAccessibility(_ level: MemoryProbeSample.PressureLevel) -> String {
        switch level {
        case .comfortable: return "comfortable"
        case .tight:       return "tight"
        case .critical:    return "critical"
        }
    }

    /// Foreground "Classify now" CTA, with progress + Cancel while a run
    /// is in flight. Hidden when there's nothing untagged.
    ///
    /// Foreground classification side-steps the BG task's charging
    /// requirement — useful when the user wants to see results NOW
    /// rather than wait for iOS's opportunistic scheduling. The BG
    /// task remains and is still the steady-state path; this is the
    /// "trigger immediately" affordance.
    @ViewBuilder
    private func classifyNowControl(unclassifiedCount: Int) -> some View {
        if let progress = classifyProgress {
            // Running state.
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Classifying \(progress.current) of \(progress.total)…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.jotPageInk)
                Spacer(minLength: 8)
                Button("Cancel") {
                    cancelClassify()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(.systemRed))
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel classification")
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.jotBlueTop.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.jotBlueTop.opacity(0.18), lineWidth: 0.5)
            )
        } else if unclassifiedCount > 0 {
            let weightsReady = LLMClientFactory.shared.currentProviderWeightsOnDisk
            if weightsReady {
                Button {
                    kickoffClassifyAll()
                } label: {
                    classifyCTALabel(
                        text: "Classify \(unclassifiedCount) unclassified now",
                        tint: Color.jotBlueTop,
                        textColor: .white
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Classify \(unclassifiedCount) unclassified transcripts now")
            } else {
                // No Qwen weights yet — route the user to AI Settings
                // where they can download. A plain disabled button is
                // a dead-end (per build 13 review #8); make it a real
                // link so the affordance has an action.
                NavigationLink {
                    AIRewriteSettingsView()
                } label: {
                    classifyCTALabel(
                        text: "Download Qwen to classify — open AI Settings",
                        tint: Color.jotMuteWeak.opacity(0.18),
                        textColor: Color.jotInk
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open AI Settings to download Qwen for classification")
            }
        }
    }

    /// Shared label shape for the Classify CTA — used by both the
    /// enabled (kicks foreground classifier) and disabled
    /// (routes to AI Settings) variants so the row looks the same and
    /// only the action differs.
    @ViewBuilder
    private func classifyCTALabel(text: String, tint: Color, textColor: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint)
        )
    }

    /// Kicks off foreground classification over every untagged row in
    /// the current `@Query` snapshot. Updates `classifyProgress` as
    /// each item completes so the header re-renders. Honors
    /// `Task.isCancelled` so the Cancel button breaks the loop cleanly.
    /// Kicks off a classify run over EVERY untagged transcript in the
    /// current `@Query` snapshot. Used by the top-of-dashboard
    /// "Classify N unclassified now" CTA. Equivalent to calling
    /// `kickoffClassify(untagged: <every nil-category transcript>)`.
    private func kickoffClassifyAll() {
        let untagged = transcripts.filter { ($0.category ?? "").isEmpty }
        kickoffClassify(untagged: untagged)
    }

    /// Kicks off a classify run for a single transcript. Invoked by the
    /// per-row "Classify automatically" affordances: (A) the entry at
    /// the top of `CategoryChip`'s menu when category is nil, and (B)
    /// the wand button rendered to the right of the chip on
    /// unclassified rows. Uses the SAME safeguard machinery as the
    /// bulk path — pre-evict, in-flight flag, between-iter evict,
    /// memory-warning observer — so a one-off classify is just as
    /// jetsam-safe as a bulk drain.
    private func kickoffClassifyOne(_ transcript: Transcript) {
        kickoffClassify(untagged: [transcript])
    }

    private func kickoffClassify(untagged: [Transcript]) {
        guard !untagged.isEmpty else { return }
        guard classifyTask == nil else { return } // single run at a time

        let total = untagged.count
        classifyProgress = (current: 0, total: total)

        // Pre-evict every transcription subsystem BEFORE warming Qwen.
        // Empirical (build 16/17 telemetry): Parakeet 600M v2 (~2 GB
        // resident) + Qwen 4B (~3 GB) + any incidental Apple FM /
        // streaming-prepare state co-resident peaks around 5 GB and
        // trips iOS jetsam on 6 GB iPhones. The Lab classifier is an
        // explicit "give Qwen the whole budget" run, so we shed
        // everything else first.
        //   - Batch Parakeet manager: ~2 GB. Released here.
        //   - Streaming Parakeet prepare task: tiny on its own but
        //     cancellable, so we cancel.
        //   - Apple Foundation Models: sessions are call-scoped
        //     (created and dropped inside CleanupService methods),
        //     so no service-level state to clear here.
        // All evictions refuse to run mid-dictation via their own
        // !isTranscribing guards.
        TranscriptionService.shared.evictForExternalRequest(reason: "classifier-foreground-start")
        Task { @MainActor in
            await StreamingTranscriptionService.shared.evictForExternalRequest(reason: "classifier-foreground-start")
        }

        DiagnosticsLog.record(
            source: "main-app",
            category: .classifyStart,
            message: "Foreground classify run started",
            metadata: [
                "itemCount": "\(total)",
                "evictedBatch": "\(true)",
                "evictedStreaming": "\(true)",
            ]
        )

        // Clear any stale cancel-request flag from a prior run. Without
        // this reset, the first inference would terminate immediately
        // when re-firing soon after a Cancel.
        AppGroup.rewriteCancelRequested = false

        // Mutex with the BG task. Set BEFORE spawning the inner Task so
        // an immediate scenePhase.background firing `submitIfEnabled()`
        // sees the flag. Cleared in defer regardless of exit path
        // (completion, cancel, throw).
        AppGroup.defaults.set(true, forKey: AppGroup.Keys.classifierForegroundInFlight)

        classifyTask = Task { @MainActor in
            var endReason = "completed"
            var processedCount = 0
            defer {
                DiagnosticsLog.record(
                    source: "main-app",
                    category: .classifyEnd,
                    message: "Foreground classify run ended",
                    metadata: [
                        "reason": endReason,
                        "processed": "\(processedCount)",
                        "planned": "\(total)",
                    ]
                )
                classifyProgress = nil
                classifyTask = nil
                AppGroup.defaults.set(false, forKey: AppGroup.Keys.classifierForegroundInFlight)
            }

            for (index, row) in untagged.enumerated() {
                if Task.isCancelled {
                    endReason = "cancelled"
                    return
                }
                classifyProgress = (current: index + 1, total: total)

                let category = await TranscriptClassifier.classify(text: row.text)

                // Re-check cancel after the (long) classify call before
                // mutating storage — a user-cancel mid-classify shouldn't
                // also persist a result they were trying to skip.
                if Task.isCancelled {
                    endReason = "cancelled"
                    return
                }

                // Stickiness guard: the user may have tapped CategoryChip
                // on this row during the 2-5s classify await and chosen a
                // category manually. The chip's menu writes via the same
                // modelContext, so by the time we land here `row.category`
                // could already be non-nil. Overwriting it would silently
                // clobber the user's deliberate pick. Mirrors the
                // `category == nil` predicate that gates the BG drainBatch.
                guard row.category == nil else { continue }

                row.category = category.rawValue
                do {
                    try modelContext.save()
                    processedCount += 1
                } catch {
                    modelContext.rollback()
                }

                // Jetsam safeguard: evict Qwen between iterations so MLX's
                // KV cache + intermediate buffers don't accumulate across
                // calls. Without this, the app gets killed by iOS after
                // 3-6 classifications when total resident hits the jetsam
                // threshold (~1-1.5 GB on most iPhones). The cost is a
                // cold reload (~3-5s) on the next iteration's warm(),
                // but stability beats speed for a Lab feature the user
                // explicitly opts into.
                //
                // Resolve the client fresh each iter (instead of capturing
                // once at the top of the run) so a mid-loop provider
                // switch evicts the new client. Unreachable in 1.0.2
                // because Qwen is the only provider, but the lookup
                // cost is zero — future-proofing now is free.
                await LLMClientFactory.shared.client().evict()

                // Yield the runloop so SwiftUI gets a chance to redraw
                // (the progress text) and any pending tap handlers can
                // fire. Without this the run hogs the main actor end
                // to end and the Cancel button feels frozen.
                await Task.yield()
            }
        }
    }

    /// Cancels the in-flight classify run. Sets the App Group
    /// "rewrite cancel requested" flag so an in-flight Qwen inference
    /// terminates promptly (the Qwen35Client polls this flag during
    /// streaming generation), then cancels the Swift Task itself so
    /// the loop bails without queueing another classify call. Without
    /// the App Group flag, Cancel would wait up to ~5s for the current
    /// inference to complete naturally before the post-await
    /// `Task.isCancelled` check fires.
    private func cancelClassify() {
        AppGroup.rewriteCancelRequested = true
        classifyTask?.cancel()
    }

    // MARK: - Section per bucket

    /// Canonical buckets in the order they appear on the dashboard.
    /// "Unclassified" lives at the bottom — it's a queue, not a useful
    /// category, so the user's eye lands on what's already tagged first.
    private var bucketsInDisplayOrder: [String] {
        ["email", "message", "note", "code", "general", "unclassified"]
    }

    private var clusters: [String: [Transcript]] {
        Dictionary(grouping: transcripts) { t in
            (t.category?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "unclassified"
        }
    }

    @ViewBuilder
    private func bucketSection(label: String, rows: [Transcript]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(sectionLabel(for: label))
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Color.jotPageInkCaption)
                Text("\(rows.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jotPageInkSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)

            LiquidGlassCard(paddingH: 0, paddingV: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                        transcriptRow(row)
                        if idx < rows.count - 1 {
                            Rectangle()
                                .fill(Color.jotPageSeparator)
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    private func sectionLabel(for raw: String) -> String {
        switch raw {
        case "email":        return "EMAIL"
        case "message":      return "MESSAGE"
        case "note":         return "NOTE"
        case "code":         return "CODE"
        case "general":      return "GENERAL"
        case "unclassified": return "UNCLASSIFIED"
        default:             return raw.uppercased()
        }
    }

    // MARK: - Per-transcript row

    @ViewBuilder
    private func transcriptRow(_ transcript: Transcript) -> some View {
        // Critical layout note: the CategoryChip's Menu cannot live inside
        // a NavigationLink's label closure — SwiftUI's tap routing collapses
        // Menu taps into the link's "navigate" action, so the picker never
        // opens and the user pushes Detail instead. Splitting into two
        // siblings (NavigationLink for text region, Chip as a sibling on
        // the trailing edge) gives each control its own hit target.
        let isUntagged = (transcript.category ?? "").isEmpty
        let weightsReady = LLMClientFactory.shared.currentProviderWeightsOnDisk
        let canAutoClassify = isUntagged && weightsReady && classifyTask == nil

        HStack(alignment: .top, spacing: 8) {
            NavigationLink {
                TranscriptDetailView(transcript: transcript)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(rowPreview(transcript))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.jotPageInk)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(transcript.createdAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.jotPageInkCaption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            CategoryChip(
                transcript: transcript,
                shape: .dashboardRow,
                onAutoClassify: canAutoClassify
                    ? { kickoffClassifyOne(transcript) }
                    : nil
            )
            .fixedSize(horizontal: true, vertical: false)

            // Wand button — "let the model classify this single row."
            // Same per-row action as the chip's menu entry; surfacing
            // it as a visible button is more discoverable than burying
            // it inside the menu. Hidden when the row already has a
            // category (no auto-classify needed) OR when classify is
            // in flight (would race the active run).
            if canAutoClassify {
                Button {
                    kickoffClassifyOne(transcript)
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.jotBlueTop)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(Color.jotBlueTop.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Classify this transcript automatically")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func rowPreview(_ transcript: Transcript) -> String {
        let source = transcript.rewriteUserEdit
            ?? transcript.cleanedText
            ?? transcript.text
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 140 { return trimmed }
        let prefix = trimmed.prefix(140)
        return "\(prefix)…"
    }
}
