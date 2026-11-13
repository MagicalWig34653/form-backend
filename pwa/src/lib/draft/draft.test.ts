import { describe, expect, it } from 'vitest';
import { canonicalize, sha256Hex } from './jcs';
import {
  addField,
  bumpMinor,
  bumpVersions,
  fieldList,
  mailReferences,
  removeField,
  restamp,
  setMail,
  setTitle,
  title,
  updateField,
  validateFieldInput,
  viewsOf,
  formOf,
} from './doc';
import {
  emptyMailForm,
  formToMail,
  isMailAddress,
  mailToForm,
  parseAddressLines,
  validateMailForm,
} from './mail';
import type { JsonObject } from '../api/admin';

/** The server's standard document of a new form (DraftStore.standardDocument), with fixed ids. */
const standard = (): JsonObject => ({
  form: {
    contractVersion: '0.1.0',
    proposalStatus: 'VORGESCHLAGEN',
    id: 'f1',
    version: '1.0.0',
    tenantId: 't1',
    title: { de: 'Kontakt' },
    unknownFields: 'reject',
    normalization: 'typed-v1',
    fields: {
      message: {
        name: 'nachricht',
        kind: 'text',
        label: { de: 'Nachricht' },
        required: false,
        hidden: false,
        locked: false,
        sensitive: false,
        validation: { type: 'string' },
      },
    },
    security: { encryptionProfile: 'hpke-v2', specialCategories: false },
    storage: { adapter: 'db', maxSubmissionBytes: 10485760, onFailure: 'reject-acceptance' },
  },
  flow: { id: 'g1', version: '1.0.0' },
  views: [
    {
      id: 'v1',
      version: '1.0.0',
      form: { id: 'f1', version: '1.0.0', sha256: 'x' },
      steps: [
        {
          id: 'main',
          title: { de: 'Formular' },
          sections: [
            {
              id: 'main',
              title: { de: 'Angaben' },
              fields: [{ fieldId: 'message', readOnly: false, disabled: false }],
            },
          ],
        },
      ],
    },
  ],
});

describe('canonical JSON / hash (must equal the Swift server)', () => {
  it('matches the server fixture of JCSTests', () => {
    const sample = {
      form: {
        id: 'f',
        fields: [
          { n: 'a', required: true },
          { n: 'b', max: 190 },
        ],
      },
      views: [{ id: 'v', title: 'Größe €' }],
      flow: { nodes: ['entry', 'end'] },
    };
    expect(canonicalize(sample)).toBe(
      '{"flow":{"nodes":["entry","end"]},"form":{"fields":[{"n":"a","required":true},{"max":190,"n":"b"}],"id":"f"},"views":[{"id":"v","title":"Größe €"}]}',
    );
  });
  it('hashes the canonical text with SHA-256 (hex, lower case)', async () => {
    // sha256 of the canonical text above, computed independently with Python hashlib
    expect(
      await sha256Hex({
        form: {
          id: 'f',
          fields: [
            { n: 'a', required: true },
            { n: 'b', max: 190 },
          ],
        },
        views: [{ id: 'v', title: 'Größe €' }],
        flow: { nodes: ['entry', 'end'] },
      }),
    ).toBe('eb5cf956c717259eb12ceca708247a434b92e2d2985b707de7aa30ba4e4f4298');
  });
  it('sorts keys by UTF-16 code units and escapes like the server', () => {
    expect(canonicalize({ '\u{1F600}': 1, '\uFB33': 2, '\r': 3, 1: 4, é: 5 })).toBe(
      '{"\\r":3,"1":4,"é":5,"\u{1F600}":1,"\uFB33":2}',
    );
    expect(canonicalize('a\u0001"\\/\n')).toBe('"a\\u0001\\"\\\\/\\n"');
  });
  it('rejects what the server rejects', () => {
    for (const bad of [1.5, NaN, Infinity, 2 ** 53, -(2 ** 53), undefined as unknown, () => 1])
      expect(() => canonicalize(bad)).toThrow();
    expect(canonicalize({ a: undefined, b: 1 })).toBe('{"b":1}');
    expect(canonicalize(9007199254740991)).toBe('9007199254740991');
  });
});

