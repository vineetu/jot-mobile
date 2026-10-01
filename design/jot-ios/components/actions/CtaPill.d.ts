/**
 * Primary CTA pill — blue gradient, glow, full width.
 * @startingPoint section="Components" subtitle="Primary blue-gradient CTA pill" viewport="700x180"
 */
export interface CtaPillProps {
  /** Label (a verb: "Get started", "Grant microphone", "Start dictating"). */
  children: React.ReactNode;
  onClick?: () => void;
  /** Pill height; wizard uses 62–64. Default 62. */
  height?: number;
  disabled?: boolean;
}
