# Plan: Transcript Classifier (Background, Charging-Only)

> **Status:** Build 12 (1.0.2). Dark-launched — code ships in every build, scheduling gated behind a Lab toggle that defaults OFF. Vineet flips it on his device for early validation. Public users never opt in (no incentive — the category is invisible to them in v1).
> **Size: M** (~½ day, dominated by schema V4 + BG task plumbing + Lab Settings UI).

---

## Intent

Tag each transcript with one of `email | message | note | code | general` so we can later build a per-category style-personalization model. v1 is the **classification layer only** — no UI surfacing, no fine-tuning, no eval. Just accumulate a tagged corpus on every user's device.

The "Build N before N+1" rule from the working plan doc (`Personalized Dictation Style`) puts the classifier first. Future builds layer on top:
1. **Build 12 (this PR):** classifier + accumulating corpus.
2. **Future:** Mac bake-off (does style LoRA beat a prompt baseline?).
3. **Future:** On-device LoRA training in `BGProcessingTask`.

If step 2 fails, the corpus + classifier still pay rent as a routing input to context-aware rewrite prompts.

---

## Scope (v1)

### In

- Schema V4: `category: String?` on `Transcript` (nil = unclassified).
- `TranscriptClassifier` service: prompts Qwen 3.5 4B with a structured-output JSON template, parses, gates on a confidence-gap threshold, returns one of the five categories or `general`.
- `BGProcessingTask` registered for identifier `com.vineetu.jot.mobile.Jot.classify-transcripts`. `requiresExternalPower = true` so iOS schedules it during charging windows.
- Task handler: fetches untagged transcripts in batches of ~25, classifies each, saves. Honors `expirationHandler` for mid-batch checkpoint.
- Diagnostics: every fire logs to `DiagnosticsLog` with queue depth, processed count, exit reason.
- Lab Settings section at the bottom of `SettingsView` with one toggle: "Background transcript classifier — experimental." Bound to `UserDefaults` key `jot.classifier.enabled`, default `false`.

### Out (deferred)

- Any UI surface that shows the category to the user.
- Re-classification of transcripts that change (e.g., after Edit). v1 classifies once; later edits don't re-trigger.
- Multi-shot ensemble (3 classifications for vote). v1 is single-shot.
- Apple Foundation Models or BART-MNLI fallback. v1 is Qwen-only.
- Memory entitlement (`com.apple.developer.kernel.increased-memory-limit`). Add if telemetry shows OOM.

---

## Why Qwen 3.5 4B (already on-device)

- Zero new model download. We just shipped backup-exclusion work specifically to avoid bloating user backups with FluidAudio weights; adding BART-MNLI (~400MB) would compound that.
- Reuses the existing `LLMClientFactory.shared.client()` `rewrite(text:systemPrompt:)` API — no new MLX wiring.
- "Confidence" via gap_score returned by the model itself is calibration-suspect, but combined with a 0.3 gap threshold and "fall back to general" semantics, the failure mode is conservative (default to general, not assign a wrong category).
- If field telemetry shows quality is bad, graduate to BART-MNLI or Apple FM in a later build.

---

## Risks (testable, not theoretical)

### Risk 1: BG task OOM on Qwen cold-load

Qwen 4B weights ~2.5 GB on disk, ~2-3 GB in RAM when loaded. In normal app use Qwen is warm when the user opens the app for Rewrite. In a BG task, the app may have been backgrounded for hours and Qwen is evicted. The task wakes, tries to cold-load Qwen, iOS may terminate for memory pressure.

