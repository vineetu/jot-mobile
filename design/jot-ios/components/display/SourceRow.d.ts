/**
 * Ask Jot source-note row.
 */
export interface SourceRowProps {
  /** Note date/title, e.g. "May 29". */
  date: string;
  /** One-line snippet (truncates). */
  snippet: string;
  /** Opens the note. */
  onClick?: () => void;
}
