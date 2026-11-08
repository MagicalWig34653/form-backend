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
})();
