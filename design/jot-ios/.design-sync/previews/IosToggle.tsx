import React from "react";
import { GlassCard, IosToggle } from "@jot/design-system";

// Jot is dark-first: tokens on :root are the dark theme, so every cell sits on
// the app's own screen background instead of the card's white body.
const Screen = ({ children, width = 360 }: { children: React.ReactNode; width?: number }) => (
  <div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
                padding: 20, borderRadius: 18, width, boxSizing: "border-box" }}>
    {children}
  </div>
);

/** Both states side by side. */
export const States = () => (
  <Screen>
    <div style={{ display: "flex", gap: 24, alignItems: "center" }}>
      <IosToggle on />
      <IosToggle on={false} />
    </div>
  </Screen>
);

/** A Settings row — label and subline with the switch trailing, as in Jot's settings cards. */
export const SettingsRow = () => (
  <Screen>
    <GlassCard radius={18} padding="13px 16px">
      <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 15, fontWeight: 500, letterSpacing: -0.2 }}>Live text while dictating</div>
          <div style={{ fontSize: 12.5, color: "var(--ink-caption)", marginTop: 3, lineHeight: 1.35 }}>Show words as you speak. Turning off saves battery.</div>
        </div>
        <IosToggle on />
      </div>
    </GlassCard>
  </Screen>
);
