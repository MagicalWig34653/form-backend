import { describe, expect, it } from 'vitest';
import {
  buildMarker,
  byteLength,
  composeBody,
  decodeBase64,
  encodeBase64,
  initialMode,
  readMarker,
  stripMarker,
} from './source';
import { isSafeImage, isSafeLink, sanitizeRichText, simpleFrame } from './richtext';
import {
  designToRichText,
  moveBlock,
  newBlock,
  parseMjml,
  serializeMjml,
  templateDoc,
  type SimpleBlock,
} from './design';
import { compileMjml } from './compile';
import { bodyAfterSourceEdit, planSwitch } from './modes';
import { previewDocument } from './preview';

const LEGACY_TEMPLATE =
  '<mjml><mj-body background-color="#f4f4f4"><mj-section background-color="#ffffff" padding="24px"><mj-column>' +
  '<mj-text font-family="Arial, Helvetica, sans-serif" font-size="15px" line-height="1.6" color="#333333">' +
  'Guten Tag,<br /><br />Ihr Text.</mj-text></mj-column></mj-section></mj-body></mjml>';

/** What the legacy editor wrote (btoa(unescape(encodeURIComponent(JSON)))). */
const legacyMarker = (json: object): string =>
  '<!--kubus-mail-quelle:' + Buffer.from(JSON.stringify(json), 'utf8').toString('base64') + '-->';

describe('source marker', () => {
  it('round-trips umlauts, emoji and other Unicode', () => {
    const text = 'Grüße aus Köln – 𝔘𝔫𝔦𝔠𝔬𝔡𝔢 😀 «#=[vorname]=#» 中文';
    expect(decodeBase64(encodeBase64(text))).toBe(text);
    expect(encodeBase64(text)).toBe(Buffer.from(text, 'utf8').toString('base64'));
    const body = composeBody({ kind: 'design', source: text, handEdited: false }, '<p>x</p>');
    expect(readMarker(body)).toEqual({ kind: 'design', source: text, handEdited: false });
    expect(stripMarker(body)).toBe('<p>x</p>');
  });

  it('reads markers written by the legacy editor and writes the same format', () => {
    const body = legacyMarker({ m: 'einfach', s: '<p>Hallo Ä</p>', q: true }) + '\n<table></table>';
    expect(readMarker(body)).toEqual({
      kind: 'simple',
      source: '<p>Hallo Ä</p>',
      handEdited: true,
    });
    expect(initialMode(body)).toBe('source');
    expect(buildMarker('simple', '<p>Hallo Ä</p>', true)).toBe(
      legacyMarker({ m: 'einfach', s: '<p>Hallo Ä</p>', q: true }),
    );
  });

  it('starts in the source view when the marker is missing or broken', () => {
    expect(initialMode('<p>Altes HTML</p>')).toBe('source');
    expect(initialMode('')).toBe('source');
    expect(initialMode('<!--kubus-mail-quelle:@@@-->')).toBe('source');
    expect(initialMode('<!--kubus-mail-quelle:' + btoa('{"m":"x","s":"a"}') + '-->')).toBe(
      'source',
    );
    expect(readMarker('<!--kubus-mail-quelle:' + btoa('kein json') + '-->')).toBeNull();
    expect(initialMode(composeBody({ kind: 'design', source: 'a', handEdited: false }, ''))).toBe(
      'design',
    );
  });

  it('counts bytes, not characters', () => {
    expect(byteLength('ä')).toBe(2);
  });
});

