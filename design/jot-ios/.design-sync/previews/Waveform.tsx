import React from "react";
import { Waveform, CapsLabel } from "@jot/design-system";

// Jot is dark-first: tokens on :root are the dark theme, so every cell sits on
// the app's own screen background instead of the card's white body.
const Screen = ({ children, width = 360 }: { children: React.ReactNode; width?: number }) => (
  <div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
                padding: 20, borderRadius: 18, width, boxSizing: "border-box" }}>
    {children}
  </div>
);

/** Beside a "Listening" status row, as the recording surface shows it. */
export const Listening = () => (
  <Screen>
    <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
      <Waveform bars={7} height={22} animate={false} />
      <span style={{ fontSize: 15, color: "var(--ink-sub)" }}>Listening</span>
    </div>
  </Screen>
);

/** Taller and denser, the Watch-face size. */
export const Tall = () => (
  <Screen>
    <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
      <Waveform bars={11} height={40} animate={false} />
      <CapsLabel>Watch</CapsLabel>
    </div>
  </Screen>
);

/** The default animated loop (captured mid-motion). */
export const Animated = () => (
  <Screen>
    <Waveform />
  </Screen>
);
