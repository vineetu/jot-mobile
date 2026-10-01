import React from "react";

/**
 * Onboarding hero tile — gradient squircle holding a glyph. Semantic variants:
 * "mic" (orange), "keyboard" (parchment), "success" (green). Onboarding only.
 */
export interface HeroTileProps {
  /** Semantic gradient preset. */
  variant?: "mic" | "keyboard" | "success";
  /** Custom gradient start (overrides variant). */
  from?: string;
  /** Custom gradient end (overrides variant). */
  to?: string;
  /** Glow shadow color; defaults to the gradient end. */
  glow?: string;
  /** Tile size in px. Default 132 (wizard uses 104–132). */
  size?: number;
  /** Corner radius factor × size. Default 0.30. */
  radius?: number;
  /** The glyph, usually <JotGlyph/> at ~0.45 × size. */
  children?: React.ReactNode;
}
