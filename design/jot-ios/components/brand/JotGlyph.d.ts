/**
 * Jot's inline-SVG glyph set (SF Symbols stand-ins) — round caps, stroke-based.
 */
export interface JotGlyphProps {
  /** Which glyph to render. */
  name: "mic" | "keyboard" | "check" | "sparkle" | "chevron-left" | "chevron-right"
      | "close" | "arrow-up" | "doc" | "copy" | "trash" | "pause" | "globe"
      | "search" | "keyboard-mini" | "watch";
  /** Square size in px (watch/chevrons keep their aspect). Default 24. */
  size?: number;
  /** Stroke/fill color. Default currentColor. */
  color?: string;
}
