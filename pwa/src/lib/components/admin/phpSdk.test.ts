import { expect, it } from 'vitest';
import { phpExample } from '$lib/admin/phpSnippet';

const code = phpExample(['nachricht']);

it('PHP-Beispiel enthält echte Namensräume mit einfachen Backslashes', () => {
  expect(code).toContain('use FormBackend\\Client;');
  expect(code).toContain('use FormBackend\\Exception\\RejectedException;');
  expect(code).toContain("Credentials::fromFile('/etc/myapp/credentials.json')");
  expect(code).not.toContain('\\\\');
});
