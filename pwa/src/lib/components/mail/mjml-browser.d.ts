declare module 'mjml-browser' {
  interface MjmlError {
    line?: number;
    message: string;
    tagName?: string;
    formattedMessage?: string;
  }
  interface MjmlOptions {
    validationLevel?: 'strict' | 'soft' | 'skip';
    keepComments?: boolean;
    fonts?: Record<string, string>;
    beautify?: boolean;
    minify?: boolean;
  }
  function mjml2html(mjml: string, options?: MjmlOptions): { html: string; errors: MjmlError[] };
  export default mjml2html;
}
