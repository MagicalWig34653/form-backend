// Applies the stored or system colour scheme before first paint (no flash).
(function () {
  var dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  try {
    var stored = localStorage.getItem('theme');
    if (stored === 'dark') dark = true;
    else if (stored === 'light') dark = false;
  } catch {
    /* storage unavailable: fall back to system preference */
  }
  document.documentElement.classList.toggle('dark', dark);
  try {
    var fx = localStorage.getItem('effects');
    var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    document.documentElement.dataset.effects =
      reduced || fx === 'off' ? 'off' : fx === 'full' ? 'full' : 'subtle';
  } catch {
    /* Defaults apply once the app starts. */
  }
  try {
    var colors = { blue: '#2563eb', violet: '#7c3aed', green: '#047857', orange: '#c2410c' };
    var accent = localStorage.getItem('accent');
    if (accent && Object.hasOwn(colors, accent)) {
      document.documentElement.dataset.accent = accent;
      document.documentElement.style.setProperty('--ui-accent', colors[accent]);
      document.documentElement.style.setProperty(
        '--ui-accent-soft',
        'color-mix(in srgb, ' + colors[accent] + ' 10%, var(--background))',
      );
    }
  } catch {
    /* Session-only preference. */
  }
})();
