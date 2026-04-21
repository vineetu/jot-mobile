import SwiftUI

/// Pixel-accurate iOS keyboard metrics. Every value in this struct is sourced
/// from `docs/research/ios-keyboard-1to1.md` — not a guess, not a tuned
/// approximation. Changing a constant here changes how Jot's keyboard matches
/// the native iOS keyboard at the pixel level.
///
/// ## Model
///
/// KeyboardKit (the open-source Swift package whose goal is 1:1 iOS
/// replication) models every row as a sequence of _cells_, where each cell
/// has:
///
/// - A horizontal inset of `buttonInsets.horizontal = 3 pt` on each side.
/// - A vertical inset of `buttonInsets.vertical = 5 pt` on each side.
///
/// Two adjacent cells share their facing insets, producing a 6 pt visual gap
/// between key caps. Two stacked rows share their facing insets, producing a
/// 10 pt visual gap between rows. The row height includes the 10 pt
/// (5+5) of vertical inset.
///
/// We translate that into SwiftUI as:
///
/// - `sideInset = 3 pt` — outer-edge horizontal padding; the first key cap's
///   left inset and the last key cap's right inset.
/// - `keySpacing = 6 pt` — `HStack` spacing between key caps.
/// - `verticalInset = 5 pt` — outer-edge vertical padding; the first row's
///   top inset and the last row's bottom inset.
/// - `rowSpacing = 10 pt` — `VStack` spacing between rows.
/// - `keyHeight = rowHeight - 2 × verticalInset` — the inner key cap height.
///
/// ## Width bucket
///
/// iOS picks different row heights for the "standard" and "large" iPhone
/// classes. The threshold is width ≥ 428 pt (iPhone 14 Plus, 15 Plus, Pro Max
/// generations). Below 428, `rowHeight = 54`; at 428 or above, `rowHeight = 56`.
///
/// ## iOS 26 / Liquid Glass
///
/// iOS 26 bumps row height by +2 pt and rounds the corner radius from 5 to 9.
/// We detect it with `#available(iOS 26.0, *)`; if you need to force the
/// pre-iOS-26 look for testing, initialize with `liquidGlass: false`.
struct KeyboardMetrics: Equatable {

    // MARK: - Inputs

    /// The total width available to the keyboard. Usually comes from
    /// `GeometryReader.size.width`.
    let availableWidth: CGFloat

    /// Whether iOS 26 Liquid Glass styling is active (thicker rows + rounder
    /// caps). The convenience initializer picks this from `#available`; pass
    /// explicitly to force one style in previews / tests.
    let liquidGlass: Bool

    // MARK: - Derived row sizing

    /// Row height in points. Standard phones (width < 428) use 54 pt; large
    /// phones (width ≥ 428) use 56 pt. Liquid Glass adds +2 pt on either
    /// class.
    ///
    /// Source: KeyboardKit `KeyboardLayout.DeviceConfiguration.standardPhone`
    /// and `standardPhoneLarge` — confirmed in the research doc summary
    /// table.
    var rowHeight: CGFloat {
        let base: CGFloat = isLargeWidth ? 56 : 54
        return liquidGlass ? base + 2 : base
    }

    /// Space between two adjacent rows. `verticalInset * 2` so that the
    /// top+bottom insets of adjacent rows sum to the advertised gap.
    var rowSpacing: CGFloat { verticalInset * 2 }

    /// Top / bottom vertical padding inside a row. 5 pt pre-iOS-26, 4.5 pt
    /// under Liquid Glass.
    var verticalInset: CGFloat { liquidGlass ? 4.5 : 5 }

    /// The height of a single key cap — the interactive/visual rectangle
    /// inside its row cell. Equals `rowHeight - 2 × verticalInset`.
    var keyHeight: CGFloat { rowHeight - 2 * verticalInset }

    // MARK: - Derived horizontal sizing

    /// Outer-edge horizontal padding (each side). Matches KeyboardKit's
    /// `buttonInsets.horizontal`.
    var sideInset: CGFloat { 3 }

    /// Inter-key horizontal spacing inside an `HStack`. Two adjacent cells
    /// each contribute 3 pt → 6 pt total.
    var keySpacing: CGFloat { 6 }

    /// Width of a standard letter key cap. Row 1 of the alpha plane has 10
    /// keys; dividing the inner width by 10 (subtracting the 9 inter-key
    /// gaps) gives the width that lets the top row fit exactly.
    ///
    /// This is the unit that every other key width is expressed in: action
    /// keys like shift and backspace occupy `1.5 × letterKeyWidth`, the
    /// return key occupies `2 × letterKeyWidth`, and so on.
    var letterKeyWidth: CGFloat {
        max(20, (innerWidth - 9 * keySpacing) / 10)
    }

    /// The horizontal space left after the outer edge padding on both sides.
    var innerWidth: CGFloat { availableWidth - 2 * sideInset }

    // MARK: - Corner radius

    /// Corner radius for every key cap (alpha + action). Pre-iOS-26 is 5 pt
    /// (a gentle round); Liquid Glass steps up to 9 pt (noticeably rounder).
    ///
    /// Source: KeyboardKit `KeyboardStyle.Button.cornerRadius` for the
    /// active configuration.
    var buttonCornerRadius: CGFloat { liquidGlass ? 9 : 5 }

    // MARK: - Overall keyboard height

    /// Total height of the keyboard's letters area (4 rows, no accessory
    /// bar). Used to drive `frame(height:)` on the keyboard surface.
    var keysAreaHeight: CGFloat {
        let numRows: CGFloat = 4
        return numRows * keyHeight + (numRows - 1) * rowSpacing + 2 * verticalInset
    }

    // MARK: - Width-class flag

    /// True when the device is "large" — iPhone Plus / Pro Max widths at or
    /// above 428 pt. Drives the +2 pt row-height bump.
    var isLargeWidth: Bool { availableWidth >= 428 }
}

extension KeyboardMetrics {
    /// Convenience initializer that resolves Liquid Glass from the runtime
    /// iOS version. On iOS 26+, returns a metrics struct with Liquid Glass
    /// enabled; otherwise the pre-iOS-26 profile.
    init(availableWidth: CGFloat) {
        self.availableWidth = availableWidth
        if #available(iOS 26.0, *) {
            self.liquidGlass = true
        } else {
            self.liquidGlass = false
        }
    }
}
