import React from "react";
import { GlassCard, CapsLabel, IosToggle } from "@jot/design-system";

// Jot is dark-first: tokens on :root are the dark theme, so every cell sits on
// the app's own screen background instead of the card's white body.
const Screen = ({ children, width = 360 }: { children: React.ReactNode; width?: number }) => (
  <div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
                padding: 20, borderRadius: 18, width, boxSizing: "border-box" }}>
    {children}
  </div>
);

/** Settings card (radius 18): a title with its subline and a trailing switch. */
export const SettingsCard = () => (
  <Screen>
    <GlassCard radius={18} padding={16}>
      <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 15, fontWeight: 500, letterSpacing: -0.2 }}>Warm hold</div>
          <div style={{ fontSize: 12.5, color: "var(--ink-caption)", marginTop: 3, lineHeight: 1.35 }}>
            Keep the mic ready for a minute after you stop, so the next thought starts instantly.
          </div>
        </div>
        <IosToggle on />
      </div>
    </GlassCard>
  </Screen>
);

/** Transcript hero card (radius 28): the note's own words in Fraunces italic. */
export const TranscriptCard = () => (
  <Screen>
    <GlassCard radius={28} padding={22}>
      <CapsLabel>Today · 0:41</CapsLabel>
      <p style={{ margin: "10px 0 0", fontFamily: "var(--font-serif)", fontStyle: "italic",
                  fontSize: 22, lineHeight: 1.3, color: "var(--ink)" }}>
        Call the dentist Thursday morning, before ten — and ask whether the crown can wait until after the trip.
      </p>
    </GlassCard>
  </Screen>
);

/** Two cards stacked with the standard card gap, the way a settings screen groups them. */
export const Stacked = () => (
  <Screen>
    <div style={{ display: "grid", gap: 12 }}>
      <GlassCard radius={18} padding={16}>
        <div style={{ fontSize: 15, fontWeight: 500 }}>Live text while dictating</div>
        <div style={{ fontSize: 12.5, color: "var(--ink-caption)", marginTop: 3 }}>Show words as you speak.</div>
      </GlassCard>
      <GlassCard radius={18} padding={16}>
        <div style={{ fontSize: 15, fontWeight: 500 }}>Vocabulary</div>
        <div style={{ fontSize: 12.5, color: "var(--ink-caption)", marginTop: 3 }}>Names and terms Jot should get right.</div>
      </GlassCard>
    </div>
  </Screen>
);
