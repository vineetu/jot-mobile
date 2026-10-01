import React from "react";
import { SerifTitle, BodyText } from "@jot/design-system";

// Jot is dark-first: tokens on :root are the dark theme, so every cell sits on
// the app's own screen background instead of the card's white body.
const Screen = ({ children, width = 360 }: { children: React.ReactNode; width?: number }) => (
  <div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
                padding: 20, borderRadius: 18, width, boxSizing: "border-box" }}>
    {children}
  </div>
);

/** The onboarding welcome title at its largest size. */
export const Welcome = () => (
  <Screen>
    <SerifTitle size={41}>Welcome to Jot.</SerifTitle>
    <div style={{ marginTop: 12 }}><BodyText>Voice transcription for fast messaging — dictate into any app.</BodyText></div>
  </Screen>
);

/** A spoken question, left-aligned, as Ask Jot echoes it. */
export const Question = () => (
  <Screen>
    <SerifTitle size={22} align="left">What did I decide about the launch date?</SerifTitle>
  </Screen>
);

/** The size ramp: 30 for titles, 25 for prompts, 22 for questions. */
export const Sizes = () => (
  <Screen>
    <div style={{ display: "grid", gap: 14 }}>
      <SerifTitle size={30} align="left">Keep talking — Jot's still listening.</SerifTitle>
      <SerifTitle size={25} align="left">Say what you'd like changed.</SerifTitle>
      <SerifTitle size={22} align="left">Summarise my notes from last week.</SerifTitle>
    </div>
  </Screen>
);
