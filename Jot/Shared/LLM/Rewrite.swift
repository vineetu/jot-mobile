import FoundationModels

// `@Generable` projects this struct into a JSON schema for Apple Foundation
// Models' guided generation: `LanguageModelSession.respond(... generating:
// Rewrite.self)` (on-device or Private Cloud Compute — see `RewriteClient`)
// constrains decoding so the model literally cannot emit preamble like "Here
// is the rewritten text:" — only valid JSON matching this shape. The text
// payload is the rewritten body and nothing else.
//
// This file is in `Shared/` so it compiles into both the main app and the
// extensions. `FoundationModels` is a system framework available in
// extensions on iOS 26, so import-side it's safe everywhere.
@available(iOS 26.0, *)
@Generable
struct Rewrite: Codable {
    @Guide(description: "The rewritten text only — never an answer or reply to it; no preamble, no quotes, no explanation")
    let text: String
}