describe('rich text sanitizer', () => {
  it('keeps mail-safe formatting and drops everything else', () => {
    const dirty =
      '<div onclick="x()">Hallo <b>fett</b> <i>kursiv</i><script>alert(1)</script>' +
      '<a href="javascript:alert(1)">böse</a> <a href="https://example.org/?a=1&b=2">gut</a>' +
      '<img src=x onerror=alert(1)><style>p{}</style><span style="color:red">#=[name]=#</span></div>';
    expect(sanitizeRichText(dirty)).toBe(
      '<p>Hallo <strong>fett</strong> <em>kursiv</em>böse <a href="https://example.org/?a=1&amp;b=2">gut</a>#=[name]=#</p>',
    );
  });

  it('accepts only http(s)/mailto links and https/data images', () => {
    expect(isSafeLink('https://a.b/#=[id]=#')).toBe(true);
    expect(isSafeLink('mailto:a@b.de')).toBe(true);
    expect(isSafeLink('#=[url]=#')).toBe(false);
    expect(isSafeLink('javascript:alert(1)')).toBe(false);
    expect(isSafeImage('http://a.b/x.png')).toBe(false);
    expect(isSafeImage('https://a.b/x.png')).toBe(true);
    expect(isSafeImage('data:image/png;base64,iVBORw0KGgo=')).toBe(true);
    expect(isSafeImage('data:image/svg+xml;base64,PHN2Zz4=')).toBe(false);
  });

  it('frames rich text in a table layout', () => {
    expect(simpleFrame('<p>x</p>')).toContain('role="presentation"');
  });
});

describe('design model', () => {
  it('parses the legacy template into an editable text block and back', () => {
    const doc = parseMjml(LEGACY_TEMPLATE)!;
    expect(doc.blocks).toHaveLength(1);
    expect(doc.blocks[0]!.type).toBe('text');
    expect(doc.sectionAttrs).toEqual({ 'background-color': '#ffffff', padding: '24px' });
    const again = parseMjml(serializeMjml(doc))!;
    expect(again.blocks.map((b) => b.type)).toEqual(['text']);
    expect((again.blocks[0] as SimpleBlock).content).toBe('Guten Tag,<br><br>Ihr Text.');
  });

  it('keeps unknown MJML verbatim as MJML blocks', () => {
    const src =
      '<mjml><mj-head><mj-title>T</mj-title></mj-head><mj-body>' +
      '<mj-section><mj-column><mj-text>A</mj-text><mj-social><mj-social-element name="x" /></mj-social></mj-column></mj-section>' +
      '<mj-section><mj-column><mj-text>B</mj-text></mj-column><mj-column><mj-text>C</mj-text></mj-column></mj-section>' +
      '<mj-section><mj-column><mj-image src="https://e.x/a.png" /><mj-spacer height="10px" /></mj-column></mj-section>' +
      '</mj-body></mjml>';
    const doc = parseMjml(src)!;
    expect(doc.head).toContain('mj-title');
    expect(doc.blocks.map((b) => b.type)).toEqual(['text', 'raw', 'raw', 'image', 'spacer']);
    const out = serializeMjml(doc);
    expect(out).toContain('<mj-social>');
    expect(out).toContain('<mj-text>C</mj-text>');
    expect(out).toContain('<mj-image src="https://e.x/a.png" />');
  });

  it('leaves unsafe URLs out of the MJML', () => {
    const doc = templateDoc({ greeting: 'Hallo' });
    const button = newBlock('button', { text: 't', button: 'Los' }) as SimpleBlock;
    button.attrs.href = 'javascript:alert(1)';
    const image = newBlock('image', { text: 't', button: 'b' }) as SimpleBlock;
    image.attrs.src = 'http://insecure.example/a.png';
    doc.blocks.push(button, image);
    const out = serializeMjml(doc);
    expect(out).not.toContain('javascript:');
    expect(out).not.toContain('insecure.example');
  });

  it('moves blocks and derives rich text', () => {
    expect(moveBlock([1, 2, 3], 0, 2)).toEqual([2, 3, 1]);
    expect(moveBlock([1, 2, 3], 2, 0)).toEqual([3, 1, 2]);
    const doc = templateDoc({ greeting: '<p>Hallo</p>' });
    const b = newBlock('button', { text: 't', button: 'Los' }) as SimpleBlock;
    b.attrs.href = 'https://x.de';
    doc.blocks.push(b);
    expect(designToRichText(doc)).toBe('<p>Hallo</p><p><a href="https://x.de">Los</a></p>');
  });
});

