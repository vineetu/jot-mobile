/**
 * Glass chrome circle button — back/close/pause/copy chrome.
 */
export interface GlassButtonProps {
  /** Glyph, usually <JotGlyph/>. */
  children: React.ReactNode;
  onClick?: () => void;
  /** Diameter: 46 wizard chrome, 42 in-app back, 56 transport, 54 Ask copy. Default 46. */
  size?: number;
  /** Fade out but keep layout (e.g. back button on step 1). */
  hidden?: boolean;
  ariaLabel?: string;
}
