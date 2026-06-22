# CarPlay Support for Jot — Discovery & Plan (capture-first)

**Status:** Discovery + plan. Owner-confirmed direction (§0). No product code written.
**Date:** 2026-06-19
**Author:** discovery study (agent) + owner brainstorm
**Sources of truth:** Apple *CarPlay Developer Guide* (June 2026 edition, downloaded from
`https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf`) for every CarPlay
claim; Jot source `file:line` for every Jot claim.

**Companion (READ ALONGSIDE):** [`app-intents-mic-investigation.md`](./app-intents-mic-investigation.md)
diagnoses the owner's "the recording intent is broken / Siri can't get the mic" symptom. Its
decisive finding **corrects §4.1 below**: a backgrounded, Siri-launched intent **cannot start
the microphone** on iOS (privacy gate) — capturing audio from an intent requires a **visible
foreground bounce into Jot** (`openAppWhenRun = true`), which `DictateIntent` already does.
"Cold, hands-free, no-bounce capture" is **not** achievable on iOS by design.

---

## 0. Locked product decisions (2026-06-19, owner-confirmed)

These supersede any "Siri-first / Ask-first" framing elsewhere in this doc — the research
below is preserved for evidence, but the **plan is now capture-first, Route-B-first.**

1. **Capture is the FLAGSHIP.** Ask is secondary. (Owner: "I want capture to be the flagship.
   Ask is frosting on the cake — not many people use Ask.")
2. **The product is the eyes-free CarPlay voice app (Route B).** The cheap Siri/App-Intents
   path (Route A) is demoted to an *optional phone byproduct* — it can't deliver eyes-free
   capture (background-mic gate forces a visible app-bounce) and Siri may refuse custom
   intents while driving. We do **not** plan around it.
3. **Ask stays in the build — as the entitlement passport, not a user feature.** Apple's
   `carplay-voice-based-conversation` entitlement is for *conversational* apps; a pure voice
   recorder is the category that doesn't exist. Jot **already ships Ask**, so we expose it in
   the CarPlay surface ("ask your notes") at ~zero cost so the submission reads as a genuine
   voice assistant. No new Ask UX investment.
4. **Capture flow = explicit stop, no auto-endpoint.** (Owner: "explicit stop, not
   automatically.") **Manually launch Jot from the CarPlay home screen** — Apple *requires* manual
   launch for this category (no wake-word, no steering-wheel button; one deliberate tap, then
   eyes-free) → recording starts → **explicit stop = a single tap** on the template's built-in
   Stop/Done control (the *primary* stop). A **30-second no-speech backstop** (Silero VAD, already
   bundled) auto-saves if the driver forgets — keyed off absence of *words*, not sound, so road/HVAC
   noise won't keep it alive (distinct from the short-pause auto-endpoint, which is rejected).
   **Voice-word stop ("done"/"save") is deferred to V2** — on V1 it's a trap (the stop word lands in
   the note; needs a parallel keyword-spotter + trailing-trim). → on-device transcribe → save →
   **TTS speaks "Saved."** No text shown. (Category limits: `CPVoiceControlTemplate` is the primary
   UI; max depth 3; *custom* buttons may be iOS 27+ — on the 26.4 floor verify the built-in
   Stop/Cancel fires a usable delegate callback. See §7.)
5. **Build the shared foundation first:** on-device **TTS via FluidAudio Kokoro** (82M, ANE,
   SSML/IPA — the SAME stack Jot already uses for Parakeet ASR + Silero VAD, so it stays on-device
   and preserves the "only feedback leaves the device" invariant; **not** `AVSpeechSynthesizer`).
   Voices the "Saved" confirmation + concise Ask answers (Kokoro renders short text all-at-once —
   ideal here; PocketTTS streaming is a later option for long answers). Bundle cost: the Kokoro
   model (~tens of MB) — acceptable, flag at build. The headless transcribe→save tail already
   exists; the CarPlay scene owns the mic in its foreground audio session (no Siri, no bounce,
   no driving-block).

---

## 1. Verdict (bottom line up top)

**Jot CAN have a real, native CarPlay-template app — but only through the brand-new
"voice-based conversational app" category that Apple shipped in iOS 26.4 (Feb 2026),
and that category is a much better fit for the *Ask* capability than for the *capture*
capability.** A general "voice notes / productivity" CarPlay category does **not** exist
and never has — Jot does not fit Audio, Communication, Navigation, Parking, etc. So the
honest framing is:

- The owner's **Ask-by-voice + spoken answer** goal maps almost exactly onto Apple's new
  `com.apple.developer.carplay-voice-based-conversation` category. Its guidelines literally
  require voice-primary interaction and explicitly tell you *not* to render text/imagery in
  response to queries — i.e. Apple is mandating the exact eyes-free behavior the owner asked
  for. This is the category created for ChatGPT / Claude / Gemini voice mode in the car.
  ([CarPlay Developer Guide p.13; 9to5Mac; MacRumors](#references))
- The owner's **capture-a-thought** goal (start/stop a recording, save it) does **not** have
  a clean home. It is not "voice conversational" (you're not asking the assistant a question),
  it is not audio playback, it is not a driving task in Apple's sense. Realistically capture
  rides along *inside* the voice-conversational app as one more thing you can say ("jot this
  down: …"), OR it lives on the **Siri / App Intents** path that already works today.

**Decision (see §0): the product is Route B — the CarPlay voice-conversational app — built
capture-first.** It is the only route that delivers eyes-free in-car capture (the CarPlay scene
runs foreground and owns the mic directly: no Siri, no background-mic gate, no app-bounce,
no driving-block). Ask is kept only as the conversational justification that makes the
entitlement grantable. The zero-entitlement Siri path (Route A) is an optional phone byproduct,
not the goal.

### Difficulty rating per capability

| Capability | Siri / App-Intents route | CarPlay voice-conversational app route |
|---|---|---|
| **Capture** (start/stop, save a Jot, no on-screen text) | **Moderate** — the transcribe/save tail is headless, but the **mic can't start from a backgrounded intent** (iOS privacy gate — the owner's "broken" symptom). Capture needs a **visible foreground bounce** into Jot (`openAppWhenRun=true`, as `DictateIntent` already does) — not eyes-free. Plus the Siri-while-driving question (§6). See [app-intents-mic-investigation.md](./app-intents-mic-investigation.md). | **Moderate** — fits awkwardly into the voice template; needs a "jot this down" voice command + the existing headless save path (mic owned by the CarPlay scene's foreground audio session). |
| **Ask** (ask by voice, hear answer spoken) | **Moderate** — programmatic Q→A string path already exists; **TTS is net-new**; and custom intents are frequently blocked while driving (caveat §6). | **Moderate–Hard, gated by Apple approval** — perfect category fit, but requires the `carplay-voice-based-conversation` entitlement (case-by-case Apple review, iOS 26.4 minimum) + `CPVoiceControlTemplate` + AVAudioSession + **net-new TTS**. Rated **Hard / approval-gated** until the entitlement is granted. |

**One-paragraph bottom line:** Jot is not eligible for any "notes/productivity" CarPlay category
(none exists), but it *is* a legitimate candidate for Apple's new iOS 26.4 voice-conversational
category. We build the **eyes-free CarPlay voice app, capture-first**: open it on the dash, speak
a thought, stop explicitly, it saves and says "Saved" — no glancing. The CarPlay scene owns the
mic in its own foreground audio session, so none of the Siri/background-mic limitations apply.
Net-new engineering is small and bounded: **on-device TTS** (the spoken confirmation) plus the
**CarPlay scene + voice template + AVAudioSession** wiring; transcription, save, and Ask all
reuse the shipping main-app pipelines. The real risk is **approval, not engineering** — Apple
grants `carplay-voice-based-conversation` case-by-case with no SLA, and we must credibly present
Jot's in-car experience as voice-conversational (capture thoughts **and** ask your notes). Submit
that request early; it's the long pole.

---

## 2. CarPlay category analysis (authoritative, cited)

### 2.1 The complete list of CarPlay app categories (June 2026)

From the CarPlay Developer Guide, *"CarPlay apps"* / *"Entitlements"* sections. These are the
**only** categories that can be granted a CarPlay app entitlement:

| Category | Entitlement key | Min iOS |
|---|---|---|
| Audio | `com.apple.developer.carplay-audio` | iOS 14 |
| Communication (SiriKit messaging or VoIP) | `com.apple.developer.carplay-communication` | iOS 14 |
| Driving task | `com.apple.developer.carplay-driving-task` | iOS 16 |
| EV charging | `com.apple.developer.carplay-charging` | iOS 14 |
| Fueling | `com.apple.developer.carplay-fueling` | iOS 16 |
| Navigation (turn-by-turn) | `com.apple.developer.carplay-maps` | iOS 12 |
| Parking | `com.apple.developer.carplay-parking` | iOS 14 |
| Public safety | `com.apple.developer.carplay-public-safety` | iOS 14 |
| Quick food ordering | `com.apple.developer.carplay-quick-ordering` | iOS 14 |
| Video | `com.apple.developer.carplay-video` | iOS 27 |
| **Voice-based conversational** | **`com.apple.developer.carplay-voice-based-conversation`** | **iOS 26.4** |

> Quoted from the Guide's Entitlements table (p.13) and category bullet list (p.3). There is
> **no** "notes", "productivity", "voice memo", "dictation", or general-purpose category. A
> productivity/dictation app cannot get an entitlement *as such* — it has to fit one of the
> rows above. (Apple's own *Voice Memos* app ships **zero** CarPlay surface, consistent with
> this.) ([CarPlay Developer Guide p.3, p.13](#references))

**Hard rule:** "All CarPlay apps require a CarPlay app entitlement specific to your app
category… Apple will review your request. If your app meets the criteria… Apple will assign a
CarPlay app entitlement." An app can hold an entitlement for **one** category and may only use
the templates that category permits — "Attempting to use an unsupported template triggers an
exception at runtime." (Guide, Entitlements + Templates, p.12–14).

### 2.2 Which categories could Jot conceivably fit? (ruled in/out)

- **Voice-based conversational — FIT (for Ask).** Guide p.7, *"Additional guidelines for
  CarPlay voice-based conversational apps"*:
  1. *"must have a primary modality of voice upon launch; and after launch, appropriately
     respond to questions or requests and perform actions."*
  2. *"Only hold an audio session open when voice features are actively being used."*
  3. *"Optimize for voice interaction in the driving environment (for example, don't show text
     or imagery in response to queries)."*
  This is Jot's Ask feature, verbatim. Apple introduced this category in the iOS 26.4 beta
  (Feb 2026) explicitly to let ChatGPT / Claude / Gemini run as in-car voice assistants.
  ([CarPlay Developer Guide p.7; 9to5Mac; MacRumors; iClarified](#references))

- **Driving task — DOES NOT FIT.** Guide p.5: *"Driving task apps must enable tasks people
  need to do while driving. Tasks must actually help with the drive, not just be tasks that are
  done while driving… Use cases outside of the vehicle environment are not permitted."*
  Jotting a personal thought is precisely "a task done while driving" but **not one that helps
  with the drive**, and Jot's use cases are overwhelmingly outside the vehicle. This category
  would be rejected. (It's also template-only — no custom UI — but that's moot given the
  primary-purpose failure.)

- **Audio — DOES NOT FIT for recording.** The audio category is for **playback** services
  (Guide p.4: *"CarPlay audio apps must be designed primarily to provide audio playback
  services"*). It uses `CPNowPlayingTemplate` + `MPNowPlayingInfoCenter` for *playing* media,
  not capturing it. We *could* technically use a now-playing surface to play back a spoken Ask
  answer, but we cannot get the **audio** entitlement for an app whose primary purpose is
  dictation/notes, and the audio category does not sanction microphone capture as a feature.
  Ruled out.

- **Communication — DOES NOT FIT.** Guide p.5: communication apps must provide **short-form
  text messaging** (and support `INSendMessageIntent`, `INSearchForMessagesIntent`,
  `INSetMessageAttributeIntent`) **or VoIP calling** (CallKit + `INStartCallIntent`). Jot sends
  no messages and places no calls. Also p.4 guideline 6: *"Never show the content of messages,
  texts, or emails on the CarPlay screen."* Not Jot. Ruled out.

- **Everything else (EV charging, fueling, navigation, parking, public safety, quick food,
  video) — DOES NOT FIT.** None describe a notes/voice-capture/Q&A app.

### 2.3 The non-app surfaces that need **no** CarPlay entitlement

The Guide is explicit (p.3, p.9–10): **"Your app does not need to be a CarPlay app to support
widgets and Live Activities in CarPlay."** Two zero-entitlement surfaces exist:

- **Widgets in CarPlay** (Dashboard) and **Live Activities in CarPlay** (Dashboard /
  notification). These are *glanceable*, not interactive capture/Q&A surfaces — not a fit for
  the owner's two capabilities, but free if we ever want a "recording in progress" Live
  Activity to appear on the CarPlay dashboard. Jot already builds Live Activities
  (`DictationActivityCoordinator`), so a CarPlay-visible recording indicator is essentially
  free later. (Guide p.10: support the `.small` activity family.)

- **Siri / App Intents** — the big one. Custom App Intents are *not* a CarPlay framework
  feature and need **no** CarPlay entitlement. They run via Siri, which is available in every
  CarPlay car. This is the pragmatic route (§3, §6). The catch is real and documented in §6.

---

## 3. Routes, ranked

### Route A — Siri / App-Intents only (NO CarPlay entitlement) — **recommended first**

**What it enables:** "Hey Siri, new Jot note" to start/stop a capture hands-free; potentially
"Hey Siri, ask Jot …" for Q&A — both via Siri, on any CarPlay head unit, today, with no Apple
approval. Capture reuses Jot's already-headless pipeline 1:1. Ask reuses the existing
programmatic Q→A path; the answer is spoken via **net-new TTS** (and/or Siri reads the
`IntentResult` dialog).

**Entitlement / approval risk:** **None.** No CarPlay entitlement, no review. Ships on a normal
App Store update.

**The caveat that makes this "Moderate" not "Easy" for live use:** custom App Intents are
frequently refused by Siri **while connected to CarPlay / while driving** — Siri answers
*"Sorry, I can't do that while you're driving."* This is widely reported on Apple's own
DevForums for *custom* intents (the built-in messaging/calling/navigation domains are the ones
wired for CarPlay). So even though the intents run perfectly on the phone, their **in-car**
reliability is the open question — must be verified on a real CarPlay unit on current iOS
(see §6 Q1). ([Apple DevForums #709496, #733589; see references](#references))

**Effort:** **S** for capture (intents already exist), **M** for Ask (wire a programmatic
Q→A intent + add TTS).

### Route B — CarPlay voice-based conversational app (entitlement required) — **recommended second / target**

**What it enables:** A first-class Jot icon on the CarPlay home screen. Tap it (or it launches
voice-first) → `CPVoiceControlTemplate` shows a listening/processing indicator → driver asks a
question → Jot retrieves + generates → **the answer is spoken aloud** (net-new TTS), no text
shown. The same voice surface can host "jot this down: …" to satisfy capture. This is the
purpose-built, Apple-blessed eyes-free experience.

**Entitlement / approval risk:** **Real and gating.** Requires the
`com.apple.developer.carplay-voice-based-conversation` entitlement — case-by-case Apple review,
no published SLA (days to weeks), iOS 26.4 minimum on the device. Apple must agree Jot's
"primary modality is voice." Jot's *current* primary modality is a keyboard/dictation app, not
a conversational assistant — so the framing of the request matters (we'd present the in-car
experience as voice-conversational Ask). Approval is plausible (this is exactly the
ChatGPT/Claude/Gemini lane) but not guaranteed.

**Effort:** **M–L.** Net-new: a `CarPlay` scene + `CPTemplateApplicationSceneDelegate`,
`CPVoiceControlTemplate` driving, AVAudioSession `playAndRecord` management per Apple's rules,
and **TTS**. Inference reuses the main app (no keyboard 60 MB limit — that's irrelevant here,
the main app runs Parakeet/embeddings/LLM).

### Route C — CarPlay audio app hosting spoken answers — **rejected**

Could a `CPNowPlayingTemplate` / `MPNowPlayingInfoCenter` audio app play back a spoken Ask
answer? Technically a now-playing surface can play audio — but (a) Jot can't get the **audio**
entitlement (its primary purpose isn't audio *playback*), and (b) the audio category doesn't
sanction mic capture, so it can't host capture or the *listening* half of Ask. Strictly worse
than Route B for every goal. Rejected. (Guide p.4 audio-app primary-purpose rule.)

**Ranking (per §0 decision):** **B is the product** — the eyes-free, capture-first CarPlay voice
app; it's the only route that delivers what the owner wants in the car. **A is an optional phone
byproduct**, not the goal (can't do eyes-free capture; Siri-while-driving unreliable). **C is out.**
Pursue the entitlement early since it gates B.

---

## 4. Reuse map — what each route leans on, and what's net-new

### 4.1 Capture (start recording → save a Jot, no on-screen text) — **save path reusable; mic needs a foreground bounce**

> **CORRECTED (per [app-intents-mic-investigation.md](./app-intents-mic-investigation.md)).** An
> earlier draft of this section called "capture already runs headless from a backgrounded intent"
> the central enabling fact. That is **wrong** and is exactly the owner's "broken" symptom: iOS
> **forbids starting the microphone from a cold, backgrounded, Siri-launched intent** (privacy
> gate; Apple DevForums #815725 + DTS #756507). The *transcribe-and-save tail* is genuinely
> headless and free; the *mic-start* is not. Capturing audio from an intent requires a **visible
> foreground bounce into Jot** (`openAppWhenRun = true`) — the phone switches into Jot to grab the
> mic. There is no no-bounce alternative on iOS (even a correct `AudioRecordingIntent` can only
> pause/resume an *already-foreground-started* session, and Jot ripped out the Live Activity
> machinery that contract needs).

- **The backgrounded intent that does NOT capture (the owner's "broken" one):**
  `RecordAndTranscribeIntent` (`Jot/App/Intents/RecordAndTranscribeIntent.swift:105`), a toggle
  intent with `static let openAppWhenRun = false` (`:117`). Siri can launch it, but the
  cold-background `RecordingService.shared.start()` it calls can't acquire the mic → nothing is
  captured. Its header doc-comment (`:21–26`) oversells an `AudioRecordingIntent` conformance the
  body never declares (`:60–71`: "conforms to AppIntent only"). **This is fiction — every
  `AudioRecordingIntent` token in the tree is in a comment, never a conformance.**
- **The intent that DOES capture (foreground bounce):** `DictateIntent` (`Jot/App/Intents/DictateIntent.swift`)
  uses `openAppWhenRun = true` — it foregrounds Jot, which can then start the mic. It is reportedly
  "one `isDiscoverable` flag from being re-registered." This is the only shape that captures audio
  from a voice/Action-Button trigger today; Apple DTS prescribes it and iOS 26.4+ enforces it.
- **Start / stop surface (no UI):** `controller.startRecording(startedAt:)` (`RecordAndTranscribeIntent.swift:166`)
  and `controller.stopAndTranscribe()` (`:184`), implemented on the process-wide
  `DictationControllerImpl` in `DictateIntent.swift` (which wraps
  `RecordingService.shared.start()` / `.stop()` and `TranscriptionService`).
- **Headless save (no view):** `DictationPipeline.completeEndOfRecording(transcript:startedAt:stoppedAt:controller:)`
  (`Jot/App/Intents/DictationPipeline.swift:151`) runs the whole tail — classify, publish to
  clipboard, and **`TranscriptStore.append(...)`** persist into SwiftData — with no SwiftUI view
  involved. (The `transient` flag gates the save; default path saves.)
- **Net-new for capture:** on the *pipeline* side, nothing — transcribe + `TranscriptStore.append`
  are headless. The real work is the **mic acquisition**: re-register the foreground-bounce
  `DictateIntent` (Route A) or own the mic in the CarPlay scene's foreground audio session
  (Route B). Plus confirming the Siri-while-driving behavior (§6 Q5).

> **Why this matters (corrected):** the *save* half of "record without showing text" — a headless
> transcribe→save path that needs no UI — **already exists and is shipping**, and the "no live
> text on the car screen" constraint is free (we just don't present a streaming view). But the
> *record* half is NOT free from a backgrounded intent: starting the mic requires Jot to be
> foreground (a visible app-switch on Siri/Action-Button, or the CarPlay scene in Route B). Do not
> plan around "cold hands-free no-bounce capture" — iOS doesn't allow it.

### 4.2 Ask (ask by voice → get a spoken answer)

- **Programmatic Q→A string path exists, decoupled from the view:**
  - `LLMClient.ask(systemPrompt:userPrompt:) async throws -> String`
    (`Jot/Shared/LLM/LLMClient.swift:61`) returns a **single final answer string** (non-streaming).
    `askStreaming(...)` (`:68`) is the streaming variant; default impl falls back to one final
    yield (`:80–93`). **For CarPlay we want the non-streaming `ask()`** — no token UI needed.
  - `AskController` (`Jot/App/Ask/AskController.swift`) orchestrates the real pipeline:
    `ask()` (`:226`) enqueues `runPipeline(question:)` (`:266`), which does retrieval
    (`retrieveTopK(forQuery:k:)` `:636`, using `EmbeddingGemmaService.shared.encode(...)` +
    BM25 + RRF fusion) then calls the LLM and stores `answerText`. The retrieval and generation
    steps are **not view-coupled** — phases are observable state, not UI.
  - **Caveat:** today `AskController` is `@Observable` and somewhat entangled with the Ask view's
    lifecycle (it accumulates into `@Observable` properties and uses `askStreaming`). For a
    headless CarPlay/intent caller we should extract a thin **`AskEngine.answer(question:) async -> (text, citations)`** that runs retrieval + non-streaming `ask()` and returns a plain
    string, rather than driving the view's controller. This is a small refactor, not new ML.
    (Verify the exact `AskController` line numbers before refactoring — they were reported by a
    survey agent and should be re-confirmed against the file.)
- **Net-new for Ask — TEXT-TO-SPEECH.** Confirmed by grep: **there is no `AVSpeechSynthesizer`
  / `AVSpeechUtterance` / TTS anywhere in Jot today.** (Searched the whole `Jot/` tree; the only
  hits are cosmetic copy like "Show words as you speak" and an RMS field
  `speechAmplitudeThreshold` — neither is TTS.) Speaking the answer aloud is **brand-new work**.
  Engine = **FluidAudio Kokoro** (82M, ANE, SSML/IPA) — the package already linked for Parakeet
  ASR + Silero VAD, so it's on-device, same-stack, and keeps the "only feedback leaves the device"
  invariant (chosen over `AVSpeechSynthesizer` for quality + stack consistency; §7). It also voices
  the capture **"Saved"** confirmation, not just Ask answers.
  - In **Route A**, Siri may also simply *read the intent's dialog result* aloud, which can
    substitute for app-owned TTS for short answers — worth testing before wiring Kokoro into the
    intent path.
  - In **Route B**, app-owned TTS (Kokoro) is required (the `CPVoiceControlTemplate` flow expects
    the app to produce the spoken response; Apple requires *not* showing the text).

### 4.3 What's genuinely net-new (summary)

| Net-new item | Route A | Route B | Notes |
|---|---|---|---|
| **Text-to-speech (FluidAudio Kokoro)** | Maybe (Siri may read dialog) | **Yes, required** | On-device/ANE, same stack as Parakeet ASR, no entitlement, preserves privacy invariant. ~tens-of-MB model. |
| Headless **`AskEngine`** (string in → string out) | Yes (small refactor of `AskController`) | Yes | Decouple Q→A from the SwiftUI Ask view. |
| **Ask App Intent** (`AskJotIntent`) | Yes | n/a (uses template instead) | Mirrors existing intents; returns `IntentResult` dialog. |
| **CarPlay scene + `CPTemplateApplicationSceneDelegate`** | No | **Yes** | New scene in the app's scene manifest. |
| **`CPVoiceControlTemplate`** driving | No | **Yes** | Listening/processing states; ≤4 action buttons. |
| **AVAudioSession `playAndRecord`** mgmt per Apple's CarPlay rules | Partially (capture already manages a session) | **Yes** | "Only hold the session open while voice is active." |
| **CarPlay entitlement + provisioning** | No | **Yes (Apple review)** | `carplay-voice-based-conversation`, iOS 26.4 min. |

---

## 5. Open questions / assumptions for the owner

1. **Which iOS floor?** Route B's voice-conversational category requires **iOS 26.4** on the
   user's device. Jot's deployment target is iOS 26.0 (per `Jot/CLAUDE.md`). Acceptable to gate
   the CarPlay-app experience to 26.4+? (Route A/Siri has no such floor.)
2. **Is "primary modality is voice" defensible to Apple for Jot?** Jot is marketed as a
   dictation/notes app, not a conversational assistant. The entitlement request must credibly
   present the *in-car* experience as voice-conversational Ask. Owner should decide whether to
   pursue this framing (and accept possible rejection) before we build Route B.
3. **Capture inside a "voice-conversational" app — acceptable to Apple?** The category is built
   for Q&A assistants. Folding "jot this down" capture into it is reasonable but unverified with
   App Review. Assumption: capture is offered as a voice action within the conversational
   surface, not as a separate template. Confirm appetite to risk this.
4. **Spoken-answer length / verbosity.** Ask answers can be long. For eyes-free TTS we likely
   need a "spoken summary" generation mode (shorter, plainer) distinct from the on-screen answer.
   Is a separate concise-answer prompt acceptable? (Net-new prompt, small.)
5. **Siri-while-driving reliability (the make-or-break for Route A live use).** Custom App
   Intents are often blocked by Siri in CarPlay (*"can't do that while you're driving"*). We
   must test on a real head unit. If Jot's capture/Ask intents are blocked while driving, Route
   A's value drops to "works in the car only via the phone before you start driving" and Route B
   becomes the *only* true in-motion path. **This is the single most important thing to verify
   before committing to a route.**
6. **Do we want a CarPlay Dashboard Live Activity** (zero-entitlement) showing "Jot recording…"?
   Cheap given `DictationActivityCoordinator` already exists, but out of scope for the two core
   capabilities — flag for later.

---

## 6. Staged implementation plan (recommended route) — prose / pseudocode only

**Strategy (per §0):** build **Route B — the eyes-free CarPlay voice app, capture-first** — as the
product. The entitlement is the long pole, so request it on day one and build the foundation in
parallel. Ask is reused (already shipping) only as the conversational passport. The cheap Siri
path is NOT the plan.

### Stage 0 — Entitlement request + de-risk (no product code)
- **Submit the `com.apple.developer.carplay-voice-based-conversation` entitlement request now**
  (`https://developer.apple.com/contact/carplay/`), framed as a voice-conversational assistant for
  your notes: **capture thoughts by voice AND ask your notes** (§5 Q2–Q3). Review is case-by-case
  with no SLA — it gates everything, so start it first.
- Decide the deployment floor: the CarPlay voice app requires **iOS 26.4** on-device (Jot targets
  26.0 today). The CarPlay surface gates to 26.4+; the phone app is unaffected (§5 Q1).
- (If a real head unit is available) sanity-check the `CPVoiceControlTemplate` listen→speak loop —
  but note Route B does NOT depend on Siri, so the "Siri-while-driving" block is irrelevant here.
- **Prerequisite cleanup:** correct the misleading `AudioRecordingIntent` doc-comments
  (`RecordAndTranscribeIntent.swift:21–26`, `JotAppShortcuts.swift:22`, `TranscriptStore.swift:14`)
  so this work isn't derailed by the same fiction that misled the prior research doc.

### Stage 1 — Shared foundation (no entitlement needed; useful on the phone too)
- **On-device TTS — the one genuinely new subsystem.** Add a thin `SpokenResponder` over
  **FluidAudio Kokoro** (82M, ANE; the same package already linked for Parakeet ASR + Silero VAD —
  on-device, preserves the "only feedback leaves the device" invariant): `speak(_:)` +
  interrupt/stop. Voices the "Saved" confirmation + concise Ask answers. (NOT `AVSpeechSynthesizer`
  — owner call; Kokoro is higher quality and same-stack. Bundle adds the Kokoro model, ~tens of MB.)
- **Confirm the headless capture tail runs view-free:** `RecordingService.start()/stop()` →
  `TranscriptionService` → `DictationPipeline.completeEndOfRecording(...)` → `TranscriptStore.append`.
  This already exists and needs no streaming view — the "no text on the car screen" rule is free.
- **(Secondary) Ask engine:** extract a thin `AskEngine.answer(question:) async -> String` from
  `AskController` (retrieval → non-streaming `LLMClient.ask(...)`), plus a concise "spoken answer"
  prompt. Only needed for the Ask passport; not on the capture critical path.

### Stage 2 — CarPlay voice app, **capture-first** (the deliverable; gated on entitlement grant)
- Add the entitlement key to a CarPlay-enabled provisioning profile; add a **CarPlay scene** to the
  scene manifest with a `CPTemplateApplicationSceneDelegate`. The scene runs **foreground and owns
  the mic** via its own `AVAudioSession` (`playAndRecord`, held open **only** while voice is active,
  per Apple's rule) — no Siri, no background-mic gate, no app-bounce.
- **Capture flow (the hero), explicit stop:** **manually launch Jot from the CarPlay home screen**
  (Apple-required for this category — no wake-word/wheel-button) →
  **recording starts immediately** → driver speaks → **explicit stop = one tap** on the template's
  built-in Stop/Done → on-device transcribe (`TranscriptionService`) → save
  (`completeEndOfRecording`) → `SpokenResponder.speak("Saved")`. **No text shown.** A **30s
  no-speech VAD backstop** (Silero) auto-saves if the driver forgets to tap.
  - *Open item (verify in Stage 2 against the live SDK):* `CPVoiceControlTemplate` custom buttons
    may be iOS-27-only; on the 26.4 floor confirm the built-in nav-bar Stop/Cancel fires a usable
    delegate callback. Voice-word stop is **deferred to V2** (the stop word transcribes into the
    note — needs a parallel keyword-spotter + trailing-trim). See §7 M1/M2.
- **Ask (the passport), reused:** a second voice action — driver asks a question → transcribe →
  `AskEngine.answer(...)` → `SpokenResponder.speak(...)` the concise summary. No text.
- **Disambiguate capture vs ask:** by leading phrase ("jot this down…" vs "ask…/what/when/where…")
  or a tiny on-device classifier over the transcribed utterance. Default ambiguous input to
  **capture** (the flagship) — saving a stray thought is harmless; mis-saving a question is not.
- (Optional, free later) a CarPlay Dashboard Live Activity "recording…" via the existing
  `DictationActivityCoordinator` (`.small` family).

### Stage 3 — (Optional) phone Siri capture — NOT the goal
- Only if we also want a phone shortcut: re-register the **foreground-bounce** `DictateIntent`
  (`openAppWhenRun=true`). Acknowledge it is **not eyes-free** (visible app-switch) and Siri may
  refuse it while driving. This is a phone convenience, explicitly not the in-car product.

### What we deliberately do NOT do
- No live transcript streaming on the car screen (owner's explicit constraint; also Apple's rule
  for the voice category). The headless pipeline already needs no streaming view.
- No attempt at the **driving-task / audio / communication** entitlements — they don't fit (§2.2)
  and would be rejected.

---

## 7. Adversarial review outcomes (2026-06-19) — folded in

An independent adversarial review ran against this plan. Verdict: **Stage 1 is safe to build now;
Stage 2 needed three fixes + an entitlement reframe before committing.** These resolutions are now
the plan of record and **supersede** any earlier inline mention of `AVSpeechSynthesizer` or a
voice-word primary stop.

- **M1/M2 — Stop mechanism (was under-designed).** Primary stop = **one tap** on the template's
  built-in Stop/Done. *Custom* `CPVoiceControlTemplate` buttons appear to be **iOS 27+**; on the
  iOS 26.4 floor the base template exposes only the system nav-bar control — **verify it fires a
  usable callback** early. **Voice-word stop is a trap** (the word transcribes into the note) →
  **deferred to V2** with explicit trailing-token trimming. Added a **30s no-speech VAD backstop**
  (Silero, already bundled) for "forgot to tap" — keyed on absence of *words*, not sound.
- **TTS = FluidAudio Kokoro** (82M, ANE, SSML/IPA) + PocketTTS available — **not**
  `AVSpeechSynthesizer` (owner call; verified FluidAudio ships TTS). On-device, same stack,
  privacy-preserving. Bundle adds the Kokoro model (~tens of MB).
- **M4 — Dedicated CarPlay `AVAudioSession` (net-new, NOT reusable).** The voice category needs
  `.playAndRecord` / `.default` mode / no-mix (speak TTS **and** listen). Jot's current capture is
  `.record / .measurement / [.mixWithOthers]` (`RecordingService.swift:1252-1256`), and
  `.playAndRecord` was **deliberately removed after an `AURemoteIO` failure** on the Action-Button
  path (comment :1246-1250). Stage 2 scopes a separate CarPlay session **and re-validates that
  prior failure** in-context.
- **N3 — Interruption handling (was missing).** Calls / nav prompts / Siri ducking tear down the
  session mid-capture. Add `AVAudioSession.interruptionNotification` handling (save-partial +
  resume) for a 30s–2min recording. Added to the Stage-2 scope.
- **M3 — Entitlement submission reframed.** Present to Apple as **Ask-primary** ("ask your notes by
  voice" — answers questions, performs the save action) — the *inverse* of the internal
  capture-first priority — because the category gatekeeps for genuine conversational assistants and
  a capture-primary framing invites rejection (grant-likelihood **moderate**). Implication: the
  in-car **Ask must be genuinely competent, not a token**. **Route A (foreground-bounce
  `DictateIntent` via Siri/Shortcuts) is the NAMED fallback**: if the entitlement is denied, Route A
  *becomes* the product (captures today, no entitlement; not eyes-free, but real).
- **Minor:** default-ambiguous-to-capture can silently mis-save a *question* → add an audible
  low-confidence "capture or ask?" cue (don't silently pollute the library). Keep the 26.4-category
  **simulator smoke-test a hard Stage-0 gate**. The `AskEngine` extraction is real work
  (`AskController` is `@Observable`-entangled), not free.

## 8. Testing without a car — the Xcode CarPlay Simulator

**Yes — we can build and validate almost the entire experience with no car.** Critically, this
means **implementation is NOT blocked on Apple's entitlement grant** — the grant only gates
*shipping* to a device/TestFlight/App Store.

- **The tool:** with the iOS Simulator running, choose **I/O → External Displays → CarPlay** to open
  a simulated head-unit window; the Jot CarPlay scene appears on its home screen. ([createwithswift](https://www.createwithswift.com/testing-apps-with-an-iphone-and-the-carplay-simulator/))
- **No granted entitlement needed for sim dev:** add the entitlement key to a **local
  `.entitlements`** file + the CarPlay scene to the Info.plist scene manifest, and the simulator
  renders it — the sim doesn't enforce Apple's provisioning grant. ([Apple DevForums #726227](https://developer.apple.com/forums/thread/726227))
- **Real mic + audio work in the sim:** the iOS Simulator uses the **Mac's microphone**, so the
  full capture loop is testable end-to-end — speak into the Mac mic → Parakeet transcribes → save →
  FluidAudio Kokoro speaks "Saved" (TTS playback works in the sim too). This is the big one:
  we can prove the capture-flagship flow on the simulated head unit before any approval.
- **What the sim CANNOT give us (needs a real device/car eventually):** the CarPlay Simulator is
  known-buggy/limited; real head-unit audio routing, the actual manual-launch UX + driving-mode
  behavior, and the shippable entitlement all require a device/car. **Verify early** that the
  brand-new **iOS 26.4 voice-conversational** category renders in the sim — `CPVoiceControlTemplate`
  itself is old (iOS 14) and supported, but the 26.4 *category* gating is new and should be smoke-
  tested first. ([iClarified](https://www.iclarified.com/99965/ios-264-beta-adds-carplay-support-for-voice-ai-apps-like-chatgpt-and-gemini); [Apple DevForums #821632](https://developer.apple.com/forums/thread/821632))

**Implication for staging:** Stage 1 (TTS) + Stage 2 (the CarPlay capture flow) can be **built and
sim-tested now, in parallel with the entitlement request** — we don't wait on Apple to start.

## References

CarPlay claims — Apple *CarPlay Developer Guide*, June 2026 edition (page numbers as extracted):
- Category list — p.3; Entitlements table + rules — p.12–13; Templates + per-category template
  matrix — p.14; per-category guidelines (driving task p.5, communication p.5, audio p.4,
  voice-based conversational **p.7**), widgets/Live Activities zero-entitlement — p.3, p.9–10.
  PDF: `https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf`
- Requesting CarPlay Entitlements — `https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements`
- CarPlay framework — `https://developer.apple.com/documentation/carplay`

iOS 26.4 voice-conversational category (intent, scope, ChatGPT/Claude/Gemini):
- 9to5Mac — `https://9to5mac.com/2026/02/18/ios-26-4-adds-support-for-voice-based-ai-apps-to-carplay/`
- MacRumors — `https://www.macrumors.com/2026/02/18/ios-26-4-carplay-support/`
- iClarified — `https://www.iclarified.com/99965/ios-264-beta-adds-carplay-support-for-voice-ai-apps-like-chatgpt-and-gemini`

Siri / custom-intent-while-driving limitation:
- Apple DevForums #709496 (Siri Custom Intents on CarPlay) — `https://developer.apple.com/forums/thread/709496`
- Apple DevForums #733589 (Open CarPlay app with Siri) — `https://developer.apple.com/forums/thread/733589`

Jot source (claims grounded in `file:line`):
- `Jot/App/Intents/RecordAndTranscribeIntent.swift:105,117,136,166,184` (headless capture intent)
- `Jot/App/Intents/DictateIntent.swift` (process-wide `DictationControllerImpl`, legacy fallback)
- `Jot/App/Intents/DictationPipeline.swift:151` (`completeEndOfRecording`, headless save)
- `Jot/App/Intents/JotAppShortcuts.swift:72` (`AppShortcutsProvider` registration)
- `Jot/App/Intents/TranscribeAudioFileIntent.swift:71` (file-in/text-out, `openAppWhenRun=false`)
- `Jot/Shared/LLM/LLMClient.swift:61,68` (`ask` / `askStreaming` — non-streaming string path)
- `Jot/App/Ask/AskController.swift:226,266,636` (Ask pipeline; line numbers to re-confirm)
- TTS absence: full-tree grep for `AVSpeechSynthesizer`/`AVSpeechUtterance` → **no production hits.**
