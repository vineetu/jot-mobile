/**
 * The locked Jot brand mark (j + 3-bar waveform tittle).
 * @startingPoint section="Brand" subtitle="The locked j + waveform mark" viewport="700x200"
 */
export interface JotMarkProps {
  /** Rendered width in px (height = size × 160/116). Default 64. */
  size?: number;
  /** Stroke color. White on blue/dark surfaces; #1A8CFF flat on light. Default "#fff". */
  color?: string;
  /** Stem stroke width in viewBox units. Default 15 — do not change casually. */
  sw?: number;
}
