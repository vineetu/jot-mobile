import React from "react";

/**
 * Translucent hairline card — Jot's standard surface for grouped content.
 */
export interface GlassCardProps {
  children: React.ReactNode;
  /** 18 settings/step cards, 28 transcript card. Default 18. */
  radius?: number;
  /** CSS padding value. Default 18. */
  padding?: number | string;
  /** Extra inline styles merged onto the card. */
  style?: React.CSSProperties;
}
