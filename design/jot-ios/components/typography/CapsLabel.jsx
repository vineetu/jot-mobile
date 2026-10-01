import React from "react";

/**
 * Tiny uppercase letter-spaced label ("YOU ASKED", "SOURCES", "BETA").
 */
export function CapsLabel({ children, accent = false, size = 11 }) {
  return (
    <span style={{
      fontFamily: "var(--font-sys)", fontWeight: 700, fontSize: size,
      letterSpacing: size <= 10 ? "2px" : "1.4px", textTransform: "uppercase",
      color: accent ? "var(--jot-blue-flat)" : "var(--ink-caption)",
    }}>{children}</span>
  );
}
