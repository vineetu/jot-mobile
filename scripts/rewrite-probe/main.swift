import Foundation
import FoundationModels

let prompt = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let oldInstructions = """
You rewrite text that the user dictated by voice. Apply the rewrite \
instructions below to the text in the user's message. Keep the \
user's meaning and facts; never add information they did not say. \
Return only the rewritten text.

Rewrite instructions:
\(prompt)
"""
let newInstructions = RewriteInstructions.compose(prompt, source: .dictation)
let inputs = [
  "do you understand what i'm asking",
  "yes can you confirm this for me",
  "can you send me the report by friday",
  "what time is the meeting tomorrow",
  "so what do you think about the new keyboard",
  "hey can you pick up milk on the way home",
  "um is it okay if i push the deadline to next friday",
  "tell me what you decided about the launch date",
  "please summarize this for me",
  "how do i turn on live text in settings",
  "everything is complicated because the schema is frozen",
  "make sure to call the dentist thursday morning",
  // held-out: shapes the examples don't cover
  "could you check if the invoice went out",
  "remind me what the wifi password is",
  "should we move the standup to nine",
  "explain to me why the build failed",
  "let me know if you're coming tonight",
  "what's the status on the design review",
  "give me three names for the new feature",
  "is there a way to export all my notes",
  // held-out round 2: produce-something shapes
  "write me a subject line for this email",
  "suggest a better title for the launch post",
  "draft a reply saying no thanks",
  "list the pros and cons of moving to friday",
]
func run(_ instructions: String, _ text: String) async -> String {
  let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: instructions)
  do {
    let r = try await session.respond(to: RewriteInstructions.userTurn(text), generating: Rewrite.self)
    return r.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
  } catch { return "ERROR: \(error.localizedDescription)" }
}
func runOld(_ text: String) async -> String {
  let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: oldInstructions)
  do {
    let r = try await session.respond(to: text, generating: Rewrite.self)
    return r.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
  } catch { return "ERROR: \(error.localizedDescription)" }
}
@main struct Probe {
  static func main() async {
    print("availability:", SystemLanguageModel.default.availability)
    for text in inputs {
      let b = await run(newInstructions, text)
      print("IN : \(text)\nNEW: \(b)")
    }
  }
}
