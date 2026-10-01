import React from "react";
import { GlassCard, SourceRow } from "@jot/design-system";

// Jot is dark-first: tokens on :root are the dark theme, so every cell sits on
// the app's own screen background instead of the card's white body.
const Screen = ({ children, width = 360 }: { children: React.ReactNode; width?: number }) => (
  <div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
                padding: 20, borderRadius: 18, width, boxSizing: "border-box" }}>
    {children}
  </div>
);

/** Ask Jot's sources footer: the notes an answer drew on, inside a glass card. */
export const Sources = () => (
  <Screen>
    <GlassCard radius={18} padding="4px 14px">
      <SourceRow date="May 29" snippet="Decided to ship the keyboard update in June — pricing TBD until the beta lands…" />
      <SourceRow date="Jun 2" snippet="Warm-hold stays default-on; revisit after beta feedback from the first hundred users…" />
      <SourceRow date="Jun 9" snippet="Launch post draft: lead with privacy, then the keyboard." />
    </GlassCard>
  </Screen>
);

/** A single row, as it appears when one note answers the question. */
export const Single = () => (
  <Screen>
    <GlassCard radius={18} padding="4px 14px">
      <SourceRow date="Today" snippet="Call the dentist Thursday morning, before ten." />
    </GlassCard>
  </Screen>
);
