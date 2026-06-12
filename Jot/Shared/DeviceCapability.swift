import Foundation

/// Device-capability resolution for batch-only streaming
/// (`docs/plans/batch-only-streaming.md`, FINAL DIRECTION).
///
/// One boolean, RAM-gated — deliberately NOT a device-ID table (future
/// devices auto-qualify; no list to maintain).
enum DeviceCapability {

    /// 6 GB-RAM class and up = iPhone 12 Pro / 14 and later — the
    /// functional line for the 600M model (~2 GB resident at inference).
    ///
    /// `physicalMemory` reports BELOW nominal (kernel carve-out): 6 GB
    /// devices report ~5.5–5.9e9, 4 GB ~3.7e9. The 4.6e9 threshold splits
    /// the classes with uniform margin (adversarial review #2 F3 — a naive
    /// `>= 6e9` could misclassify real 6 GB hardware). Calibrate against
    /// the Diagnostics `physicalMemory` log before tightening.
    ///
    /// NOTE the two-line policy (owner): OFFICIAL support is iPhone 14 Pro
    /// and later (Store/Help copy promises only that); this gate is the
    /// backward-compatibility functional line — the 12 Pro → 14 Plus band
    /// works best-effort, unsupported.
    static var is600MCapable: Bool {
        ProcessInfo.processInfo.physicalMemory >= 4_600_000_000
    }

    /// Resolved "Live text while dictating" state. Explicit user choice
    /// (`"on"`/`"off"`) always wins; `"auto"` follows the capability
    /// default so a future revision of the default reaches auto users
    /// without clobbering anyone's choice (review #2 F8).
    ///
    /// Read at recording start (never mid-session). Ask captures bypass
    /// this — their live text is the input mechanism, not a preview.
    static var liveTextEnabled: Bool {
        switch AppGroup.liveTextSetting {
        case "on": return true
        case "off": return false
        default: return is600MCapable
        }
    }
}
