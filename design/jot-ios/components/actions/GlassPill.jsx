import React from "react";

/**
 * Glass pill button with a text label ("Done", "Ask another") —
 * same glass recipe as GlassButton, capsule shape.
 */
export function GlassPill({ children, onClick, height = 38, accent = false }) {
  return (
    <button onClick={onClick} style={{
      height, borderRadius: height / 2, padding: "0 17px", flexShrink: 0,
      background: "var(--chrome-fill)", border: "0.5px solid var(--chrome-bord)",
      backdropFilter: "var(--blur-chrome)", WebkitBackdropFilter: "var(--blur-chrome)",
      display: "inline-flex", alignItems: "center", gap: 7, cursor: "pointer",
      fontFamily: "var(--font-sys)", fontWeight: 600, fontSize: height >= 38 ? "var(--ts-label)" : 14,
      color: accent ? "var(--jot-blue-flat)" : "var(--ink)",
      transition: "transform var(--dur-press)", WebkitTapHighlightColor: "transparent",
    }}
      onMouseDown={(e) => { e.currentTarget.style.transform = "scale(0.95)"; }}
      onMouseUp={(e) => { e.currentTarget.style.transform = "scale(1)"; }}
      onMouseLeave={(e) => { e.currentTarget.style.transform = "scale(1)"; }}>
      {children}
    </button>
  );
}
