import { expect, it } from 'vitest';
import { t } from '$lib/i18n';

it('PHP-Beispiel enthält echte Namensräume mit einfachen Backslashes', () => {
  expect(t.phpSdk.code).toContain('use FormBackend\\Client;');
  expect(t.phpSdk.code).toContain('use FormBackend\\Exception\\RejectedException;');
  expect(t.phpSdk.code).toContain("Credentials::fromFile('/etc/myapp/credentials.json')");
  expect(t.phpSdk.code).not.toContain('\\\\');
});
