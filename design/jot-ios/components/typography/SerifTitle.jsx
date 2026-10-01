import React from "react";

/**
 * Editorial title — Fraunces ITALIC, weight 500. The voice of Jot's titles,
 * transcripts and questions.
 */
export function SerifTitle({ children, size = 30, align = "center", nowrap = false }) {
  return (
    <h1 style={{
      fontFamily: "var(--font-serif)", fontStyle: "italic", fontWeight: 500,
      fontOpticalSizing: "auto", fontSize: size, lineHeight: 1.1,
      letterSpacing: "-0.5px", color: "var(--ink)", textAlign: align,
      margin: 0, whiteSpace: nowrap ? "nowrap" : "normal", textWrap: "pretty",
    }}>{children}</h1>
  );
}
