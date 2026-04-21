import Foundation

/// Layout tables for Jot's keyboard. Three planes: letters, numbers, symbols —
/// the same three Apple's native iOS keyboard exposes. Each plane is a grid of
/// rows, where each row is an array of ``KeyboardKeyDescriptor`` values. The
/// rendering layer (``KeyboardView``) maps descriptors to SwiftUI ``View`` via
/// ``KeyboardKey`` and never reaches back here.
enum KeyboardLayouts {

    /// Which plane is currently shown. `letters` is the default; `numbers`
    /// toggles from the `123` action key; `symbols` from `#+=` inside numbers.
    /// Matches Apple's naming (`.keyboardType == .default`, `.numberPad` etc.
    /// are the underlying UIKit equivalents, but we don't bind to those —
    /// our planes are user-visible state, not a keyboard-type contract).
    enum Plane: Hashable {
        case letters
        case numbers
        case symbols
    }

    // MARK: - Rows

    /// Letters plane. Rows render as 10 / 9 / 7-with-flanks / bottom-action.
    /// The second row is visually centered (9 keys inside a 10-key grid) via
    /// the renderer's per-row exact-fit layout, which absorbs the leftover
    /// ~half a key as symmetric edge padding.
    static let letters: [[KeyboardKeyDescriptor]] = [
        "qwertyuiop".map { .letter(String($0)) },
        "asdfghjkl".map { .letter(String($0)) },
        [.shift] + "zxcvbnm".map { .letter(String($0)) } + [.backspace],
    ]

    /// Numbers plane. Three primary rows + the same bottom-action row.
    static let numbers: [[KeyboardKeyDescriptor]] = [
        "1234567890".map { .literal(String($0)) },
        "-/:;()$&@\"".map { .literal(String($0)) },
        [.planeToggle(.symbols, label: "#+=")]
            + ".,?!'".map { .literal(String($0)) }
            + [.backspace],
    ]

    /// Symbols plane. Same shape as `numbers`.
    static let symbols: [[KeyboardKeyDescriptor]] = [
        "[]{}#%^*+=".map { .literal(String($0)) },
        "_\\|~<>€£¥•".map { .literal(String($0)) },
        [.planeToggle(.numbers, label: "123")]
            + ".,?!'".map { .literal(String($0)) }
            + [.backspace],
    ]

    /// Bottom action row. Plane toggle on the left, Jot history next to it,
    /// then space, then return. Apple's own keyboard-switcher globe is
    /// omnipresent on the system keyboard chrome so we don't render one of
    /// our own — a second globe key confuses users and costs ~1.5 key widths
    /// of horizontal real estate for no gain. The history button lives on
    /// this bottom row (not in the accessory bar above the grid) so it falls
    /// under one-handed thumb reach — the accessory-bar placement forced
    /// reaching across the whole phone for a feature people trigger often.
    static func bottomRow(for plane: Plane) -> [KeyboardKeyDescriptor] {
        let planeKey: KeyboardKeyDescriptor
        switch plane {
        case .letters:
            planeKey = .planeToggle(.numbers, label: "123")
        case .numbers, .symbols:
            planeKey = .planeToggle(.letters, label: "ABC")
        }
        return [planeKey, .historyKey, .space, .returnKey]
    }

    /// Resolve the primary rows for a plane. Renderer composes these with
    /// ``bottomRow(for:)`` to form the full four-row keyboard.
    static func rows(for plane: Plane) -> [[KeyboardKeyDescriptor]] {
        switch plane {
        case .letters: return letters
        case .numbers: return numbers
        case .symbols: return symbols
        }
    }
}

/// All the things a key can mean. Kept as a closed enum so the renderer's
/// `switch` is exhaustive — a new key type is a compile error at every site
/// that dispatches on it (the compiler is the checklist).
enum KeyboardKeyDescriptor: Hashable {
    /// Case-sensitive letter. Final insertion text is derived from the
    /// current ``ShiftState``.
    case letter(String)
    /// Literal non-letter character — digits, punctuation, symbols. Ignores
    /// shift state; the symbol planes already express both cases where
    /// applicable (`[` vs `{`, etc).
    case literal(String)
    case space
    /// Inserts the appropriate return character. Host apps that want a
    /// "Go" / "Search" style affordance can style via
    /// `textDocumentProxy.returnKeyType` later; MVP sticks to a single
    /// semantic.
    case returnKey
    case backspace
    /// Shift modifier. Behavior is delegated to ``ShiftState``: single tap
    /// cycles off → shifted → off; double-tap locks caps.
    case shift
    /// Swap to a different plane. The label is what the key shows — e.g.
    /// `"123"`, `"ABC"`, `"#+="`.
    case planeToggle(KeyboardLayouts.Plane, label: String)
    /// Opens the transcript history overlay. Placed on the bottom row (not
    /// the accessory bar) so it's reachable with a single-handed thumb —
    /// accessory-bar placement made the most-used Jot-specific action the
    /// *least* reachable button on the keyboard.
    case historyKey