**Mitigation v1:** ship instrumented and watch. Every BG task fire logs whether it OOM'd. If it consistently does, escalate:
- Add `com.apple.developer.kernel.increased-memory-limit` entitlement (foreground-only — doesn't help BG).
- Switch to Apple Foundation Models (~3B, system-managed, probably more memory-efficient in BG).
- Switch to BART-MNLI (~400MB, plenty of memory budget).

### Risk 2: BG task never fires

iOS opportunistic scheduling means the task may fire rarely or never on some devices (locked phone never charged, etc.). Backlog accumulates forever.

**Mitigation v1:** ship instrumented. Diagnostic log records every fire. After a week of real use, we'll know firing patterns.

**Fallback later:** if firing patterns are too sparse, add a "Classify now" button in Lab Settings that triggers a foreground sweep when the user explicitly taps it.

### Risk 3: Classification quality

Qwen self-reported `gap` is a poor proxy for true confidence. v1's 0.3 threshold is a guess. If the field consistently misclassifies or over-fires "general," we tune the threshold or move to ensemble-of-3.

**Mitigation v1:** Vineet eyeballs his own results on his device. We don't ship the category UI until quality holds.

---

## Data model — Schema V4

Following `Jot/CLAUDE.md` schema discipline. Add `JotSchemaV4.swift` (copy of V3 + new field), append lightweight V3→V4 migration to `JotMigrationPlan`.

```swift
@Model
final class Transcript {
    // ... V3 fields, identical ...

    /// Background classifier's category assignment. `nil` = unclassified
    /// (the default for fresh dictations and pre-V4-upgrade rows).
    /// One of `email | message | note | code | general` when classified.
    /// The classifier writes this from a BGProcessingTask; nothing else
    /// reads it in v1 except future research / corpus-building.
    var category: String?
}
```

V4→V3 downgrade is unsupported (per schema-migrations doc); user cannot install build 11 over build 12.

---

## Classifier prompt template (v1)

```
You are classifying user dictation transcripts into one of these categories:
- email: drafting or composing an email
- message: short message / SMS / Slack / chat
- note: personal note, journal, todo, reminder
- code: programming, technical content, code-like text
- general: anything that doesn't clearly fit above

Read this transcript and pick the category that fits best.

Output ONLY valid JSON, no commentary, in this exact shape:
{"top": "category_name", "second": "alternate_category", "gap": 0.0}

Where:
- "top" is the best-fit category from the list above
- "second" is the second-best category (or "general" if none)
- "gap" is your estimate, 0.0-1.0, of how much "top" beats "second" 
  (0.0 = tied, 1.0 = top is overwhelmingly correct)

Transcript:
"""
{transcript text}
"""
```

Parsing rules:
- Extract first `{...}` JSON block from the response.
- If parse fails, return `general`.
- If `top` not in the five-category set, return `general`.
- If `gap < 0.3`, return `general`.
- Else return `top` as Category.

---

## BG task wiring

### Registration (`JotApp.init`)

```swift
BGTaskScheduler.shared.register(
    forTaskWithIdentifier: TranscriptClassifierTask.identifier,
    using: nil
) { task in
    Task { await TranscriptClassifierTask.run(task as! BGProcessingTask) }
}
```

### Submission (scenePhase = .background)

```swift
guard UserDefaults.standard.bool(forKey: "jot.classifier.enabled") else { return }
let request = BGProcessingTaskRequest(identifier: TranscriptClassifierTask.identifier)
request.requiresExternalPower = true
request.requiresNetworkConnectivity = false
try? BGTaskScheduler.shared.submit(request)
```

### Handler

```swift
static func run(_ task: BGProcessingTask) async {
    let log = DiagnosticsLog.shared
    let started = Date()
    var processed = 0

    let work = Task<Void, Never> {
        // 1. Fetch untagged transcripts, oldest-first.
        // 2. Loop: classify each, save, increment counter.
        // 3. Check Task.isCancelled between iters.
        // 4. Hard cap at 25 per fire to bound runtime.
    }

    task.expirationHandler = {
        work.cancel()
        log.append("[CLASSIFY] expired after \(Date().timeIntervalSince(started))s, processed=\(processed)")
        task.setTaskCompleted(success: false)
    }

    await work.value
    log.append("[CLASSIFY] completed in \(Date().timeIntervalSince(started))s, processed=\(processed)")
    task.setTaskCompleted(success: true)

    // Re-schedule next fire so the chain continues if backlog remains.
    Self.schedule()
}
```

### Backlog handling

First fire processes ALL untagged rows (yours, Vineet's existing corpus). Hard cap 25 per fire bounds wall-clock. Task re-schedules itself at the end if more work remains, so subsequent charging windows drain the queue.

### Info.plist

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.vineetu.jot.mobile.Jot.classify-transcripts</string>
</array>
<key>UIBackgroundModes</key>
<array>
    <string>processing</string>
</array>
```

---

## Lab Settings UI

A new section at the bottom of `SettingsView`:

```
LAB FEATURES — EXPERIMENTAL
[ Background transcript classifier      [ off / on ] ]
   Tags each dictation as email/message/note/code/general
   when your iPhone is charging. Currently invisible — used
   for future personalization research. On-device only.
```

Toggle binds to `UserDefaults.standard.bool(forKey: "jot.classifier.enabled")`. Default `false`. Flipping ON immediately submits the first `BGProcessingTaskRequest` (so the user doesn't have to wait for a backgrounding event to bootstrap the chain).

---

## Diagnostics

Every BG task fire writes to `DiagnosticsLog.shared`:

```
[CLASSIFY] start queueDepth=12
[CLASSIFY] item id=ABC text-chars=234 -> email gap=0.42 (1.8s)
[CLASSIFY] item id=DEF text-chars=89 -> general (parse-failed)
...
[CLASSIFY] completed in 47s, processed=12, remaining=0
```

User can dump this log via Settings → Diagnostics (existing feature). Lets Vineet inspect classifier behavior without instrumented Xcode.

---

## Schema impact summary

- **Add/remove/rename `@Model` fields?** Add ONE field (`category: String?`) to `Transcript`. No removes, no renames.
- **Add new `@Model` entities?** No.
- **MigrationStage:** `.lightweight` V3 → V4.

---

## Verification

- **Build clean:** xcodebuild compiles for iOS Simulator + device.
- **Toggle OFF baseline:** with Lab toggle off, no BG task ever submitted (verify via BGTaskScheduler debug print or by absence of `[CLASSIFY]` log lines).
- **Toggle ON, backgrounded, plugged in overnight:** wake up, dump diagnostics log, expect `[CLASSIFY]` lines with classified categories.
- **Inspect DB:** open the SwiftData store (or check a debug Settings row that counts `category != nil`) to confirm rows got tagged.
- **Schema upgrade test:** install build 11 (V3) over build 12 (V4) is unsupported; install build 12 over build 11 should load existing transcripts cleanly. Watch Console.app for `[SCHEMA-FALLBACK]`.

---

## What changes in `features.md`

Nothing public-facing. The classifier is invisible in v1. If/when we surface the category, we add a §13.x privacy disclosure that the category is classified on-device for personalization research and never leaves the phone.
