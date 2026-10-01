/**
 * Uppercase micro-label.
 */
export interface CapsLabelProps {
  children: React.ReactNode;
  /** Blue accent (e.g. BETA tag). Default false (faint ink). */
  accent?: boolean;
  /** px: 11 captions, 9.5 BETA. Default 11. */
  size?: number;
}
