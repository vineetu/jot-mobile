import React from "react";
import { JotAppIcon } from "@jot/design-system";

// Jot is dark-first: tokens on :root are the dark theme, so every cell sits on
// the app's own screen background instead of the card's white body.
const Screen = ({ children, width = 360 }: { children: React.ReactNode; width?: number }) => (
  <div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
                padding: 20, borderRadius: 18, width, boxSizing: "border-box" }}>
    {children}
  </div>
);
const Label = ({ children }: { children: React.ReactNode }) => (
  <span style={{ fontSize: 10.5, color: "var(--ink-caption)" }}>{children}</span>
);

/** The onboarding hero size. */
export const Hero = () => (
  <Screen>
    <div style={{ display: "flex", justifyContent: "center" }}><JotAppIcon size={132} /></div>
  </Screen>
);

/** The size ramp: 132 hero, 84 settings tile, 44 row. */
export const Sizes = () => (
  <Screen width={440}>
    <div style={{ display: "flex", gap: 22, alignItems: "flex-end" }}>
      <JotAppIcon size={110} />
      <JotAppIcon size={84} />
      <JotAppIcon size={60} />
      <JotAppIcon size={44} />
    </div>
    <div style={{ marginTop: 10 }}><Label>110 · 84 · 60 · 44</Label></div>
  </Screen>
);
