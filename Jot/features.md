# Jot — Product Feature Inventory

> **Scope**: User-facing features only, grouped by surface. No implementation details, file paths, class names, or framework primitives.
> **Cross-links**: Features that interact with each other are linked using anchor references.
> **Visual mockup**: a browsable mockup of every screen lives in `atlas/` (serve it and open `atlas/gen/index.html`; light + dark, all device sizes). `atlas/atlas.json` is the join table — each screen lists the `§` here it demonstrates, so you can go § → screen. Keep it current: when a screen's look changes, re-shoot/regenerate that one screen; when a feature is added/removed, add/remove its screen entry in `atlas.json`.

---

## How Jot Should Feel — Intention & Voice

These intentions sit *above* every feature below. They are the lens for any new design or copy decision — when a feature choice is ambiguous, resolve it toward these.

- **Voice frees your mind.** The point of dictation is to *not* stare at a screen — looking at the screen is the distraction; speaking lets the user think. Surfaces should encourage the user to look away and trust the app, not watch it work.
- **Get out of the way — especially the recording hero.** When the keyboard foregrounds Jot just to record (an Apple constraint, not our choice), the app should send the user *back to their app*, not trap them there. The ideal is they dictate from their own app and barely see Jot. Only when the user *deliberately* chooses Jot (the in-app Dictate button) do we invite them to stay and watch. See [§2.7](#2-7-backgrounding-the-recording-surface) / [§2.3](#2-3-live-streaming-transcript).
- **One model, two passes.** The same accurate model produces both the live preview and the final transcript. While you speak, it keeps re-reading the most recent stretch of audio to refresh the live preview; when you stop, it re-reads the whole recording for the clean, punctuated final ([§2.8](#2-8-live-preview--final-transcript)). The live text is a hint, not the product — it's still rough, so it's shown small, italic, and fading, never the focus.
- **Instructional and inviting, never condescending.** Microcopy states the option and shows how ("Go back to your app," "Here's how to swipe back"). No rhetorical "why don't you…," nothing that talks down to the user.
- **Private by default.** Everything happens on this iPhone. The only thing that ever leaves the device is feedback the user explicitly chooses to send ([§13.6](#13-6-no-accounts-no-telemetry-no-analytics)).

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
  - [1.11 Multi-Select & Combine](#1-11-multi-select--combine)
  - [1.12 Ask Jot Entry Point](#1-12-ask-jot-entry-point)
  - [1.13 Light & Dark Appearance](#1-13-light--dark-appearance)
- [2. Recording Experience](#2-recording-experience)
  - [2.1 Full-Screen Recording Surface](#2-1-full-screen-recording-surface)
  - [2.2 Recording Status Indicator](#2-2-recording-status-indicator)
  - [2.3 Live Streaming Transcript](#2-3-live-streaming-transcript)
  - [2.4 Pause / Resume](#2-4-pause--resume)
  - [2.5 Stop and Finalize](#2-5-stop-and-finalize)
  - [2.6 Cancel Recording](#2-6-cancel-recording)
  - [2.7 Backgrounding the Recording Surface](#2-7-backgrounding-the-recording-surface)
  - [2.8 Live Preview & Final Transcript](#2-8-live-preview--final-transcript)
  - [2.9 Auto-Dismiss on Completion](#2-9-auto-dismiss-on-completion)
  - [2.10 Automatic Clipboard Copy on Completion](#2-10-automatic-clipboard-copy-on-completion)
  - [2.11 Chained Follow-Up Voice Commands](#2-11-chained-follow-up-voice-commands)
  - [2.12 Accessibility: VoiceOver Focus](#2-12-accessibility-voiceover-focus)
  - [2.13 Apple Watch Dictation](#2-13-apple-watch-dictation)
  - [2.14 Cold-Start Loading](#2-14-cold-start-loading)
- [3. Transcript Detail](#3-transcript-detail)
  - [3.1 Original / Rewrite Tabs](#3-1-original--rewrite-tabs)
  - [3.2 Transcript Metadata](#3-2-transcript-metadata)
  - [3.3 Selectable Text](#3-3-selectable-text)
  - [3.4 Rewrite Attribution](#3-4-rewrite-attribution)
  - [3.5 Action Bar](#3-5-action-bar)
  - [3.6 Rewrite Progress and Cancellation](#3-6-rewrite-progress-and-cancellation)
  - [3.7 Edit Transcript](#3-7-edit-transcript)
  - [3.8 Rewrite Feedback](#3-8-rewrite-feedback)
- [4. Setup Wizard](#4-setup-wizard)
  - [4.1 Welcome (W1)](#4-1-welcome-w1)
  - [4.2 Microphone Permission (W2)](#4-2-microphone-permission-w2)
  - [4.3 Keyboard Installation & Full Access (W3)](#4-3-keyboard-installation--full-access-w3)
  - [4.4 How It Works (W4)](#4-4-how-it-works-w4)
  - [4.5 Keyboard Try-It (W5)](#4-5-keyboard-try-it-w5)
  - [4.6 Warm Hold Opt-In (W6)](#4-6-warm-hold-opt-in-w6)
  - [4.7 Completion (W7)](#4-7-completion-w7)
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
  - [5.8 Pause / Resume](#5-8-pause--resume)
  - [5.9 Dark / Light Mode Adaptation](#5-9-dark--light-mode-adaptation)
  - [5.10 Status Banner](#5-10-status-banner)
  - [5.11 Full Access Requirement](#5-11-full-access-requirement)
  - [5.12 Auto-Paste of Completed Dictation](#5-12-auto-paste-of-completed-dictation)
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
  - [7.10 Setup Routing from Articulate](#7-10-setup-routing-from-articulate)
  - [7.11 AI Settings Copy Discrepancy — Titles and Tags](#7-11-ai-settings-copy-discrepancy--titles-and-tags)
  - [7.13 Voice Prompt](#7-13-voice-prompt)
- [8. Vocabulary Boost](#8-vocabulary-boost)
  - [8.1 Custom Term List](#8-1-custom-term-list)
  - [8.2 Vocabulary Empty State](#8-2-vocabulary-empty-state)
  - [8.3 Term Addition](#8-3-term-addition)
  - [8.4 Term Editing and Ordering](#8-4-term-editing-and-ordering)
  - [8.5 Term Quality Warnings](#8-5-term-quality-warnings)
  - [8.6 Vocabulary Boost Toggle](#8-6-vocabulary-boost-toggle)
  - [8.7 Vocabulary Model Status](#8-7-vocabulary-model-status)
  - [8.8 Vocabulary Correction Prompts in the Keyboard](#8-8-vocabulary-correction-prompts-in-the-keyboard)
- [9. Help & Onboarding Reference](#9-help--onboarding-reference)
  - [9.1 Help Screen](#9-1-help-screen)
  - [9.2 How Jot Works](#9-2-how-jot-works)
  - [9.3 AI Rewrite Guide](#9-3-ai-rewrite-guide)
  - [9.4 Privacy Explainer](#9-4-privacy-explainer)
  - [9.5 Collapsible Troubleshooting](#9-5-collapsible-troubleshooting)
  - [9.6 Feedback Contact](#9-6-feedback-contact)
  - [9.7 What Jot Does](#9-7-what-jot-does)
- [10. System Integrations](#10-system-integrations)
  - [10.1 Shortcuts: Transcribe Audio with Jot](#10-1-shortcuts-transcribe-audio-with-jot)
  - [10.2 Action Button Shortcut](#10-2-action-button-shortcut)
  - [10.3 Deep Link Routing](#10-3-deep-link-routing)
  - [10.4 Shortcuts: Save a Note](#10-4-shortcuts-save-a-note)
  - [10.5 Shortcuts: Ask Your Notes](#10-5-shortcuts-ask-your-notes)
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
  - [13.5 Rewrite Edit Training Pairs](#13-5-rewrite-edit-training-pairs)
  - [13.6 No Accounts, No Telemetry, No Analytics](#13-6-no-accounts-no-telemetry-no-analytics)
- [14. Ask Jot](#14-ask-jot)
  - [14.1 Natural-Language Q&A](#14-1-natural-language-qa)
  - [14.2 Voice or Typed Questions](#14-2-voice-or-typed-questions)
  - [14.3 Cited Answers](#14-3-cited-answers)
  - [14.4 Library-Wide Retrieval & Indexing](#14-4-library-wide-retrieval--indexing)
  - [14.5 Answer Model Choice](#14-5-answer-model-choice)
  - [14.6 Availability](#14-6-availability)
  - [14.7 How-To Answers About Jot](#14-7-how-to-answers-about-jot)
  - [14.8 Ask from Shortcuts](#14-8-ask-from-shortcuts)
- [Known Bugs & Planned Work →](known-bugs-and-plans.md) *(separate page — bug tracker + roadmap)*

---

## 1. Home & Library

### 1.1 Editorial Header
The home screen opens with a large serif headline that **rotates through a shuffled pool of dictate calls-to-action** ("What do you want to dictate today?", "Talk faster than you type. Start here.", "Speak it straight into your last app.", and similar) in place of the former static "Recents." title, with today's date retained as a subtitle directly above the search bar and transcript list. The rotating line doubles as the home's quiet micro-messaging surface, gently coaching the speak-don't-type habit without an extra banner. The top row of the header carries only the circular brand logo (clipped from the app icon art) on the left — the "Jot" text wordmark was dropped, and the logo is sized to read at the same diameter as the [Help](#1-8-help-access) and [Settings](#1-9-settings-access) glass buttons on the right so the three sit on one line. Cumulative dictation stats — typing time saved today, lifetime dictation count, and a 14-day sparkline — are surfaced in [Settings → About](#6-5-about--support) rather than on the home page, keeping the home surface focused on recent activity.

### 1.2 Transcript Library with Time Grouping
All past recordings are presented in a scrollable list automatically bucketed into four recency groups — Today, Yesterday, Last 7 days, and Earlier — so users can find recent notes without searching. Library entries include transcripts captured from any surface — the main app, the keyboard, Shortcuts, and the [Apple Watch app](#2-13-apple-watch-dictation) — all interleaved by capture time. Each row shows the recording's timestamp, its duration when known (live dictations record it; file transcriptions via Shortcuts do not), and a two-line excerpt of the transcript text. The most recent entry is rendered as a featured one-line serif-italic quote on a soft blue-tinted card at the top of the list, so the newest transcript reads as the headline of the page; the recency label that introduces it (e.g. "Today") sits inside the same blue-tinted panel so the header and featured quote read as a single editorial section. Entries below the featured row, and all other recency sections, use the standard row treatment on the parent card surface. A small coral `sparkles` glyph appears alongside the timestamp on any row whose transcript has an [AI Rewrite](#7-ai-rewrite) — a quiet, glanceable affordance that distinguishes rewritten entries from raw originals. The same coral sparkle appears on the [keyboard Recents strip](#5-2-recents-strip-idle-state) for visual parity. A few voice captures never land in the library by design — for example a [Voice Prompt](#7-13-voice-prompt) rewrite instruction is used once and never saved as a transcript.

### 1.3 Live Search
A persistent search bar at the top of the library filters the transcript list in real time as the user types, matching against both the displayed (cleaned/rewritten) text and the original raw transcript text, so any recording can be located by a remembered phrase regardless of which version it appears in.

### 1.4 Home Empty State
When the library contains no transcripts, a dedicated empty state is shown in place of the list, inviting the user to make their first dictation.

### 1.5 Home No-Search-Results State
When a search query is active but no transcripts match, a "No matches" message is shown with a suggestion to try a different search term.

### 1.6 Floating Dictate Button
A prominent blue floating action button labeled "Dictate" sits anchored at the bottom of the home screen. Tapping it navigates to the full-screen [Recording Hero](#2-recording-experience) via a navigation push.

While a recording is in progress and the user has [backed out of the recording surface](#2-7-backgrounding-the-recording-surface), the Dictate button is replaced in place by a blue gradient "Recording" pill containing a pulsing white dot, the live elapsed timer, and a small upward arrow. Tapping the pill returns to the live recording surface; the pill carries a soft outer blue wash so it reads as live without dominating the home view.

### 1.7 Transcript Row Actions
Each transcript row supports a swipe-left gesture that reveals two actions — a red **Delete** for single-row removal and a **Select** action that enters [multi-select mode](#1-11-multi-select--combine) with that row pre-selected — so multi-select is discoverable from the swipe rather than hidden. A long-press also enters multi-select (a secondary path) starting with the long-pressed row pre-selected. A short tap on a row opens the [Transcript Detail view](#3-transcript-detail). Delete triggers a confirmation dialog before permanently removing the entry.

### 1.8 Help Access
A question-mark button in the home header opens the [Help screen](#9-help--onboarding-reference) as a modal sheet, accessible at any time without leaving the library.

### 1.9 Settings Access
A gear icon in the home header opens [Settings](#6-settings) as a modal sheet. It replaces the former profile-avatar circle — a gear reads plainly as "settings" without implying a user account, which Jot does not have.

### 1.11 Multi-Select & Combine
Multi-select mode is primarily discoverable from the **swipe-left gesture** on any transcript row, which reveals a **Select** action alongside Delete (see [§1.7](#1-7-transcript-row-actions)); tapping Select enters multi-select with that row pre-selected. A long-press on a row is kept as a secondary entry path (and the VoiceOver "Enter selection mode" action), also entering multi-select with the pressed row pre-selected. In this mode the Dictate button is replaced by a bottom toolbar with three actions: **Select All** (selects every visible transcript), **Combine** (merges 2–5 selected entries into one new transcript), and **Delete N** (removes all selected entries after a confirmation dialog). Tapping additional rows toggles their selection. Exit multi-select by completing an action or by tapping outside the selected rows. Combine is enabled only when at least 2 and at most 5 rows are selected; outside that range the button dims. Tapping Combine opens a confirmation dialog with two options: **Combine and delete originals** (destructive — the source entries are removed and replaced by the new combined one) and **Combine and keep originals** (the new combined entry is created alongside the originals). In both cases, the combined entry is built from the **best available version** of each source — if a source has an [AI Rewrite](#7-ai-rewrite), the rewrite is used; if it does not, the original transcript is used. The picked strings are joined **oldest-first** (the earliest dictation appears at the top of the combined entry, the most recent at the bottom) with paragraph breaks. This is the opposite of the library's visual order — the library shows newest on top — because the combined entry reads naturally as a chronological narrative rather than as a stack of the rows in display order. The result is stored as the new entry's original (the new combined entry has no Rewrite of its own and no Rewrite tab). The new entry receives a fresh timestamp and ledger number.

### 1.12 Ask Jot Entry Point
A small sparkles pill sits next to the [search bar](#1-3-live-search) in the home header. Where search finds a remembered phrase, this opens [Ask Jot](#14-ask-jot) — natural-language Q&A across all the user's notes. The pill only appears once the device has a capable answer model available (see [§14.6](#14-6-availability)), so the entry point is never shown in a non-working state.

### 1.13 Light & Dark Appearance
The entire app follows the system Light / Dark setting automatically — the page wallpaper, Liquid-Glass cards, editorial type, and every text color shift to their dark variants over a near-black page, with no in-app appearance switch. The [Jot Keyboard](#5-9-dark--light-mode-adaptation) and [Apple Watch app](#2-13-apple-watch-dictation) follow the same system appearance (the watch is always on a true-black backdrop). Brand, status, and semantic-icon colors stay constant across both modes; only surfaces, text inks, and keyboard chrome adapt.

---

## 2. Recording Experience

### 2.1 Full-Screen Recording Surface
The app presents a dedicated full-screen recording view primarily in three cases: the user taps the home [Dictate button](#1-6-floating-dictate-button); the user taps Dictate on the [Jot Keyboard](#5-jot-keyboard) from another app with no [Warm Hold](#13-2-warm-hold) active (a *cold* start — the surface opens with a "head back to your app" coaching cue); or the user re-enters a recording they had backgrounded, via the home "Recording" return pill. (As a safety net, tapping Dictate in the keyboard while Jot is foregrounded on a screen with no dictation-ready field also opens the surface rather than dropping the tap.) Dictation that stays in context never shows this surface: keyboard dictation while Jot is already foreground and voice-editing inside a transcript both record inline into the focused field, and the [Action Button Shortcut](#10-2-action-button-shortcut) and Warm-Hold keyboard dictation record in the background without presenting it.

**Exception — keyboard dictation within the [Warm Hold](#13-2-warm-hold) window:** when a warm-hold session is still active, tapping Dictate in the keyboard does NOT bring Jot to the foreground. The recording starts in the background and the user remains in the host app; only the keyboard's [streaming strip](#5-3-streaming-strip-recording-state) animates to reflect recording state. See [§2.9](#2-9-auto-dismiss-on-completion) and [§13.2](#13-2-warm-hold) for details.

### 2.2 Recording Status Indicator
Recording state is communicated implicitly — the dedicated full-screen surface and the live streaming transcript make it unmistakable that the microphone is active. The elapsed-time counter lives inside the blue stop button at the bottom of the screen as a monospace timer, so the duration of the session is always visible alongside the primary "stop" affordance rather than as a separate top-of-screen status line. The freed top space above the transcript carries quiet rotating micro-messages (e.g. "Recording stays on while you go," "looking away helps you find the words," "the thinking happens out loud, not on the screen").

### 2.3 Live Streaming Transcript
While the user speaks, a scrolling text area displays a continuously updating live preview of what is being said, rendered in an italic serif font. The preview is produced by the same accurate model re-reading the most recent stretch of audio — refreshed in sentence-sized chunks at natural pauses and every few seconds — so it is a rough running approximation, not the final text (see [§2.8](#2-8-live-preview--final-transcript)). The view auto-scrolls to follow the newest text so the user always sees the most recent words without manually scrolling. A soft fade at the top edge signals that more content exists above. Because the preview arrives in sentence-sized chunks (at speech pauses or every few seconds), the newest visible words can trail the voice by a few seconds — a quiet ellipsis sits right after the last word, its dots brightening in a slow cycle, signaling that transcription is still catching up and more text is on the way. With Reduce Motion enabled the ellipsis is a steady static one, and it disappears entirely while [paused](#2-4-pause--resume) since nothing is being captured. The same trailing ellipsis appears in the keyboard's [streaming strip](#5-3-streaming-strip-recording-state). This live preview can be turned off with the "Live text while dictating" toggle in [Settings → Dictation](#6-1-speech-model-management) (on by default; turning it off saves battery and does not change the saved transcript; off by default on lower-memory iPhones) — the saved final transcript is unaffected ([§2.8](#2-8-live-preview--final-transcript)).

### 2.4 Pause / Resume
A Pause control sits on the recording surface alongside [Stop](#2-5-stop-and-finalize) and [Cancel](#2-6-cancel-recording). Pausing temporarily stops capturing audio **without finalizing** the recording — the session stays live and the same dictation continues when the user resumes, so the paused gap is simply absent from the saved audio. While paused, the recording dot goes static/hollow and the surface reads "Paused · mic ready, not capturing," and the elapsed timer freezes (it counts only time actually captured, so it resumes from where it left off). The microphone is kept warm during the pause for instant resume, which is why iOS keeps showing its orange microphone indicator — but nothing is captured or stored while paused, exactly as during [Warm Hold](#13-2-warm-hold); the on-screen wording makes the held-but-not-recording state explicit. The live streaming preview is preserved across a pause and new words append after resume rather than restarting. Only Resume or [Stop](#2-5-stop-and-finalize) / [Cancel](#2-6-cancel-recording) leave the paused state; a forgotten pause auto-finalizes once the session reaches the overall recording cap. Pause/Resume is available from both the recording surface and the [Jot Keyboard](#5-8-pause--resume).

### 2.5 Stop and Finalize
A large blue gradient stop button at the bottom of the screen ends the recording. The button contains a white stop square and the running elapsed-time monospace counter side-by-side. After stopping, a brief transcribing state is shown (the stop button displays a spinner) while the [on-device speech model](#6-1-speech-model-management) produces the final accurate transcript from the audio captured during the session — which may differ from the live preview shown during recording. Stop ends the recording from either the active or a [paused](#2-4-pause--resume) state.

### 2.6 Cancel Recording
A "Cancel" pill at the top right of the recording screen discards the current recording without saving any transcript, useful when the user dictated the wrong thing or changed their mind. It is the only header control that ends the recording, and it discards from either the active or a [paused](#2-4-pause--resume) state.

### 2.7 Backgrounding the Recording Surface
The recording surface includes a visible back chevron at the top-left. Tapping it backgrounds the recording without cancelling it — for example, to glance at the home screen or another app — and the standard iOS edge-swipe-back gesture works the same way in parallel. The microphone and live transcription keep running; the home surface replaces the [Dictate button](#1-6-floating-dictate-button) with a blue "Recording" return pill that taps back into the live recording surface. Stopping or cancelling are the only ways to actually end a recording (see [§2.5](#2-5-stop-and-finalize) and [§2.6](#2-6-cancel-recording)).

### 2.8 Live Preview & Final Transcript
Jot uses a single on-device speech model for everything — there is no separate "fast" streaming model. While the user speaks, that same accurate model produces the [live preview](#2-3-live-streaming-transcript) by repeatedly re-reading a trailing window of the recent audio (in sentence-sized chunks, triggered at natural pauses and every few seconds), so the user sees a running approximation as they go. When the user stops, the model re-reads the entire recording once more to produce the clean, fully-punctuated final transcript that is saved to the [library](#1-2-transcript-library-with-time-grouping). Because the preview only ever looks at the most recent audio while the final pass sees the whole recording, the saved transcript can differ from — and reads better than — what scrolled by live. The live preview is the one part that can be switched off — via the "Live text while dictating" toggle in [Settings → Dictation](#6-1-speech-model-management) (and off by default on lower-memory iPhones) — without affecting the saved final transcript, which is always produced on stop. On a fresh install or just after an update the model may still be loading for the first dictation; recording still begins the instant the user taps and nothing said is lost while it loads (see [§2.14](#2-14-cold-start-loading) and [§2.9](#2-9-auto-dismiss-on-completion)).

### 2.9 Auto-Dismiss on Completion
Once transcription finishes, the recording view dismisses itself automatically and the user lands on Jot's home view, with the new transcript already saved and available in the [library](#1-2-transcript-library-with-time-grouping).

When the dictation was initiated from a third-party app's keyboard (via the Jot down key) **and there is no active Warm Hold session (cold start)**, Jot is brought to the foreground during recording and the user must manually swipe back to the host app — for example, by swiping right along the iOS app-switcher gesture bar. The transcribed text is pasted into the originating text field once the user returns to that app. Jot does not automatically switch the user back to the host app. On a fresh install or right after an update, the on-device speech model may still be loading when this cold start fires; in that case the recording **begins capturing the instant the user taps** — their voice is buffered while the model finishes loading, so nothing said during the wait is lost — and, only if the load is genuinely slow, the surface shows a short reassuring [cold-start line](#2-14-cold-start-loading) (no progress bar) until the model is ready and the transcript catches up. Stopping before the model has finished simply waits for it, then transcribes the buffered audio.

**Within the Warm Hold window**, this flow is different: Jot is never brought to the foreground, so no manual swipe-back is needed. The keyboard's streaming strip shows recording progress in place, and when transcription completes the text is auto-pasted without the user leaving the host app. See [§13.2](#13-2-warm-hold) for the Warm Hold UI-path disclosure.

### 2.10 Automatic Clipboard Copy on Completion
When an in-app dictation — started from the home screen [Dictate button](#1-6-floating-dictate-button) or [Recording Hero](#2-1-full-screen-recording-surface) — finishes and the final transcript is saved, Jot automatically places the [automatically cleaned](#7-1-automatic-cleanup) transcript text on the system clipboard. The user can immediately paste it into any other app (Notes, Messages, Mail, a browser field, and so on) without any extra step: no need to open the transcript detail, tap a copy button, or long-press the row. This auto-copy happens as soon as the transcription completes — at the same moment the result becomes available to the [Jot Keyboard](#5-12-auto-paste-of-completed-dictation) — and precedes the [Auto-Dismiss](#2-9-auto-dismiss-on-completion) that returns the user to the library. The [Action Button Shortcut](#10-2-action-button-shortcut) similarly copies its result to the clipboard on completion; both flows share this behavior. Manual copy options — the [row long-press](#1-7-transcript-row-actions), [detail Copy button](#3-5-action-bar), and [Actions Popover "Copy last"](#5-6-actions-popover) — remain available for later retrieval of any transcript.

### 2.11 Chained Follow-Up Voice Commands
Within 30 seconds after a dictation completes, the user can make a short follow-up dictation to transform the prior text — for example, "make it shorter" or "translate that to Spanish." Jot recognises this as a command against the just-dictated text rather than a new separate dictation: the transformed result replaces the prior text on the clipboard, a new transcript entry is created, and the original no longer appears in the keyboard's recent history. Outside the 30-second window, all new dictations are treated as fresh independent entries.

In the new entry's [detail view](#3-1-original--rewrite-tabs), the command utterance itself (e.g., "make it shorter") becomes the **Original** tab text, while the transformed prior dictation appears under the **Rewrite** tab. This means a user opening the follow-up entry sees their voice command as the Original and the rewritten text — attributed as "Rewritten with [model name]" — as the Rewrite.

**Home library vs. keyboard recents asymmetry**: in the Home library, both the original transcript and the follow-up entry appear as separate rows — the original is not hidden or marked in any way. In the keyboard's recents strip, only the follow-up entry is shown; the original is filtered out and does not appear. A user browsing the Home library therefore sees the full chain, while a user glancing at the keyboard recents sees only the latest result.

See also: [keyboard chained follow-up cross-reference](#5-3-streaming-strip-recording-state).

### 2.12 Accessibility: VoiceOver Focus
When the recording surface opens via an automated entry path — such as a keyboard-initiated recording triggered by a deep link — VoiceOver focus is placed on the recording status element (pulsing dot and elapsed timer) so assistive technology users are immediately informed that recording is underway, rather than landing on the back-navigation button.

### 2.13 Apple Watch Dictation
Jot ships a standalone Apple Watch app (watchOS 26+) for capturing thoughts directly from the watch — useful when reaching for the phone is awkward. Recording works without the iPhone present: audio is captured locally on the watch as a small compressed file and queued. Whenever the watch comes within range of the paired iPhone running Jot, queued recordings transfer automatically in the background and run through the same on-device transcription pipeline as in-app dictations — the resulting transcript appears in the [Home library](#1-2-transcript-library-with-time-grouping) alongside everything else. The watch app is introduced to new users on the final [Setup Wizard completion panel (W7)](#4-7-completion-w7), which surfaces a "one more thing" Apple Watch card.

**Watch home screen.** The screen opens directly on a large round blue "dictate" button that glows and slowly breathes — no app-name title, since you're already in the watch app. Tapping it starts recording; "Tap to dictate" sits just below. The page then scrolls into a "Recent" section: a header row with an "All N" link to the full list (shown once there are more than three transcripts), then any recordings still waiting on the phone shown at the top as "Waiting to sync" cards (a play button, the status, and how long ago it was captured in amber) — each disappears the moment the phone confirms receipt, with the finished transcript following seconds later. **Tap a "Waiting to sync" card to play the recording back** on the watch speaker (useful to hear, or to recover, one that's stuck), or **swipe it left to delete** it if you don't want to sync it. Below the pending cards sit the three most recent transcripts as tap-to-open cards. Recordings sync automatically, so there is no top-of-screen pending badge or success ribbon. At the very bottom — only reachable by scrolling past the transcripts — a single muted "Sync diagnostics ›" footer row leads to the connection-status surface and Reset sync button.

**Recording sheet.** Modal sheet centered on a large round coral button with the running `mm:ss` timer **inside** it — tapping the button stops and saves. The button carries no "Stop" word; a quiet "Tap to stop" hint sits below a live coral amplitude waveform. The button + waveform freeze (waveform replaced by a static "REC" cue) in Always-On Display and when Reduce Motion is enabled. The only outcome is a saved recording — there is no discard path: even dismissing the sheet saves the capture rather than losing it, so accidental taps can't lose audio. Recordings cap at 15 minutes per session; the watch warns at 14:30 with a haptic and banner so long captures aren't silently truncated. An extended runtime session keeps the recorder alive while the wrist is lowered.

**Recent transcript list.** The watch surfaces the most recent ten transcripts (read-only — taps open a full-text view; all editing happens on the phone). The top three appear inlined on the home screen as individual cards; the rest are one tap away via "All N". Watch-originated entries show a small watch glyph next to the date; transcripts captured on the phone show no glyph (the absence is the default). Recordings still waiting on the phone appear as "Waiting to sync" cards at the top of both lists — tap one to play it back, swipe left to delete it — and each clears as soon as the phone has it, with the real transcript following moments later. Opening a transcript shows its full text plus a "Synced to iPhone" confirmation row. A "Last synced" footer surfaces in amber on the full list if it's been more than 24 hours since the last successful sync.

**Complications + Smart Stack tile.** A watch complication (corner, circular, inline variants) and a Smart Stack tile let the user start a recording in one tap from any watch face — both deep-link straight into the recording sheet.

**Storage cap.** The watch holds at most 50 pending recordings before new captures are blocked with an explicit alert ("Watch storage full — open Jot on iPhone to sync"). Fail-closed by design: silently dropping the oldest unsynced recording would be worse than the brief friction of forcing a sync.

### 2.14 Cold-Start Loading
When a dictation starts while the [speech model](#6-1-speech-model-management) is still loading — typically the first dictation after an install or update, or after the system reclaimed the model's cache — recording begins capturing the instant the user taps ([§2.9](#2-9-auto-dismiss-on-completion)), so nothing said is lost. On a fast/warm load nothing special is shown beyond the normal "Listening…". Only a genuinely slow cold load surfaces a short reassuring line, and during a long load that line rotates through a few different messages so it doesn't sit static — there is **no progress bar, no percentage, and no model name**. This applies on both the [recording surface](#2-1-full-screen-recording-surface) and the [keyboard streaming strip](#5-3-streaming-strip-recording-state); the [live transcript](#2-3-live-streaming-transcript) replaces it the moment the model is ready.

---

## 3. Transcript Detail

### 3.1 Original / Rewrite Tabs
The detail view for any transcript presents two tabs — Original and Rewrite — selectable via a two-pill segment control. The Original tab always shows the unmodified text produced by the [speech model](#6-1-speech-model-management). The Rewrite tab shows the [automatic cleanup](#7-1-automatic-cleanup) output when present, and later shows the output of [AI Rewrite](#7-ai-rewrite) if one has been generated; older entries with neither show an empty state with a prompt to create one. When cleanup or a rewrite already exists, the detail view defaults to the Rewrite tab on open so the improved text is immediately visible.

### 3.2 Transcript Metadata
A subline at the top of the detail view displays the relative recording date, the word count, and the duration when available (present for live dictations; omitted for file transcriptions via Shortcuts), giving context without cluttering the reading area. The detail view has no title surface — title and tag fields are intentionally absent from v1 (see also [§7.11](#7-11-ai-settings-copy-discrepancy--titles-and-tags)).

### 3.3 Selectable Text
Both the original transcript text and the rewrite text are fully selectable, allowing users to copy any portion to the clipboard using the standard iOS text selection handles.

### 3.4 Rewrite Attribution
When a rewrite is present, a small attribution line names the active rewrite model. The label always reflects whichever rewrite model is currently selected in Settings; the UI does not distinguish between [automatic cleanup](#7-1-automatic-cleanup) output and downloaded-model output. The attribution row also hosts the [rewrite feedback affordance](#3-8-rewrite-feedback) (thumbs up / thumbs down) and the Discard rewrite button.

### 3.8 Rewrite Feedback
The [Rewrite Attribution](#3-4-rewrite-attribution) row hosts a 👍 / 👎 pair to the left of the Discard button. Tapping one sets the rating; tapping the active glyph again clears it; tapping the opposite glyph swaps it. A light haptic confirms each tap and the glyph fills in (`hand.thumbsup.fill` in accent blue or `hand.thumbsdown.fill` in red) when active. The rating is local and private; nothing is uploaded. It pairs with the [Edit Rewrite](#3-7-edit-transcript) flow to produce a complete signal — a 👎 plus a user correction is the strongest data for future model fine-tuning, but each half is meaningful on its own (a 👎 with no edit still says "this was wrong but I didn't have time"; a 👍 with no edit says "the model nailed it"). The rating clears whenever the underlying rewrite changes — tapping Articulate regenerates the rewrite and resets the rating; Discard clears the rewrite, edit, and rating together (see [§13.5](#13-5-rewrite-edit-training-pairs)).

### 3.5 Action Bar
A row of actions at the bottom of the detail view provides four actions, left-to-right: Delete, [Edit](#3-7-edit-transcript), an "Articulate" button (blue pill that triggers [AI Rewrite](#7-ai-rewrite)), and Copy. Delete sits on the far-left so the destructive action is harder to hit accidentally; Copy sits on the far-right where the right-hand thumb naturally falls. The Copy button is icon-only — there is no visible text label. After tapping Copy, the icon changes to a checkmark briefly before reverting to the copy icon after approximately 1.3 seconds, confirming the action to the user. The VoiceOver accessibility label updates from "Copy transcript" to "Copied to clipboard" during this window. Tapping Delete shows a "Delete this entry?" confirmation dialog with a destructive "Delete" button and a "Cancel" button before the entry is permanently removed.

### 3.6 Rewrite Progress and Cancellation
When a rewrite is actively running, a progress card appears alongside the action bar (the action bar itself remains visible) with a "Rewriting…" indicator and a Cancel button, allowing the user to abort the generation mid-stream.

### 3.7 Edit Transcript
The Edit pencil in the [action bar](#3-5-action-bar) turns the currently-visible tab into an editable text field with a slim bottom bar offering Cancel and a blue Save (✓) button. The tab pill is hidden while editing — one tab at a time. Editing the **Original** tab overwrites the transcript text in place; the pre-edit speech-model output is not retained (the user's correction becomes the new ground truth). Editing the **Rewrite** tab keeps the model's rewrite frozen as the "before" and saves the user's correction as the "after," so the pair is preserved as a future-improvement training signal (see [§13.5](#13-5-rewrite-edit-training-pairs)). Tapping Articulate after an edit generates a fresh rewrite and clears the prior user-edit; tapping the Rewrite tab's Discard affordance clears both the model rewrite and any user edit together. The Edit pill is disabled while a rewrite is mid-flight and while the back chevron is also disabled mid-edit so accidental swipes don't silently lose work. While editing, a microphone button in the bottom bar lets the user dictate straight into the field: speaking inserts text at the cursor (or replaces the current selection), the words stream in live as they are spoken, and tapping the button again (now a Stop control) finishes and drops the dictated text in place. This in-field dictation pastes into what the user is editing and saves no separate transcript of its own; Cancel and Save stay disabled until the dictation is stopped so the streamed text can't be cut off mid-word. While editing, any text the user **adds or changes during this session** — whether typed or dictated — is shown in *italic*, while the untouched original text stays upright, so it's easy to see exactly what was changed. The italic is a live editing cue only: on Save everything is stored as plain text and the next time the entry is opened it all reads upright again.

---

## 4. Setup Wizard

The setup wizard has seven panels (W1–W7). The default on-device speech models ship inside the app — see [§6.1 Speech Model Management](#6-1-speech-model-management) — so the wizard no longer needs a "Download speech model" step. The wizard also no longer includes a separate in-app dictation practice step; users go straight from the How-It-Works explainer to dictating from the real keyboard, which is the workflow they will use day-to-day.

### 4.1 Welcome (W1)
The first wizard panel introduces Jot with a large wordmark headline and a short tagline, then offers a single "Get started" call-to-action that begins the setup flow. W1 also has the standard wizard close (X) button with a "Skip setup?" confirmation prompt (same as on every other panel).

### 4.2 Microphone Permission (W2)
The second panel requests microphone access via the system permission dialog. If the user grants permission, the wizard advances automatically. If permission was previously denied, the panel shows a deep-link button that opens iOS Settings directly to Jot's permission page so the user can enable it without hunting through menus.

### 4.3 Keyboard Installation & Full Access (W3)
The third panel sends users to Keyboard Settings once to add Jot and turn on Full Access. When the keyboard has not been detected, the primary call-to-action reads "Open Keyboard Settings"; when the user returns with Jot installed, it changes to "Continue" and the panel title updates to "Jot keyboard detected." Jot can detect keyboard installation via the system's installed-keyboards list, but it cannot detect Full Access directly — Full Access remains a manual user attestation. A secondary "I've already done this" button is shown only in the not-yet-detected state as an escape hatch; once the keyboard is detected, "Continue" is the only footer action. See [§13.3](#13-3-full-access-disclosure).

### 4.4 How It Works (W4)
The fourth panel is a visual explainer illustrating the core usage loop: tap Dictate in the keyboard → swipe back to the host app while it keeps recording → stop from the keyboard → [cleaned text](#7-1-automatic-cleanup) is pasted automatically at the cursor. The body sentence says "Tap Dictate, swipe back to your app, then stop from the keyboard." and the caption underneath the flow diagram reads `TAP DICTATE → SWIPE BACK → STOP → TEXT PASTED`. The diagram uses the origami-crane glyph in the middle position to indicate "Jot app opens." (The crane is a legacy brand mark still used here and as the keyboard-extension icon; the app's home-screen icon is now the glassy "j".) This orientation screen has no required user action other than reading and tapping "Got it".

### 4.5 Keyboard Try-It (W5)
The fifth panel is a guided "try the keyboard" step. The user taps a practice field, which raises the keyboard; if the system keyboard appears instead of Jot, an in-field cue tells them to tap the globe key to switch to the Jot keyboard (escalating to "it's the bottom-left key" if they linger). They tap "Jot down", their words stream live in the keyboard, and on stop the result is pasted into the practice field as an "it works" moment, following the normal [automatic cleanup](#7-1-automatic-cleanup) path. The user then taps **Continue** themselves — the panel does **not** auto-advance — and a manual "I tried it" button allows skipping. The speech model begins warming when the wizard opens, so it's usually ready (or nearly so) by this panel. This is the wizard's only "try it" step — practicing inside the wizard surface was dropped so users experience Jot exactly as they will use it after setup.

### 4.6 Warm Hold Opt-In (W6)
The sixth panel offers the [Warm Hold](#13-2-warm-hold) feature: keeping the microphone session alive for 2 minutes after each recording to reduce startup latency for the next dictation. The user flips a "Keep mic ready" toggle (showing an "Always" / "Off" status) and taps Continue; the choice is saved to Settings and can be changed later via [Settings → Privacy](#6-4-privacy-controls), where the duration is also customizable (60s, 2 min, 3 min, or 5 min).

### 4.7 Completion (W7)
The seventh and final panel congratulates the user with a "You're ready." headline and a body line ("Jot works now — start dictating in any app, any time."), then closes onboarding with a single "Start jotting." call-to-action. There is no longer a fork to an optional AI Rewrite step — AI Rewrite is set up later from [Settings → AI](#6-3-ai-settings-link) whenever the user wants it, not during onboarding. Below the body, W7 shows a "one more thing" Apple Watch card — a soft-blue tile with a watch glyph, the title "It's on your wrist, too," and a line noting that ideas captured on the watch sync back automatically — introducing the [Apple Watch app](#2-13-apple-watch-dictation) before the user finishes setup.

### 4.9 Wizard Navigation Chrome
Every wizard panel except Welcome (W1) shares a consistent chrome: a back chevron (top-left) that steps to the previous panel, and a close button (top-right, X) that exits the wizard entirely. Welcome has no previous step, so the back chevron is absent on that panel. Tapping the close button shows a "Skip setup?" confirmation dialog before dismissing. If a recording is in progress when the wizard is exited, the recording is stopped automatically so no audio is left capturing in the background. A left-edge swipe gesture (drag rightward from the leading 22 pt strip) performs the same back action as the back chevron.

### 4.10 Wizard Progress Dots
At the top of every wizard panel, a row of seven dots represents the seven setup steps (W1–W7). The current step's dot is larger and filled in the accent color; completed steps are smaller filled dots; upcoming steps are smaller outlined dots.

---

## 5. Jot Keyboard

### 5.0 Dictation-Only Design
Jot's keyboard is dictation-only and has no QWERTY layout. Users keep their regular system keyboard for typing and switch to Jot only to dictate. This is surfaced explicitly in the [How It Works wizard step](#4-4-how-it-works-w4) so users understand the intended workflow before completing setup.

### 5.1 Full Custom Keyboard
Jot replaces the system keyboard with a fully custom layout when active. The layout is recording-controls-first: a top information strip and an action row with the primary controls — **Pause + Stop + Cancel**, with Cancel rendered as a trash-can on the left for easy reach — plus a single **adaptive Enter** key whose glyph adapts to the host field's return action (return-arrow, search glyph, Go, or Send). On wider devices the controls and Enter sit in **one line**; on narrower devices the layout adapts and keeps Enter on its own row below. The keyboard uses native side margins so it does not span the full screen width, sits at a fixed height, and styles itself to match the host app's light or dark appearance automatically. Below it, Apple's fixed system row (globe / dictation) remains. See [§5.4 Dictate / Stop](#5-4-dictate--stop-control) and [§5.8 Pause / Resume](#5-8-pause--resume).

### 5.2 Recents Strip (Idle State)
When the keyboard is idle (not recording), the top strip shows up to ten recent dictation entries with their timestamps and truncated [cleaned text](#7-1-automatic-cleanup). Each row is split into two tappable zones: the **body** (timestamp + text) re-inserts that transcript at the cursor, and a **small trailing button** (`arrow.up.forward.app` glyph, accent color) brings the main app to the foreground and opens that transcript's detail view ([§3](#3-transcript-detail)) — useful for reviewing, running a Rewrite, or sharing without leaving the keyboard's host app to find the entry manually. The strip is scrollable, with a soft fade at the bottom edge indicating additional entries below. Entries that have an [AI Rewrite](#7-ai-rewrite) display a small coral `sparkles` glyph inside the body zone before the trailing button — the same affordance used in the [home library](#1-2-transcript-library-with-time-grouping) so the visual language stays consistent across surfaces. A "See all" link brings the main app to the foreground via a deep link. If the app is on the home screen with no overlays active, the transcript library is visible; the deep link does not force a navigation reset, so if a sheet or other navigation is already open the user will not automatically land on the library. **Full Access is required for the recents strip to show any content**: without it, the strip header still renders but the row area is silently blank — no recent dictation rows appear and no empty-state message is shown (see [§5.11](#5-11-full-access-requirement)). While a row is held, it lights with a subtle blue highlight and a thin leading accent bar so the user can see exactly which entry their touch is on, and a small contextual hint appears in the strip header naming the action — "Pastes here" while pressing a row body, "Opens in Jot" while pressing the trailing button. This is purely visual feedback layered on the existing gestures: a tap still pastes, and pressing then scrolling still scrolls the list without pasting, exactly as before.

### 5.3 Streaming Strip (Recording State)
When a dictation is in progress inside the keyboard, the top strip transforms into a live recording display: a blue pulsing dot, an elapsed timer, a six-bar animated waveform, a brief header status line ("We tidy this up when you stop") noting the live text gets a cleanup pass once recording ends, and a scrollable pane that shows the [live preview transcript](#2-3-live-streaming-transcript) in real time, rendered in the same small italic serif used by the recording surface. This live preview honours the same "Live text while dictating" [setting](#6-1-speech-model-management) as the recording surface; with it off the pane stays empty and only the final transcript pastes on stop. When a [cold start](#2-9-auto-dismiss-on-completion) begins before the [speech model](#6-1-speech-model-management) has finished loading, the pane shows the same [cold-start loading](#2-14-cold-start-loading) treatment in place of the partial text — a short reassuring line (no progress bar) only if the load is genuinely slow — and switches to the live transcript the moment the model is ready (recording is already capturing the whole time, so nothing said during the load is lost). The pane is bottom-anchored — the first words appear near the bottom of the pane and older lines push upward as more text arrives — with the same trailing "still transcribing" ellipsis as the [recording surface's live preview](#2-3-live-streaming-transcript) (quiet accent-blue dots right after the newest word, brightening in a slow cycle; static under Reduce Motion) and a top-edge fade for overflow; the visible stream is capped to a bounded height so it never grows past the strip. While the dictation is [paused](#5-8-pause--resume), the pulsing dot goes static/hollow, the timer freezes, "Paused · mic ready, not capturing" is shown, and the waveform hides; the partial text already shown is kept (its trailing ellipsis hidden, since nothing is being captured) and resuming appends to it. A "↓ live" pill appears when the user has manually scrolled up and the view is no longer tracking the newest content; tapping the pill restores auto-follow. Follow-up voice commands (see [§2.11](#2-11-chained-follow-up-voice-commands)) apply within the 30-second window after the keyboard dictation completes.

### 5.4 Dictate / Stop Control
A prominent pill button in the keyboard's action row toggles recording on and off. The label and appearance change to reflect the current state — "Dictate" when idle, active stop styling when recording — so the current state is always unambiguous. While recording it is joined by [Pause / Resume](#5-8-pause--resume) and a trash-can Cancel on the left ([§5.1](#5-1-full-custom-keyboard)). When Full Access is not enabled, the button displays "Enable Full Access" and tapping it opens Jot's iOS Settings page (from which the user navigates to Keyboards → Jot to toggle Full Access) instead of starting a recording.

### 5.5 Post-Stop "Working" State
Immediately after the user stops a keyboard dictation, the Jot down button transitions to a "Working" label while transcription finishes on-device. The keyboard remains visible and the user can see that processing is in progress before the result is inserted. After the result is inserted, if Jot has a candidate correction to the user's custom vocabulary, the keyboard may surface a small confirmation card asking the user to answer one question (e.g. "what should this say?") — see [§8.8 Vocabulary Correction Prompts in the Keyboard](#8-8-vocabulary-correction-prompts-in-the-keyboard).

### 5.6 Actions Popover
An actions button in the action row opens a compact glass popover with four operations: **Paste** (pastes whatever is currently on the system clipboard into the host app's focused field), **Copy** (places the currently-selected text in the host's focused field on the clipboard; enabled only when there is a non-empty selection AND Full Access is granted), **Undo last insertion** (removes the text the keyboard most recently pasted), and **Redo last insertion** (re-inserts text that was just undone). The popover dismisses after each action.

### 5.7 Backspace Hold-to-Delete
The backspace key deletes one character on tap. Holding the backspace key triggers a repeat-delete behavior, continuously removing characters while the key is held, matching standard iOS keyboard ergonomics.

### 5.8 Pause / Resume
While a keyboard dictation is in progress, a Pause control sits in the action row next to Stop and the trash-can Cancel ([§5.1](#5-1-full-custom-keyboard)). It is the same [Pause / Resume](#2-4-pause--resume) behavior as the recording surface: pausing keeps the microphone warm and the dictation open without finalizing it, the [streaming strip](#5-3-streaming-strip-recording-state) shows "Paused · mic ready, not capturing" with a static dot and frozen timer, and resuming continues the same dictation with new words appended. Pause can be initiated and cleared from the keyboard without bringing the main app to the foreground; the paused/resumed state stays in sync between the keyboard and the recording surface.

### 5.9 Dark / Light Mode Adaptation
The keyboard reads the host app's keyboard appearance setting and renders itself accordingly, so Jot's keyboard matches dark-mode apps natively without any user configuration. The rest of the app adapts to the system appearance the same way — see [§1.13](#1-13-light--dark-appearance).

### 5.10 Status Banner
Errors and warnings (such as microphone permission issues or model loading failures) surface as an overlay status banner inside the keyboard, keeping the user informed without requiring them to leave the host app.

### 5.11 Full Access Requirement
The return key works without Full Access. Backspace and Undo/Redo also work without Full Access. The following actions are specifically gated:

- **Jot down**: when Full Access is absent, the Jot down button is replaced by an "Enable Full Access" CTA (with a lock-shield icon). Tapping it opens iOS Settings to Jot's app-settings page; from there the user navigates General → Keyboard → Keyboards → Jot Keyboard → Allow Full Access to flip the toggle.
- **Paste**: the Paste row in the [Actions Popover](#5-6-actions-popover) is silently disabled (dimmed, non-interactive) without Full Access, because clipboard reads are unavailable. No error is shown.
- **Copy**: the Copy row in the [Actions Popover](#5-6-actions-popover) is silently disabled without Full Access, because the keyboard can only read the host's selected text when Full Access is granted. No error is shown.
- **Status banner**: the banner that relays dictation result messages is suppressed entirely when Full Access is absent.
- **Recents strip content**: without Full Access the recents strip header still renders, but the row area is silently blank — no entries appear and no empty-state message is shown. Full Access is required for any recent dictation rows to appear.
- **See all (recents)**: tapping the "See all" link in the keyboard's recents strip requires Full Access. Without it, the tap opens Jot's iOS Settings page — from which the user can navigate to Keyboards → Jot to enable Full Access — rather than opening the main app's full recents list.

The [Setup Wizard](#4-3-keyboard-installation--full-access-w3) guides users through enabling Full Access during initial setup. See also [§6.4 Privacy Controls](#6-4-privacy-controls) for the Full Access informational row in Settings and [§13.3 Full Access Disclosure](#13-3-full-access-disclosure) for the canonical explanation of why Full Access is required.

### 5.12 Auto-Paste of Completed Dictation
When a keyboard dictation finishes and the transcript is ready, the keyboard automatically inserts the [automatically cleaned](#7-1-automatic-cleanup) text into the host app's focused text field — no tap required. This is the core workflow the [How It Works wizard step](#4-4-how-it-works-w4) illustrates: speak, stop, and the text appears at the cursor. The auto-paste arms at the moment the user taps Stop and fires as soon as the final transcript is available.

---

## 6. Settings

### 6.1 Speech Model Management
Jot picks its on-device speech model **automatically, based on the iPhone** — there is no model selector or variant picker. On newer, higher-memory iPhones (iPhone 12 Pro / 13 Pro and iPhone 14 and later) Jot uses the larger, more accurate model, which ships bundled inside the app, so it is available immediately on install with no download and the first dictation works offline. On older or lower-memory iPhones that can't run the larger model (such as iPhone 11, the iPhone 12 and 13 non-Pro, and iPhone SE), Jot automatically uses a smaller English model that is **not bundled** (to keep the app download small) and is **fetched once, on the first dictation**; it then stays on the iPhone and works offline like the bundled model. The choice is made by the device — there is no manual download, switch, or purge control, and the bundled model can't be deleted (it lives in the read-only app bundle and is restored on reinstall). Because the model is chosen automatically and is not something the user manages, the Settings card for it is now labelled **"Dictation"** and carries only two controls — no model name, no readiness pill, no variant picker, and no "runs entirely on this iPhone" footer:

- **Language** — a non-interactive selector reading "English" (the only language today; more languages will appear here as they ship).
- **Live text while dictating** — a toggle (on by default) that controls whether the [live preview](#2-3-live-streaming-transcript) is shown while recording. Turning it off saves battery and does not change the saved transcript; it starts off by default on lower-memory iPhones.

[Vocabulary Boost](#8-vocabulary-boost) always applies, regardless of these settings.

### 6.2 Vocabulary Settings Link
A row shows the current count of [custom vocabulary terms](#8-vocabulary-boost) and navigates to the full [Vocabulary settings screen](#8-vocabulary-boost) where terms can be managed.

### 6.3 AI Settings Link
A row in the AI section shows the current status of the [AI Rewrite model](#7-ai-rewrite) and navigates to the full AI Rewrite settings screen where the model can be downloaded, freed, and prompts can be managed. There is no longer a choice of which model answers [Ask Jot](#14-ask-jot) — Ask always uses Apple Intelligence, so the former "Use on-board Qwen for Ask" toggle has been removed (see [§14.5](#14-5-answer-model-choice)).

### 6.4 Privacy Controls
A Privacy section shows a tappable Full Access row (subline "General → Keyboard → Keyboards → Jot", trailing external-arrow), plus a toggle for [Warm Hold](#13-2-warm-hold) after [wizard step W6](#4-6-warm-hold-opt-in-w6). When Warm Hold is on, the toggle is followed by a "Ready for" duration picker with 60s, 2 min, 3 min, and 5 min options. The Full Access row opens iOS Settings to Jot's app-settings page; the subline gives the user the breadcrumb to navigate from there to Allow Full Access (Jot cannot read its state directly — see [§13.3](#13-3-full-access-disclosure)). The bottom-of-section caption "Your words stay on your iPhone. No accounts, no cloud, no telemetry — only feedback you send is ever transmitted." carries the on-device-only message (with [Send Feedback](#9-6-feedback-contact) named as the sole exception); no separate "On-device only" row is shown. Below the rows, a plain (non-tappable) **"Your privacy is protected"** explainer mirrors the iOS system-Settings privacy copy (see [§13.6a](#13-6a-ios-settings-helper-system-settings--jot)).

### 6.5 About & Support
An About section provides links to Help & Support (opens [Help](#9-help--onboarding-reference)), Re-run setup wizard (restarts the [Setup Wizard](#4-setup-wizard) from the beginning for troubleshooting or exploration), Send feedback (opens an in-app feedback form — see [§9.6](#9-6-feedback-contact)), the app version number, Donations (opens the in-app [Donations](#6-7-donations) screen), a Privacy Policy link, an Acknowledgements screen (see [§6.6](#6-6-acknowledgements)), and a **Diagnostics** screen — a scrollable on-device log of recent app events (recording start/stop, paste outcomes, the vocabulary gate's decisions) that can be copied or cleared, surfaced for troubleshooting and containing no personal data (relocated here from the Help screen). When at least one dictation has been recorded, a "Time saved" row appears as the first entry of the About card, showing minutes saved today, the cumulative dictation count, and a small 14-day blue sparkline — the same lifetime stats that the home page used to surface inline, relocated here so the home view stays focused on recent activity (see [§1.1](#1-1-editorial-header)).

### 6.6 Acknowledgements
A dedicated Acknowledgements screen credits the open-source software and open-weight models that Jot is built on. It is organised into two sections: "Models & fonts" — listing the on-device speech models, the AI rewrite model (Qwen 3.5 4B), and the typeface used in the app, each with the author, license type, and a tappable link to the upstream source — and "Swift packages" — listing the major third-party Swift packages used by the app, with attribution and source links. Note: the list is curated and may not include every package the app uses. A footer note reiterates that all speech recognition and AI rewriting runs on-device and that no audio or transcript data is shared with any of the credited parties.

### 6.7 Donations
The Donations screen is reached from [Settings → About](#6-5-about--support) as an in-app navigation push. It explains Jot's free model, optionally personalizes the message with the user's estimated time saved when they have dictated for at least five minutes, and shows a searchable list of charities with their current Jot-raised totals. Charity names, totals, donation counts, and the community total come from Jot's donations summary feed; the app does not bundle charity descriptions or a fixed charity list. Each charity row offers $2 and $10 quick-give actions that open the matching Every.org donation page in the system browser. If current totals cannot be refreshed, the screen shows the last known totals when available, or a retry state when no totals have ever loaded.

---

## 7. AI Rewrite

### 7.1 Automatic Cleanup
Jot strips the most obvious filler tokens — "um", "uh", "er", "uhm", "erm" and their elongated variants — from every dictation before it lands on the clipboard or in the library. This is a fast lexical sweep that always runs: there is no toggle, no separate model, no extra download, and nothing leaves the device. The cleaned text is what appears in the Original transcript surface, gets pasted into the host app, and is what [AI Rewrite](#7-2-on-device-ai-rewrite-model) operates on when invoked. Paragraph boundaries inserted by the segmenter are preserved (the sweep only consumes adjacent spaces, never newlines), and obvious words containing filler-like substrings ("umbrella", "umpire", etc.) are left intact because the sweep is anchored on word boundaries. When the user dictates again right after a previous dictation, Jot inserts a separating space ahead of the new text so consecutive dictations don't run together into one unbroken sentence. The legacy "Clean Up Transcript" parameter on the ["Transcribe Audio with Jot" Shortcuts action](#10-1-shortcuts-transcribe-audio-with-jot) is a separate per-run flag that uses Apple Intelligence and continues to default to off.

### 7.2 On-Device AI Rewrite Model
Jot offers an optional on-device language model download that enables a full prose rewrite of any transcript. The model runs entirely on-device with no data sent to any server. Fresh installs default to the current rewrite model (about 2.5 GB on disk); the [Switch Model Picker](#7-9-switch-model-picker) is in place for future alternates, though only a single model is currently offered. **Downloading the model IS enabling the feature** — there is no separate on/off toggle. Two explicit download entry points exist: (1) tapping the "Download · 2.5 GB" CTA on the [AI Rewrite settings](#6-3-ai-settings-link) model strip, and (2) tapping the Articulate action in the [Transcript Detail view](#3-transcript-detail) when the model is not ready, which opens AI Rewrite settings as a sheet where the same Download CTA lives. Every download CTA and model strip displays the currently-selected model's name and exact size, so the user sees what they are downloading before they tap. The download runs in the foreground; the model strip surfaces a "Keep Jot open while the model downloads" caption under the progress bar to set expectations about backgrounding.

### 7.3 AI Rewrite Activation Model
**Aspirational (keyboard wand): S.** **Plan: [docs/plans/keyboard-magic-wand-entry.md](../docs/plans/keyboard-magic-wand-entry.md).** Phase 0 (XS) corrects the misleading Help copy; Phase 1 (S) wires a wand button into the keyboard action row using the rewrite plumbing that already exists in `Jot/Shared/Intents/`.

AI Rewrite has no separate on/off toggle. **Downloading the model is enabling the feature.** A user who has not downloaded the model can still see the action: in [Settings → AI](#6-3-ai-settings-link) the model strip surfaces a "Download · 2.5 GB" CTA, and in the [Transcript Detail view](#3-transcript-detail) the Articulate pill is fully visible and tapping it opens AI Rewrite settings as a sheet so the user lands directly on the same CTA. The Help and Settings screens describe rewriting via a "Magic" wand entry in the keyboard; the current keyboard UI does not expose that action (see [§5.6](#5-6-actions-popover) — the recording controls, the adaptive Enter, and Actions are the only row controls), so the keyboard wand/Magic entry point is advertised but not yet present.

### 7.4 Rewrite Trigger from Detail View
From the [Transcript Detail](#3-transcript-detail) view, the blue "Articulate" pill in the action bar opens the [Prompt Picker](#7-5-prompt-picker) so the user can select which rewrite style to apply to the current transcript.

### 7.5 Prompt Picker
A bottom sheet lists all saved rewrite prompts, each with an icon, a name, and a short description. A subline below the prompt list header shows the word count of the source transcript being rewritten and the name of the currently active rewrite model (e.g. "42 words · using Qwen 3.5 4B"). The model name reflects whichever option the user has picked in the [Switch Model Picker](#7-9-switch-model-picker). The list contains the three built-in default prompts (Cleanup, Action Items, Email) plus any prompts the user has created in [Settings → AI](#7-7-saved-prompt-management). Selecting a prompt applies it to the current transcript. Below the list, a plain centered "+ New prompt" text link opens the [New Prompt sheet](#7-12-new-prompt-sheet). A footer note clarifies that rewriting replaces the previous rewrite while leaving the original transcript untouched. See [Voice Prompt](#7-13-voice-prompt) for the picker's second row, which lets the user *speak* the rewrite instruction instead of picking a saved one.

### 7.7 Saved Prompt Management
In [Settings → AI](#6-3-ai-settings-link), users can view their full list of saved rewrite prompts. The screen leads with an italic serif "AI." title and a small "EXPERIMENTAL" chip to set expectations about feature maturity. Prompts can be reordered by dragging, deleted by swiping, and edited by tapping. Each prompt row shows an icon, the prompt name, and — for the four built-in defaults (Cleanup, AI prompt, Action Items, Email) — a mini before→after sample that previews what the prompt does to a representative transcript. Swiping to delete shows an alert with the prompt's name as the title (e.g. "Delete "My Prompt"?") and the message "This can't be undone." — with a destructive "Delete" button and a "Cancel" button — before the prompt is removed. A "+ New prompt" button at the bottom opens a dedicated New Prompt sheet (see [7.12](#7-12-new-prompt-sheet)). Inside the prompt editor for an existing prompt, the system prompt fills the editor as the hero element and a slim "Try this prompt" footer pill at the bottom expands upward into a result panel when tapped — showing the BEFORE transcript, an arrow with run timing, the AFTER rewrite, and Copy + Run again buttons; an "Expand" link opens a full-screen text editor for the instruction. The footer pill defaults to the user's most recent recording, and tapping the recording-name sublabel (marked with a small up/down chevron) opens a recording picker listing recent recordings with a coral checkmark on the currently selected one — picking a different recording updates the BEFORE block and what Run rewrites. A spoken instruction from the Prompt Picker's [Voice Prompt](#7-13-voice-prompt) row never appears in this list — it applies once and is discarded.

### 7.8 Model Download Management
Within [Settings → AI](#6-3-ai-settings-link), a single compact model strip surfaces the active model's name, file size, and a coloured-dot readiness status (ready, downloading with percent, loading, evicted, error, or not downloaded). When the model is not in a ready state, an inline action row appears under the strip in the same card with the contextual control: a "Download · <size>" button for the active model (the size reflects whichever model is currently selected in the [Switch Model Picker](#7-9-switch-model-picker)), a progress bar with Cancel during download, "Loading…" during warm-up, "Reload" after eviction, or "Retry" after an error. All download status lives inside this single strip — there is no separate top-pinned download banner. Long-pressing the model strip opens a context menu with two entries: "Change model" (opens the [Switch Model Picker](#7-9-switch-model-picker)) and a destructive "Delete model" that, after a confirmation dialog naming the model and warning the user they will need to re-download (about 2.5 GB) to use AI rewrite again, purges the on-device model. The "Delete model" entry is hidden while the model is still downloading or has never been downloaded — there is nothing on-device to remove in those states.

### 7.9 Switch Model Picker
Within [Settings → AI](#6-3-ai-settings-link), a "Switch model" row opens a picker listing the available on-device rewrite models. Currently only Qwen 3.5 4B is offered (shown with a "Default" tag); the picker's footer caption reads "Qwen 3.5 4B is currently the only rewrite model. More options will appear here as they're added." The picker shape is preserved so adding a second model is a single-row addition. Each row shows the model name, its on-disk size, and a small status caption ("Downloaded" or "Not downloaded") so the user can see at a glance whether picking will trigger a fresh download. When a second model is added, tapping a row will mark it as active immediately; the change reflects in the model strip on the [Model Download Management](#7-8-model-download-management) screen and in the model-name surfaces ([Prompt Picker](#7-5-prompt-picker), [Transcript Detail attribution line](#3-transcript-detail)). Picking a different model does NOT auto-start a download — the user explicitly downloads the new model from the AI Rewrite settings screen after switching.

### 7.10 Setup Routing from Articulate
When the user taps the Articulate action in the [Transcript Detail](#3-transcript-detail) view and the AI model is not ready — whether because it isn't downloaded, is downloading right now, is loading into memory, hit an error, or there are no saved prompts yet — the Articulate tap routes to the [AI Rewrite settings](#7-8-model-download-management) screen as a sheet. The user lands directly on the model strip's "Download · 2.5 GB" CTA (or its progress / retry equivalent for the current state) without losing their place in the transcript. The earlier dedicated "Download Pitch Sheet" interstitial has been removed in favor of this single canonical surface — Settings is the only setup destination, so the user sees the same model strip whether they arrived from the action bar, the AI row in Settings, or the wizard. The prompt list comes pre-populated with four default prompts the first time the user opens Settings → AI Rewrite, in order: **Cleanup** (rewrite a dictation for clarity — connect related ideas so they flow logically, cut repeated points while keeping every distinct idea the speaker mentioned, and fix obvious dictation errors), **AI prompt** (convert a rambling dictation into a clean, well-structured prompt the speaker can paste into Claude, ChatGPT, or any other LLM — output is organized into Context / Task / Requirements / Output sections, preserving every concrete detail while cutting filler), **Action Items** (extract tasks from a dictation, list each as a one-line task with the responsible person if mentioned, and include any deadlines), and **Email** (convert a dictation into a business email with a Bottom-Line-Up-Front opening and a one-line subject line). These defaults are seeded only when the list is completely empty: if the user deletes some prompts but keeps at least one, the deleted defaults do not return; if the user deletes all prompts, the defaults reappear the next time they open Settings → AI Rewrite (because the empty-list guard triggers again). The Transcript Detail view does not add default prompts or initiate a model download on its own — it only routes to Settings, where the user explicitly taps Download.

### 7.11 AI Settings Copy Discrepancy — Titles and Tags
**Aspirational. Size depends on path: XS (delete footnote) / M (build titles only) / L (build titles + tags).** **Plan: [docs/plans/titles-and-tags.md](../docs/plans/titles-and-tags.md).** Plan recommends delete (path A) until there's user demand for titles, since the build path forces SwiftData schema-versioning work that has been deferred. Tied to [Migration system plan](../docs/plans/migration-system.md) for SwiftData migrations (separate concern from UserDefaults migrations).

Visible footnote copy in the AI settings screens states "Titles and tags use the system's built-in AI automatically," but no title or tag UI is currently displayed for transcripts.

### 7.12 New Prompt Sheet
Creating a new rewrite prompt opens a dedicated sheet, distinct from the editor used for existing prompts ([7.7](#7-7-saved-prompt-management)). The sheet shows a name field, a selectable icon picker (8 colored tiles — the selected tile is enlarged with a white-then-color ring), a mono system-prompt editor with a helpful placeholder ("Describe how Jot should transform the selected text. Tip: be specific about voice, length, and what to preserve. Test on a recording before saving."), and a "Start from a template" footer offering four one-tap starters: "Translate to…", "Make it shorter", "More formal", and "Action items". Tapping a template chip fills the editor with a canned starter prompt and switches the icon to match. The Save button is disabled until both the name and the system prompt have content. Saved prompts land at the bottom of the prompt list and persist via the same store used by everything else in [§7.7](#7-7-saved-prompt-management).

### 7.13 Voice Prompt
The second row of the [Prompt Picker](#7-5-prompt-picker) — "Voice prompt · Say what to change." (mic icon) — lets the user dictate a one-off rewrite instruction instead of picking a saved prompt. Tapping the row immediately starts recording and the sheet switches to a minimal capture view: a pulsing "Listening…" line, the words appearing live as they're spoken, a prominent Stop button, and an X to cancel. The user says what they want changed ("make this shorter and turn it into an email to Sam") and taps Stop; the dictated instruction then drives the same rewrite that a saved prompt would, and the result lands on the Rewrite tab as usual. Cancel (or dismissing the sheet mid-recording) stops the mic and drops the audio without rewriting; if nothing intelligible was captured, the picker returns with a "Didn't catch that — try again." note. The spoken instruction is used once and is not saved — it does not appear in [Saved Prompt Management](#7-7-saved-prompt-management), and no transcript of it is added to [Home & Library](#1-home--library). The row is disabled while another recording is in progress; a [Warm Hold](#13-2-warm-hold) idle mic does not count as in-progress, and the capture honours Warm Hold on stop like every other recording surface.

---

## 8. Vocabulary Boost

### 8.1 Custom Term List
Users can maintain a list of domain-specific words, names, or technical terms that Jot should recognize correctly during transcription. The list is managed from [Settings → Vocabulary](#6-2-vocabulary-settings-link). The Vocabulary surface is marked **Experimental** with a small badge at the top of the screen. Vocabulary biasing applies to Jot's [single on-device speech model](#6-1-speech-model-management). Vocabulary is no longer offered as an onboarding step — it lives only in Settings.

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

### 8.8 Vocabulary Correction Prompts in the Keyboard
After a dictation, when Jot has a candidate correction tied to the user's custom vocabulary — a spot where it suspects a heard word should have been one of the user's saved terms — the [Jot Keyboard](#5-jot-keyboard) **holds the paste and shows a small review card before inserting** (up to three, one question at a time), so the user picks the right word *before* it lands in the field. Each card offers the heard word or the saved term, a **Stop asking** option, and a short countdown ring; if the user doesn't answer, Jot inserts its best guess and moves on — and if they don't engage the first card at all, it inserts right away rather than make them wait. Whatever the user picks is what gets pasted. Jot also learns from the answers: once the user has kept the original word a couple of times for a given suggestion, the keyboard **stops asking** about it (it still appears in the transcript for review in the app, so nothing is lost), and **Stop asking** silences one immediately. These prompts and the confirmations the user gives are private and stay on the device — nothing about them leaves the iPhone. The corrections feed the user's [vocabulary](#8-1-custom-term-list) and are independent of the [Vocabulary Boost toggle](#8-6-vocabulary-boost-toggle)'s on/off state for biasing.

---

## 9. Help & Onboarding Reference

### 9.1 Help Screen
A structured, scannable help reference accessible from the home header or from [Settings → About](#6-5-about--support) — presented as a modal sheet from home or a navigation push from Settings. It opens on **"What Jot does"** ([§9.7](#9-7-what-jot-does)), a tap-to-expand showcase of Jot's main features, followed by a **How Jot works** row that pushes [§9.2](#9-2-how-jot-works), a collapsible **Troubleshooting** section ([§9.5](#9-5-collapsible-troubleshooting)), a **Privacy** row that pushes [§9.4](#9-4-privacy-explainer), and a **Send feedback** row ([§9.6](#9-6-feedback-contact)). This screen is the browsable form of the same product knowledge that [Ask Jot answers conversationally](#14-7-how-to-answers-about-jot).

### 9.2 How Jot Works
A dedicated page (pushed from the Help screen's "How Jot works" row) walks through the basic Jot workflow — install keyboard, tap Jot down, swipe back, stop from the keyboard — as four numbered steps beside an animated mini-phone scene reused from the [Setup Wizard](#4-setup-wizard) (W4). An honest footnote explains the app-switch: iOS doesn't let keyboards use the mic directly, so Jot hops to the foreground to capture; if that ever changes, the hop goes away. Honors Reduce Motion (the animation freezes on its final frame).

### 9.3 AI Rewrite Guide
The optional [AI Rewrite](#7-ai-rewrite) feature is explained inline as the expandable body of the "Polish what you said" feature row on the Help screen (no longer a standalone section). It describes tapping **Articulate** on any transcript in the [Transcript Detail](#3-transcript-detail) view to apply Cleanup, Action Items, Email, or a custom prompt — fully on-device. Earlier copy advertising a keyboard "wand" entry point has been removed: rewriting is triggered from the transcript, not the keyboard (see [§7.3](#7-3-ai-rewrite-activation-model)).

### 9.4 Privacy Explainer
A dedicated **"See for yourself"** page (pushed from the Help screen's Privacy row) summarises Jot's on-device-only handling — no accounts, no cloud, no telemetry — and teaches the user to *verify* it with iOS's own **App Privacy Report**: a static preview lists the short set of domains Jot contacts (model downloads; the donations/feedback page) with a plain-language caption per row, plus an **Open Settings** button. Because iOS exposes no deep link into the App Privacy Report, a footnote gives the manual path (Privacy & Security › App Privacy Report). The one exception to "nothing leaves the device" — tapping [Send Feedback](#9-6-feedback-contact) — is named here; Full Access rationale stays in the [Setup Wizard](#4-3-keyboard-installation--full-access-w3) and [Settings → Privacy](#6-4-privacy-controls). The iOS system-Settings privacy helper ([§13.6a](#13-6a-ios-settings-helper-system-settings--jot)) points users to this same App Privacy Report to verify the on-device claim. See also [§13.1](#13-1-fully-on-device-processing).

### 9.5 Collapsible Troubleshooting
A Troubleshooting section in Help contains collapsible Q&A entries addressing the most common issues: the keyboard didn't paste, the recording was cut off unexpectedly, the [speech model](#6-1-speech-model-management) didn't load, and the transcription produced wrong words. Each entry is collapsed by default to keep the screen scannable.

### 9.6 Feedback Contact
A Contact section at the bottom of the Help screen provides a Send feedback button that opens an in-app feedback form. The form has a text field, an "Add screenshots" button (multi-select up to 3 from the user's photo library — each thumbnail is shown below the editor with an X button to remove individually), and an "Include diagnostic logs" toggle (default off; when on, attaches a recent slice of anonymous app events — recording start/stop, paste outcomes, memory warnings — to help track down bugs; an explicit caption reassures that no personal info or transcripts are included). A counter shows the combined screenshot size and current selection count so the user can see what they're about to upload. The app version and platform are attached automatically. The user stays inside Jot — no Mail handoff. After a successful send the form auto-clears (text, screenshots, and the logs toggle all reset) and a green-check "Sent. Thank you." confirmation appears in place for fifteen seconds before fading on its own — so the user can immediately type another piece of feedback without needing to dismiss anything, and a stale confirmation never lingers. The Send button is disabled while a submission is in flight so repeated taps can't fire duplicate uploads. On rate-limit or server errors the message is shown inline so the user can try again. The same form is reachable from Settings → About → Send feedback (see [§6.5 About](#6-5-about--support)).

### 9.7 What Jot Does
The first section of the Help screen — a card of **four tap-to-expand feature rows**, each framed as a user situation with a short body revealed on tap. **Speak instead of typing, in any app** (switch to the Jot keyboard, tap Jot down, talk; the words land in the focused field). **Keep going when life interrupts** describes the [warm-hold microphone](#13-2-warm-hold) staying ready across app switches and incoming calls, with continuous saves so partial dictations survive. **Polish what you said into what you meant** describes the three built-in [AI Rewrite](#7-ai-rewrite) prompts (Cleanup, Action Items, Email) plus custom prompts, applied via **Articulate** on a transcript. **Find your ideas by asking Jot** describes [Ask Jot](#14-ask-jot) — asking in plain words and getting an answer drawn from your own notes. A hint line invites the user to tap a feature to read how it works.

---

## 10. System Integrations

### 10.1 Shortcuts: Transcribe Audio with Jot
Jot exposes a Shortcuts action — "Transcribe Audio with Jot" — that accepts an audio file as input and returns a transcript string as output. The action runs in the background without opening the app, appends the result to the transcript history, and returns the raw transcript by default. Unlike the recording screen and keyboard, this surface does NOT run the [Automatic Cleanup](#7-1-automatic-cleanup) pass — cleanup on the Shortcuts file action is gated solely on the per-run "Clean Up Transcript" toggle described next. An optional "Clean Up Transcript" toggle applies a separate cleanup pass (Apple Intelligence based, distinct from the bundled cleanup model used elsewhere) to the output; if that pass is unavailable or fails, the shortcut silently falls back to returning the raw transcript (no error is surfaced to the Shortcuts automation). This action is chainable with other Shortcuts steps — for example, after the system "Record Audio" action — making it useful for batch workflows or automation pipelines.

### 10.2 Action Button Shortcut
Jot exposes a "Start Jot Dictation" action in Apple's Shortcuts app that can be assigned to the iPhone's Action Button (or invoked from any Shortcuts automation). When triggered, it starts recording in the background without opening the app; a second press stops recording, transcribes, and copies the result to the clipboard. The action is discoverable in the Action Button settings under the Shortcuts category.

### 10.3 Deep Link Routing
Jot supports deep links that open the app directly into a new recording session or bring the app to the foreground aimed at the [transcript library](#1-2-transcript-library-with-time-grouping). These links can be triggered from other apps, web pages, or Shortcuts. The library deep link does not force a navigation reset — if a sheet or other navigation is already open when the link fires, the user will not automatically land on the library view.

### 10.4 Shortcuts: Save a Note
Jot exposes a "Save a Note" Shortcuts action that takes a piece of text and saves it straight into the [transcript library](#1-2-transcript-library-with-time-grouping) — no recording involved. It runs headless (without opening the app) and is chainable, so any Shortcut step that produces text — a dictation in another app, a clipboard value, an earlier action's output — can drop a note into Jot. Fully on-device.

### 10.5 Shortcuts: Ask Your Notes
Jot exposes an "Ask Your Notes" Shortcuts action that takes a spoken or typed question and returns a short answer drawn from the user's own transcripts — the same [Ask Jot](#14-ask-jot) engine, reachable from the Shortcuts app without opening Jot. The action runs headless and returns its answer as plain spoken-style prose with no [citation chips](#14-3-cited-answers) (there is nowhere to render them on that surface). Useful for a quick hands-free "what did I say about…?" — see [§14.8](#14-8-ask-from-shortcuts).

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
Taps on the Jot keyboard produce audio and haptic feedback that matches the feel of the native iOS keyboard. The keyboard is recording-controls-only — there are no letter, number, punctuation, or space keys; the single typing key is the adaptive Enter key (whose label mirrors the system return key by context — see [§5.1](#5-1-custom-keyboard)). Pressing Enter plays the standard iOS keyboard click sound paired with a light tap; the recording controls (Pause, Stop, Cancel) and the Actions button play a system-style click. Every tap also produces a selection-style haptic alongside the audio. Requires Full Access; without it both audio and haptics are silently suppressed.

---

## 12. Error States & Recovery

### 12.1 Microphone Permission Denied
If microphone access is denied, the [Setup Wizard](#4-2-microphone-permission-w2) surfaces a deep-link to iOS Settings. In the main app, denied permission surfaces an alert dialog with a single OK button that dismisses the alert; there is no Settings deep link from this alert, so the user must navigate to iOS Settings manually to grant microphone access. In the keyboard, errors including permission issues surface via the [status banner](#5-10-status-banner).

### 12.2 Model Download Failure
On most iPhones the [speech model](#6-1-speech-model-management) ships bundled inside the app, so there is no speech-model download and this failure mode does not apply. Only on older/lower-memory iPhones that fetch a smaller English model on first dictation ([§6.1](#6-1-speech-model-management)) can it occur; a failed or interrupted fetch surfaces on the dictation surface and retrying the dictation re-attempts the download. (AI Rewrite and Ask models are also downloaded — see [§12.3](#12-3-ai-model-download-failure).)

### 12.3 AI Model Download Failure
If the [AI Rewrite model](#7-2-on-device-ai-rewrite-model) download fails or the model becomes unavailable, [Settings → AI](#7-8-model-download-management) surfaces retry and reload actions. In the Transcript Detail view, tapping Articulate when the model has not been downloaded (or is mid-download / loading / errored) routes the user to AI Rewrite settings as a sheet — see [§7.10](#7-10-setup-routing-from-articulate) — where the same retry/download controls live. An error card with a dismiss option appears only after a rewrite attempt actually fails (see also [§12.4](#12-4-rewrite-error)).

### 12.4 Rewrite Error
If a rewrite fails mid-generation (model error or memory pressure), the [Transcript Detail](#3-6-rewrite-progress-and-cancellation) view shows an error card the user can dismiss. If the user cancels the in-progress rewrite, the view returns silently to idle — no error card is shown for user-initiated cancellation. The original transcript is never modified by a failed or cancelled rewrite.

### 12.6 Keyboard Status Banner
Transient errors inside the [Jot Keyboard](#5-10-status-banner) — such as a transcription failure or a missing model — are communicated via an overlay banner that appears without requiring the user to leave the host app. Non-rewriting banners auto-clear approximately 2.5 seconds after they render; the "Rewriting…" banner persists until the rewriting state changes.

---

## 13. Privacy & Data Disclosures

### 13.1 Fully On-Device Processing
All speech recognition, transcription, and AI rewrite operations run on-device using downloaded models. No audio, transcript text, or rewrite content is sent to any external server. This is surfaced in [Settings → Privacy](#6-4-privacy-controls) and explained in the [Help screen](#9-4-privacy-explainer).

### 13.2 Warm Hold
When enabled (opt-in during [wizard step W6](#4-6-warm-hold-opt-in-w6) or via [Settings → Privacy](#6-4-privacy-controls)), Jot keeps the audio session active after a recording ends to reduce latency at the start of the next dictation. The duration is configurable in Settings → Privacy: it defaults to 2 minutes, offers 60s, 2 min, 3 min, and 5 min choices, and can be set up to a maximum of 5 min. The toggle is clearly labeled and off by default. During the warm-hold window the iOS orange microphone indicator remains visible and the audio session stays active; no audio is captured or retained. The same held-but-not-capturing behavior backs [Pause / Resume](#2-4-pause--resume) mid-dictation (the orange indicator stays on while paused, but paused audio is dropped, never captured or stored). Stopping a [Voice Prompt](#7-13-voice-prompt) capture honours Warm Hold like every other recording surface.

**Yielding the mic to other apps.** Warm Hold never blocks anything else from using the microphone. If another app needs audio during the warm window — you take a call, join a Teams/Zoom/FaceTime meeting, play a video, or start a Voice Memo — Jot immediately steps aside and hands the microphone over, so the other app works normally. Jot silently reclaims the warm session the next time you dictate, with nothing required from the user. (Earlier builds could hold the session in a state that prevented other apps from playing or recording audio during the warm window; Jot now always relinquishes on demand and re-acquires on the next dictation.)

**UI-path difference during Warm Hold:** when the user taps Dictate in the keyboard while a warm-hold session is still active, the keyboard recognizes the active window and recording starts immediately — Jot is not brought to the foreground. The user stays in the host app for the full dictation; only the keyboard's streaming strip ([§5.3](#5-3-streaming-strip-recording-state)) animates to show live progress. When the recording finishes and transcription completes, the text is auto-pasted as normal. Outside the warm-hold window — or when Warm Hold is disabled — a keyboard-initiated dictation follows the cold-start path: Jot is launched and comes to the foreground, the [full-screen recording surface](#2-1-full-screen-recording-surface) appears, and the user must manually swipe back to the host app when done ([§2.9](#2-9-auto-dismiss-on-completion)).

### 13.3 Full Access Disclosure
The [Setup Wizard](#4-3-keyboard-installation--full-access-w3) explains why Full Access is required for the keyboard: it allows the keyboard to access the transcript result produced by the main app in order to paste it into the host app. The [Help screen](#9-4-privacy-explainer) does not explain the Full Access rationale — it mentions Full Access only in a troubleshooting entry directing users to enable it when paste does not work. The [Settings → Privacy](#6-4-privacy-controls) section includes a tappable Full Access row that opens iOS Settings to Jot's app-settings page (with a subline that gives the navigation breadcrumb to Allow Full Access); no status chip is shown because iOS does not expose Full Access state to the main app. After setup, if the user is using the keyboard and Full Access has not been granted, the keyboard surfaces a locked-state "Enable Full Access" pill that opens iOS Settings to the same page. The reason this opens the app-settings page rather than the keyboard panel directly: Apple's QA1924 `prefs:` URL would land closer to the toggle, but on iOS 26 it returns `success: true` from `extensionContext.open` while doing nothing — so we use the documented public URL that reliably opens. The iOS system Settings page for Jot also carries a "Don't see 'Keyboards' settings?" helper and a privacy explainer (see [§13.6a](#13-6a-ios-settings-helper-system-settings--jot)).

### 13.4 Transcript Storage
Transcripts are stored locally on the device. Users can delete individual transcripts via the [swipe or context menu](#1-7-transcript-row-actions) on the home screen or via the Delete action in the [Transcript Detail](#3-5-action-bar) view. There is no active cross-device iCloud sync — each device's library is independent.

**iCloud Device Backup behavior.** When the user has iCloud Backup enabled in iOS Settings, the following are included in their device backup automatically: transcripts (Original + Rewrite), saved AI Rewrite prompts, custom vocabulary, and app preferences. Audio is never written to disk so it can't be part of any backup. The bundled speech model is not part of any backup at all — it ships inside the app itself and is restored when the app is reinstalled from the App Store; any downloaded speech-model weights (on lower-memory iPhones) re-download on first use after a restore rather than riding the backup. The downloaded AI Rewrite model (Qwen 3.5 4B, ~2.5 GB) is explicitly kept OUT of the backup so it doesn't bloat it (typical Jot backup size: a few MB, not GB): it lives in a location iOS unconditionally excludes from backup, and it re-downloads on first use after a restore. The Settings → About card surfaces a static "Backed up with iCloud (when iCloud Backup is enabled in iOS Settings)" row so users can confirm this expectation at a glance.

On restore (full device setup from an iCloud backup → Jot reinstalled), the library returns to the state it was in at the moment the backup was taken. Restoring a single app from the App Store does NOT bring its data back — only full-device "Restore from iCloud Backup" does.

Schema changes carry explicit version migrations (see `docs/schema-migrations.md`), so restoring an old backup on a newer build of Jot loads cleanly via the migration plan. Restoring a backup taken on a newer build onto an older build of Jot is not supported; install the same or newer version.

### 13.5 Rewrite Edit Training Pairs
When the user manually edits the Rewrite tab text via [Edit Transcript](#3-7-edit-transcript), Jot keeps both the model's original rewrite output AND the user's edited version on-device. The pair — what the model produced and what the user changed it to — is preserved as a future-improvement training signal for the on-device rewrite model. The optional 👍 / 👎 rating from [Rewrite Feedback](#3-8-rewrite-feedback) is stored alongside the pair as a rating-without-correction signal. Nothing about any of this is uploaded; it stays in the same local store as the rest of the user's transcripts and is included in iCloud Device Backup like other user data. Tapping Articulate on a transcript clears any prior user-edit AND rating (a stale correction or rating against a fresh model output would be meaningless), and discarding the rewrite clears all three together.

### 13.6a iOS Settings Helper (System Settings → Jot)
The iOS system Settings page for Jot (Settings → Jot, below the system permission toggles) carries two help blocks — the same place a user lands when hunting for the Keyboards toggle. The first, **"Don't see 'Keyboards' settings?"**, tells the user to close and reopen Settings, or to open the Jot app and follow [Settings → Privacy → Full Access](#6-4-privacy-controls) (breadcrumb: General → Keyboard → Keyboards → Jot → Allow Full Access). The second, **"Your privacy is protected,"** leads with a clean main claim — "Nothing you say or type ever leaves your iPhone." — and carries the single nuance in a starred footnote: the one exception is the Send Feedback form in the app's Settings, which only sends feedback when the user deliberately opens it and sends, never automatically (see [§13.6](#13-6-no-accounts-no-telemetry-no-analytics)). It adds that Full Access only enables the keyboard's microphone so speech becomes text in real time (see [§13.3](#13-3-full-access-disclosure)), and that all of this can be verified in Apple's [App Privacy Report](#9-4-privacy-explainer). The same "Your privacy is protected" copy is mirrored as a plain (non-tappable) row at the bottom of the in-app [Settings → Privacy](#6-4-privacy-controls) section so it is reachable without leaving the app.

### 13.6 No Accounts, No Telemetry, No Analytics
Settings surfaces the claim: "Your words stay on your iPhone. No accounts, no cloud, no telemetry — only feedback you send is ever transmitted." The Settings footer echoes it ("No accounts, no cloud, no telemetry. Only feedback you send leaves your iPhone."), and the Help screen's Privacy section reiterates this as: "Transcripts are stored locally on your device. Jot has no cloud sync, no analytics, no account," followed by the single stated exception: when the user taps Send Feedback, their message and any attached screenshots are sent to Jot's feedback endpoint and nothing else ever leaves the device. The only outbound network transmission in the entire app is this user-initiated feedback submission (see [§9.6 Feedback Contact](#9-6-feedback-contact)).

---

## 14. Ask Jot

**Beta.** Natural-language question-answering over the user's own transcript library — and over how Jot itself works ([§14.7](#14-7-how-to-answers-about-jot)). Where [Live Search](#1-3-live-search) finds a remembered phrase and [AI Rewrite](#7-ai-rewrite) reshapes a single note, Ask Jot answers a *question* by reading across many notes at once and writing back a grounded answer. Reached from the [home Ask entry point](#1-12-ask-jot-entry-point); presented as a full-height sheet titled "Ask Jot" with a BETA tag.

### 14.1 Natural-Language Q&A
The user asks a plain-language question ("what did I decide about the launch date?", "summarise my notes from last week") and Ask Jot returns a written answer drawn from the user's own transcripts — not generic knowledge. The answer streams in as it's written; while it's preparing, a short status line cycles through "Searching your notes…", a model-loading note if the answer model is cold, then light "thinking" messages until the first words arrive. The field shows no canned example prompts — the user asks their own thing.

### 14.2 Voice or Typed Questions
Ask is voice-first: opening it starts listening immediately (without raising the keyboard), so the default action is simply to talk, with a "Listening…" prompt shown until the first words are transcribed. The live transcript fills the question field as the user speaks; tapping the field switches to typing instead (and discards the in-progress voice). The dictated question reuses Jot's own [recording + transcription](#2-recording-experience) pipeline but is treated as a query only — it is never saved as a transcript. The question field grows to several lines for longer questions. The user can finish and send at any time by tapping the Send button (which doubles as the dictation stop), but they don't have to: once they have actually started speaking, **five seconds of silence auto-sends the question** — the same finish-and-ask action as the button. During that silence a small "Sending in Ns…" countdown appears below the field (where "Listening" sat); speaking again hides it and resets the timer, so a natural pause between thoughts never sends early. While listening with the field still empty, a rotating, non-interactive suggestion cycles below the "Listening" prompt — example questions phrased as things to say aloud (summarizing the day, asking about a topic, surfacing connected notes) that hint at what retrieval can do and help the user find their voice. The suggestion lingers a few seconds after the first words land, then fades so it never competes with the live transcript.

### 14.3 Cited Answers
Answers carry inline citation chips that map back to the specific transcripts the answer drew from. Tapping a citation dismisses the Ask sheet and opens that note in [Transcript Detail](#3-transcript-detail). A sources list beneath the answer shows which transcripts were used and which on-device model produced the answer.

### 14.4 Library-Wide Retrieval & Indexing
Ask searches the user's entire library — including notes captured from the [keyboard](#5-jot-keyboard), [Apple Watch](#2-13-apple-watch-dictation), and [Shortcuts](#10-1-shortcuts-transcribe-audio-with-jot) — combining meaning-based matching with keyword matching so relevant notes surface even when the wording differs. Notes are indexed in the background for the best results; until a note is indexed it is still findable by keyword, so search is never blind. When some notes aren't indexed yet, Ask offers a one-tap "Index" prompt with progress (indexing also runs on its own in the background). Date-style questions ("yesterday", "last 3 days", "May 26") are resolved by recording time rather than meaning.

### 14.5 Answer Model Choice
Ask answers with Apple Intelligence on this device — there is no model choice to make and no download required. (An earlier "Use on-board Qwen for Ask" toggle in [Settings → AI](#6-3-ai-settings-link) has been removed.) Ask only surfaces when a capable answer model is available, so it is never shown in a non-working state (see [§14.6](#14-6-availability)).

### 14.6 Availability
The [home Ask entry point](#1-12-ask-jot-entry-point) appears only when the device has a capable answer model available, so Ask is never surfaced in a non-working state. When no model is available, Ask explains what's needed rather than failing silently.

### 14.7 How-To Answers About Jot
Ask also answers questions about how to use Jot itself — "how do I pause a recording?", "does the keyboard have a normal layout?", "what is [Warm Hold](#13-2-warm-hold)?" — not only questions about the user's own notes ([§14.1](#14-1-natural-language-qa)). Ask decides automatically which kind of question was asked: a how-to question about the app is answered from Jot's built-in help, while a question about the user's own dictations is answered from their notes — the user never has to pick a mode. A help answer is plain, practical guidance with no [citation chips](#14-3-cited-answers) (there is no personal note to point at), and it carries a small "From Jot's Help" label so it is never mistaken for an answer drawn from the user's own notes. The help knowledge is built into the app and everything stays [on this iPhone](#13-1-fully-on-device-processing). For the browsable version of the same material, see the in-app [Help screen](#9-help--onboarding-reference).

### 14.8 Ask from Shortcuts
Beyond the in-app sheet, Ask is reachable from the Shortcuts app via the ["Ask Your Notes" action](#10-5-shortcuts-ask-your-notes): ask a question and get a spoken-style answer drawn from your notes, without opening Jot. The answer is plain prose with no [citation chips](#14-3-cited-answers) — that surface has nowhere to show them.

---

## Known Bugs & Planned Work

The bug tracker and the plan / roadmap index live in their own page, so this inventory stays user-facing only — see **[known-bugs-and-plans.md](known-bugs-and-plans.md)**.
