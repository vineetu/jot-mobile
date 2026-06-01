import SwiftUI

/// Keyboard-side warm-hold switching nudge (UX-overhaul round 2 §4 / WS-F).
///
/// The app owns the streak math (§4): on each clean stop it appends to an
/// App-Group ring buffer, computes the consecutive-qualifying-return streak,
/// and — when streak ≥ 3 with warm hold OFF and not suppressed — sets
/// `AppGroup.warmHoldNudgeShouldShow` + posts `warmHoldNudgeChanged`. The
/// keyboard can't run that math (no SwiftData, no engine), so it renders this
/// strip purely off the boolean (R10b) and writes the two terminal actions
/// back via the controller (`warmHoldEnabled` / `warmHoldNudgeSuppressed`).
///
/// This is the keyboard twin of the app-side `WarmHoldNudgeView`. It can't link
/// that file (app-only page-ink tokens + `JotDesign.Surface`), so the chrome is
/// rebuilt here from the keyboard-available Liquid Glass tokens shared with the
/// recents / streaming cards. One-shot, no rotation (R19). Copy from §8.
///
/// Auto-hide is owned by the APP side (it set the boolean and runs its own
/// ~6s timer that flips the projection back and posts the change); the keyboard
/// just re-renders when the boolean drops. So there's no timer here — passive
/// ignore ≠ suppression is enforced app-side.
struct WarmHoldNudgeStrip: View {
    let reduceMotion: Bool
    let onKeepMicReady: () -> Void
    let onDismiss: () -> Void
    let feedback: KeyboardFeedback

    /// Matches the recents / streaming card height so toggling the nudge in
    /// and out of the strip slot doesn't jump the keyboard layout.
    private static let stripHeight: CGFloat = 129

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Headline — §8 / R17: softened so it doesn't overpromise "skip the
            // wait" for the immediately-following dictation (accepting only
            // warms the NEXT session).
            Text("Bouncing back and forth to dictate? Keep the mic ready so the next one starts instantly.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.jotKeyboardActionsInk)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button {
                    feedback.systemClick()
                    feedback.selectionTick()
                    onKeepMicReady()
                } label: {
                    Text("Keep mic ready")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Self.pillTopBlue,
                                            Color.jotKeyboardAccentDeep,
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Keep mic ready")
                .accessibilityHint("Keeps the mic ready after you stop so the next dictation starts instantly")

                Button {
                    feedback.systemClick()
                    feedback.selectionTick()
                    onDismiss()
                } label: {
                    Text("Don't show this again")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.jotKeyboardStreamText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Don't show this again")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.stripHeight)
        .background(glassSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.jotKeyboardGlassHighlight, lineWidth: 0.5)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.jotKeyboardGlassHairline, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 4)
        // Spring-in (rough — tunable). Reduce Motion → plain fade, no scale.
        .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : 0.96))
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(
                reduceMotion
                    ? .easeOut(duration: 0.2)
                    : .spring(response: 0.42, dampingFraction: 0.8)
            ) {
                appeared = true
            }
        }
        .accessibilityElement(children: .contain)
    }

    // Hardcoded brand blue top stop — identical to the keyboard's Dictate pill
    // so the accept button reads as the same primary surface across modes.
    private static let pillTopBlue = Color(red: 0/255, green: 122/255, blue: 255/255)

    /// Same Liquid Glass recipe as the recents / streaming cards so the nudge
    /// reads as the same surface, just a different payload.
    @ViewBuilder
    private var glassSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.jotKeyboardGlassFill1,
                            Color.jotKeyboardGlassFill2,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }
}
