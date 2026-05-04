/// All the things a key can mean. Kept as a closed enum so the renderer's
/// switches are exhaustive; a new key type becomes a compile-time checklist.
enum KeyboardKeyDescriptor: Hashable {
    case literal(String)
    case space
    case returnKey
    case backspace

    /// Characters the key inserts into the document when tapped. `nil` means
    /// the controller handles the key via a non-text side effect.
    func insertion() -> String? {
        switch self {
        case .literal(let text):
            return text
        case .space:
            return " "
        case .returnKey:
            return "\n"
        case .backspace:
            return nil
        }
    }

    /// Label rendered on the keycap. Nil means the key uses an SF Symbol
    /// instead (see ``symbolName``).
    func label() -> String? {
        switch self {
        case .literal(let text):
            return text
        case .space:
            return "space"
        case .returnKey, .backspace:
            return nil
        }
    }

    /// SF Symbol for keys rendered as glyphs rather than text.
    func symbolName() -> String? {
        switch self {
        case .backspace:
            return "delete.left"
        case .returnKey:
            return "arrow.turn.down.left"
        case .literal, .space:
            return nil
        }
    }

    /// Accessibility label. VoiceOver reads this when the user touches the key.
    func accessibilityLabel() -> String {
        switch self {
        case .literal(let text):
            switch text {
            case ".": return "period"
            case ",": return "comma"
            case "?": return "question mark"
            case "!": return "exclamation point"
            case "'": return "apostrophe"
            case "\"": return "quote"
            default:  return text
            }
        case .space:
            return "space"
        case .returnKey:
            return "return"
        case .backspace:
            return "delete"
        }
    }

    /// Cosmetic category. Primary keys sit on a lighter base; action keys sit
    /// on a slightly darker base; return uses the accent treatment.
    var style: KeyboardKeyStyle {
        switch self {
        case .literal, .space:
            return .primary
        case .returnKey:
            return .returnAccent
        case .backspace:
            return .action
        }
    }
}

/// Visual role of a key. Drives background color / contrast in ``KeyboardKey``.
enum KeyboardKeyStyle {
    /// Primary "you're typing text into the document" keys: punctuation and
    /// space in the compact keyboard surface.
    case primary
    /// Modal / action keys.
    case action
    /// Return gets a subtle accent tint to match Apple's "blue return"
    /// treatment for default actions.
    case returnAccent
}
