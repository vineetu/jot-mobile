#if JOT_APP_HOST
import Foundation

/// Renderable piece of an Ask-mode answer. Concatenating a sequence of
/// these reconstructs the model's response with inline citation chips
/// in place of `[cite: <uuid>]` markers.
///
/// `.text` may itself contain newlines and ordinary punctuation. Citations
/// carry the full `Transcript` snapshot taken at retrieval time so the
/// chip can render a short date label and the tap path has the ID handy.
enum AskAnswerSegment: Identifiable, Hashable {
    case text(String)
    case citation(citationID: UUID, label: String)

    /// Stable identity for SwiftUI ForEach. Text segments get a hash-based
    /// ID — collisions are tolerable because they only cost a re-render.
    var id: String {
        switch self {
        case .text(let s): return "t:\(s.hashValue)"
        case .citation(let id, _): return "c:\(id.uuidString)"
        }
    }
}
#endif
