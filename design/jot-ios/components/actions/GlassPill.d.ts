/**
 * Glass capsule button with a text label ("Done", "Ask another").
 */
export interface GlassPillProps {
  children: React.ReactNode;
  onClick?: () => void;
  /** 38 for header "Done", 34 for small "Ask another". Default 38. */
  height?: number;
  /** Blue accent label instead of ink (e.g. "Ask another"). Default false. */
  accent?: boolean;
}
