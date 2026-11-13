import { t } from '$lib/i18n';
import type { Tone } from '$lib/components/admin/StatusChip.svelte';

/**
 * Single status vocabulary for a form: Entwurf (never published), Live (accepting submissions),
 * Pausiert (published but switched off). Blue stays reserved for hints.
 */
export function formStatus(published: boolean, active: boolean): { tone: Tone; label: string } {
  if (!published) return { tone: 'idle', label: t.status.draft };
  return active ? { tone: 'ok', label: t.status.live } : { tone: 'warn', label: t.status.paused };
}