describe('MJML compilation', () => {
  it('keeps placeholders unchanged in text, links, labels and alt texts', async () => {
    const doc = templateDoc({ greeting: '<p>Hallo #=[vorname]=#, Ihre Nummer: #=[nr_1]=#</p>' });
    const button = newBlock('button', { text: 't', button: 'Ansehen #=[titel]=#' }) as SimpleBlock;
    button.attrs.href = 'https://example.org/?id=#=[id]=#';
    const image = newBlock('image', { text: 't', button: 'b' }) as SimpleBlock;
    image.attrs.src = 'https://example.org/logo.png';
    image.attrs.alt = '#=[firma]=#';
    doc.blocks.push(button, image);
    const { html, errors } = await compileMjml(serializeMjml(doc));
    expect(errors).toEqual([]);
    const found = html.match(/#=\[\w+\]=#/g) ?? [];
    for (const p of ['vorname', 'nr_1', 'titel', 'id', 'firma'])
      expect(found).toContain(`#=[${p}]=#`);
    expect(html).toContain('<table');
    expect(html).toContain('<!--[if mso');
    expect(html).not.toContain('fonts.googleapis');
  });

  it('compiles the legacy template', async () => {
    const { html } = await compileMjml(LEGACY_TEMPLATE);
    expect(html).toContain('Ihr Text.');
  });
});

describe('mode switching', () => {
  const design = composeBody(
    { kind: 'design', source: LEGACY_TEMPLATE, handEdited: false },
    '<t/>',
  );
  const handEdited = composeBody(
    { kind: 'design', source: LEGACY_TEMPLATE, handEdited: true },
    '<x/>',
  );
  const simple = composeBody({ kind: 'simple', source: '<p>Hi</p>', handEdited: false }, '<t/>');

  it('switches to the source view without touching the body', () => {
    expect(planSwitch('design', 'source', design)).toEqual({
      question: null,
      seed: { kind: 'none', value: '' },
      regenerate: false,
    });
  });

  it('returns to design without regenerating when the HTML was not edited by hand', () => {
    expect(planSwitch('source', 'design', design)).toMatchObject({
      question: null,
      seed: { kind: 'design-source', value: LEGACY_TEMPLATE },
      regenerate: false,
    });
  });

  it('asks before hand edits are replaced', () => {
    expect(planSwitch('source', 'design', handEdited).question).toBe('handEditsLost');
    expect(planSwitch('source', 'design', handEdited).regenerate).toBe(true);
  });

  it('asks before foreign HTML is replaced or converted, not for an empty body', () => {
    expect(planSwitch('source', 'design', '<p>alt</p>').question).toBe('foreignToDesign');
    expect(planSwitch('source', 'simple', '<p>alt</p>')).toMatchObject({
      question: 'foreignToSimple',
      seed: { kind: 'rich', value: '<p>alt</p>' },
    });
    expect(planSwitch('source', 'design', '  ').question).toBeNull();
  });

  it('warns before the design source is lost', () => {
    expect(planSwitch('design', 'simple', design, '<p>r</p>')).toMatchObject({
      question: 'designLost',
      seed: { kind: 'rich', value: '<p>r</p>' },
    });
    expect(planSwitch('source', 'simple', design).question).toBe('designLost');
  });

  it('takes rich text into design without a question', () => {
    expect(planSwitch('simple', 'design', simple)).toMatchObject({
      question: null,
      seed: { kind: 'design-from-rich', value: '<p>Hi</p>' },
    });
  });

  it('marks hand edits in the marker and keeps the source', () => {
    const next = bodyAfterSourceEdit(design, '<p>neu</p>');
    expect(readMarker(next)).toEqual({ kind: 'design', source: LEGACY_TEMPLATE, handEdited: true });
    expect(stripMarker(next)).toBe('<p>neu</p>');
    expect(bodyAfterSourceEdit('<p>a</p>', '<p>b</p>')).toBe('<p>b</p>');
  });
});

describe('preview document', () => {
  it('drops the marker, fills escaped example values and adds a restrictive policy', () => {
    const doc = previewDocument(
      composeBody(
        { kind: 'simple', source: 's', handEdited: false },
        '<html><head></head><body>#=[a]=#</body></html>',
      ),
      'Beispiel',
    );
    expect(doc).not.toContain('kubus-mail-quelle');
    expect(doc).toContain('Beispiel a');
    expect(doc).toContain("default-src 'none'");
    expect(previewDocument('#=[x]=#', '<b>')).toContain('&lt;b&gt; x');
  });
});
