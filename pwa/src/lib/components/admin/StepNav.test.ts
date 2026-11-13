import { render, screen } from '@testing-library/svelte';
import { expect, it, vi } from 'vitest';
import StepNav from './StepNav.svelte';

it('zeigt Schrittzähler und Begründung als ein Satz und beschreibt das deaktivierte Weiter damit', () => {
  render(StepNav, {
    step: 0,
    total: 5,
    canNext: false,
    hint: 'Prüfen Sie zuerst die Verbindung.',
    onback: vi.fn(),
    onnext: vi.fn(),
  });
  const counter = screen.getByText('Schritt 1 von 5');
  const paragraph = counter.closest('p')!;
  expect(paragraph.textContent).toContain('Prüfen Sie zuerst die Verbindung.');
  const next = screen.getByRole('button', { name: 'Weiter' });
  expect((next as HTMLButtonElement).disabled).toBe(true);
  expect(next.getAttribute('aria-describedby')).toBe('step-hint');
  expect(paragraph.querySelector('#step-hint')).toBeTruthy();
  expect(paragraph.textContent).toContain('5\u00a0· Prüfen');
});

it('blendet die Begründung aus, sobald Weiter möglich ist', () => {
  render(StepNav, {
    step: 1,
    total: 5,
    canNext: true,
    hint: 'egal',
    onback: vi.fn(),
    onnext: vi.fn(),
  });
  expect(screen.queryByText(/egal/)).toBeNull();
  expect(screen.getByRole('button', { name: 'Zurück' })).toBeTruthy();
});
