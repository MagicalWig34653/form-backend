/**
 * Name of the form currently shown on the form page. FormPage writes it; the shell breadcrumb
 * (shell/nav.ts crumbsFor) may read it to show the real form name instead of the generic label.
 */
export const formContext = $state<{ tenant: string; form: string; name: string }>({
  tenant: '',
  form: '',
  name: '',
});
