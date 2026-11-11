/**
 * MJML → HTML in the browser. `mjml-browser` (MIT, about 1.2 MB unminified) is loaded on demand into its own chunk,
 * so the main bundle does not grow. MJML produces the table layout and the MSO conditional comments Outlook needs.
 */
type Compiler = (typeof import('mjml-browser'))['default'];

let loading: Promise<Compiler> | null = null;
let compiler: Compiler | null = null;

export function loadMjml(): Promise<Compiler> {
  loading ??= import('mjml-browser')
    .then((m) => {
      const fn = ((m as { default?: unknown }).default ?? m) as Compiler;
      compiler = fn;
      return fn;
    })
    .catch((error: unknown) => {
      loading = null;
      throw error;
    });
  return loading;
}

export const mjmlReady = (): boolean => compiler !== null;

export interface CompileResult {
  html: string;
  errors: string[];
}

/** Synchronous once `loadMjml()` resolved. `fonts: {}` keeps MJML from adding Google-Fonts links to the mail. */
export function compileMjmlSync(source: string): CompileResult {
  if (!compiler) throw new Error('mjml not loaded');
  const r = compiler(source, { validationLevel: 'soft', keepComments: false, fonts: {} });
  return {
    html: r.html,
    errors: r.errors.map((e) => e.formattedMessage ?? e.message),
  };
}

export async function compileMjml(source: string): Promise<CompileResult> {
  await loadMjml();
  return compileMjmlSync(source);
}
