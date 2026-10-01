/**
 * iOS-style switch (52×31, iOS green when on).
 */
export interface IosToggleProps {
  on: boolean;
  onChange?: (next: boolean) => void;
}
