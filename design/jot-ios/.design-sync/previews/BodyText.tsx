import React from "react";
import { BodyText } from "@jot/design-system";

// Jot is dark-first: tokens on :root are the dark theme, so every cell sits on
// the app's own screen background instead of the card's white body.
const Screen = ({ children, width = 360 }: { children: React.ReactNode; width?: number }) => (
  <div style={{ background: "var(--bg-screen)", color: "var(--ink)", fontFamily: "var(--font-sys)",
                padding: 20, borderRadius: 18, width, boxSizing: "border-box" }}>
    {children}
  </div>
);

/** Default 17.5 body, centred — the wizard's explanatory copy. */
export const Body = () => (
  <Screen>
    <div style={{ display: "flex", justifyContent: "center" }}>
      <BodyText>Jot needs the mic to transcribe. Audio is processed on your iPhone and discarded.</BodyText>
    </div>
  </Screen>
);

/** Secondary 15.5, left-aligned, as a settings explainer. */
export const Secondary = () => (
  <Screen>
    <BodyText size={15.5} align="left" max={320}>
      Rewrites run on your iPhone. Nothing is uploaded, and there is nothing to download.
    </BodyText>
  </Screen>
);

/** The 12.5 honest footnote, in caption ink via a wrapper as the prompt suggests. */
export const Footnote = () => (
  <Screen>
    <div style={{ color: "var(--ink-caption)", display: "flex", justifyContent: "center" }}>
      <BodyText size={12.5} max={320}>
        We'd skip this step if we could. Apple doesn't let keyboards use the mic directly — so Jot hops back to capture.
      </BodyText>
    </div>
  </Screen>
);
