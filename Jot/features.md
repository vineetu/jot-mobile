# Jot — Product Feature Inventory

> **Scope**: User-facing features only, grouped by surface. No implementation details, file paths, class names, or framework primitives.
> **Cross-links**: Features that interact with each other are linked using anchor references.

---

## Table of Contents

- [1. Home & Library](#1-home--library)
  - [1.1 Editorial Header](#1-1-editorial-header)
  - [1.2 Transcript Library with Time Grouping](#1-2-transcript-library-with-time-grouping)
  - [1.3 Live Search](#1-3-live-search)
  - [1.4 Home Empty State](#1-4-home-empty-state)
  - [1.5 Home No-Search-Results State](#1-5-home-no-search-results-state)
  - [1.6 Floating Dictate Button](#1-6-floating-dictate-button)
  - [1.7 Transcript Row Actions](#1-7-transcript-row-actions)
  - [1.8 Help Access](#1-8-help-access)
  - [1.9 Settings Access](#1-9-settings-access)
  - [1.10 Live Recording Preview on Home](#1-10-live-recording-preview-on-home)
  - [1.11 Multi-Select & Combine](#1-11-multi-select--combine)
- [2. Recording Experience](#2-recording-experience)
  - [2.1 Full-Screen Recording Surface](#2-1-full-screen-recording-surface)
  - [2.2 Recording Status Indicator](#2-2-recording-status-indicator)
  - [2.3 Live Streaming Transcript](#2-3-live-streaming-transcript)
  - [2.4 Amplitude Waveform](#2-4-amplitude-waveform)
  - [2.5 Stop and Finalize](#2-5-stop-and-finalize)
  - [2.6 Cancel Recording](#2-6-cancel-recording)
  - [2.7 Backgrounding the Recording Surface](#2-7-backgrounding-the-recording-surface)
  - [2.8 Two-Model Transcription](#2-8-two-model-transcription)
  - [2.9 Auto-Dismiss on Completion](#2-9-auto-dismiss-on-completion)
  - [2.10 Automatic Clipboard Copy on Completion](#2-10-automatic-clipboard-copy-on-completion)
  - [2.11 Chained Follow-Up Voice Commands](#2-11-chained-follow-up-voice-commands)
  - [2.12 Accessibility: VoiceOver Focus](#2-12-accessibility-voiceover-focus)
- [3. Transcript Detail](#3-transcript-detail)
  - [3.1 Original / Rewrite Tabs](#3-1-original--rewrite-tabs)
  - [3.2 Transcript Metadata](#3-2-transcript-metadata)
  - [3.3 Selectable Text](#3-3-selectable-text)
  - [3.4 Rewrite Attribution](#3-4-rewrite-attribution)
  - [3.5 Action Bar](#3-5-action-bar)
  - [3.6 Rewrite Progress and Cancellation](#3-6-rewrite-progress-and-cancellation)
- [4. Setup Wizard](#4-setup-wizard)
  - [4.1 Welcome (W1)](#4-1-welcome-w1)
  - [4.2 Microphone Permission (W2)](#4-2-microphone-permission-w2)
  - [4.3 Keyboard Installation & Full Access (W3)](#4-3-keyboard-installation--full-access-w3)
  - [4.4 How It Works (W4)](#4-4-how-it-works-w4)
  - [4.5 Keyboard Try-It (W5)](#4-5-keyboard-try-it-w5)
  - [4.6 Warm Hold Opt-In (W6)](#4-6-warm-hold-opt-in-w6)
  - [4.7 Completion (W7)](#4-7-completion-w7)
  - [4.8 AI Rewrite Download Offer (Optional Step)](#4-8-ai-rewrite-download-offer-optional-step)
  - [4.9 Wizard Navigation Chrome](#4-9-wizard-navigation-chrome)
  - [4.10 Wizard Progress Dots](#4-10-wizard-progress-dots)
- [5. Jot Keyboard](#5-jot-keyboard)
  - [5.0 Dictation-Only Design](#5-0-dictation-only-design)
  - [5.1 Full Custom Keyboard](#5-1-full-custom-keyboard)
  - [5.2 Recents Strip (Idle State)](#5-2-recents-strip-idle-state)
  - [5.3 Streaming Strip (Recording State)](#5-3-streaming-strip-recording-state)
  - [5.4 Dictate / Stop Control](#5-4-dictate--stop-control)
  - [5.5 Post-Stop "Working" State](#5-5-post-stop-working-state)
  - [5.6 Actions Popover](#5-6-actions-popover)
  - [5.7 Backspace Hold-to-Delete](#5-7-backspace-hold-to-delete)
  - [5.8 Minimize / Expand](#5-8-minimize--expand)
  - [5.9 Dark / Light Mode Adaptation](#5-9-dark--light-mode-adaptation)
  - [5.10 Status Banner](#5-10-status-banner)
  - [5.11 Full Access Requirement](#5-11-full-access-requirement)
  - [5.12 Character Key Preview Bubble](#5-12-character-key-preview-bubble)
  - [5.13 Auto-Paste of Completed Dictation](#5-13-auto-paste-of-completed-dictation)
- [6. Settings](#6-settings)
  - [6.1 Speech Model Management](#6-1-speech-model-management)
  - [6.2 Vocabulary Settings Link](#6-2-vocabulary-settings-link)
  - [6.3 AI Settings Link](#6-3-ai-settings-link)
  - [6.4 Privacy Controls](#6-4-privacy-controls)
  - [6.5 About & Support](#6-5-about--support)
  - [6.6 Acknowledgements](#6-6-acknowledgements)
  - [6.7 Donations](#6-7-donations)
- [7. AI Rewrite](#7-ai-rewrite)
  - [7.1 Automatic Cleanup](#7-1-automatic-cleanup)
  - [7.2 On-Device AI Rewrite Model](#7-2-on-device-ai-rewrite-model)
  - [7.3 AI Rewrite Activation Model](#7-3-ai-rewrite-activation-model)
  - [7.4 Rewrite Trigger from Detail View](#7-4-rewrite-trigger-from-detail-view)
  - [7.5 Prompt Picker](#7-5-prompt-picker)
  - [7.7 Saved Prompt Management](#7-7-saved-prompt-management)
  - [7.8 Model Download Management](#7-8-model-download-management)
  - [7.9 Switch Model Picker](#7-9-switch-model-picker)
  - [7.10 Setup Routing from Transform](#7-10-setup-routing-from-transform)
  - [7.11 AI Settings Copy Discrepancy — Titles and Tags](#7-11-ai-settings-copy-discrepancy--titles-and-tags)
- [8. Vocabulary Boost](#8-vocabulary-boost)
  - [8.1 Custom Term List](#8-1-custom-term-list)
  - [8.2 Vocabulary Empty State](#8-2-vocabulary-empty-state)
  - [8.3 Term Addition](#8-3-term-addition)
  - [8.4 Term Editing and Ordering](#8-4-term-editing-and-ordering)
  - [8.5 Term Quality Warnings](#8-5-term-quality-warnings)
  - [8.6 Vocabulary Boost Toggle](#8-6-vocabulary-boost-toggle)
  - [8.7 Vocabulary Model Status](#8-7-vocabulary-model-status)
- [9. Help & Onboarding Reference](#9-help--onboarding-reference)
  - [9.1 Help Screen](#9-1-help-screen)
  - [9.2 Getting Started Guide](#9-2-getting-started-guide)
  - [9.3 AI Rewrite Guide](#9-3-ai-rewrite-guide)
  - [9.4 Privacy Explainer](#9-4-privacy-explainer)
  - [9.5 Collapsible Troubleshooting](#9-5-collapsible-troubleshooting)
  - [9.6 Feedback Contact](#9-6-feedback-contact)
  - [9.7 Use Cases](#9-7-use-cases)
- [10. System Integrations](#10-system-integrations)
  - [10.1 Shortcuts: Transcribe Audio with Jot](#10-1-shortcuts-transcribe-audio-with-jot)
  - [10.2 Action Button Shortcut](#10-2-action-button-shortcut)
  - [10.3 Deep Link Routing](#10-3-deep-link-routing)
- [11. Haptics & Sensory Feedback](#11-haptics--sensory-feedback)
  - [11.1 Recording Start Haptic](#11-1-recording-start-haptic)
  - [11.2 Recording Stop Haptic](#11-2-recording-stop-haptic)
  - [11.3 Cancel Haptic](#11-3-cancel-haptic)
  - [11.4 Success Haptic](#11-4-success-haptic)
  - [11.5 Keyboard Input-Click and Haptic Feedback](#11-5-keyboard-input-click-and-haptic-feedback)
- [12. Error States & Recovery](#12-error-states--recovery)
  - [12.1 Microphone Permission Denied](#12-1-microphone-permission-denied)
  - [12.2 Model Download Failure](#12-2-model-download-failure)
  - [12.3 AI Model Download Failure](#12-3-ai-model-download-failure)
  - [12.4 Rewrite Error](#12-4-rewrite-error)
  - [12.6 Keyboard Status Banner](#12-6-keyboard-status-banner)
- [13. Privacy & Data Disclosures](#13-privacy--data-disclosures)
  - [13.1 Fully On-Device Processing](#13-1-fully-on-device-processing)
  - [13.2 Warm Hold](#13-2-warm-hold)
  - [13.3 Full Access Disclosure](#13-3-full-access-disclosure)
  - [13.4 Transcript Storage](#13-4-transcript-storage)
  - [13.5 No Accounts, No Telemetry, No Analytics](#13-5-no-accounts-no-telemetry-no-analytics)
- [14. Known Bugs (Unresolved)](#14-known-bugs-unresolved)
  - [14.1 Keyboard-initiated dictation opens Jot but does not start recording](#14-1-keyboard-initiated-dictation-opens-jot-but-does-not-start-recording)
  - [14.2 Keyboard auto-switches back to system keyboard after dictation stop](#14-2-keyboard-auto-switches-back-to-system-keyboard-after-dictation-stop)
  - [14.3 Auto-paste silently fails in some host apps (notably Slack)](#14-3-auto-paste-silently-fails-in-some-host-apps-notably-slack)
  - [14.4 New user-created prompts have no before/after preview in the list](#14-4-new-user-created-prompts-have-no-beforeafter-preview-in-the-list)
  - [14.5 Minimize sometimes leaves keyboard at full height with collapsed content inside](#14-5-minimize-sometimes-leaves-keyboard-at-full-height-with-collapsed-content-inside)
  - [14.6 Actions popover regression cluster (Paste, Undo, Move up/down)](#14-6-actions-popover-regression-cluster-paste-undo-move-updown)
- [15. Planned Work & Plans Index](#15-planned-work--plans-index)

---

## Sizing convention

Planned and pending entries below carry a **size** tag using a T-shirt scale:

- **XS** — under 2 hours, single-file trivial change.
- **S** — 2-6 hours, single feature surface, 1-3 files.
- **M** — 1-2 days, multi-file but contained.
- **L** — 3-5 days, multi-component, real design decisions.
- **XL** — over a week, architectural change or new subsystem.

Sizes appear on Known Bugs (§14) and on aspirational entries that haven't shipped. Already-shipped features don't carry sizes.

---

## 1. Home & Library

### 1.1 Editorial Header
The home screen opens with a large italic serif 'Recents.' headline and today's date as a subtitle, sitting directly above the search bar and transcript list. Cumulative dictation stats — typing time saved today, lifetime dictation count, and a 14-day sparkline — are surfaced in [Settings → About](#6-5-about--support) rather than on the home page, keeping the home surface focused on recent activity.

### 1.2 Transcript Library with Time Grouping
All past recordings are presented in a scrollable list automatically bucketed into four recency groups — Today, Yesterday, Last 7 days, and Earlier — so users can find recent notes without searching. Each row shows the recording's timestamp, its duration when known (live dictations record it; file transcriptions via Shortcuts do not), and a two-line excerpt of the transcript text. The most recent entry is rendered as a featured one-line serif-italic quote on a soft blue-tinted card at the top of the list, so the newest transcript reads as the headline of the page; the recency label that introduces it (e.g. "Today") sits inside the same blue-tinted panel so the header and featured quote read as a single editorial section. Entries below the featured row, and all other recency sections, use the standard row treatment on the parent card surface. A small coral `sparkles` glyph appears alongside the timestamp on any row whose transcript has an [AI Rewrite](#7-ai-rewrite) — a quiet, glanceable affordance that distinguishes rewritten entries from raw originals. The same coral sparkle appears on the [keyboard Recents strip](#5-2-recents-strip-idle-state) for visual parity.

### 1.3 Live Search
A persistent search bar at the top of the library filters the transcript list in real time as the user types, matching against both the displayed (cleaned/rewritten) text and the original raw transcript text, so any recording can be located by a remembered phrase regardless of which version it appears in.

### 1.4 Home Empty State
When the library contains no transcripts, a dedicated empty state is shown in place of the list, inviting the user to make their first dictation.

### 1.5 Home No-Search-Results State
When a search query is active but no transcripts match, a "No matches" message is shown with a suggestion to try a different search term.

### 1.6 Floating Dictate Button
A prominent blue floating action button labeled "Dictate" sits anchored at the bottom of the home screen. Tapping it navigates to the full-screen [Recording Hero](#2-recording-experience) via a navigation push.

While a recording is in progress and the user has [backed out of the recording surface](#2-7-backgrounding-the-recording-surface), the Dictate button is replaced in place by a blue gradient "Recording" pill containing a pulsing white dot, the live elapsed timer, and a small upward arrow. Tapping the pill returns to the live recording surface; the pill carries a soft outer blue wash so it reads as live without dominating the home view. The same backgrounded-recording state also transforms the top of the [transcript library](#1-2-transcript-library-with-time-grouping) into a [live preview row](#1-10-live-recording-preview-on-home).

### 1.7 Transcript Row Actions
Each transcript row supports a swipe-left-to-reveal-delete gesture for single-row removal (the row slides to expose a red Delete button), and a long-press that enters [multi-select mode](#1-11-multi-select--combine) starting with the long-pressed row pre-selected. A short tap on a row opens the [Transcript Detail view](#3-transcript-detail). Delete triggers a confirmation dialog before permanently removing the entry.

### 1.8 Help Access
A question-mark button in the home header opens the [Help screen](#9-help--onboarding-reference) as a modal sheet, accessible at any time without leaving the library.

### 1.9 Settings Access
A profile-avatar circle in the home header opens [Settings](#6-settings) as a modal sheet.

### 1.10 Live Recording Preview on Home
While a recording is in progress and the user has [backed out of the recording surface](#2-7-backgrounding-the-recording-surface), the top of the [transcript library](#1-2-transcript-library-with-time-grouping) is replaced in place by a live preview row: a blue pulsing "Recording" badge with the live elapsed timer, and the live streaming transcript as a serif-italic body with a blinking blue caret. When the streaming text grows past the row's compact size, an ellipsis condenses the middle so the caret-end stays visible. When the recording ends, the live row resolves seamlessly into the new most-recent entry rendered as the featured serif quote. The matching "Recording" return pill described in [§1.6](#1-6-floating-dictate-button) appears in place of the Dictate button while this state is active.

### 1.11 Multi-Select & Combine
A long-press on any transcript row in the home library (see [§1.7](#1-7-transcript-row-actions)) enters multi-select mode with the long-pressed row pre-selected. In this mode the Dictate button is replaced by a bottom toolbar with three actions: **Select All** (selects every visible transcript), **Combine** (merges 2–5 selected entries into one new transcript), and **Delete N** (removes all selected entries after a confirmation dialog). Tapping additional rows toggles their selection. Exit multi-select by completing an action or by tapping outside the selected rows. Combine is enabled only when at least 2 and at most 5 rows are selected; outside that range the button dims. Tapping Combine opens a confirmation dialog with two options: **Combine and delete originals** (destructive — the source entries are removed and replaced by the new combined one) and **Combine and keep originals** (the new combined entry is created alongside the originals). In both cases, the combined entry is built from the **best available version** of each source — if a source has an [AI Rewrite](#7-ai-rewrite), the rewrite is used; if it does not, the original transcript is used. The picked strings are joined **oldest-first** (the earliest dictation appears at the top of the combined entry, the most recent at the bottom) with paragraph breaks. This is the opposite of the library's visual order — the library shows newest on top — because the combined entry reads naturally as a chronological narrative rather than as a stack of the rows in display order. The result is stored as the new entry's original (the new combined entry has no Rewrite of its own and no Rewrite tab). The new entry receives a fresh timestamp and ledger number.

---

## 2. Recording Experience

### 2.1 Full-Screen Recording Surface
When a dictation begins — whether triggered from the home [Dictate button](#1-6-floating-dictate-button) or the [Jot Keyboard](#5-jot-keyboard) — the app presents a dedicated full-screen recording view that takes over the display for the duration of the session. The [Action Button Shortcut](#10-2-action-button-shortcut) records in the background without presenting this surface.

**Exception — keyboard dictation within the [Warm Hold](#13-2-warm-hold) window:** when a warm-hold session is still active, tapping Dictate in the keyboard does NOT bring Jot to the foreground. The recording starts in the background and the user remains in the host app; only the keyboard's [streaming strip](#5-3-streaming-strip-recording-state) animates to reflect recording state. See [§2.9](#2-9-auto-dismiss-on-completion) and [§13.2](#13-2-warm-hold) for details.

### 2.2 Recording Status Indicator
Recording state is communicated implicitly — the dedicated full-screen surface, the live streaming transcript, and the live waveform make it unmistakable that the microphone is active. The elapsed-time counter lives inside the blue stop button at the bottom of the screen as a monospace timer, so the duration of the session is always visible alongside the primary "stop" affordance rather than as a separate top-of-screen status line.

### 2.3 Live Streaming Transcript
While the user speaks, a scrolling text area displays a continuously updating live preview of what is being said, rendered in an italic serif font. The view auto-scrolls to follow the newest text so the user always sees the most recent words without manually scrolling. A soft fade at the top edge signals that more content exists above.

### 2.4 Amplitude Waveform
A 40-bar animated waveform visualises the microphone's audio level in real time, providing immediate visual confirmation that audio is being captured and giving a sense of speaking volume.

### 2.5 Stop and Finalize
A large blue gradient stop button at the bottom of the screen ends the recording. The button contains a white stop square and the running elapsed-time monospace counter side-by-side. After stopping, a brief transcribing state is shown (the stop button displays a spinner) while the [on-device speech model](#6-1-speech-model-management) produces the final accurate transcript from the audio captured during the session — which may differ from the live preview shown during recording.

### 2.6 Cancel Recording
A "Cancel" pill at the top right of the recording screen discards the current recording without saving any transcript, useful when the user dictated the wrong thing or changed their mind. It is the only header control that ends the recording.

### 2.7 Backgrounding the Recording Surface
The recording surface includes a visible back chevron at the top-left. Tapping it backgrounds the recording without cancelling it — for example, to glance at the home screen or another app — and the standard iOS edge-swipe-back gesture works the same way in parallel. The microphone, live transcription, and waveform keep running; the home surface replaces the [Dictate button](#1-6-floating-dictate-button) with a blue "Recording" return pill, and the top of the [transcript library](#1-2-transcript-library-with-time-grouping) becomes a [live preview row](#1-10-live-recording-preview-on-home) with the streaming transcript so the user can see what is being captured without returning to the hero. Stopping or cancelling are the only ways to actually end a recording (see [§2.5](#2-5-stop-and-finalize) and [§2.6](#2-6-cancel-recording)).

### 2.8 Two-Model Transcription
Jot uses two on-device speech models: a fast streaming model that powers the [live preview](#2-3-live-streaming-transcript) and a high-accuracy model that produces the final saved transcript after the recording stops. Users see the result of the accurate model in their library; the fast model only feeds the real-time display.

### 2.9 Auto-Dismiss on Completion
Once transcription finishes, the recording view dismisses itself automatically and the user lands on Jot's home view, with the new transcript already saved and available in the [library](#1-2-transcript-library-with-time-grouping).

When the dictation was initiated from a third-party app's keyboard (via the Dictate key) **and there is no active Warm Hold session (cold start)**, Jot is brought to the foreground during recording and the user must manually swipe back to the host app — for example, by swiping right along the iOS app-switcher gesture bar. The transcribed text is pasted into the originating text field once the user returns to that app. Jot does not automatically switch the user back to the host app.

**Within the Warm Hold window**, this flow is different: Jot is never brought to the foreground, so no manual swipe-back is needed. The keyboard's streaming strip shows recording progress in place, and when transcription completes the text is auto-pasted without the user leaving the host app. See [§13.2](#13-2-warm-hold) for the Warm Hold UI-path disclosure.

### 2.10 Automatic Clipboard Copy on Completion
When an in-app dictation — started from the home screen [Dictate button](#1-6-floating-dictate-button) or [Recording Hero](#2-1-full-screen-recording-surface) — finishes and the final transcript is saved, Jot automatically places the [automatically cleaned](#7-1-automatic-cleanup) transcript text on the system clipboard. The user can immediately paste it into any other app (Notes, Messages, Mail, a browser field, and so on) without any extra step: no need to open the transcript detail, tap a copy button, or long-press the row. This auto-copy happens as soon as the transcription completes — at the same moment the result becomes available to the [Jot Keyboard](#5-13-auto-paste-of-completed-dictation) — and precedes the [Auto-Dismiss](#2-9-auto-dismiss-on-completion) that returns the user to the library. The [Action Button Shortcut](#10-2-action-button-shortcut) similarly copies its result to the clipboard on completion; both flows share this behavior. Manual copy options — the [row long-press](#1-7-transcript-row-actions), [detail Copy button](#3-5-action-bar), and [Actions Popover "Copy last"](#5-6-actions-popover) — remain available for later retrieval of any transcript.

### 2.11 Chained Follow-Up Voice Commands
Within 30 seconds after a dictation completes, the user can make a short follow-up dictation to transform the prior text — for example, "make it shorter" or "translate that to Spanish." Jot recognises this as a command against the just-dictated text rather than a new separate dictation: the transformed result replaces the prior text on the clipboard, a new transcript entry is created, and the original no longer appears in the keyboard's recent history. Outside the 30-second window, all new dictations are treated as fresh independent entries.

In the new entry's [detail view](#3-1-original-rewrite-tabs), the command utterance itself (e.g., "make it shorter") becomes the **Original** tab text, while the transformed prior dictation appears under the **Rewrite** tab. This means a user opening the follow-up entry sees their voice command as the Original and the rewritten text — attributed as "Rewritten with [model name]" — as the Rewrite.

**Home library vs. keyboard recents asymmetry**: in the Home library, both the original transcript and the follow-up entry appear as separate rows — the original is not hidden or marked in any way. In the keyboard's recents strip, only the follow-up entry is shown; the original is filtered out and does not appear. A user browsing the Home library therefore sees the full chain, while a user glancing at the keyboard recents sees only the latest result.

See also: [keyboard chained follow-up cross-reference](#5-3-streaming-strip-recording-state).

### 2.12 Accessibility: VoiceOver Focus
When the recording surface opens via an automated entry path — such as a keyboard-initiated recording triggered by a deep link — VoiceOver focus is placed on the recording status element (pulsing dot and elapsed timer) so assistive technology users are immediately informed that recording is underway, rather than landing on the back-navigation button.

---

## 3. Transcript Detail

### 3.1 Original / Rewrite Tabs
The detail view for any transcript presents two tabs — Original and Rewrite — selectable via a two-pill segment control. The Original tab always shows the unmodified text produced by the [speech model](#6-1-speech-model-management). The Rewrite tab shows the [automatic cleanup](#7-1-automatic-cleanup) output when present, and later shows the output of [AI Rewrite](#7-ai-rewrite) if one has been generated; older entries with neither show an empty state with a prompt to create one. When cleanup or a rewrite already exists, the detail view defaults to the Rewrite tab on open so the improved text is immediately visible.

### 3.2 Transcript Metadata
A subline at the top of the detail view displays the relative recording date, the word count, and the duration when available (present for live dictations; omitted for file transcriptions via Shortcuts), giving context without cluttering the reading area. The detail view has no title surface — title and tag fields are intentionally absent from v1 (see also [§7.11](#7-11-ai-settings-copy-discrepancy-titles-and-tags)).

### 3.3 Selectable Text
Both the original transcript text and the rewrite text are fully selectable, allowing users to copy any portion to the clipboard using the standard iOS text selection handles.

### 3.4 Rewrite Attribution
When a rewrite is present, a small attribution line names the active rewrite model. The label always reflects whichever rewrite model is currently selected in Settings; the UI does not distinguish between [automatic cleanup](#7-1-automatic-cleanup) output and downloaded-model output.

### 3.5 Action Bar
A row of actions at the bottom of the detail view provides Copy (copies the currently visible tab's text), Share (opens the iOS share sheet), a "Transform" button (blue pill that triggers [AI Rewrite](#7-ai-rewrite)), and Delete. The Copy button is icon-only — there is no visible text label. After tapping Copy, the icon changes to a checkmark briefly before reverting to the copy icon after approximately 1.3 seconds, confirming the action to the user. The VoiceOver accessibility label updates from "Copy transcript" to "Copied to clipboard" during this window. Tapping Delete shows a "Delete this entry?" confirmation dialog with a destructive "Delete" button and a "Cancel" button before the entry is permanently removed.

### 3.6 Rewrite Progress and Cancellation
When a rewrite is actively running, a progress card appears alongside the action bar (the action bar itself remains visible) with a "Rewriting…" indicator and a Cancel button, allowing the user to abort the generation mid-stream.

---

## 4. Setup Wizard

The setup wizard has seven core panels (W1–W7) and one optional follow-on panel. The default on-device speech models ship inside the app — see [§6.1 Speech Model Management](#6-1-speech-model-management) — so the wizard no longer needs a "Download speech model" step. The wizard also no longer includes a separate in-app dictation practice step; users go straight from the How-It-Works explainer to dictating from the real keyboard, which is the workflow they will use day-to-day.

### 4.1 Welcome (W1)
The first wizard panel introduces Jot with a large wordmark headline and a short tagline, then offers a single "Get started" call-to-action that begins the setup flow. W1 also has the standard wizard close (X) button with a "Skip setup?" confirmation prompt (same as on every other panel).

### 4.2 Microphone Permission (W2)
The second panel requests microphone access via the system permission dialog. If the user grants permission, the wizard advances automatically. If permission was previously denied, the panel shows a deep-link button that opens iOS Settings directly to Jot's permission page so the user can enable it without hunting through menus.

### 4.3 Keyboard Installation & Full Access (W3)
The third panel sends users to Keyboard Settings once to add Jot and turn on Full Access. When the keyboard has not been detected, the primary call-to-action reads "Open Keyboard Settings"; when the user returns with Jot installed, it changes to "Continue" and the panel title updates to "Jot keyboard detected." Jot can detect keyboard installation via the system's installed-keyboards list, but it cannot detect Full Access directly — Full Access remains a manual user attestation. A secondary "I've already done this" button is shown only in the not-yet-detected state as an escape hatch; once the keyboard is detected, "Continue" is the only footer action. See [§13.3](#13-3-full-access-disclosure).

### 4.4 How It Works (W4)
The fourth panel is a visual explainer illustrating the core usage loop: tap Dictate in the keyboard → swipe back to the host app while it keeps recording → stop from the keyboard → [cleaned text](#7-1-automatic-cleanup) is pasted automatically at the cursor. The body sentence says "Tap Dictate, swipe back to your app, then stop from the keyboard." and the caption underneath the flow diagram reads `TAP DICTATE → SWIPE BACK → STOP → TEXT PASTED`. The diagram uses the Jot brand icon (origami crane) in the middle position to indicate "Jot app opens." This orientation screen has no required user action other than reading and tapping "Got it".

### 4.5 Keyboard Try-It (W5)
The fifth panel provides a sample text field and instructs the user to switch to the Jot keyboard and dictate something. The panel waits for dictation to complete from the keyboard and advances automatically when one arrives; the inserted result follows the normal [automatic cleanup](#7-1-automatic-cleanup) path. A manual "I tried it" button also allows skipping. This is the wizard's only "try it" step — practicing inside the wizard surface was dropped so users experience Jot exactly as they will use it after setup.

### 4.6 Warm Hold Opt-In (W6)
The sixth panel offers the [Warm Hold](#13-2-warm-hold) feature: keeping the microphone session alive for 60 seconds after each recording to reduce startup latency for the next dictation. The user chooses "Keep mic ready" or "No thanks"; the choice is saved to Settings and can be changed later via [Settings → Privacy](#6-4-privacy-controls), where the duration is also customizable (60s, 2 min, 3 min, or 5 min).

### 4.7 Completion (W7)
The seventh panel congratulates the user with a "You're ready." headline and pitches the one remaining optional wizard step (AI Rewrite). Users can proceed to it immediately ("Set up now") or dismiss the wizard ("Maybe later") and explore that feature on their own schedule.

### 4.8 AI Rewrite Download Offer (Optional Step)
The single optional wizard step pitches the [AI Rewrite](#7-ai-rewrite) model download — approximately 2.5 GB for the on-device model. The panel title carries an "EXPERIMENTAL" chip beside it to set expectations about the feature's maturity. The model's name and size are shown verbatim in the body copy and the download CTA ("Download · 2.5 GB"), so users see exactly what they are getting before they tap. Users who opt in start the download immediately and the wizard dismisses; users who decline skip the download without any impact on core dictation functionality. The exact model that gets downloaded follows the user's current selection in the [Switch Model Picker](#7-9-switch-model-picker), which currently offers a single option. When the model is **already downloaded** on the device (e.g. a user re-running the wizard after a prior install), the panel adapts: the body copy reads "is already on this iPhone," the primary CTA becomes "Continue" instead of "Download · 2.5 GB," and the Skip button is hidden — there is nothing to skip past, so the only action is to acknowledge and move on.

### 4.9 Wizard Navigation Chrome
Every wizard panel except Welcome (W1) shares a consistent chrome: a back chevron (top-left) that steps to the previous panel, and a close button (top-right, X) that exits the wizard entirely. Welcome has no previous step, so the back chevron is absent on that panel. Tapping the close button shows a "Skip setup?" confirmation dialog before dismissing. If a recording is in progress when the wizard is exited, the recording is stopped automatically so no audio is left capturing in the background. A left-edge swipe gesture (drag rightward from the leading 22 pt strip) performs the same back action as the back chevron.

### 4.10 Wizard Progress Dots
At the top of every wizard panel, a row of seven dots represents the seven core setup steps (W1–W7). The current step's dot is larger and filled in the accent color; completed steps are smaller filled dots; upcoming steps are smaller outlined dots. During the optional step (AI Rewrite Download), this row is replaced by a different indicator: seven muted mini-dots representing the completed core steps, a short dash separator, and one accent dot for the active optional step.

---

## 5. Jot Keyboard

### 5.0 Dictation-Only Design
Jot's keyboard is dictation-only and has no QWERTY layout. Users keep their regular system keyboard for typing and switch to Jot only to dictate. This is surfaced explicitly in the [How It Works wizard step](#4-4-how-it-works-w4) so users understand the intended workflow before completing setup.

### 5.1 Full Custom Keyboard
Jot replaces the system keyboard with a fully custom layout when active. The layout includes a top information strip, an action row with primary controls, a punctuation shortcut row (hidden during recording), and a bottom row with space and return keys — all styled to match the host app's light or dark appearance automatically.

### 5.2 Recents Strip (Idle State)
When the keyboard is idle (not recording), the top strip shows up to ten recent dictation entries with their timestamps and truncated [cleaned text](#7-1-automatic-cleanup). Each row is split into two tappable zones: the **body** (timestamp + text) re-inserts that transcript at the cursor, and a **small trailing button** (`arrow.up.forward.app` glyph, accent color) brings the main app to the foreground and opens that transcript's detail view ([§3](#3-transcript-detail)) — useful for reviewing, running a Rewrite, or sharing without leaving the keyboard's host app to find the entry manually. The strip is scrollable, with a soft fade at the bottom edge indicating additional entries below. Entries that have an [AI Rewrite](#7-ai-rewrite) display a small coral `sparkles` glyph inside the body zone before the trailing button — the same affordance used in the [home library](#1-2-transcript-library-with-time-grouping) so the visual language stays consistent across surfaces. A "See all" link brings the main app to the foreground via a deep link. If the app is on the home screen with no overlays active, the transcript library is visible; the deep link does not force a navigation reset, so if a sheet or other navigation is already open the user will not automatically land on the library. **Full Access is required for the recents strip to show any content**: without it, the strip header still renders but the row area is silently blank — no recent dictation rows appear and no empty-state message is shown (see [§5.11](#5-11-full-access-requirement)).

### 5.3 Streaming Strip (Recording State)
When a dictation is in progress inside the keyboard, the top strip transforms into a live recording display: a blue pulsing dot, an elapsed timer, a six-bar animated waveform, and a scrollable pane that shows the [streaming partial transcript](#2-3-live-streaming-transcript) in real time. The pane is bottom-anchored — the first words appear near the bottom of the pane and older lines push upward as more text arrives — with a blinking caret at the trailing edge and a top-edge fade for overflow. A "↓ live" pill appears when the user has manually scrolled up and the view is no longer tracking the newest content; tapping the pill restores auto-follow. Follow-up voice commands (see [§2.11](#2-11-chained-follow-up-voice-commands)) apply within the 30-second window after the keyboard dictation completes.

### 5.4 Dictate / Stop Control
A prominent pill button in the keyboard's action row toggles recording on and off. The label and appearance change to reflect the current state — "Dictate" when idle, active stop styling when recording — so the current state is always unambiguous. When Full Access is not enabled, the button displays "Enable Full Access" and tapping it opens Jot's iOS Settings page (from which the user navigates to Keyboards → Jot to toggle Full Access) instead of starting a recording.

### 5.5 Post-Stop "Working" State
Immediately after the user stops a keyboard dictation, the Dictate button transitions to a "Working" label while transcription finishes on-device. The keyboard remains visible and the user can see that processing is in progress before the result is inserted.

### 5.6 Actions Popover
An actions button in the action row opens a compact glass popover with six operations: **Paste** (pastes whatever is currently on the system clipboard into the host app's focused field), **Copy** (places the currently-selected text in the host's focused field on the clipboard; enabled only when there is a non-empty selection AND Full Access is granted), **Undo last insertion** (removes the text the keyboard most recently pasted), **Redo last insertion** (re-inserts text that was just undone), **Move up** (shifts the cursor backward by approximately one host-visible window — about 256–1000 characters depending on the host; multiple taps accumulate), and **Move down** (shifts the cursor forward by the same chunk). Move up/down do NOT reach the absolute top or bottom of long fields in one tap — the underlying iOS keyboard-proxy buffers caret updates so each tap moves one window; this is intentional honesty in the labels. The popover dismisses after each action.

### 5.7 Backspace Hold-to-Delete
The backspace key deletes one character on tap. Holding the backspace key triggers a repeat-delete behavior, continuously removing characters while the key is held, matching standard iOS keyboard ergonomics.

### 5.8 Minimize / Expand
A minimize button collapses the keyboard to a slim 58-point bar containing only the core Dictate/Stop control. In collapsed mode, recording works identically — streaming text accumulates in the background — but the keyboard occupies minimal screen real estate. An expand button restores the full keyboard view. The minimized/expanded state persists across keyboard presentations: if a user leaves the keyboard in its collapsed state, the next time the keyboard appears it opens collapsed. When the user toggles between minimized and expanded, VoiceOver announces "Keyboard minimized" or "Keyboard expanded" respectively.

### 5.9 Dark / Light Mode Adaptation
The keyboard reads the host app's keyboard appearance setting and renders itself accordingly, so Jot's keyboard matches dark-mode apps natively without any user configuration.

### 5.10 Status Banner
Errors and warnings (such as microphone permission issues or model loading failures) surface as an overlay status banner inside the keyboard, keeping the user informed without requiring them to leave the host app. **Known limitation:** the banner is shown only in the standard (non-collapsed) keyboard view. When the keyboard is in its collapsed state, the banner is not visible — users in collapsed mode will not see status messages until they manually expand the keyboard.

### 5.11 Full Access Requirement
Literal key presses — typed characters, space, and return — work without Full Access. Backspace, Minimize/Expand, and Undo/Redo also work without Full Access. The following actions are specifically gated:

- **Dictate**: when Full Access is absent, the Dictate button is replaced by an "Enable Full Access" CTA (with a lock-shield icon) in both the standard and collapsed keyboard views. Tapping it opens iOS Settings to Jot's app-settings page; from there the user navigates General → Keyboard → Keyboards → Jot Keyboard → Allow Full Access to flip the toggle.
- **Paste**: the Paste row in the [Actions Popover](#5-6-actions-popover) is silently disabled (dimmed, non-interactive) without Full Access, because clipboard reads are unavailable. No error is shown.
- **Copy**: the Copy row in the [Actions Popover](#5-6-actions-popover) is silently disabled without Full Access, because the keyboard can only read the host's selected text when Full Access is granted. No error is shown.
- **Status banner**: the banner that relays dictation result messages is suppressed entirely when Full Access is absent.
- **Recents strip content**: without Full Access the recents strip header still renders, but the row area is silently blank — no entries appear and no empty-state message is shown. Full Access is required for any recent dictation rows to appear.
- **See all (recents)**: tapping the "See all" link in the keyboard's recents strip requires Full Access. Without it, the tap opens Jot's iOS Settings page — from which the user can navigate to Keyboards → Jot to enable Full Access — rather than opening the main app's full recents list.

The [Setup Wizard](#4-3-keyboard-installation--full-access-w3) guides users through enabling Full Access during initial setup. See also [§6.4 Privacy Controls](#6-4-privacy-controls) for the Full Access informational row in Settings and [§13.3 Full Access Disclosure](#13-3-full-access-disclosure) for the canonical explanation of why Full Access is required.

### 5.12 Character Key Preview Bubble
When a character key is pressed in portrait orientation, a magnified preview bubble (callout) appears above the key cap, displaying the pressed character in a large font — matching Apple's native iOS keyboard callout behavior. The keyboard's key set consists of literal punctuation characters (`@`, `.`, `,`, `?`, `!`, `'`), space, return, and backspace — there are no shift or globe keys. The preview bubble appears only for literal character keys; it is suppressed for space, return, backspace, and in landscape orientation.

### 5.13 Auto-Paste of Completed Dictation
When a keyboard dictation finishes and the transcript is ready, the keyboard automatically inserts the [automatically cleaned](#7-1-automatic-cleanup) text into the host app's focused text field — no tap required. This is the core workflow the [How It Works wizard step](#4-4-how-it-works-w4) illustrates: speak, stop, and the text appears at the cursor. The auto-paste arms at the moment the user taps Stop and fires as soon as the final transcript is available.

---

## 6. Settings

### 6.1 Speech Model Management
The Settings screen surfaces the name and current status of the installed speech model along with a chip showing its readiness. A chevron opens a sub-screen where the user can switch between two model variants — "Parakeet 110M (lighter, faster)" and "Parakeet 600M (more accurate)". The lighter "Parakeet 110M" variant is the default and ships bundled with the app — it is always available immediately on install with no download. "Parakeet 600M" is an opt-in download (~440 MB) for users who want higher accuracy. When the user has the bundled 110M variant selected, the action button reads "Re-download all models" (a maintenance affordance for the small additional file set that backs vocabulary biasing); when the 600M variant is selected and not yet downloaded, the button reads "Download all models"; when it is downloaded, the button reads "Re-download all models". Tapping "Re-download all models" shows a "Re-download all models?" confirmation dialog with a destructive "Re-download" button and a "Cancel" button before the download is initiated. The first-time "Download all models" button does not show this confirmation. The bundled 110M variant cannot be deleted — it lives inside the app bundle and is restored on reinstall. [Vocabulary Boost](#8-vocabulary-boost) applies to either variant.

### 6.2 Vocabulary Settings Link
A row in the Speech section shows the current count of [custom vocabulary terms](#8-vocabulary-boost) and navigates to the full [Vocabulary settings screen](#8-vocabulary-boost) where terms can be managed.

### 6.3 AI Settings Link
A row in the AI section shows the current status of the [AI Rewrite model](#7-ai-rewrite) and navigates to the full AI Rewrite settings screen where the model can be downloaded, freed, and prompts can be managed.

### 6.4 Privacy Controls
A Privacy section shows a tappable Full Access row (subline "General → Keyboard → Keyboards → Jot", trailing external-arrow), plus a toggle for [Warm Hold](#13-2-warm-hold) after [wizard step W6](#4-6-warm-hold-opt-in-w6). When Warm Hold is on, the toggle is followed by a "Ready for" duration picker with 60s, 2 min, 3 min, and 5 min options. The Full Access row opens iOS Settings to Jot's app-settings page; the subline gives the user the breadcrumb to navigate from there to Allow Full Access (Jot cannot read its state directly — see [§13.3](#13-3-full-access-disclosure)). The bottom-of-section caption "Your words stay on your iPhone. No accounts, no cloud, no telemetry." carries the on-device-only message; no separate "On-device only" row is shown.

### 6.5 About & Support
An About section provides links to Help & Support (opens [Help](#9-help--onboarding-reference)), Re-run setup wizard (restarts the [Setup Wizard](#4-setup-wizard) from the beginning for troubleshooting or exploration), Send feedback (opens an in-app feedback form — see [§9.6](#9-6-feedback-contact)), the app version number, Donations (opens the in-app [Donations](#6-7-donations) screen), a Privacy Policy link, and an Acknowledgements screen (see [§6.6](#6-6-acknowledgements)). When at least one dictation has been recorded, a "Time saved" row appears as the first entry of the About card, showing minutes saved today, the cumulative dictation count, and a small 14-day blue sparkline — the same lifetime stats that the home page used to surface inline, relocated here so the home view stays focused on recent activity (see [§1.1](#1-1-editorial-header)).

### 6.6 Acknowledgements
A dedicated Acknowledgements screen credits the open-source software and open-weight models that Jot is built on. It is organised into two sections: "Models & fonts" — listing the on-device speech models, the AI rewrite model (Qwen 3.5 4B), and the typeface used in the app, each with the author, license type, and a tappable link to the upstream source — and "Swift packages" — listing the major third-party Swift packages used by the app, with attribution and source links. Note: the list is curated and may not include every package the app uses. A footer note reiterates that all speech recognition and AI rewriting runs on-device and that no audio or transcript data is shared with any of the credited parties.

### 6.7 Donations
The Donations screen is reached from [Settings → About](#6-5-about--support) as an in-app navigation push. It explains Jot's free model, optionally personalizes the message with the user's estimated time saved when they have dictated for at least five minutes, and shows a searchable list of charities with their current Jot-raised totals. Charity names, totals, donation counts, and the community total come from Jot's donations summary feed; the app does not bundle charity descriptions or a fixed charity list. Each charity row offers $2 and $10 quick-give actions that open the matching Every.org donation page in the system browser. If current totals cannot be refreshed, the screen shows the last known totals when available, or a retry state when no totals have ever loaded.

---

## 7. AI Rewrite

### 7.1 Automatic Cleanup
Jot strips the most obvious filler tokens — "um", "uh", "er", "uhm", "erm" and their elongated variants — from every dictation before it lands on the clipboard or in the library. This is a fast lexical sweep that always runs: there is no toggle, no separate model, no extra download, and nothing leaves the device. The cleaned text is what appears in the Original transcript surface, gets pasted into the host app, and is what [AI Rewrite](#7-2-on-device-ai-rewrite-model) operates on when invoked. Paragraph boundaries inserted by the segmenter are preserved (the sweep only consumes adjacent spaces, never newlines), and obvious words containing filler-like substrings ("umbrella", "umpire", etc.) are left intact because the sweep is anchored on word boundaries. The legacy "Clean Up Transcript" parameter on the ["Transcribe Audio with Jot" Shortcuts action](#10-1-shortcuts-transcribe-audio-with-jot) is a separate per-run flag that uses Apple Intelligence and continues to default to off.

### 7.2 On-Device AI Rewrite Model
Jot offers an optional on-device language model download that enables a full prose rewrite of any transcript. The model runs entirely on-device with no data sent to any server. Fresh installs default to the current rewrite model (about 2.5 GB on disk); the [Switch Model Picker](#7-9-switch-model-picker) is in place for future alternates, though only a single model is currently offered. **Downloading the model IS enabling the feature** — there is no separate on/off toggle. Three explicit download entry points exist: (1) tapping the "Download · 2.5 GB" CTA on the AI Rewrite settings model strip, (2) tapping the Transform action in the [Transcript Detail view](#3-transcript-detail) when the model is not ready, which opens AI Rewrite settings as a sheet where the same Download CTA lives, and (3) the [wizard's optional download step](#4-8-ai-rewrite-download-offer-optional-step). Every download CTA and model strip displays the currently-selected model's name and exact size, so the user sees what they are downloading before they tap. The download runs in the foreground; the model strip surfaces a "Keep Jot open while the model downloads" caption under the progress bar to set expectations about backgrounding.

### 7.3 AI Rewrite Activation Model
**Aspirational (keyboard wand): S.** **Plan: [docs/plans/keyboard-magic-wand-entry.md](../docs/plans/keyboard-magic-wand-entry.md).** Phase 0 (XS) corrects the misleading Help copy; Phase 1 (S) wires a wand button into the keyboard action row using the rewrite plumbing that already exists in `Jot/Shared/Intents/`.

AI Rewrite has no separate on/off toggle. **Downloading the model is enabling the feature.** A user who has not downloaded the model can still see the action: in [Settings → AI](#6-3-ai-settings-link) the model strip surfaces a "Download · 2.5 GB" CTA, in the [Transcript Detail view](#3-transcript-detail) the Transform pill is fully visible and tapping it opens AI Rewrite settings as a sheet so the user lands directly on the same CTA, and the [wizard W7 AI offer step](#4-8-ai-rewrite-download-offer-optional-step) pitches the same download. The Help and Settings screens describe rewriting via a "Magic" wand entry in the keyboard; the current keyboard UI does not expose that action (see [§5.6](#5-6-actions-popover) — Minimize, Dictate/Stop, and Actions are the only row controls), so the keyboard wand/Magic entry point is advertised but not yet present.

### 7.4 Rewrite Trigger from Detail View
From the [Transcript Detail](#3-transcript-detail) view, the blue "Transform" pill in the action bar opens the [Prompt Picker](#7-5-prompt-picker) so the user can select which rewrite style to apply to the current transcript.

### 7.5 Prompt Picker
A bottom sheet lists all saved rewrite prompts, each with an icon, a name, and a short description. A subline below the prompt list header shows the word count of the source transcript being rewritten and the name of the currently active rewrite model (e.g. "42 words · using Qwen 3.5 4B"). The model name reflects whichever option the user has picked in the [Switch Model Picker](#7-9-switch-model-picker). The list contains the three built-in default prompts (Articulate, Action Items, Email) plus any prompts the user has created in [Settings → AI](#7-7-saved-prompt-management). Selecting a prompt applies it to the current transcript. Below the list, a plain centered "+ New prompt" text link opens the [New Prompt sheet](#7-12-new-prompt-sheet). A footer note clarifies that rewriting replaces the previous rewrite while leaving the original transcript untouched.

### 7.7 Saved Prompt Management
In [Settings → AI](#6-3-ai-settings-link), users can view their full list of saved rewrite prompts. The screen leads with an italic serif "AI." title and a small "EXPERIMENTAL" chip to set expectations about feature maturity. Prompts can be reordered by dragging, deleted by swiping, and edited by tapping. Each prompt row shows an icon, the prompt name, and — for the four built-in defaults (Articulate, AI prompt, Action Items, Email) — a mini before→after sample that previews what the prompt does to a representative transcript. Swiping to delete shows an alert with the prompt's name as the title (e.g. "Delete "My Prompt"?") and the message "This can't be undone." — with a destructive "Delete" button and a "Cancel" button — before the prompt is removed. A "+ New prompt" button at the bottom opens a dedicated New Prompt sheet (see [7.12](#7-12-new-prompt-sheet)). Inside the prompt editor for an existing prompt, the system prompt fills the editor as the hero element and a slim "Try this prompt" footer pill at the bottom expands upward into a result panel when tapped — showing the BEFORE transcript, an arrow with run timing, the AFTER rewrite, and Copy + Run again buttons; an "Expand" link opens a full-screen text editor for the instruction. The footer pill defaults to the user's most recent recording, and tapping the recording-name sublabel (marked with a small up/down chevron) opens a recording picker listing recent recordings with a coral checkmark on the currently selected one — picking a different recording updates the BEFORE block and what Run rewrites.

### 7.8 Model Download Management
Within [Settings → AI](#6-3-ai-settings-link), a single compact model strip surfaces the active model's name, file size, and a coloured-dot readiness status (ready, downloading with percent, loading, evicted, error, or not downloaded). When the model is not in a ready state, an inline action row appears under the strip in the same card with the contextual control: a "Download · <size>" button for the active model (the size reflects whichever model is currently selected in the [Switch Model Picker](#7-9-switch-model-picker)), a progress bar with Cancel during download, "Loading…" during warm-up, "Reload" after eviction, or "Retry" after an error. All download status lives inside this single strip — there is no separate top-pinned download banner. Long-pressing the model strip opens a context menu with two entries: "Change model" (opens the [Switch Model Picker](#7-9-switch-model-picker)) and a destructive "Delete model" that, after a confirmation dialog naming the model and warning the user they will need to re-download (about 2.5 GB) to use AI rewrite again, purges the on-device model. The "Delete model" entry is hidden while the model is still downloading or has never been downloaded — there is nothing on-device to remove in those states.

### 7.9 Switch Model Picker
Within [Settings → AI](#6-3-ai-settings-link), a "Switch model" row opens a picker listing the available on-device rewrite models. Currently only Qwen 3.5 4B is offered (shown with a "Default" tag); the picker's footer caption reads "Qwen 3.5 4B is currently the only rewrite model. More options will appear here as they're added." The picker shape is preserved so adding a second model is a single-row addition. Each row shows the model name, its on-disk size, and a small status caption ("Downloaded" or "Not downloaded") so the user can see at a glance whether picking will trigger a fresh download. When a second model is added, tapping a row will mark it as active immediately; the change reflects in the model strip on the [Model Download Management](#7-8-model-download-management) screen and in the model-name surfaces ([Prompt Picker](#7-5-prompt-picker), [Transcript Detail attribution line](#3-transcript-detail)). Picking a different model does NOT auto-start a download — the user explicitly downloads the new model from the AI Rewrite settings screen after switching.

### 7.10 Setup Routing from Transform
When the user taps the Transform action in the [Transcript Detail](#3-transcript-detail) view and the AI model is not ready — whether because it isn't downloaded, is downloading right now, is loading into memory, hit an error, or there are no saved prompts yet — the Transform tap routes to the [AI Rewrite settings](#7-8-model-download-management) screen as a sheet. The user lands directly on the model strip's "Download · 2.5 GB" CTA (or its progress / retry equivalent for the current state) without losing their place in the transcript. The earlier dedicated "Download Pitch Sheet" interstitial has been removed in favor of this single canonical surface — Settings is the only setup destination, so the user sees the same model strip whether they arrived from the action bar, the AI row in Settings, or the wizard. The prompt list comes pre-populated with four default prompts the first time the user opens Settings → AI Rewrite, in order: **Articulate** (rewrite a dictation for clarity — connect related ideas so they flow logically, cut repeated points while keeping every distinct idea the speaker mentioned, and fix obvious dictation errors), **AI prompt** (convert a rambling dictation into a clean, well-structured prompt the speaker can paste into Claude, ChatGPT, or any other LLM — output is organized into Context / Task / Requirements / Output sections, preserving every concrete detail while cutting filler), **Action Items** (extract tasks from a dictation, list each as a one-line task with the responsible person if mentioned, and include any deadlines), and **Email** (convert a dictation into a business email with a Bottom-Line-Up-Front opening and a one-line subject line). These defaults are seeded only when the list is completely empty: if the user deletes some prompts but keeps at least one, the deleted defaults do not return; if the user deletes all prompts, the defaults reappear the next time they open Settings → AI Rewrite (because the empty-list guard triggers again). The Transcript Detail view does not add default prompts or initiate a model download on its own — it only routes to Settings, where the user explicitly taps Download.

### 7.11 AI Settings Copy Discrepancy — Titles and Tags
**Aspirational. Size depends on path: XS (delete footnote) / M (build titles only) / L (build titles + tags).** **Plan: [docs/plans/titles-and-tags.md](../docs/plans/titles-and-tags.md).** Plan recommends delete (path A) until there's user demand for titles, since the build path forces SwiftData schema-versioning work that has been deferred. Tied to [Migration system plan](../docs/plans/migration-system.md) for SwiftData migrations (separate concern from UserDefaults migrations).

Visible footnote copy in the AI settings screens states "Titles and tags use the system's built-in AI automatically," but no title or tag UI is currently displayed for transcripts.

### 7.12 New Prompt Sheet
Creating a new rewrite prompt opens a dedicated sheet, distinct from the editor used for existing prompts ([7.7](#7-7-saved-prompt-management)). The sheet shows a name field, a selectable icon picker (8 colored tiles — the selected tile is enlarged with a white-then-color ring), a mono system-prompt editor with a helpful placeholder ("Describe how Jot should transform the selected text. Tip: be specific about voice, length, and what to preserve. Test on a recording before saving."), and a "Start from a template" footer offering four one-tap starters: "Translate to…", "Make it shorter", "More formal", and "Action items". Tapping a template chip fills the editor with a canned starter prompt and switches the icon to match. The Save button is disabled until both the name and the system prompt have content. Saved prompts land at the bottom of the prompt list and persist via the same store used by everything else in [§7.7](#7-7-saved-prompt-management).

---

## 8. Vocabulary Boost

### 8.1 Custom Term List
Users can maintain a list of domain-specific words, names, or technical terms that Jot should recognize correctly during transcription. The list is managed from [Settings → Vocabulary](#6-2-vocabulary-settings-link). The Vocabulary surface is marked **Experimental** with a small badge at the top of the screen. Vocabulary biasing applies to either Parakeet variant ("Parakeet 110M" or "Parakeet 600M") selected in [Settings → Speech model](#6-1-speech-model-management). Vocabulary is no longer offered as an onboarding step — it lives only in Settings.

### 8.2 Vocabulary Empty State
When no terms have been added, the vocabulary screen shows a dedicated empty state inviting the user to add their first term.

### 8.3 Term Addition
There are two paths for adding a term:

**Primary — floating "Add term" button.** A floating action button is always visible at the bottom of the Vocabulary screen (hovering above the list). Tapping it opens a dedicated modal sheet titled "New term" — a half-height sheet with a form for entering the new term text.

**Secondary — inline "Add Term" row.** An "Add Term" row is also present at the bottom of the terms list (visible both in normal and Edit mode). Tapping it inserts a blank term inline and focuses the text field immediately, without opening a sheet.

Terms added via either path are applied to subsequent transcriptions only when the [Vocabulary Boost toggle](#8-6-vocabulary-boost-toggle) is on. The [vocabulary boost model](#8-7-vocabulary-model-status) ships bundled with the app, so no separate download is required.

### 8.4 Term Editing and Ordering
Within the Vocabulary settings screen, terms can be reordered by dragging, deleted by swiping, and the list can be switched into an edit mode for bulk management. Each existing term row is always an inline text field — there is no separate edit-mode-only state or tap-to-reveal gesture. Tapping anywhere in a row places the cursor and lets the user edit the term text immediately. There is no variants or aliases field — each row edits only the term text.

### 8.5 Term Quality Warnings
Terms that are too short to be useful, or terms that are common everyday English words (which do not need boosting), are flagged with a warning indicator inline in the list, helping users curate a list of genuinely useful terms.

### 8.6 Vocabulary Boost Toggle
A master toggle in the Vocabulary settings screen enables or disables vocabulary boosting entirely, letting users compare transcription with and without their term list without deleting the list itself.

### 8.7 Vocabulary Model Status
The vocabulary boost is powered by a small additional on-device model (~100 MB) that improves recognition of the user's saved terms. It ships bundled inside the app alongside the [default speech model](#6-1-speech-model-management), so it is always available immediately on install with no separate download. The Vocabulary settings screen shows this model's readiness status; on a healthy install the status is always "ready" (no download, retry, or progress states are reachable for the bundled model).

---

## 9. Help & Onboarding Reference

### 9.1 Help Screen
A structured help reference is accessible from the home header or from [Settings → About](#6-5-about--support). It is presented as a modal sheet from the home screen or as a navigation push from Settings, so it fits naturally into both entry points.

### 9.2 Getting Started Guide
The first section of the help screen walks through the basic Jot workflow — install keyboard, tap Dictate, speak, swipe back — in plain language for users who need a refresher after the wizard.

### 9.3 AI Rewrite Guide
A separate section in the Help screen explains the optional [AI Rewrite](#7-ai-rewrite) feature. It covers three points: tapping the wand icon on any transcript or in the keyboard to trigger a rewrite; the model being fully on-device at about 2.5 GB so text never leaves the device; and enabling the feature via Settings to download the model. (The reassurance that the original transcript stays untouched appears in the [Prompt Picker sheet](#7-5-prompt-picker), not in Help.)

### 9.4 Privacy Explainer
A privacy section in Help summarises Jot's on-device-only data handling — all transcription happens on-device, transcripts are stored locally with no cloud sync or analytics, and optional AI rewrites are also on-device. The privacy section does not explain why Full Access is requested; that rationale is covered in the [Setup Wizard](#4-3-keyboard-installation--full-access-w3) and [Settings → Privacy](#6-4-privacy-controls). Full Access appears in Help only as a troubleshooting answer: the troubleshooting entry "Keyboard didn't paste" instructs users to enable Full Access via Settings → General → Keyboard.

### 9.5 Collapsible Troubleshooting
A Troubleshooting section in Help contains collapsible Q&A entries addressing the four most common issues: the keyboard didn't paste, the recording was cut off unexpectedly, the optional [speech model](#6-1-speech-model-management) didn't download (Parakeet 600M), and the transcription produced wrong words. Each entry is collapsed by default to keep the screen scannable.

### 9.6 Feedback Contact
A Contact section at the bottom of the Help screen provides a Send feedback button that opens an in-app feedback form. The form is a single text field with a Send button; the app version and platform are attached automatically. The user stays inside Jot — no Mail handoff. After sending, the screen confirms with the feedback ID; on rate-limit or server errors the message is shown inline so the user can try again. The same form is reachable from Settings → About → Send feedback (see [§6.5 About](#6-5-about--support)).

### 9.7 Use Cases
A "What it's for" section appears as the first section of the Help screen (above [§9.2 Getting Started Guide](#9-2-getting-started-guide)) and frames Jot in three user-situation stories rather than feature claims. **Speak instead of typing, in any app** describes globe-switching to the Jot keyboard and dictating directly into the current text field. **Keep going when life interrupts** describes the [warm-hold microphone](#5-12-warm-hold) staying ready for up to five minutes across app switches and incoming calls, with continuous saves so partial dictations survive interruptions. **Polish what you said into what you meant** describes the three built-in [AI Rewrite](#7-ai-rewrite) prompts (Articulate, Action Items, Email) plus the ability to write a custom prompt once and reuse it on any transcript. Each story is a short paragraph under a small bold subhead, with the AI prompt names highlighted inline.

---

## 10. System Integrations

### 10.1 Shortcuts: Transcribe Audio with Jot
Jot exposes a Shortcuts action — "Transcribe Audio with Jot" — that accepts an audio file as input and returns a transcript string as output. The action runs in the background without opening the app, appends the result to the transcript history, and returns the raw transcript by default. Unlike the recording screen and keyboard, this surface does NOT run the [Automatic Cleanup](#7-1-automatic-cleanup) pass — cleanup on the Shortcuts file action is gated solely on the per-run "Clean Up Transcript" toggle described next. An optional "Clean Up Transcript" toggle applies a separate cleanup pass (Apple Intelligence based, distinct from the bundled cleanup model used elsewhere) to the output; if that pass is unavailable or fails, the shortcut silently falls back to returning the raw transcript (no error is surfaced to the Shortcuts automation). This action is chainable with other Shortcuts steps — for example, after the system "Record Audio" action — making it useful for batch workflows or automation pipelines.

### 10.2 Action Button Shortcut
Jot exposes a "Start Jot Dictation" action in Apple's Shortcuts app that can be assigned to the iPhone's Action Button (or invoked from any Shortcuts automation). When triggered, it starts recording in the background without opening the app; a second press stops recording, transcribes, and copies the result to the clipboard. The action is discoverable in the Action Button settings under the Shortcuts category.

### 10.3 Deep Link Routing
Jot supports deep links that open the app directly into a new recording session or bring the app to the foreground aimed at the [transcript library](#1-2-transcript-library-with-time-grouping). These links can be triggered from other apps, web pages, or Shortcuts. The library deep link does not force a navigation reset — if a sheet or other navigation is already open when the link fires, the user will not automatically land on the library view.

---

## 11. Haptics & Sensory Feedback

### 11.1 Recording Start Haptic
A haptic pulse fires when a recording session begins, providing tactile confirmation that the microphone is active — useful when the phone is not in view.

### 11.2 Recording Stop Haptic
A distinct haptic fires when the user taps the stop button, confirming the recording has ended.

### 11.3 Cancel Haptic
Cancelling a recording mid-session produces its own haptic, differentiating the "nothing saved" outcome from the "saved successfully" stop.

### 11.4 Success Haptic
A success haptic fires after transcription completes and the result is saved, marking the moment the transcript becomes available in the library.

### 11.5 Keyboard Input-Click and Haptic Feedback
Key presses on the Jot keyboard produce audio and haptic feedback that matches the feel of the native iOS keyboard. The keyboard surfaces only punctuation literals (`@`, `.`, `,`, `?`, `!`, `'`), space, return, and backspace — there are no letter or number keys. Pressing a punctuation literal or space plays the standard iOS keyboard click sound paired with a light tap haptic. Tapping return plays a slightly different click sound. Tapping backspace plays a distinct delete sound. Every key press also produces a selection-style haptic alongside the audio. Requires Full Access; without it both audio and haptics are silently suppressed.

---

## 12. Error States & Recovery

### 12.1 Microphone Permission Denied
If microphone access is denied, the [Setup Wizard](#4-2-microphone-permission-w2) surfaces a deep-link to iOS Settings. In the main app, denied permission surfaces an alert dialog with a single OK button that dismisses the alert; there is no Settings deep link from this alert, so the user must navigate to iOS Settings manually to grant microphone access. In the keyboard, errors including permission issues surface via the [status banner](#5-10-status-banner).

### 12.2 Model Download Failure
The default Parakeet 110M speech bundle ships inside the app, so it cannot fail to download. This failure mode only applies to the opt-in Parakeet 600M variant (see [§6.1 Speech Model Management](#6-1-speech-model-management)): if a download fails after the user taps "Download all models" in Settings, the model section surfaces a retry action.

### 12.3 AI Model Download Failure
If the [AI Rewrite model](#7-2-on-device-ai-rewrite-model) download fails or the model becomes unavailable, [Settings → AI](#7-8-model-download-management) surfaces retry and reload actions. In the Transcript Detail view, tapping Transform when the model has not been downloaded (or is mid-download / loading / errored) routes the user to AI Rewrite settings as a sheet — see [§7.10](#7-10-setup-routing-from-transform) — where the same retry/download controls live. An error card with a dismiss option appears only after a rewrite attempt actually fails (see also [§12.4](#12-4-rewrite-error)).

### 12.4 Rewrite Error
If a rewrite fails mid-generation (model error or memory pressure), the [Transcript Detail](#3-6-rewrite-progress-and-cancellation) view shows an error card the user can dismiss. If the user cancels the in-progress rewrite, the view returns silently to idle — no error card is shown for user-initiated cancellation. The original transcript is never modified by a failed or cancelled rewrite.

### 12.6 Keyboard Status Banner
Transient errors inside the [Jot Keyboard](#5-10-status-banner) — such as a transcription failure or a missing model — are communicated via an overlay banner that appears without requiring the user to leave the host app. Non-rewriting banners auto-clear approximately 2.5 seconds after they render; the "Rewriting…" banner persists until the rewriting state changes.

---

## 13. Privacy & Data Disclosures

### 13.1 Fully On-Device Processing
All speech recognition, transcription, and AI rewrite operations run on-device using downloaded models. No audio, transcript text, or rewrite content is sent to any external server. This is surfaced in [Settings → Privacy](#6-4-privacy-controls) and explained in the [Help screen](#9-4-privacy-explainer).

### 13.2 Warm Hold
When enabled (opt-in during [wizard step W6](#4-6-warm-hold-opt-in-w6) or via [Settings → Privacy](#6-4-privacy-controls)), Jot keeps the audio session active after a recording ends to reduce latency at the start of the next dictation. The duration is configurable in Settings → Privacy: it defaults to 60s, offers 60s, 2 min, 3 min, and 5 min choices, and can be set up to a maximum of 5 min. The toggle is clearly labeled and off by default. During the warm-hold window the iOS orange microphone indicator remains visible and the audio session stays active; no audio is captured or retained.

**UI-path difference during Warm Hold:** when the user taps Dictate in the keyboard while a warm-hold session is still active, the keyboard recognizes the active window and recording starts immediately — Jot is not brought to the foreground. The user stays in the host app for the full dictation; only the keyboard's streaming strip ([§5.3](#5-3-streaming-strip-recording-state)) animates to show live progress. When the recording finishes and transcription completes, the text is auto-pasted as normal. Outside the warm-hold window — or when Warm Hold is disabled — a keyboard-initiated dictation follows the cold-start path: Jot is launched and comes to the foreground, the [full-screen recording surface](#2-1-full-screen-recording-surface) appears, and the user must manually swipe back to the host app when done ([§2.9](#2-9-auto-dismiss-on-completion)).

### 13.3 Full Access Disclosure
The [Setup Wizard](#4-3-keyboard-installation--full-access-w3) explains why Full Access is required for the keyboard: it allows the keyboard to access the transcript result produced by the main app in order to paste it into the host app. The [Help screen](#9-4-privacy-explainer) does not explain the Full Access rationale — it mentions Full Access only in a troubleshooting entry directing users to enable it when paste does not work. The [Settings → Privacy](#6-4-privacy-controls) section includes a tappable Full Access row that opens iOS Settings to Jot's app-settings page (with a subline that gives the navigation breadcrumb to Allow Full Access); no status chip is shown because iOS does not expose Full Access state to the main app. After setup, if the user is using the keyboard and Full Access has not been granted, the keyboard surfaces a locked-state "Enable Full Access" pill that opens iOS Settings to the same page. The reason this opens the app-settings page rather than the keyboard panel directly: Apple's QA1924 `prefs:` URL would land closer to the toggle, but on iOS 26 it returns `success: true` from `extensionContext.open` while doing nothing — so we use the documented public URL that reliably opens.

### 13.4 Transcript Storage
Transcripts are stored locally on the device. Users can delete individual transcripts via the [swipe or context menu](#1-7-transcript-row-actions) on the home screen or via the Delete action in the [Transcript Detail](#3-5-action-bar) view. There is no active cross-device iCloud sync — each device's library is independent.

**iCloud Device Backup behavior.** When the user has iCloud Backup enabled in iOS Settings, the following are included in their device backup automatically: transcripts (Original + Rewrite), saved AI Rewrite prompts, custom vocabulary, and app preferences. Audio is never written to disk so it can't be part of any backup. Two categories of downloaded model weights are explicitly kept OUT of the backup so they don't bloat it (typical Jot backup size: a few MB, not GB):

- The AI Rewrite model (Qwen 3.5 4B, ~2.5 GB) lives under `Library/Caches/`, which iOS unconditionally excludes from backup. No app code needed.
- The optional downloaded speech model (Parakeet 600M v2, ~2 GB on disk after CoreML compilation) lives under `Library/Application Support/FluidAudio/` because Application Support is sticky (iOS doesn't evict it under memory pressure — keeps dictation reliable). Application Support IS backed up by default, so Jot explicitly sets `isExcludedFromBackup = true` on the FluidAudio directory at launch.

Both model categories re-download on first use after a restore. The Settings → About card surfaces a static "Backed up with iCloud (when iCloud Backup is enabled in iOS Settings)" row so users can confirm this expectation at a glance.

On restore (full device setup from an iCloud backup → Jot reinstalled), the library returns to the state it was in at the moment the backup was taken. Restoring a single app from the App Store does NOT bring its data back — only full-device "Restore from iCloud Backup" does.

Schema changes carry explicit version migrations (see `docs/schema-migrations.md`), so restoring an old backup on a newer build of Jot loads cleanly via the migration plan. Restoring a backup taken on a newer build onto an older build of Jot is not supported; install the same or newer version.

### 13.5 No Accounts, No Telemetry, No Analytics
Settings surfaces the claim: "Your words stay on your iPhone. No accounts, no cloud, no telemetry." The Help screen's Privacy section reiterates this as: "Transcripts are stored locally on your device. Jot has no cloud sync, no analytics, no account."

---

## 14. Known Bugs (Unresolved)

This section tracks user-facing bugs that are reproduced but not yet fixed. Each entry is a short symptom statement + the reproducer + the current root-cause hypothesis. Entries are removed when a fix lands and ships.

### 14.1 Keyboard-initiated dictation opens Jot but does not start recording
**Size: S.** **Plan: [docs/plans/bug-cold-start-dictation-race.md](../docs/plans/bug-cold-start-dictation-race.md).** Hypothesis recorded here may not match code reality — see plan for diagnostic-first approach.

**Symptom:** User taps the Dictate pill in the Jot keyboard from a host app. Jot is brought to the foreground (recording hero may briefly appear) but recording never actually starts — the timer stays at 0:00 and no audio is captured. The user has to back out and tap the home-screen Dictate FAB to actually record.

**When it happens:** Cold-start path only (no [warm-hold](#13-2-warm-hold) window active). Observed especially after the speech model has been unloaded (e.g. post-memory-warning or first launch after device reboot). User manually triggering dictation in the same session briefly flashes a "Parakeet loading…" indicator before recording begins, which suggests the keyboard-initiated path may be racing the speech-model ANE-load.

**Current hypothesis:** the `jot://dictate` URL-bounce reaches the main app before the speech model has finished loading into ANE. The recording-start handler proceeds and starts the audio engine, but the streaming session's `loadModels(from:)` fails or hangs, leaving the recording in a half-started state where the engine isn't capturing. Needs trace logs to confirm.

### 14.2 Keyboard auto-switches back to system keyboard after dictation stop
**Size: M.** **Plan: [docs/plans/bug-keyboard-auto-switch.md](../docs/plans/bug-keyboard-auto-switch.md).** Two hypotheses (keyboard kill vs. main-app jetsam); diagnostic plan disambiguates.

**Symptom:** Rare. After the user taps Stop in the Jot keyboard (the same Dictate pill in its stop state), iOS switches the active keyboard back to the previous system keyboard. When the user manually switches back to Jot via the globe key, the transcript has already been auto-pasted into the host field and the keyboard is in its normal idle state.

**When it happens:** Rare; not yet reliably reproduced. User can supply logs from a capture when it happens next.

**Current hypothesis:** the keyboard extension is being terminated by iOS (memory pressure during transcribe/cleanup) and iOS falls back to the previously-active keyboard while it relaunches. The auto-paste still completes because the main-app pipeline finishes independently and the v7 paste deadline machinery resurrects it on next keyboard presentation. Needs trace logs around the stop → transcribe-complete window to confirm.

### 14.3 Auto-paste silently fails in some host apps (notably Slack)
**Size: M.** **Plan: [docs/plans/bug-slack-silent-paste.md](../docs/plans/bug-slack-silent-paste.md).** Probe shipped in build 4; plan tightens it (existing `contextGrew` signal is ambiguous on long fields) then ships banner + clipboard fallback.

**Symptom:** Stop a warm-hold dictation while focused on a host app's text field (observed in Slack). The keyboard's `pasteSuccess` event fires in the diagnostics log with the full character count, but no text appears in the host field. The dictated transcript is still stored in Jot's library — only the auto-paste step silently no-ops.

**When it happens:** Warm-hold path (Jot never foregrounded). Most reliably observed with Slack as the host; possibly other apps with custom JS-backed compose fields or draft-autosave systems. Intermittent rather than every time.

**Why `pasteSuccess` is misleading:** `UITextDocumentProxy.insertText(_:)` is a void call — it returns nothing whether the host accepted the insert or not. The "pasteSuccess" log line confirms only that the keyboard *called* the function, not that any text actually landed in the host's text field. The host can silently reject the insert if the proxy is mid-disconnect, if the keyboard isn't the active input view at the moment of call, or if the host's text-input delegate rejects programmatic inserts.

**Current hypothesis:** the host's textDocumentProxy is disconnected (returns `nil` for `documentContextBeforeInput`) at the moment of insert, so iOS no-ops the call silently. Slack's compose field has known unusual focus + draft-autosave behavior that may transiently break the proxy connection. As of build 4 the `pasteSuccess` log now also captures `proxyHadContextBefore` + a before/after context-length delta so the next failure produces actionable signal: if `contextGrew` equals the inserted character count, the host accepted the text; if it's `0` or `-1`, the insert was silently dropped. Once a failure is captured with the new instrumentation, the fix (likely gating insert on `proxyHadContextBefore == true` and posting an error banner otherwise) becomes a one-liner.

### 14.4 New user-created prompts have no before/after preview in the list
**Size: S.** **Plan: [docs/plans/bug-user-prompt-no-preview.md](../docs/plans/bug-user-prompt-no-preview.md).** Deterministic, ready to implement.

**Symptom:** Each bundled default prompt in [Settings → AI Rewrite](#7-7-saved-prompt-management) (Articulate, AI prompt, Action Items, Email) renders with a mini before→after sample directly inside its row — a representative dictation in italic + the prompt's transformed output below it. When the user creates their own prompt via the "+ New prompt" sheet, the new row appears in the list but **without a before/after sample**; it just shows the icon + name + a one-line preview of the system prompt. Visually inconsistent with the bundled rows and gives the user no quick "is this prompt doing what I expect" cue.

**When it happens:** Every user-created prompt, every time. Not intermittent.

**Why it's there:** The before/after samples for the bundled defaults are hardcoded in `AIRewriteSettingsView.swift` (switch on `prompt.defaultKind`). User-created prompts have no such hardcoded sample — and we don't currently capture the output from the editor's "Try this prompt" footer pill, even though we already have the user dictating a real recording AND running the prompt against it in that flow.

**Plan:** Capture the most recent (before, after) pair produced by the "Try this prompt" footer for each user-created prompt and persist it on the `SavedPrompt` row (or as a separate side-table keyed by id). Render that pair in the list row using the same component path as the bundled defaults. Falls back to the existing "first-line of system prompt" preview when no try-run has happened yet. Deferred for now — capture the bug, fix later.

### 14.5 Minimize sometimes leaves keyboard at full height with collapsed content inside
**Size: diagnosis-first.** **Plan: [docs/plans/bug-keyboard-minimize-stuck-height.md](../docs/plans/bug-keyboard-minimize-stuck-height.md).** Ten plausible causes enumerated; fix size XS→M depending on which one confirms via the existing `[KB-COLLAPSE-DEBUG]` instrumentation.

**Symptom:** Tapping the Minimize button in the [Jot Keyboard](#5-8-minimize--expand) sometimes swaps the SwiftUI render to the collapsed-bar view (small Stop button centered) but leaves the keyboard's outer frame at full expanded height (~450 pt). User sees the small content floating in a tall empty envelope. Intermittent — not every Minimize tap is affected.

**Workaround that works:** globe-switch to any other keyboard, then globe-switch back to Jot. On re-presentation, the keyboard renders at the correct collapsed 58 pt height.

**This is the opposite failure mode from [§5.10](#5-10-status-banner):** there the height grows but content doesn't; here the content shrinks but height doesn't.

**Current hypotheses (no winner — diagnostic capture pending):** ten candidate causes ranging from system input-view height caching, animation-interruption races on double-tap, status-banner auto-expand collisions, SwiftUI vs UIKit ordering, hosting-controller intrinsic-content-size conflicts, transitions during the tap window, and `UIInputView` size-negotiation timing. The plan explores each path and lists the diagnostic signal that would disambiguate. Fix is not chosen until logs confirm.

### 14.6 Actions popover regression cluster (Paste, Undo, Move up/down, Dismiss)
**Size: bundled, XS-S.** **Plan: [docs/plans/bug-actions-popover-regressions.md](../docs/plans/bug-actions-popover-regressions.md).** Four bugs in the keyboard's [Actions Popover](#5-6-actions-popover) surface:

- **Paste** doesn't re-read the system clipboard when the popover opens. Stale enabled-state persists across opens until the keyboard re-appears. **Confidence: 90%.** Fix is XS — call `refreshPasteState()` from the Actions button tap.
- **Undo** appears to be missing coverage for Recents-strip tap insertions (and possibly other keyboard-driven inserts). Code reading suggests the path *should* be tracked; needs diagnostic instrumentation before fix. **Confidence: 50%.**
- **Move up / Move down** is moving roughly one line per tap when it previously moved ~one host-visible window (~256–1000 chars). Possible regression introduced during the rename from "Jump to start / end." Needs git history check + per-iteration instrumentation. **Confidence: 40%.**
- **Popover dismiss is unreliable.** Tapping the Actions button again doesn't close it; tapping arbitrary outside areas doesn't close it. User has to tap a specific area (Recents) to dismiss. **Confidence: 60%.** Fix: full-frame `Color.clear` catcher with `.highPriorityGesture` + explicit toggle-close in the Actions button + optional ✕ in the popover top-right.

---

## 15. Planned Work & Plans Index

Curated index of plan documents that elaborate aspirational features, deferred engineering work, and unresolved bugs. Each plan has a recommendation, alternatives, edge cases, and a test plan ready to pick up.

### Aspirational (advertised but not yet built)

- **Delete misleading "wand in keyboard" Help copy** — [§7.3](#7-3-ai-rewrite-activation-model) → [docs/plans/keyboard-magic-wand-entry.md](../docs/plans/keyboard-magic-wand-entry.md) — **XS.** A keyboard wand was advertised but never built and will never be built. Plan is a one-line copy edit in Help to drop the false advertising. No new UI.
- **Transcript titles** — [§3.2](#3-2-transcript-metadata), [§7.11](#7-11-ai-settings-copy-discrepancy--titles-and-tags) → [docs/plans/titles-and-tags.md](../docs/plans/titles-and-tags.md) — **XS (recommended path) or M (if build).** Plan recommends path A (delete the §7.11 footnote) until there's user demand. Build path is coupled to SwiftData schema versioning. Tags are explicitly out of scope.
- **Cancel-during-recording in keyboard** — [§5.6](#5-6-actions-popover), [§5.4](#5-4-dictate--stop-control) → [docs/plans/keyboard-cancel-during-recording.md](../docs/plans/keyboard-cancel-during-recording.md) — **XS.** Replaces the Actions button with a Cancel button while a dictation is actively recording. Closes the "no abort from keyboard" gap on warm-hold and in-app paths.
- **Cancel button visual design** — companion to the above → [docs/plans/keyboard-cancel-button-ux.md](../docs/plans/keyboard-cancel-button-ux.md). Treatment B chosen (glass + red `xmark`) with dark-mode opacity mitigations called out at implementation time.

### Deferred engineering (queue in `docs/deferred-engineering.md`)

- **Generic versioned migration system** — [docs/plans/migration-system.md](../docs/plans/migration-system.md) — **M.** Replaces hand-rolled `UserDefaults`-gated migrations with a typed `Migration` protocol supporting synchronous, detached, and always-apply patterns. Crash-recovery via attempt counter + circuit breaker.
- **In-app tap-to-record** — [docs/plans/in-app-tap-to-record.md](../docs/plans/in-app-tap-to-record.md) — **S.** When dictating from inside Jot, skip the URL bounce → Hero push. The keyboard is already app-agnostic at the proxy level, so paste targeting and cross-boundary scenarios come for free. ~2 lines of dispatch + Hero-push suppression on main-app side.
- **In-app feature list + forward-only release log** — [docs/plans/feature-catalog-release-log.md](../docs/plans/feature-catalog-release-log.md) — **S.** Static hand-coded SwiftUI list grouped by hero feature. Release log starts forward from the version that ships this feature; no back-fill of past versions. No JSON sidecar, no CI check, no `features.md` sync.
- **Donation milestone re-prompt** — [docs/plans/donation-milestone-card.md](../docs/plans/donation-milestone-card.md) — **S.** Evolves the existing `DonationCard` (`Jot/App/Donation/DonationCard.swift` — already shipping) from a single-shot at 2h into a multi-milestone re-prompt at 2h / 10h / 25h with a 90-day cooldown and a "never ask again" affordance.

### Known bugs (§14)

- **§14.1 Cold-start dictation race** — [docs/plans/bug-cold-start-dictation-race.md](../docs/plans/bug-cold-start-dictation-race.md) — **S.** Diagnostic instrumentation first; primary fix is a one-line `warmUp()` kick in the deferred branch of `triggerAutoStart`.
- **§14.2 Keyboard auto-switch on stop** — [docs/plans/bug-keyboard-auto-switch.md](../docs/plans/bug-keyboard-auto-switch.md) — **M.** Two hypotheses (keyboard kill vs. main-app jetsam); diagnostic plan disambiguates. Resurrection UX uses a Dictate-button overlay rather than a banner because of the §5.10 collapsed-banner bug.
- **§14.3 Slack silent paste** — [docs/plans/bug-slack-silent-paste.md](../docs/plans/bug-slack-silent-paste.md) — **M.** Build-4 probe ships; plan tightens it (existing `contextGrew` is ambiguous on long fields) then adds banner + clipboard fallback with `setItems` expiration.
- **§14.4 User-prompt no preview** — [docs/plans/bug-user-prompt-no-preview.md](../docs/plans/bug-user-prompt-no-preview.md) — **S.** Persist last (before, after) pair from the Try-This footer + render via the same component path as bundled defaults.
- **§14.5 Minimize sometimes leaves keyboard at full height with collapsed content inside** — [docs/plans/bug-keyboard-minimize-stuck-height.md](../docs/plans/bug-keyboard-minimize-stuck-height.md) — **diagnosis-first.** Ten plausible causes enumerated; existing `[KB-COLLAPSE-DEBUG]` log layer is most of the instrumentation needed. Fix size XS→M depending on which cause confirms.
- **§14.6 Actions popover regression cluster** — [docs/plans/bug-actions-popover-regressions.md](../docs/plans/bug-actions-popover-regressions.md) — **XS-S bundled.** Four bugs: Paste-stale (90% confidence, XS fix), Undo coverage for Recents tap (50% confidence, diagnostic-first), Move up/down regression (40% confidence, git check + diagnostic), and unreliable popover dismiss (60% confidence, XS fix — full-frame catcher + explicit toggle-close + ✕ affordance).

### Index conventions

- Sizes follow the [T-shirt scale](#sizing-convention) at the top.
- Every plan has been adversarial-reviewed; review findings are folded into the corresponding plan doc.
- Plan docs use this template: Problem → Goal → Non-Goals → Design → Implementation outline → Edge cases → Test plan → Open questions → Cross-links.

### Decisions to make

All ~30 open questions across the 10 plans are walked path-by-path in **[docs/plans/open-questions-deep-dive.md](../docs/plans/open-questions-deep-dive.md)**. Each question has alternatives explored, second-order effects, and a recommendation. A TL;DR table at the bottom summarises every recommendation in one screen.
