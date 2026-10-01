import React from "react";
import { JotMark } from "@jot/design-system";

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

/** White on the dark screen — how the mark sits on blue and dark surfaces. */
export const OnDark = () => (
  <Screen>
    <div style={{ display: "flex", gap: 28, alignItems: "flex-end" }}>
      <JotMark size={64} color="#fff" />
      <JotMark size={40} color="#fff" />
      <JotMark size={24} color="#fff" />
      <Label>64 · 40 · 24</Label>
    </div>
  </Screen>
);

/** Brand blue, as used on light surfaces. */
export const BrandBlue = () => (
  <div style={{ background: "#F4F6FA", color: "#15171C", fontFamily: "var(--font-sys)", padding: 20, borderRadius: 18, width: 360, boxSizing: "border-box" }}>
    <div style={{ display: "flex", gap: 28, alignItems: "flex-end" }}>
      <JotMark size={64} color="#1A8CFF" />
      <JotMark size={40} color="#1A8CFF" />
      <span style={{ fontSize: 10.5, color: "#6B7280" }}>#1A8CFF on light</span>
    </div>
  </div>
);