describe('draft document edits', () => {
  it('copes with reactive proxies', () => {
    const proxied = new Proxy(standard(), {});
    expect(
      fieldList(addField(proxied, { name: 'x', label: 'X', kind: 'text', required: false })).length,
    ).toBe(2);
  });
  it('adds a field to the form and to every view without touching the original', () => {
    const doc = standard();
    const next = addField(doc, { name: 'email', label: 'E-Mail', kind: 'email', required: true });
    expect(fieldList(doc).map((f) => f.name)).toEqual(['nachricht']);
    expect(fieldList(next).map((f) => f.name)).toEqual(['nachricht', 'email']);
    expect(fieldList(next)[1]).toMatchObject({
      id: 'email',
      label: 'E-Mail',
      kind: 'email',
      required: true,
    });
    expect((formOf(next).fields as JsonObject).email).toMatchObject({
      validation: { type: 'string', format: 'email' },
      sensitive: true,
      hidden: false,
      locked: false,
    });
    const shown = (
      ((viewsOf(next)[0]!.steps as JsonObject[])[0]!.sections as JsonObject[])[0]!
        .fields as JsonObject[]
    ).map((f) => f.fieldId);
    expect(shown).toEqual(['message', 'email']);
  });
  it('builds validations per kind, including choices', () => {
    let doc = standard();
    doc = addField(doc, {
      name: 'wahl',
      label: 'Wahl',
      kind: 'choice',
      required: false,
      options: ['a', 'b'],
    });
    doc = addField(doc, { name: 'zahl', label: 'Zahl', kind: 'number', required: false });
    doc = addField(doc, { name: 'datum', label: 'Datum', kind: 'date', required: false });
    const f = formOf(doc).fields as Record<string, JsonObject>;
    expect(f.wahl!.validation).toEqual({ type: 'string', enum: ['a', 'b'] });
    expect(f.zahl!.validation).toMatchObject({ pattern: '^-?[0-9]+([.,][0-9]+)?$' });
    expect(f.datum!.validation).toEqual({ type: 'string', format: 'date' });
    expect(fieldList(doc).find((x) => x.id === 'wahl')!.options).toEqual(['a', 'b']);
  });
  it('validates names and options the way the server does', () => {
    const doc = standard();
    const ok = { name: 'vorname', label: 'Vorname', kind: 'text' as const, required: false };
    expect(validateFieldInput(doc, ok)).toBeNull();
    for (const [name, why] of [
      ['1abc', 'name'],
      ['a b', 'name'],
      ['a.b', 'name'],
      ['a-b', 'name'],
      ['ü', 'name'],
      ['', 'name'],
      ['x'.repeat(65), 'name'],
      ['nachricht', 'duplicate'],
      ['csrf_token', 'reserved'],
    ] as const)
      expect(validateFieldInput(doc, { ...ok, name }), name).toBe(why);
    expect(validateFieldInput(doc, { ...ok, label: ' ' })).toBe('label');
    expect(validateFieldInput(doc, { ...ok, kind: 'choice', options: [] })).toBe('options');
    expect(validateFieldInput(doc, { ...ok, kind: 'choice', options: ['a', 'a'] })).toBe('options');
    expect(validateFieldInput(doc, { ...ok, name: 'nachricht' }, 'message')).toBeNull(); // editing a field keeps its own name
  });
  it('updates and removes fields everywhere; mail references block removal', () => {
    let doc = addField(standard(), {
      name: 'email',
      label: 'E-Mail',
      kind: 'email',
      required: false,
    });
    doc = updateField(doc, 'email', {
      name: 'email',
      label: 'Ihre E-Mail',
      kind: 'email',
      required: true,
    });
    expect(fieldList(doc).find((f) => f.id === 'email')).toMatchObject({
      label: 'Ihre E-Mail',
      required: true,
    });
    doc = setMail(doc, {
      from: { address: 'a@example.org' },
      confirmation: { toField: 'email', subject: 'S', body: 'B' },
    });
    expect(mailReferences(doc, 'email')).toEqual(['confirmation.toField']);
    expect(mailReferences(doc, 'nachricht')).toEqual([]);
    const removed = removeField(doc, 'message');
    expect(fieldList(removed).map((f) => f.id)).toEqual(['email']);
    expect(
      (
        ((viewsOf(removed)[0]!.steps as JsonObject[])[0]!.sections as JsonObject[])[0]!
          .fields as JsonObject[]
      ).map((f) => f.fieldId),
    ).toEqual(['email']);
  });
  it('title, mail section and version bumping', () => {
    let doc = setTitle(standard(), '  Neuer Titel ');
    expect(title(doc)).toBe('Neuer Titel');
    doc = setMail(doc, { from: { address: 'a@example.org' } });
    expect(formOf(doc).mail).toBeDefined();
    expect(formOf(setMail(doc, null)).mail).toBeUndefined();
    const bumped = bumpVersions(doc);
    expect(formOf(bumped).version).toBe('1.1.0');
    expect(viewsOf(bumped)[0]!.version).toBe('1.1.0');
    expect(bumpMinor('2.7.3')).toBe('2.8.0');
    expect(bumpMinor('x')).toBe('x');
  });
  it('restamp refreshes the views reference to the form version and content hash', async () => {
    const doc = bumpVersions(
      addField(standard(), { name: 'email', label: 'E', kind: 'email', required: false }),
    );
    const stamped = await restamp(doc);
    const ref = viewsOf(stamped)[0]!.form as JsonObject;
    expect(ref.version).toBe('1.1.0');
    expect(ref.sha256).toBe(await sha256Hex(formOf(stamped)));
    expect(ref.sha256).toMatch(/^[0-9a-f]{64}$/);
    expect((viewsOf(doc)[0]!.form as JsonObject).sha256).toBe('x'); // the input is untouched
  });
});

