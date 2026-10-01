import React from "react";
import { CtaPill, TextLink } from "@jot/design-system";

// Jot is dark-first: tokens on :root are the dark theme, so every cell sits on
// the app's own screen background instead of the card's white body.
const Screen = ({ children, width = 360 }: { children: React.ReactNode; width?: number }) => (
  <div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
                padding: 20, borderRadius: 18, width, boxSizing: "border-box" }}>
    {children}
  </div>
);

/** The wizard's docked primary action — one per screen, label is a verb. */
export const Primary = () => (
  <Screen><CtaPill>Get started</CtaPill></Screen>
);

/** With the secondary text link the wizard pairs beneath it. */
export const WithSecondary = () => (
  <Screen>
    <CtaPill height={64}>Grant microphone</CtaPill>
    <div style={{ textAlign: "center", marginTop: 14 }}><TextLink>I've already added it</TextLink></div>
  </Screen>
);

/** Disabled until the step is satisfied. */
export const Disabled = () => (
  <Screen><CtaPill disabled>Continue</CtaPill></Screen>
);
