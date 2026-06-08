import Foundation

/// Per-session pending auto-paste record. Replaces the v6 pair of
/// `pendingAutoPasteFlag` + `pendingAutoPasteCreatedAt` keys.
///
/// `id` plumbs through URL scheme + App Group + `ClipboardHandoff.FreshDictation`
/// so the keyboard can match a specific in-flight pipeline's published
/// transcript to the keyboard's pending intent — replacing the v6
/// `pendingAutoPasteMaxAge: 600s` wall-clock ceiling that this design retires.
///
/// `hostKeyboardTypeRaw` and `hostDocumentIdentifier` are captured at tap time.
/// They are NO LONGER used to gate the paste: the "same-input-context" reject
/// guards were removed so the keyboard pastes wherever the cursor is at flush
/// time (iOS only presents the keyboard over a focused input). The fields are
/// retained for diagnostics / backward-compatible decoding of persisted
/// sessions; they can be dropped in a future cleanup.
struct PendingPasteSession: Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    let hostKeyboardTypeRaw: Int?
    let hostDocumentIdentifier: UUID?
}
