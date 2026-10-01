import React from "react";

/**
 * Glass chrome circle button (back / close / pause / copy):
 * translucent fill, 0.5px hairline border, backdrop blur. Press = scale(0.9).
 */
export function GlassButton({ children, onClick, size = 46, hidden = false, ariaLabel }) {
  return (
    <button onClick={onClick} aria-label={ariaLabel} style={{
      width: size, height: size, borderRadius: size / 2, flexShrink: 0,
      background: "var(--chrome-fill)", border: "0.5px solid var(--chrome-bord)",
      backdropFilter: "var(--blur-chrome)", WebkitBackdropFilter: "var(--blur-chrome)",
      display: "flex", alignItems: "center", justifyContent: "center",
      cursor: "pointer", padding: 0, color: "var(--chrome-glyph)",
      opacity: hidden ? 0 : 1, pointerEvents: hidden ? "none" : "auto",
      transition: "opacity .25s, transform var(--dur-press)", WebkitTapHighlightColor: "transparent",
    }}
      onMouseDown={(e) => { e.currentTarget.style.transform = "scale(0.9)"; }}
      onMouseUp={(e) => { e.currentTarget.style.transform = "scale(1)"; }}
      onMouseLeave={(e) => { e.currentTarget.style.transform = "scale(1)"; }}>
      {children}
    </button>
  );
}
