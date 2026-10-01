import React from "react";
import { TextLink, JotGlyph, CtaPill } from "@jot/design-system";

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

/** The quiet secondary action, centred beneath a CTA. */
export const UnderCta = () => (
  <Screen>
    <CtaPill>Add the keyboard</CtaPill>
    <div style={{ textAlign: "center", marginTop: 10 }}><TextLink>I've already added it</TextLink></div>
  </Screen>
);

/** With a small leading glyph — Ask Jot's "Type instead". */
export const WithGlyph = () => (
  <Screen>
    <div style={{ textAlign: "center" }}>
      <TextLink><JotGlyph name="keyboard-mini" size={18} /> Type instead</TextLink>
    </div>
  </Screen>
);

/** Plain. */
export const Plain = () => (
  <Screen>
    <div style={{ display: "flex", justifyContent: "center", gap: 6 }}>
      <TextLink>Not now</TextLink>
      <TextLink>Learn more</TextLink>
    </div>
  </Screen>
);
