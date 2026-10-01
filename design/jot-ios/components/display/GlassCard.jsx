import React from "react";

/**
 * Jot's barely-there card: translucent fill + 0.5px hairline, no drop shadow.
 */
export function GlassCard({ children, radius = 18, padding = 18, style }) {
  return (
    <div style={{
      background: "var(--card)", border: "0.5px solid var(--card-bord)",
      borderRadius: radius, padding, ...style,
    }}>{children}</div>
  );
}
