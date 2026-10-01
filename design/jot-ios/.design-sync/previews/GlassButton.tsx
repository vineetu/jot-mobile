import React from "react";
import { GlassButton, JotGlyph } from "@jot/design-system";

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

/** Wizard chrome at 46: back and close, as the header row uses them. */
export const Chrome46 = () => (
  <Screen>
    <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
      <GlassButton size={46} ariaLabel="Back"><JotGlyph name="chevron-left" /></GlassButton>
      <GlassButton size={46} ariaLabel="Close"><JotGlyph name="close" size={16} /></GlassButton>
      <Label>back · close</Label>
    </div>
  </Screen>
);

/** Recording transport at 56: pause, and the destructive trash in the red reserved for it. */
export const Transport56 = () => (
  <Screen>
    <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
      <GlassButton size={56} ariaLabel="Pause"><JotGlyph name="pause" /></GlassButton>
      <GlassButton size={56} ariaLabel="Discard"><JotGlyph name="trash" color="var(--jot-red)" /></GlassButton>
      <GlassButton size={54} ariaLabel="Copy"><JotGlyph name="copy" size={22} /></GlassButton>
      <Label>pause · trash · copy</Label>
    </div>
  </Screen>
);

/** `hidden` keeps the layout slot but fades the control — the back button on step 1. */
export const HiddenSlot = () => (
  <Screen>
    <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
      <GlassButton size={46} hidden ariaLabel="Back"><JotGlyph name="chevron-left" /></GlassButton>
      <div style={{ flex: 1, textAlign: "center", fontSize: 15, fontWeight: 600 }}>Step 1 of 7</div>
      <GlassButton size={46} ariaLabel="Close"><JotGlyph name="close" size={16} /></GlassButton>
    </div>
  </Screen>
);