describe('mail form', () => {
  it('round-trips the section and parses address lists', () => {
    const f = emptyMailForm();
    f.fromAddress = ' info@example.org ';
    f.fromName = 'Praxis';
    f.organisation = {
      enabled: true,
      content: 'full',
      to: 'a@example.org, b@example.org\nc@example.org',
      bcc: '',
      replyToField: 'email',
      subject: 'S',
      body: 'B',
      format: 'html',
    };
    f.confirmation = { enabled: true, toField: 'email', subject: 'D', body: 'T', format: 'text' };
    const mail = formToMail(f)!;
    expect(mail).toEqual({
      from: { address: 'info@example.org', name: 'Praxis' },
      organisation: {
        to: ['a@example.org', 'b@example.org', 'c@example.org'],
        replyToField: 'email',
        content: 'full',
        subject: 'S',
        body: 'B',
        format: 'html',
      },
      confirmation: { toField: 'email', subject: 'D', body: 'T', format: 'text' },
    });
    expect(formToMail(mailToForm(mail))).toEqual(mail);
    expect(
      formToMail({
        ...f,
        organisation: { ...f.organisation, enabled: false },
        confirmation: { ...f.confirmation, enabled: false },
      }),
    ).toBeNull();
    expect(mailToForm(undefined).organisation.enabled).toBe(true);
    expect(parseAddressLines(' a@b.de;;\n c@d.de ,')).toEqual(['a@b.de', 'c@d.de']);
  });
  it('uses the same address rules as the server', () => {
    for (const ok of ['a@example.org', 'Max.Muster+tag@Example.ORG', "o'brien@example.co.uk"])
      expect(isMailAddress(ok), ok).toBe(true);
    for (const bad of [
      '',
      'a',
      'a@b',
      'a@b.c',
      'a b@c.de',
      '.a@c.de',
      'a..b@c.de',
      'Name <a@c.de>',
      'a@c.de\r\nBcc: x@y.de',
      'ü@c.de',
      'a@c-.de',
      'a@c.d1',
      'a@@c.de',
    ])
      expect(isMailAddress(bad), bad).toBe(false);
  });
  it('validates a complete configuration and reports each problem separately', () => {
    const f = emptyMailForm();
    f.fromAddress = 'info@example.org';
    f.organisation = {
      enabled: true,
      content: 'full',
      to: 'a@example.org',
      bcc: '',
      replyToField: '',
      subject: 'S',
      body: 'B',
      format: 'text',
    };
    expect(validateMailForm(f, ['email'])).toEqual({});
    f.organisation.to = 'a@example.org, nope';
    f.organisation.subject = 'a\nb';
    f.organisation.body = ' '; // an empty organisation body is valid (standard field list)
    f.confirmation = { enabled: true, toField: 'fehlt', subject: '', body: 'x', format: 'text' };
    f.fromAddress = 'x';
    expect(validateMailForm(f, ['email'])).toEqual({
      fromAddress: 'address',
      orgTo: 'recipients',
      orgSubject: 'subject',
      confToField: 'field',
      confSubject: 'subject',
    });
    expect(
      validateMailForm(
        {
          ...f,
          organisation: { ...f.organisation, enabled: false },
          confirmation: { ...f.confirmation, enabled: false },
        },
        [],
      ),
    ).toEqual({});
  });
});
