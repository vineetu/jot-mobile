/**
 * Fraunces-italic editorial title.
 */
export interface SerifTitleProps {
  children: React.ReactNode;
  /** px: 41 welcome, 30 titles, 25 prompts, 22 questions. Default 30. */
  size?: number;
  /** Default "center". */
  align?: "left" | "center";
  nowrap?: boolean;
}
