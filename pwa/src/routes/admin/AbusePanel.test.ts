import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { expect, it, vi } from 'vitest';
import AbusePanel from './AbusePanel.svelte';
import type { Editor } from '$lib/draft/editor.svelte';
import type { JsonObject } from '$lib/api/admin';
const request = vi.hoisted(() => vi.fn());
vi.mock('$lib/api', () => ({ http: { request } }));
it('speichert Secret separat und nur die Policy im Entwurf', async () => {
  request.mockResolvedValue({ ok: true, data: { configured: true } });
  const document: JsonObject = { form: { security: {} } };
  const apply = vi.fn(async (change: (doc: JsonObject) => JsonObject) => {
    const next = change(document);
    expect(JSON.stringify(next)).not.toContain('synthetic-secret');
    expect((next.form as JsonObject).security).toEqual({
      abuse: { siteKey: 'synthetic-site', failPolicy: 'open', testMode: true },
    });
    return null;
  });
  const editor = { draft: { document }, saving: false, apply } as unknown as Editor;
  render(AbusePanel, { editor, tenant: 'tenant', form: 'form' });
  await fireEvent.input(screen.getByLabelText('Turnstile Site-Key (leer: deaktiviert)'), {
    target: { value: 'synthetic-site' },
  });
  await fireEvent.input(screen.getByLabelText('Turnstile Secret ersetzen'), {
    target: { value: 'synthetic-secret' },
  });
  await fireEvent.click(screen.getByLabelText('Testmodus'));
  expect(screen.getByText(/Testmodus: Captcha und IP-Regeln/)).toBeTruthy();
  await fireEvent.submit(screen.getByText('Missbrauchsschutz speichern').closest('form')!);
  await waitFor(() => expect(apply).toHaveBeenCalledOnce());
  expect(request).toHaveBeenCalledWith('PUT', '/tenants/tenant/forms/form/abuse-secret', {
    body: { secret: 'synthetic-secret' },
  });
  expect((screen.getByLabelText('Turnstile Secret ersetzen') as HTMLInputElement).value).toBe('');
});
