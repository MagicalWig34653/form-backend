import type { BuilderMode, MarkerState } from './source';
import { composeBody, readMarker, stripMarker } from './source';

/**
 * Mode switching without silent data loss. A switch never changes the stored body by itself unless the user
 * confirmed it or nothing can get lost; the body is regenerated only when the new editor has to produce it.
 */
export type SwitchQuestion =
  /** Foreign HTML (no marker) cannot be turned back into MJML: design starts from the template. */
  | 'foreignToDesign'
  /** Foreign HTML is taken over as rich text: layout and formatting may change. */
  | 'foreignToSimple'
  /** The HTML was edited by hand; the editor regenerates it from its source. */
  | 'handEditsLost'
  /** Leaving design for "Einfach" drops the MJML source and layout. */
  | 'designLost';

export interface SwitchPlan {
  /** Ask before switching; null = switch right away. */
  question: SwitchQuestion | null;
  /** Seed of the target editor: MJML for design, rich-text HTML for "Einfach", nothing for source. */
  seed: {
    kind: 'design-source' | 'design-template' | 'design-from-rich' | 'rich' | 'none';
    value: string;
  };
  /** The target editor writes a new body right after the switch. */
  regenerate: boolean;
}

/**
 * @param from current mode
 * @param body current stored body
 * @param richFromDesign rich text derived from the open design (only needed for design → simple)
 */
export function planSwitch(
  from: BuilderMode,
  to: BuilderMode,
  body: string,
  richFromDesign = '',
): SwitchPlan {
  const none: SwitchPlan = { question: null, seed: { kind: 'none', value: '' }, regenerate: false };
  if (from === to || to === 'source') return none;
  const marker: MarkerState | null = readMarker(body);
  const empty = stripMarker(body).trim() === '';

  if (to === 'design') {
    if (from === 'simple')
      return {
        question: null,
        seed: { kind: 'design-from-rich', value: marker?.kind === 'simple' ? marker.source : '' },
        regenerate: true,
      };
    // from source
    if (marker?.kind === 'design')
      return {
        question: marker.handEdited ? 'handEditsLost' : null,
        seed: { kind: 'design-source', value: marker.source },
        regenerate: marker.handEdited,
      };
    if (marker?.kind === 'simple')
      return {
        question: marker.handEdited ? 'handEditsLost' : null,
        seed: { kind: 'design-from-rich', value: marker.source },
        regenerate: true,
      };
    return {
      question: empty ? null : 'foreignToDesign',
      seed: { kind: 'design-template', value: '' },
      regenerate: true,
    };
  }

  // to simple
  if (from === 'design')
    return {
      question: 'designLost',
      seed: { kind: 'rich', value: richFromDesign },
      regenerate: true,
    };
  if (marker?.kind === 'simple')
    return {
      question: marker.handEdited ? 'handEditsLost' : null,
      seed: { kind: 'rich', value: marker.source },
      regenerate: marker.handEdited,
    };
  if (marker?.kind === 'design')
    return {
      question: 'designLost',
      seed: { kind: 'rich', value: richFromDesign },
      regenerate: true,
    };
  return {
    question: empty ? null : 'foreignToSimple',
    seed: { kind: 'rich', value: stripMarker(body) },
    regenerate: true,
  };
}

/**
 * Body after a hand edit in the source view: the editable source stays in the marker (so switching back works),
 * flagged as hand-edited so the next start opens the source view instead of regenerating over the hand work.
 */
export function bodyAfterSourceEdit(previousBody: string, html: string): string {
  const marker = readMarker(previousBody);
  return marker ? composeBody({ ...marker, handEdited: true }, html) : html;
}
