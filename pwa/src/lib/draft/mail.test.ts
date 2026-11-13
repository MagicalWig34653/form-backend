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

describe('organisation content (ADR 0041, decision 13.11.2026: standard = all fields)', () => {
  it('treats a stored form without the key as full', () => {
    const f = mailToForm(base);
    expect(f.organisation.content).toBe('full');
    expect(formToMail(f)?.organisation).toMatchObject({ content: 'full', subject: 'S', body: 'B' });
  });

  it('keeps notification only when it is stored explicitly, and round-trips it', () => {
    const note = { ...base, organisation: { ...base.organisation, content: 'notification' } };
    const f = mailToForm(note);
    expect(f.organisation.content).toBe('notification');
    expect(formToMail(f)?.organisation).toMatchObject({ content: 'notification' });
    const odd = { ...base, organisation: { ...base.organisation, content: 'x' } };
    expect(mailToForm(odd).organisation.content).toBe('full');
  });

  it('a new mail section defaults to full and needs no template (the system sends the field list)', () => {
    const f = mailToForm(null);
    f.fromAddress = 'a@example.org';
    f.organisation.to = 'team@example.org';
    expect(f.organisation.content).toBe('full');
    expect(validateMailForm(f, [])).toEqual({});
    expect(formToMail(f)?.organisation).toEqual({
      to: ['team@example.org'],
      content: 'full',
      subject: '',
      body: '',
      format: 'text',
    });
  });

  it('an empty organisation template is valid, an oversized or multi-line one is not', () => {
    const f = mailToForm(null);
    f.fromAddress = 'a@example.org';
    f.organisation.to = 'team@example.org';
    f.organisation.subject = 'Zeile\neins';
    expect(validateMailForm(f, [])).toMatchObject({ orgSubject: 'subject' });
    f.organisation.subject = '';
    f.organisation.body = 'x'.repeat(100_001);
    expect(validateMailForm(f, [])).toMatchObject({ orgBody: 'bodySize' });
  });

  it('switching to notification with a half-filled template never blocks saving', () => {
    const f = mailToForm(null);
    f.fromAddress = 'a@example.org';
    f.organisation.to = 'team@example.org';
    f.organisation.body = 'Text #=[geloescht]=#';
    f.organisation.replyToField = 'geloescht';
    f.organisation.content = 'notification';
    expect(validateMailForm(f, [])).toEqual({});
    // kept for a switch back; the server accepts a partial template and a stale reply-to in notification mode
    expect(formToMail(f)?.organisation).toMatchObject({
      content: 'notification',
      subject: '',
      body: 'Text #=[geloescht]=#',
      replyToField: 'geloescht',
    });
  });

  it('notification drops a hidden template the server would reject', () => {
    const f = mailToForm(null);
    f.fromAddress = 'a@example.org';
    f.organisation.to = 'team@example.org';
    f.organisation.content = 'notification';
    f.organisation.subject = 'Zeile\teins';
    f.organisation.body = 'B';
    expect(formToMail(f)?.organisation).not.toHaveProperty('body');
    f.organisation.subject = 'S';
    f.organisation.body = 'x'.repeat(100_001);
    expect(formToMail(f)?.organisation).not.toHaveProperty('body');
  });

  it('the confirmation mail still demands subject and body', () => {
    const f = mailToForm(null);
    f.fromAddress = 'a@example.org';
    f.organisation.to = 'team@example.org';
    f.confirmation.enabled = true;
    f.confirmation.toField = 'email';
    expect(validateMailForm(f, ['email'])).toMatchObject({
      confSubject: 'subject',
      confBody: 'body',
    });
  });
});
