import React from "react";
import { CapsLabel } from "@jot/design-system";

// Jot is dark-first: tokens on :root are the dark theme, so every cell sits on
// the app's own screen background instead of the card's white body.
const Screen = ({ children, width = 360 }: { children: React.ReactNode; width?: number }) => (
  <div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
                padding: 20, borderRadius: 18, width, boxSizing: "border-box" }}>
    {children}
  </div>
);

/** Section caps as Ask Jot uses them. */
export const Captions = () => (
  <Screen>
    <div style={{ display: "grid", gap: 12 }}>
      <CapsLabel>You asked</CapsLabel>
      <CapsLabel>Sources</CapsLabel>
      <CapsLabel>Recent</CapsLabel>
    </div>
  </Screen>
);

/** The blue BETA tag at its 9.5 size, next to a title. */
export const BetaTag = () => (
  <Screen>
    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
      <span style={{ fontSize: 17, fontWeight: 600 }}>Ask Jot</span>
      <CapsLabel accent size={9.5}>Beta</CapsLabel>
    </div>
  </Screen>
);
