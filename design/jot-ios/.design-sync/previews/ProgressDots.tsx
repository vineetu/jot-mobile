import React from "react";
import { ProgressDots, CapsLabel } from "@jot/design-system";

// Jot is dark-first: tokens on :root are the dark theme, so every cell sits on
// the app's own screen background instead of the card's white body.
const Screen = ({ children, width = 360 }: { children: React.ReactNode; width?: number }) => (
  <div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
                padding: 20, borderRadius: 18, width, boxSizing: "border-box" }}>
    {children}
  </div>
);

/** The wizard on its third step of seven. */
export const StepThree = () => (
  <Screen>
    <div style={{ display: "flex", justifyContent: "center" }}><ProgressDots total={7} current={2} /></div>
  </Screen>
);

/** First and last steps, so the done / active / to-do tones all show. */
export const Ends = () => (
  <Screen>
    <div style={{ display: "grid", gap: 18, justifyItems: "center" }}>
      <div style={{ display: "grid", gap: 6, justifyItems: "center" }}>
        <ProgressDots total={7} current={0} /><CapsLabel size={9.5}>Step 1</CapsLabel>
      </div>
      <div style={{ display: "grid", gap: 6, justifyItems: "center" }}>
        <ProgressDots total={7} current={6} /><CapsLabel size={9.5}>Step 7</CapsLabel>
      </div>
    </div>
  </Screen>
);
