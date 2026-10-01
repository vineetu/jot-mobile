import React from "react";
import { StopPill, GlassButton, JotGlyph } from "@jot/design-system";

// Jot is dark-first: tokens on :root are the dark theme, so every cell sits on
// the app's own screen background instead of the card's white body.
const Screen = ({ children, width = 360 }: { children: React.ReactNode; width?: number }) => (
  <div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
                padding: 20, borderRadius: 18, width, boxSizing: "border-box" }}>
    {children}
  </div>
);

/** The recording surface's control row: trash, Stop with the running timer, pause. */
export const RecordingRow = () => (
  <Screen>
    <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 14 }}>
      <GlassButton size={56}><JotGlyph name="trash" color="var(--jot-red)" /></GlassButton>
      <StopPill time="0:08" />
      <GlassButton size={56}><JotGlyph name="pause" /></GlassButton>
    </div>
  </Screen>
);

/** Timer at a longer take, and the 60pt live-transcription size. */
export const Sizes = () => (
  <Screen>
    <div style={{ display: "grid", gap: 14, justifyItems: "center" }}>
      <div style={{ display: "flex", width: 190 }}><StopPill time="1:24" /></div>
      <div style={{ display: "flex", width: 220 }}><StopPill time="12:07" height={60} maxWidth={220} /></div>
    </div>
  </Screen>
);
