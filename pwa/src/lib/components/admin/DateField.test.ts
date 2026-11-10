import { fireEvent, render, screen } from '@testing-library/svelte';
import { describe, expect, it, vi } from 'vitest';
import DateField, { formatDate, parseDate } from './DateField.svelte';

describe('Datumsformat', () => {
  it('liest deutsche und ISO-Daten und verwirft unmögliche', () => {
    expect(parseDate('03.11.2026')).toBe('2026-11-03');
    expect(parseDate('3.1.2026')).toBe('2026-01-03');
    expect(parseDate('2026-11-03')).toBe('2026-11-03');
    expect(parseDate('31.02.2026')).toBeNull();
    expect(parseDate('2026')).toBeNull();
    expect(formatDate('2026-11-03')).toBe('03.11.2026');
    expect(formatDate('')).toBe('');
  });
});

describe('DateField', () => {
  it('meldet ein gültiges Datum als ISO und markiert ungültige Eingaben', async () => {
    const onchange = vi.fn();
    render(DateField, { id: 'd', label: 'Datum', onchange });
    const input = screen.getByLabelText('Datum') as HTMLInputElement;
    await fireEvent.input(input, { target: { value: '03.11.2026' } });
    expect(onchange).toHaveBeenCalledTimes(1);
    expect(input.value).toBe('03.11.2026');
    await fireEvent.input(input, { target: { value: '99.99.2026' } });
    await fireEvent.blur(input);
    expect(await screen.findByRole('alert')).toBeTruthy();
    expect(input.getAttribute('aria-invalid')).toBe('true');
  });
  it('bietet einen Kalender-Knopf mit eigenem Namen', () => {
    render(DateField, { id: 'd', label: 'Datum' });
    expect(screen.getByRole('button', { name: /Datum.*Kalender/ })).toBeTruthy();
  });
});
