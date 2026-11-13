import { t } from '$lib/i18n';

/**
 * One confirmation dialog for every sensitive action (rendered once by ConfirmHost).
 * Title = the action in words, description = the consequence in one sentence, button repeats the verb.
 */
export interface ConfirmOptions {
  title: string;
  description: string;
  /** Label of the primary button; repeats the verb of the title, never "OK". */
  confirmLabel: string;
  cancelLabel?: string;
  /** Destructive actions focus "Abbrechen" first and use the destructive button style. */
  destructive?: boolean;
  /** When set, the user has to type this name before the primary button is enabled. */
  requireText?: string;
}

interface Pending extends ConfirmOptions {
  resolve: (confirmed: boolean) => void;
}

const state = $state<{ current: Pending | null }>({ current: null });

export const confirmState = {
  get current(): Pending | null {
    return state.current;
  },
  /** Settles the open dialog; closing it any other way counts as "no". */
  settle(confirmed: boolean): void {
    const pending = state.current;
    if (!pending) return;
    state.current = null;
    pending.resolve(confirmed);
  },
};

/** Resolves true only when the user explicitly confirms. A second request cancels the first. */
export function confirmAction(options: ConfirmOptions): Promise<boolean> {
  confirmState.settle(false);
  return new Promise<boolean>((resolve) => {
    state.current = { ...options, resolve };
  });
}

/** Standard question before unsaved changes are thrown away. */
export const confirmDiscard = (): Promise<boolean> =>
  confirmAction({
    title: t.confirm.discardTitle,
    description: t.confirm.discardBody,
    confirmLabel: t.confirm.discard,
    destructive: true,
  });
