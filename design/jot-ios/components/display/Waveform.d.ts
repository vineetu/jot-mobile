/**
 * Reactive voice waveform — thin blue bars.
 */
export interface WaveformProps {
  /** Bar count. Default 7. */
  bars?: number;
  /** Max bar height px. Default 22. */
  height?: number;
  /** Bar color. Default brand blue flat. */
  color?: string;
  /** Loop the scale animation. Default true. */
  animate?: boolean;
}
