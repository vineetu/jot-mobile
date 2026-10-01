import React from "react";

const TILE_PRESETS = {
  mic:      { from: "var(--tile-mic-from)",     to: "var(--tile-mic-to)" },
  keyboard: { from: "var(--tile-key-from)",     to: "var(--tile-key-to)" },
  success:  { from: "var(--tile-success-from)", to: "var(--tile-success-to)" },
};

/**
 * Onboarding hero tile: squircle gradient tile with a white (or dark,
 * for parchment) glyph centered inside. Inset top sheen + colored glow.
 */
export function HeroTile({ variant, from, to, glow, size = 132, radius = 0.30, children }) {
  const p = TILE_PRESETS[variant] || {};
  const f = from || p.from || "var(--jot-blue-1)";
  const t = to || p.to || "var(--jot-blue-3)";
  return (
    <div style={{
      width: size, height: size, borderRadius: size * radius, flexShrink: 0,
      background: `linear-gradient(180deg, ${f} 0%, ${t} 100%)`,
      display: "flex", alignItems: "center", justifyContent: "center",
      boxShadow: `var(--tile-inner), 0 18px 38px -14px ${glow || t}, 0 6px 14px -8px rgba(0,0,0,0.4)`,
    }}>{children}</div>
  );
}