    /// Characters the key inserts into the document when tapped. `nil` means
    /// the key has no direct text side-effect (shift, backspace, history,
    /// plane toggles) and the VC handles it via a different code path.
    func insertion(for shift: ShiftState) -> String? {
        switch self {
        case .letter(let base):
            return shift.isUppercased ? base.uppercased() : base
        case .literal(let text):
            return text
        case .space:
            return " "
        case .returnKey:
            return "\n"
        case .backspace, .shift, .planeToggle, .historyKey:
            return nil
        }
    }

    /// Label rendered on the keycap. Nil means the key uses an SF Symbol
    /// instead (see ``symbolName``).
    func label(for shift: ShiftState) -> String? {
        switch self {
        case .letter(let base):
            return shift.isUppercased ? base.uppercased() : base
        case .literal(let text):
            return text
        case .space:
            return "space"
        case .planeToggle(_, let label):
            return label
        case .returnKey, .backspace, .shift, .historyKey:
            return nil
        }
    }

    /// SF Symbol for keys rendered as glyphs rather than text. Glyph choice
    /// mirrors Apple's keyboard where applicable (`shift`, `delete.left`,
    /// `arrow.turn.down.left`); the history key uses the same
    /// `clock.arrow.circlepath` glyph Apple reserves for "recent items".
    func symbolName(for shift: ShiftState) -> String? {
        switch self {
        case .shift:
            switch shift {
            case .off:        return "shift"
            case .shifted:    return "shift.fill"
            case .capsLocked: return "capslock.fill"
            }
        case .backspace:    return "delete.left"
        case .returnKey:    return "arrow.turn.down.left"
        case .historyKey:   return "clock.arrow.circlepath"
        default:            return nil
        }
    }

    /// Accessibility label. VoiceOver reads this when the user touches the
    /// key. Falls back to the insertion text when we don't have a friendlier
    /// name.
    func accessibilityLabel(for shift: ShiftState) -> String {
        switch self {
        case .letter(let base):
            return shift.isUppercased ? "\(base.uppercased()) uppercase" : base
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
        case .space:                  return "space"
        case .returnKey:              return "return"
        case .backspace:              return "delete"
        case .shift:
            switch shift {
            case .off:        return "shift"
            case .shifted:    return "shift, enabled"
            case .capsLocked: return "shift, caps lock"
            }
        case .planeToggle(_, let label):
            switch label {
            case "123":   return "numbers"
            case "ABC":   return "letters"
            case "#+=":   return "symbols"
            default:      return label
            }
        case .historyKey:             return "dictation history"
        }
    }

    /// Cosmetic category. Primary keys (letters, digits, symbols) sit on a
    /// lighter base; action keys (shift, backspace, plane toggles, history,
    /// return) sit on a slightly darker base — the same visual distinction
    /// Apple's keyboard uses.
    var style: KeyboardKeyStyle {
        switch self {
        case .letter, .literal:
            return .primary
        case .space:
            return .primary
        case .returnKey:
            return .returnAccent
        case .backspace, .shift, .planeToggle, .historyKey:
            return .action
        }
    }
}

/// Visual role of a key. Drives background color / contrast in
/// ``KeyboardKey``. Kept separate from the descriptor so the renderer owns
/// look-and-feel decisions and the layout stays pure data.
enum KeyboardKeyStyle {
    /// Primary "you're typing text into the document" keys — letters, digits,
    /// punctuation, space.
    case primary
    /// Modal / action keys — shift, backspace, plane toggles, history.
    case action
    /// Return gets a subtle accent tint to match Apple's "blue return"
    /// treatment for default actions. The main app doesn't customize return
    /// key type per field, so we use a neutral accent that looks at home
    /// next to both `Return` and `Go` / `Search`.
    case returnAccent
}

/// Tri-state shift modifier. Matches Apple's keyboard:
///
/// - `off`: next letter lowercase
/// - `shifted`: next letter uppercase, then auto-revert
/// - `capsLocked`: every letter uppercase until shift is tapped again
enum ShiftState {
    case off
    case shifted
    case capsLocked

    var isUppercased: Bool {
        switch self {
        case .off:                    return false
        case .shifted, .capsLocked:   return true
        }
    }

    /// Cycle state on a single tap. Off → shifted → off. Caps lock is
    /// engaged separately via `.capsLocked` (double-tap handling).
    func singleTapped() -> ShiftState {
        switch self {
        case .off:                    return .shifted
        case .shifted, .capsLocked:   return .off
        }
    }

    /// After inserting a letter, shifted collapses back to off; caps locked
    /// persists; off stays off.
    func afterLetterInsert() -> ShiftState {
        switch self {
        case .shifted:   return .off
        case .off:       return .off
        case .capsLocked: return .capsLocked
        }
    }
}
