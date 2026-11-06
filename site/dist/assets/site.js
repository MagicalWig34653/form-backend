(function () {
  var root = document.documentElement;
  var toggle = document.getElementById('theme-toggle');
  if (toggle) toggle.addEventListener('click', function () {
    var next = root.dataset.theme === 'dark' ? 'light' : 'dark';
    root.dataset.theme = next;
    try { localStorage.setItem('fb-docs-theme', next); } catch (e) { /* storage is optional */ }
  });

  var menu = document.querySelector('.menu-btn');
  var nav = document.getElementById('site-nav');
  if (menu && nav) menu.addEventListener('click', function () {
    var open = nav.classList.toggle('open');
    menu.setAttribute('aria-expanded', String(open));
  });

  // Wide tables scroll inside a focusable region (keyboard access to the scrolled content).
  Array.prototype.forEach.call(document.querySelectorAll('main table'), function (t) {
    var w = document.createElement('div');
    w.className = 'table-wrap'; w.tabIndex = 0; w.setAttribute('role', 'region'); w.setAttribute('aria-label', 'Tabelle, horizontal scrollbar');
    t.parentNode.insertBefore(w, t); w.appendChild(t);
  });

  // Table of contents from h2/h3, with stable anchors.
  var list = document.getElementById('toc-list');
  var heads = Array.prototype.slice.call(document.querySelectorAll('main h2, main h3'));
  var used = {};
  heads.forEach(function (h) {
    if (!h.id) {
      var id = h.textContent.toLowerCase().replace(/ä/g, 'ae').replace(/ö/g, 'oe').replace(/ü/g, 'ue').replace(/ß/g, 'ss').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'abschnitt';
      var n = id, i = 2;
      while (used[n]) n = id + '-' + i++;
      used[n] = true; h.id = n;
    }
    var a = document.createElement('a');
    a.className = 'anchor'; a.href = '#' + h.id; a.setAttribute('aria-label', 'Link zu diesem Abschnitt'); a.textContent = '#';
    h.appendChild(a);
  });
  var tocHeads = heads.filter(function (h) { return h.tagName === 'H2'; });
  if (list && tocHeads.length > 1) {
    tocHeads.forEach(function (h) {
      var li = document.createElement('li'), a = document.createElement('a');
      a.href = '#' + h.id; a.textContent = h.firstChild.textContent; li.appendChild(a); list.appendChild(li);
    });
    if ('IntersectionObserver' in window) {
      var links = {};
      Array.prototype.forEach.call(list.querySelectorAll('a'), function (a) { links[a.getAttribute('href').slice(1)] = a; });
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting) {
            Object.keys(links).forEach(function (k) { links[k].removeAttribute('aria-current'); });
            links[e.target.id].setAttribute('aria-current', 'true');
          }
        });
      }, { rootMargin: '0px 0px -75% 0px' });
      tocHeads.forEach(function (h) { io.observe(h); });
    }
  } else {
    var aside = document.querySelector('.toc');
    if (aside) aside.hidden = true;
  }

  // Copy buttons on code blocks.
  Array.prototype.forEach.call(document.querySelectorAll('pre'), function (pre) {
    if (!navigator.clipboard) return;
    var b = document.createElement('button');
    b.type = 'button'; b.className = 'copy'; b.textContent = 'Kopieren';
    b.addEventListener('click', function () {
      navigator.clipboard.writeText(pre.querySelector('code') ? pre.querySelector('code').innerText : pre.innerText).then(function () {
        b.textContent = 'Kopiert'; setTimeout(function () { b.textContent = 'Kopieren'; }, 1600);
      }, function () { b.textContent = 'Nicht möglich'; });
    });
    pre.appendChild(b);
  });
})();
