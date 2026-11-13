import { expect, it } from 'vitest';
import { phpExample } from '$lib/admin/phpSnippet';

it('verwendet die tatsächlichen Feldnamen des Formulars', () => {
  const code = phpExample(['nachricht']);
  expect(code).toContain("'nachricht' => $_POST['nachricht'] ?? '',");
  expect(code).not.toContain("'name'");
  expect(code).toContain('use FormBackend\\Client;');
});
it('richtet mehrere Feldnamen aus und maskiert Hochkommata', () => {
  const code = phpExample(['a', "b'c"]);
  expect(code).toContain("'a'    => $_POST['a']");
  expect(code).toContain("'b\\'c' => $_POST['b\\'c']");
});
it('zeigt ohne Felder nur einen Platzhalter als Kommentar', () => {
  const code = phpExample([]);
  expect(code).toContain("// 'feldname' =>");
  expect(code.split('\n').some((l) => /^\s+'[a-z]+'\s+=>/.test(l))).toBe(false);
});
