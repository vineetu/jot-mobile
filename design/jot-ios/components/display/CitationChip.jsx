import React from "react";
import { JotGlyph } from "../brand/JotGlyph.jsx";

/**
 * Inline citation chip in Ask Jot answers — soft blue capsule with a doc
 * glyph + short label (a note date), baseline-aligned inside flowing text.
 */
export function CitationChip({ label, onClick }) {
  return (
    <button onClick={onClick} style={{
      display: "inline-flex", alignItems: "center", gap: 4, verticalAlign: "baseline",
      transform: "translateY(1.5px)", margin: "0 1px",
      background: "var(--jot-blue-soft)", border: "0.5px solid rgba(26,140,255,0.25)",
      borderRadius: 7, padding: "1.5px 7px 1.5px 5px", cursor: "pointer",
      fontFamily: "var(--font-sys)", fontWeight: 600, fontSize: 12.5,
      color: "var(--jot-blue-flat)", WebkitTapHighlightColor: "transparent",
    }}>
      <JotGlyph name="doc" size={11} color="var(--jot-blue-flat)" />
      {label}
    </button>
  );
}
