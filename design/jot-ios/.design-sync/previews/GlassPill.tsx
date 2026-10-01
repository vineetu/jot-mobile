import React from "react";
import { GlassPill } from "@jot/design-system";

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

/** The header "Done" at 38 — ink label on glass. */
export const Done = () => (
  <Screen>
    <div style={{ display: "flex", justifyContent: "flex-end" }}>
      <GlassPill>Done</GlassPill>
    </div>
  </Screen>
);

/** The small accent variant Ask Jot uses to reset: 34 tall, blue label. */
export const AskAnother = () => (
  <Screen>
    <div style={{ display: "flex", gap: 12, alignItems: "center" }}>
      <GlassPill height={34} accent>Ask another</GlassPill>
      <Label>accent · 34</Label>
    </div>
  </Screen>
);

/** Both heights together. */
export const Sizes = () => (
  <Screen>
    <div style={{ display: "flex", gap: 12, alignItems: "center" }}>
      <GlassPill>Done</GlassPill>
      <GlassPill height={34}>Cancel</GlassPill>
      <GlassPill height={34} accent>Ask another</GlassPill>
    </div>
  </Screen>
);
