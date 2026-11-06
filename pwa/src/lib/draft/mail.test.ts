import { describe, expect, it } from 'vitest';
import { formToMail, mailToForm, validateMailForm } from './mail';

const base = {
  from: { address: 'absender@example.org' },
  organisation: { to: ['team@example.org'], subject: 'S', body: 'B', format: 'text' },
};

describe('derived mail values', () => {
  it('survive a load/save round trip unchanged', () => {
    const derived = {
      fullName: { op: 'join', fields: ['prename', 'lastname'], separator: ' ' },
      wahl: { op: 'firstNonEmpty', fields: ['a', 'b'] },
      ab: { op: 'date', field: 'abWann', format: 'dd.MM.yyyy' },
      jetzt: { op: 'now', format: 'dd.MM.yyyy - HH:mm', timeZone: 'Europe/Berlin' },
    };
    const mail = formToMail(mailToForm({ ...base, derived }));
    expect(mail?.derived).toEqual(derived);
  });

  it('omits the section when there are no derived values', () => {
    expect(formToMail(mailToForm(base))).not.toHaveProperty('derived');
  });

  it('validates names, inputs and formats', () => {
    const names = ['prename', 'lastname', 'abWann'];
    const good = mailToForm({
      ...base,
      derived: { fullName: { op: 'join', fields: ['prename', 'lastname'], separator: ' ' } },
    });
    expect(validateMailForm(good, names)).toEqual({});
    const shadow = mailToForm({
      ...base,
      derived: { prename: { op: 'join', fields: ['lastname'], separator: ' ' } },
    });
    expect(validateMailForm(shadow, names).derived).toBe('derived');
    const unknown = mailToForm({
      ...base,
      derived: { x: { op: 'join', fields: ['nope'], separator: ' ' } },
    });
    expect(validateMailForm(unknown, names).derived).toBe('derived');
    const date = mailToForm({
      ...base,
      derived: { d: { op: 'date', field: 'abWann', format: 'dd.MM.yyyy' } },
    });
    expect(validateMailForm(date, names)).toEqual({});
    date.derived[0]!.format = '';
    expect(validateMailForm(date, names).derived).toBe('derived');
  });
});
