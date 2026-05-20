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
  - [4.8 Vocabulary Seed (Optional Step 1)](#4-8-vocabulary-seed-optional-step-1)
  - [4.9 AI Rewrite Download Offer (Optional Step 2)](#4-9-ai-rewrite-download-offer-optional-step-2)
  - [4.10 Wizard Navigation Chrome](#4-10-wizard-navigation-chrome)
  - [4.11 Wizard Progress Dots](#4-11-wizard-progress-dots)
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
  - [7.3 AI Rewrite Master Toggle](#7-3-ai-rewrite-master-toggle)
  - [7.4 Rewrite Trigger from Detail View](#7-4-rewrite-trigger-from-detail-view)
  - [7.5 Prompt Picker](#7-5-prompt-picker)
  - [7.6 Voice Prompt Capture](#7-6-voice-prompt-capture)
  - [7.7 Saved Prompt Management](#7-7-saved-prompt-management)
  - [7.8 Model Download Management](#7-8-model-download-management)
  - [7.9 Switch Model Picker](#7-9-switch-model-picker)
  - [7.10 Download Pitch Sheet](#7-10-download-pitch-sheet)
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
  - [12.5 Voice Prompt Transcription Error](#12-5-voice-prompt-transcription-error)
  - [12.6 Keyboard Status Banner](#12-6-keyboard-status-banner)
- [13. Privacy & Data Disclosures](#13-privacy--data-disclosures)
  - [13.1 Fully On-Device Processing](#13-1-fully-on-device-processing)
  - [13.2 Warm Hold](#13-2-warm-hold)
  - [13.3 Full Access Disclosure](#13-3-full-access-disclosure)
  - [13.4 Transcript Storage](#13-4-transcript-storage)
  - [13.5 No Accounts, No Telemetry, No Analytics](#13-5-no-accounts-no-telemetry-no-analytics)

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
A long-press on any transcript row in the home library (see [§1.7](#1-7-transcript-row-actions)) enters multi-select mode with the long-pressed row pre-selected. In this mode the Dictate button is replaced by a bottom toolbar with three actions: **Select All** (selects every visible transcript), **Combine** (merges 2–5 selected entries into one new transcript), and **Delete N** (removes all selected entries after a confirmation dialog). Tapping additional rows toggles their selection. Exit multi-select by completing an action or by tapping outside the selected rows. Combine is enabled only when at least 2 and at most 5 rows are selected; outside that range the button dims. Tapping Combine opens a confirmation dialog with two options: **Combine and delete originals** (destructive — the source entries are removed and replaced by the new combined one) and **Combine and keep originals** (the new combined entry is created alongside the originals). In both cases, the combined entry is built from the **best available version** of each source — if a source has an [AI Rewrite](#7-ai-rewrite), the rewrite is used; if it does not, the original transcript is used. The picked strings are joined in chronological order with paragraph breaks, and the result is stored as the new entry's original (the new combined entry has no Rewrite of its own and no Rewrite tab). The new entry receives a fresh timestamp and ledger number.

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

The setup wizard has seven core panels (W1–W7) and two optional follow-on panels. The default on-device speech models ship inside the app — see [§6.1 Speech Model Management](#6-1-speech-model-management) — so the wizard no longer needs a "Download speech model" step. The wizard also no longer includes a separate in-app dictation practice step; users go straight from the How-It-Works explainer to dictating from the real keyboard, which is the workflow they will use day-to-day.

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
The seventh panel congratulates the user with a "You're ready." headline and pitches the two optional wizard steps. Users can proceed to the optional steps immediately ("Set up now") or dismiss the wizard ("Maybe later") and explore those features on their own schedule.

### 4.8 Vocabulary Seed (Optional Step 1)
The first optional wizard step lets users immediately populate their [Vocabulary Boost](#8-vocabulary-boost) list with domain-specific terms that the model should recognize correctly. Users type terms into a text field and add them one at a time; the panel shows the accumulating list with a trailing xmark button on each row to remove individual terms. When the list is empty, two greyed-out example rows appear as visual hints to suggest the kind of terms users might add; these examples disappear as soon as the user adds their first real term. A "Done" or "Skip" button closes the step.

### 4.9 AI Rewrite Download Offer (Optional Step 2)
The second optional wizard step pitches the [AI Rewrite](#7-ai-rewrite) model download — approximately 2.5 GB for the default on-device model. The panel title carries an "EXPERIMENTAL" chip beside it to set expectations about the feature's maturity. The active model's name and size are shown verbatim in the body copy and the download CTA ("Download · 2.5 GB"), so users see exactly what they are getting before they tap. Users who opt in start the download immediately and the wizard dismisses; users who decline skip the download without any impact on core dictation functionality. The exact model that gets downloaded follows the user's current selection in the [Switch Model Picker](#7-9-switch-model-picker) — fresh installs default to the recommended model. When the model is **already downloaded** on the device (e.g. a user re-running the wizard after a prior install), the panel adapts: the body copy reads "is already on this iPhone," the primary CTA becomes "Continue" instead of "Download · 2.5 GB," and the Skip button is hidden — there is nothing to skip past, so the only action is to acknowledge and move on.

### 4.10 Wizard Navigation Chrome
Every wizard panel except Welcome (W1) shares a consistent chrome: a back chevron (top-left) that steps to the previous panel, and a close button (top-right, X) that exits the wizard entirely. Welcome has no previous step, so the back chevron is absent on that panel. Tapping the close button shows a "Skip setup?" confirmation dialog before dismissing. If a recording is in progress when the wizard is exited, the recording is stopped automatically so no audio is left capturing in the background. A left-edge swipe gesture (drag rightward from the leading 22 pt strip) performs the same back action as the back chevron.

### 4.11 Wizard Progress Dots
At the top of every wizard panel, a row of seven dots represents the seven core setup steps (W1–W7). The current step's dot is larger and filled in the accent color; completed steps are smaller filled dots; upcoming steps are smaller outlined dots. During the optional steps (Vocabulary Seed and AI Rewrite Download), this row is replaced by a different indicator: seven muted mini-dots representing the completed core steps, a short dash separator, and two accent dots tracking progress through the two optional steps. The current optional step's dot follows the same active/upcoming pattern as the core row.

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
An actions button in the action row opens a compact glass popover with four operations: Paste (pastes whatever is currently on the system clipboard into the host app's focused field), Copy last (places the last dictation result on the clipboard without inserting), Undo the last insertion (removes the text that was pasted), and Redo (re-inserts text that was just undone). The popover dismisses after each action.

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
- **Copy last**: the Copy last row in the [Actions Popover](#5-6-actions-popover) is silently disabled without Full Access, because the keyboard can only read dictation results stored by the main app when Full Access is granted. No error is shown.
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
The Settings screen surfaces the name and current status of the installed speech model along with a chip showing its readiness. A chevron opens a sub-screen where the user can switch between two model variants — "Parakeet 110M (lighter, faster)" and "Parakeet 600M (more accurate)". The lighter "Parakeet 110M" variant is the default and ships bundled with the app — it is always available immediately on install with no download. The "Parakeet 600M" variant is an opt-in download (~440 MB) for power users who want the highest accuracy. When the user has the bundled 110M variant selected, the action button reads "Re-download all models" (a maintenance affordance for the small additional file set that backs vocabulary biasing); when the 600M variant is selected and not yet downloaded, the button reads "Download all models"; when the 600M variant is downloaded, the button reads "Re-download all models". Tapping "Re-download all models" shows a "Re-download all models?" confirmation dialog with a destructive "Re-download" button and a "Cancel" button before the download is initiated. The first-time "Download all models" button does not show this confirmation. The bundled 110M variant cannot be deleted — it lives inside the app bundle and is restored on reinstall.

### 6.2 Vocabulary Settings Link
A row in the Speech section shows the current count of [custom vocabulary terms](#8-vocabulary-boost) and navigates to the full [Vocabulary settings screen](#8-vocabulary-boost) where terms can be managed.

### 6.3 AI Settings Link
A row in the AI section shows the current status of the [AI Rewrite model](#7-ai-rewrite) and navigates to the full AI Rewrite settings screen where the model can be downloaded, freed, and prompts can be managed.

### 6.4 Privacy Controls
A Privacy section shows a tappable Full Access row (subline "General → Keyboard → Keyboards → Jot", trailing external-arrow), plus a toggle for [Warm Hold](#13-2-warm-hold) after [wizard step W6](#4-6-warm-hold-opt-in-w6). When Warm Hold is on, the toggle is followed by a "Ready for" duration picker with 60s, 2 min, 3 min, and 5 min options. The Full Access row opens iOS Settings to Jot's app-settings page; the subline gives the user the breadcrumb to navigate from there to Allow Full Access (Jot cannot read its state directly — see [§13.3](#13-3-full-access-disclosure)). The bottom-of-section caption "Your words stay on your iPhone. No accounts, no cloud, no telemetry." carries the on-device-only message; no separate "On-device only" row is shown.

### 6.5 About & Support
An About section provides links to Help & Support (opens [Help](#9-help--onboarding-reference)), Re-run setup wizard (restarts the [Setup Wizard](#4-setup-wizard) from the beginning for troubleshooting or exploration), Send feedback (opens an in-app feedback form — see [§9.6](#9-6-feedback-contact)), the app version number, Donations (opens the in-app [Donations](#6-7-donations) screen), a Privacy Policy link, and an Acknowledgements screen (see [§6.6](#6-6-acknowledgements)). When at least one dictation has been recorded, a "Time saved" row appears as the first entry of the About card, showing minutes saved today, the cumulative dictation count, and a small 14-day blue sparkline — the same lifetime stats that the home page used to surface inline, relocated here so the home view stays focused on recent activity (see [§1.1](#1-1-editorial-header)).

### 6.6 Acknowledgements
A dedicated Acknowledgements screen credits the open-source software and open-weight models that Jot is built on. It is organised into two sections: "Models & fonts" — listing the on-device speech models, the available AI rewrite models (Qwen 3.5 4B and Phi-4 mini), and the typeface used in the app, each with the author, license type, and a tappable link to the upstream source — and "Swift packages" — listing the major third-party Swift packages used by the app, with attribution and source links. Note: the list is curated and may not include every package the app uses. A footer note reiterates that all speech recognition and AI rewriting runs on-device and that no audio or transcript data is shared with any of the credited parties.

### 6.7 Donations
The Donations screen is reached from [Settings → About](#6-5-about--support) as an in-app navigation push. It explains Jot's free model, optionally personalizes the message with the user's estimated time saved when they have dictated for at least five minutes, and shows a searchable list of charities with their current Jot-raised totals. Charity names, totals, donation counts, and the community total come from Jot's donations summary feed; the app does not bundle charity descriptions or a fixed charity list. Each charity row offers $2 and $10 quick-give actions that open the matching Every.org donation page in the system browser. If current totals cannot be refreshed, the screen shows the last known totals when available, or a retry state when no totals have ever loaded.

---

## 7. AI Rewrite

### 7.1 Automatic Cleanup
Jot strips the most obvious filler tokens — "um", "uh", "er", "uhm", "erm" and their elongated variants — from every dictation before it lands on the clipboard or in the library. This is a fast lexical sweep that always runs: there is no toggle, no separate model, no extra download, and nothing leaves the device. The cleaned text is what appears in the Original transcript surface, gets pasted into the host app, and is what [AI Rewrite](#7-2-on-device-ai-rewrite-model) operates on when invoked. Paragraph boundaries inserted by the segmenter are preserved (the sweep only consumes adjacent spaces, never newlines), and obvious words containing filler-like substrings ("umbrella", "umpire", etc.) are left intact because the sweep is anchored on word boundaries. The legacy "Clean Up Transcript" parameter on the ["Transcribe Audio with Jot" Shortcuts action](#10-1-shortcuts-transcribe-audio-with-jot) is a separate per-run flag that uses Apple Intelligence and continues to default to off.

### 7.2 On-Device AI Rewrite Model
Jot offers an optional on-device language model download that enables a full prose rewrite of any transcript. The model runs entirely on-device with no data sent to any server. Fresh installs default to a recommended on-device model (about 2.5 GB on disk); the [Switch Model Picker](#7-9-switch-model-picker) lets users select an alternate model instead, and existing users who already have a previous model installed are not silently flipped to the new default. The automatic model download is triggered in two ways: enabling the [AI Rewrite master toggle](#7-3-ai-rewrite-master-toggle) while the model is not installed, or opening Settings → AI Rewrite when the toggle is already on and the model is not yet installed. Users can also initiate a download from a third entry point: tapping the Transform action in the [Transcript Detail view](#3-transcript-detail) when the model is not ready surfaces the [Download Pitch sheet](#7-10-download-pitch-sheet), which contains a one-tap "Download · 2.5 GB" CTA that starts the download. This detail-flow entry point requires an explicit tap on the pitch sheet CTA — it is not automatic. A fourth entry point is the [wizard's optional download step](#4-9-ai-rewrite-download-offer-optional-step-2). Every download CTA and model strip displays the currently-selected model's name and exact size, so the user sees what they are downloading before they tap.

### 7.3 AI Rewrite Master Toggle
A master "Enable AI Rewrite" toggle in [Settings → AI](#6-3-ai-settings-link) turns the entire AI Rewrite feature on or off. The Settings label describes the toggle as enabling a "Magic button" in the keyboard that rewrites selected text; the Help screen similarly refers to a wand icon in the keyboard for rewriting. The current keyboard UI does not expose this action — the keyboard's action row contains only Minimize, Dictate/Stop, and Actions (see [§5.6](#5-6-actions-popover)). The keyboard wand/Magic entry point is advertised in Settings and Help but is not yet present in the keyboard surface. When the toggle is disabled, the model section and prompts section in Settings are dimmed; in the [Transcript Detail](#3-transcript-detail) view both the Original and Rewrite tabs remain visible but the Rewrite action button in the empty state is dimmed and non-functional. No rewrite processing occurs while the toggle is off.

### 7.4 Rewrite Trigger from Detail View
From the [Transcript Detail](#3-transcript-detail) view, the blue "Transform" pill in the action bar opens the [Prompt Picker](#7-5-prompt-picker) so the user can select which rewrite style to apply to the current transcript.

### 7.5 Prompt Picker
A bottom sheet lists all saved rewrite prompts, each with an icon, a name, and a short description. A subline below the prompt list header shows the word count of the source transcript being rewritten and the name of the currently active rewrite model (e.g. "42 words · using Qwen 3.5 4B"). The model name reflects whichever option the user has picked in the [Switch Model Picker](#7-9-switch-model-picker). Selecting a prompt applies it to the current transcript. At the tail of the same scrollable list, a compact one-line "Voice prompt" row (see [7.6](#7-6-voice-prompt-capture)) lets the user dictate a one-shot instruction without leaving the picker. Below the list, a plain centered "+ New prompt" text link opens the [New Prompt sheet](#7-12-new-prompt-sheet). A footer note clarifies that rewriting replaces the previous rewrite while leaving the original transcript untouched.

### 7.6 Voice Prompt Capture
The "Voice prompt" option in the [Prompt Picker](#7-5-prompt-picker) opens a dedicated capture view where the user speaks a one-off rewrite instruction of up to 60 seconds. The spoken instruction is auto-transcribed on-device and used as a one-time instruction for that single rewrite — it is not saved to the prompt library. The capture view starts listening automatically if microphone permission is available; a stop tap ends the capture; a spinner indicates transcription; "Try again" handles errors.

### 7.7 Saved Prompt Management
In [Settings → AI](#6-3-ai-settings-link), users can view their full list of saved rewrite prompts. The screen leads with an italic serif "AI." title and a small "EXPERIMENTAL" chip to set expectations about feature maturity. Prompts can be reordered by dragging, deleted by swiping, and edited by tapping. Each prompt row shows an icon, the prompt name, and — for the three built-in defaults (Articulate, Action Items, Email) — a mini before→after sample that previews what the prompt does to a representative transcript. Swiping to delete shows an alert with the prompt's name as the title (e.g. "Delete "My Prompt"?") and the message "This can't be undone." — with a destructive "Delete" button and a "Cancel" button — before the prompt is removed. A "+ New prompt" button at the bottom opens a dedicated New Prompt sheet (see [7.12](#7-12-new-prompt-sheet)). Inside the prompt editor for an existing prompt, the system prompt fills the editor as the hero element and a slim "Try this prompt" footer pill at the bottom expands upward into a result panel when tapped — showing the BEFORE transcript, an arrow with run timing, the AFTER rewrite, and Copy + Run again buttons; an "Expand" link opens a full-screen text editor for the instruction. The footer pill defaults to the user's most recent recording, and tapping the recording-name sublabel (marked with a small up/down chevron) opens a recording picker listing recent recordings with a coral checkmark on the currently selected one — picking a different recording updates the BEFORE block and what Run rewrites.

### 7.8 Model Download Management
Within [Settings → AI](#6-3-ai-settings-link), a single compact model strip surfaces the active model's name, file size, and a coloured-dot readiness status (ready, downloading with percent, loading, evicted, error, or not downloaded). When the model is not in a ready state, an inline action row appears under the strip in the same card with the contextual control: a "Download · <size>" button for the active model (the size reflects whichever model is currently selected in the [Switch Model Picker](#7-9-switch-model-picker)), a progress bar with Cancel during download, "Loading…" during warm-up, "Reload" after eviction, or "Retry" after an error. All download status lives inside this single strip — there is no separate top-pinned download banner. Long-pressing the model strip opens a context menu with two entries: "Change model" (opens the [Switch Model Picker](#7-9-switch-model-picker)) and a destructive "Delete model" that, after a confirmation dialog naming the model and warning the user they will need to re-download (about 2.5 GB) to use AI rewrite again, purges the on-device model. The "Delete model" entry is hidden while the model is still downloading or has never been downloaded — there is nothing on-device to remove in those states.

### 7.9 Switch Model Picker
Within [Settings → AI](#6-3-ai-settings-link), a "Switch model" row opens a picker listing the available on-device rewrite models. The recommended default sits at the top with a "Default" tag; alternate variants are listed below. Each row shows the model name, its on-disk size, and a small status caption ("Downloaded" or "Not downloaded") so the user can see at a glance whether picking will trigger a fresh download. Tapping a row marks it as active immediately; the change is reflected in the model strip on the [Model Download Management](#7-8-model-download-management) screen and in the model-name surfaces ([Prompt Picker](#7-5-prompt-picker), [Transcript Detail attribution line](#3-transcript-detail), [Download Pitch Sheet](#7-10-download-pitch-sheet)). Picking a different model does NOT auto-start a download — the user explicitly downloads the new model from the AI Rewrite settings screen after switching.

### 7.10 Download Pitch Sheet
When a user taps the Transform action in the [Transcript Detail](#3-transcript-detail) view and the AI model has not been downloaded (status: not ready), a pitch sheet appears naming the currently-selected model and offering a one-tap download initiation ("Download · 2.5 GB" for the default model, or whichever size matches the active selection in the [Switch Model Picker](#7-9-switch-model-picker)) or dismissal ("Maybe later"), so the upsell is contextual rather than buried in Settings. The pitch sheet is only reachable when the user has at least one saved prompt — if no prompts exist, the Transform button is non-interactive regardless of model status. The prompt list comes pre-populated with three default prompts the first time the user opens Settings → AI Rewrite: **Articulate** (polish a dictation while preserving the speaker's voice and word choices and fixing obvious dictation errors — the bundled prompt that won A/B testing on Qwen 3.5 4B for fidelity to the speaker's voice), **Action Items** (extract tasks from a dictation, list each as a one-line task with the responsible person if mentioned, and include any deadlines), and **Email** (convert a dictation into a business email with a Bottom-Line-Up-Front opening and a one-line subject line). These defaults are seeded only when the list is completely empty: if the user deletes some prompts but keeps at least one, the deleted defaults do not return; if the user deletes all prompts, the defaults reappear the next time they open Settings → AI Rewrite (because the empty-list guard triggers again). Auto-download of the rewrite model is gated on the master AI Rewrite toggle being on; the prompt list and model picker remain visible in a disabled/inactive state when the toggle is off. The Transcript Detail view does not add default prompts or initiate a model download on its own.

### 7.11 AI Settings Copy Discrepancy — Titles and Tags
Visible footnote copy in the AI settings screens states "Titles and tags use the system's built-in AI automatically," but no title or tag UI is currently displayed for transcripts.

### 7.12 New Prompt Sheet
Creating a new rewrite prompt opens a dedicated sheet, distinct from the editor used for existing prompts ([7.7](#7-7-saved-prompt-management)). The sheet shows a name field, a selectable icon picker (8 colored tiles — the selected tile is enlarged with a white-then-color ring), a mono system-prompt editor with a helpful placeholder ("Describe how Jot should transform the selected text. Tip: be specific about voice, length, and what to preserve. Test on a recording before saving."), and a "Start from a template" footer offering four one-tap starters: "Translate to…", "Make it shorter", "More formal", and "Action items". Tapping a template chip fills the editor with a canned starter prompt and switches the icon to match. The Save button is disabled until both the name and the system prompt have content. Saved prompts land at the bottom of the prompt list and persist via the same store used by everything else in [§7.7](#7-7-saved-prompt-management).

---

## 8. Vocabulary Boost

### 8.1 Custom Term List
Users can maintain a list of domain-specific words, names, or technical terms that Jot should recognize correctly during transcription. The list is managed from [Settings → Vocabulary](#6-2-vocabulary-settings-link) and is also seeded during the [optional wizard step](#4-8-vocabulary-seed-optional-step-1).

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
A Troubleshooting section in Help contains collapsible Q&A entries addressing the four most common issues: the keyboard didn't paste, the recording was cut off unexpectedly, the optional [Parakeet 600M speech model](#6-1-speech-model-management) didn't download, and the transcription produced wrong words. Each entry is collapsed by default to keep the screen scannable.

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
The default Parakeet 110M speech bundle ships inside the app, so it cannot fail to download. This failure mode only applies to the opt-in Parakeet 600M variant (see [§6.1 Speech Model Management](#6-1-speech-model-management)): if its download fails after the user taps "Download all models" in Settings, the model section surfaces a retry action.

### 12.3 AI Model Download Failure
If the [AI Rewrite model](#7-2-on-device-ai-rewrite-model) download fails or the model becomes unavailable, [Settings → AI](#7-8-model-download-management) surfaces retry and reload actions. In the Transcript Detail view, tapping Rewrite when the model has not been downloaded opens the [Download Pitch Sheet](#7-10-download-pitch-sheet) — an interstitial that explains the feature and offers a one-tap download; no dimmed/disabled button state is shown for the not-downloaded case. An error card with a dismiss option appears only after a rewrite attempt actually fails (see also [§12.4](#12-4-rewrite-error)).

### 12.4 Rewrite Error
If a rewrite fails mid-generation (model error or memory pressure), the [Transcript Detail](#3-6-rewrite-progress-and-cancellation) view shows an error card the user can dismiss. If the user cancels the in-progress rewrite, the view returns silently to idle — no error card is shown for user-initiated cancellation. The original transcript is never modified by a failed or cancelled rewrite.

### 12.5 Voice Prompt Transcription Error
If the [Voice Prompt Capture](#7-6-voice-prompt-capture) fails to transcribe the spoken instruction, a "Try again" button is shown so the user can re-record without dismissing the capture sheet.

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
Transcripts are stored locally on the device. Users can delete individual transcripts via the [swipe or context menu](#1-7-transcript-row-actions) on the home screen or via the Delete action in the [Transcript Detail](#3-5-action-bar) view. There is no iCloud sync — transcripts are stored only on the device. Jot does not explicitly exclude transcripts from standard iCloud Device Backups, so they may be included in a device backup if the user has iCloud Backup enabled.

### 13.5 No Accounts, No Telemetry, No Analytics
Settings surfaces the claim: "Your words stay on your iPhone. No accounts, no cloud, no telemetry." The Help screen's Privacy section reiterates this as: "Transcripts are stored locally on your device. Jot has no cloud sync, no analytics, no account."
