/**
 * Recording Stop pill with running timer.
 */
export interface StopPillProps {
  /** Timer text, mm:ss. Default "0:08". */
  time?: string;
  onClick?: () => void;
  /** 56 (recording surface) or 60 (live transcription). Default 56. */
  height?: number;
  /** Default 190. */
  maxWidth?: number;
}
