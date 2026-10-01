import React from "react";
import { CitationChip, GlassCard, CapsLabel } from "@jot/design-system";

// Jot is dark-first: tokens on :root are the dark theme, so every cell sits on
// the app's own screen background instead of the card's white body.
const Screen = ({ children, width = 360 }: { children: React.ReactNode; width?: number }) => (
  <div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
                padding: 20, borderRadius: 18, width, boxSizing: "border-box" }}>
    {children}
  </div>
);

/** Inside an Ask Jot answer — chips flow with the sentence, baseline-aligned. */
export const InAnswer = () => (
  <Screen>
    <GlassCard radius={18} padding={16}>
      <p style={{ margin: 0, fontSize: 16, lineHeight: 1.5, color: "var(--ink)" }}>
        Decided to ship the keyboard update in June <CitationChip label="May 29" /> and keep the
        warm-hold default on <CitationChip label="Jun 2" />. Pricing is still open.
      </p>
    </GlassCard>
  </Screen>
);

/** A bare row of chips, as the sources strip under a short answer. */
export const ChipRow = () => (
  <Screen>
    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
      <CapsLabel>Sources</CapsLabel>
      <CitationChip label="May 29" />
      <CitationChip label="Jun 2" />
      <CitationChip label="Today" />
    </div>
  </Screen>
);
