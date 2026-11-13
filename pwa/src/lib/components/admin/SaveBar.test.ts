import { fireEvent, render, screen } from '@testing-library/svelte';
import { describe, expect, it, vi } from 'vitest';
import { t } from '$lib/i18n';
import SaveBar from './SaveBar.svelte';

describe('SaveBar', () => {
  it('ist ohne Änderungen und ohne Status nicht sichtbar', () => {
    render(SaveBar, { dirty: false });
    expect(screen.queryByRole('region')).toBeNull();
  });
  it('zeigt bei Änderungen Hinweis, Speichern und Verwerfen', async () => {
    const onsave = vi.fn();
    const ondiscard = vi.fn();
    render(SaveBar, { dirty: true, onsave, ondiscard });
    expect(screen.getByRole('region', { name: t.saveBar.label })).toBeTruthy();
    expect(screen.getByText(t.saveBar.unsaved)).toBeTruthy();
    await fireEvent.click(screen.getByRole('button', { name: t.saveBar.save }));
    await fireEvent.click(screen.getByRole('button', { name: t.saveBar.discard }));
    expect(onsave).toHaveBeenCalledTimes(1);
    expect(ondiscard).toHaveBeenCalledTimes(1);
  });
  it('sperrt die Knöpfe während des Speicherns', () => {
    render(SaveBar, { dirty: true, busy: true, onsave: () => {}, ondiscard: () => {} });
    for (const button of screen.getAllByRole('button'))
      expect((button as HTMLButtonElement).disabled).toBe(true);
  });
  it('meldet Status als Fehler (alert) oder Erfolg (status) und blendet danach die Knöpfe aus', () => {
    const { unmount } = render(SaveBar, { dirty: false, status: 'Fehler', statusKind: 'error' });
    expect(screen.getByRole('alert').textContent).toContain('Fehler');
    expect(screen.queryByRole('button')).toBeNull();
    unmount();
    render(SaveBar, { dirty: false, status: t.saveBar.saved });
    expect(screen.getByRole('status').textContent).toContain(t.saveBar.saved);
  });
  it('sendet ohne onsave das zugeordnete Formular ab', () => {
    render(SaveBar, { dirty: true, form: 'f1' });
    const button = screen.getByRole('button', { name: t.saveBar.save }) as HTMLButtonElement;
    expect(button.type).toBe('submit');
    expect(button.getAttribute('form')).toBe('f1');
  });
});
