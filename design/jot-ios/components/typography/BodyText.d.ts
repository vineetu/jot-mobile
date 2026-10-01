/**
 * SF body copy, muted ink.
 */
export interface BodyTextProps {
  children: React.ReactNode;
  align?: "left" | "center";
  /** Max width px. Default 320. */
  max?: number;
  /** px: 17.5 body, 15.5 secondary, 12.5 footnote. Default 17.5. */
  size?: number;
}
