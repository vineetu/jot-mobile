import Foundation

/// Per-session pending auto-paste record. Replaces the v6 pair of
/// `pendingAutoPasteFlag` + `pendingAutoPasteCreatedAt` keys.
///
/// `id` plumbs through URL scheme + App Group + `ClipboardHandoff.FreshDictation`
/// so the keyboard can match a specific in-flight pipeline's published
/// transcript to the keyboard's pending intent — replacing the v6
/// `pendingAutoPasteMaxAge: 600s` wall-clock ceiling that this design retires.
///
/// `hostKeyboardTypeRaw` and `hostDocumentIdentifier` are best-effort
/// same-input-context guards captured at tap time so the keyboard avoids
/// inserting into a different field the user has navigated to since the tap.
struct PendingPasteSession: Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    let hostKeyboardTypeRaw: Int?
    let hostDocumentIdentifier: UUID?
}
