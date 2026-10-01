import React from "react";
import { HeroTile, JotGlyph } from "@jot/design-system";

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

/** The three onboarding variants — mic, keyboard, success — each with its glyph. */
export const Variants = () => (
  <Screen width={400}>
    <div style={{ display: "flex", gap: 22, alignItems: "flex-end" }}>
      <div style={{ textAlign: "center" }}><HeroTile variant="mic" size={96}><JotGlyph name="mic" size={44} color="#fff" /></HeroTile><div style={{ marginTop: 8 }}><Label>mic</Label></div></div>
      <div style={{ textAlign: "center" }}><HeroTile variant="keyboard" size={96}><JotGlyph name="keyboard" size={44} color="var(--tile-key-glyph)" /></HeroTile><div style={{ marginTop: 8 }}><Label>keyboard</Label></div></div>
      <div style={{ textAlign: "center" }}><HeroTile variant="success" size={96}><JotGlyph name="check" size={44} color="#fff" /></HeroTile><div style={{ marginTop: 8 }}><Label>success</Label></div></div>
    </div>
  </Screen>
);

/** At the wizard's hero size, 132, as the microphone step shows it. */
export const WizardHero = () => (
  <Screen>
    <div style={{ display: "flex", justifyContent: "center" }}>
      <HeroTile variant="mic" size={132}><JotGlyph name="mic" size={60} color="#fff" /></HeroTile>
    </div>
  </Screen>
);

/** A custom gradient via from/to for a one-off hero. */
export const CustomGradient = () => (
  <Screen>
    <div style={{ display: "flex", justifyContent: "center" }}>
      <HeroTile from="var(--jot-blue-1)" to="var(--jot-blue-3)" size={104}><JotGlyph name="sparkle" size={48} color="#fff" /></HeroTile>
    </div>
  </Screen>
);
