/* Flesk: gestor de archivos (árbol + pestañas + CodeMirror + visores tipo nube). Sin dependencias externas. */
(function () {
  'use strict';
  var C = window.FLESK_FM; if (!C || !C.domain) return;
  var T = function (k) { return (C.i18n && C.i18n[k]) || k; };
  var ASSETS = C.base.replace(/files\.php$/, 'assets/');
  var $ = function (id) { return document.getElementById(id); };
  var tabs = [];            // {path, name, kind, el, cm, dirty, file}
  var active = null;
  var target = '';          // carpeta actual (relativa a la raíz del dominio)
  var targetWritable = false;

  function api(params) { var q = new URLSearchParams(Object.assign({ domain: C.domain }, params)); return C.base + '?' + q.toString(); }
  function rawUrl(path, dl) { return api({ api: 'raw', path: path, dl: dl ? '1' : '' }); }
  function getJSON(params) {
    return fetch(api(params), { credentials: 'same-origin', headers: { 'Accept': 'application/json' } })
      .then(function (r) { return r.json().catch(function () { return { ok: false, error: T('fm.err_generic') }; }); });
  }
  function post(action, data, files) {
    var fd = new FormData();
    fd.append('csrf', C.csrf); fd.append('api', action); fd.append('domain', C.domain);
    Object.keys(data || {}).forEach(function (k) { fd.append(k, data[k]); });
    (files || []).forEach(function (f) { fd.append('files[]', f, f.name); });
    return fetch(C.base, { method: 'POST', body: fd, credentials: 'same-origin' })
      .then(function (r) { return r.json().catch(function () { return { ok: false, error: r.status === 413 ? T('fm.err_upload_size').replace('%s', C.uploadMaxH) : T('fm.err_generic') }; }); });
  }
  function human(b) { if (b == null) return ''; var u = ['B', 'KB', 'MB', 'GB'], i = 0; while (b >= 1024 && i < 3) { b /= 1024; i++; } return (i ? b.toFixed(1) : b) + ' ' + u[i]; }
  function status(msg, isErr) {
    var s = $('fmStatus'); s.textContent = msg || ''; s.className = 'fm-status' + (isErr ? ' err' : msg ? ' ok' : '');
    if (msg && !isErr) setTimeout(function () { if (s.textContent === msg) { s.textContent = ''; s.className = 'fm-status'; } }, 3500);
  }
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function icon(entry) {
    if (entry.type === 'dir') return 'bi-folder-fill';
    var m = { image: 'bi-file-earmark-image', audio: 'bi-file-earmark-music', video: 'bi-file-earmark-play', pdf: 'bi-file-earmark-pdf',
      docx: 'bi-file-earmark-word', sheet: 'bi-file-earmark-spreadsheet', csv: 'bi-filetype-csv', binary: 'bi-file-earmark-zip' };
    if (m[entry.kind]) return m[entry.kind];
    var ext = (entry.name.split('.').pop() || '').toLowerCase();
    var e2 = { php: 'bi-filetype-php', html: 'bi-filetype-html', htm: 'bi-filetype-html', css: 'bi-filetype-css', js: 'bi-filetype-js',
      json: 'bi-filetype-json', md: 'bi-filetype-md', sql: 'bi-filetype-sql', txt: 'bi-filetype-txt', xml: 'bi-filetype-xml', sh: 'bi-filetype-sh', yml: 'bi-filetype-yml' };
    return e2[ext] || 'bi-file-earmark-code';
  }
  function setTarget(path, writable) {
    target = path || ''; targetWritable = !!writable;
    $('fmTarget').textContent = '/' + target; $('fmDropTarget').textContent = '/' + target;
  }

  // ---------------- Selección múltiple
  var sel = new Set(), entries = {}, anchor = null;
  function visibleRows() {
    return Array.prototype.filter.call(document.querySelectorAll('#fmRootList .fm-item'), function (li) { return li.offsetParent !== null; });
  }
  function setSel(path, on) { if (on) sel.add(path); else sel.delete(path); }
  function selClick(e, ev, on) {
    if (ev.shiftKey && anchor !== null) {
      var rows = visibleRows().map(function (li) { return li.dataset.path; });
      var a = rows.indexOf(anchor), b = rows.indexOf(e.path);
      if (a >= 0 && b >= 0) { var lo = Math.min(a, b), hi = Math.max(a, b); for (var i = lo; i <= hi; i++) setSel(rows[i], true); }
      else setSel(e.path, on);
    } else { setSel(e.path, on); anchor = e.path; }
    syncSel();
  }
  function syncSel() {
    // Olvidar rutas que ya no están en el árbol
    sel.forEach(function (p) { if (!document.querySelector('.fm-item[data-path="' + CSS.escape(p) + '"]')) sel.delete(p); });
    document.querySelectorAll('#fmRootList .fm-item').forEach(function (li) {
      var on = sel.has(li.dataset.path), cb = li.querySelector(':scope > .fm-row > .fm-check');
      if (cb) cb.checked = on; li.querySelector(':scope > .fm-row').classList.toggle('picked', on);
    });
    var n = sel.size, bar = $('fmSelBar');
    bar.hidden = n === 0; $('fmSelCount').textContent = T('fm.n_selected').replace('%s', n);
    var vis = visibleRows(), all = $('fmSelAll');
    var nv = vis.filter(function (li) { return sel.has(li.dataset.path); }).length;
    all.checked = vis.length > 0 && nv === vis.length; all.indeterminate = nv > 0 && nv < vis.length;
    var anyRO = Array.from(sel).some(function (p) { return entries[p] && !entries[p].writable; });
    $('fmSelDelete').disabled = n === 0 || anyRO;
  }
  function selectedList() { return Array.from(sel).sort(); }
  function postForm(fields) {
    var ifr = $('fmZipFrame');
    if (!ifr) { ifr = el('iframe'); ifr.id = 'fmZipFrame'; ifr.name = 'fmZipFrame'; ifr.hidden = true; document.body.appendChild(ifr); }
    var f = el('form'); f.method = 'post'; f.action = C.base; f.target = 'fmZipFrame'; f.hidden = true;
    fields.forEach(function (kv) { var i = el('input'); i.type = 'hidden'; i.name = kv[0]; i.value = kv[1]; f.appendChild(i); });
    document.body.appendChild(f); f.submit(); setTimeout(function () { f.remove(); }, 1000);
  }
  function postPaths(action, paths) {
    var fd = new FormData();
    fd.append('csrf', C.csrf); fd.append('api', action); fd.append('domain', C.domain);
    paths.forEach(function (p) { fd.append('paths[]', p); });
    return fetch(C.base, { method: 'POST', body: fd, credentials: 'same-origin' })
      .then(function (r) { return r.json().catch(function () { return { ok: false, error: T('fm.err_generic') }; }); });
  }
  function itemErrors(r) { return (r.items || []).filter(function (i) { return i.error; }).map(function (i) { return '/' + i.path + ': ' + i.error; }).join(' · '); }
  function selDownload() {
    var list = selectedList(); if (!list.length) return;
    if (list.length === 1 && entries[list[0]] && entries[list[0]].type === 'file') { window.location = rawUrl(list[0], true); return; }
    status(T('fm.zip_preparing'));
    postPaths('zipmulticheck', list).then(function (r) {
      if (!r.ok) return status(r.error + (itemErrors(r) ? ' — ' + itemErrors(r) : ''), true);
      postForm([['csrf', C.csrf], ['api', 'zipmulti'], ['domain', C.domain]].concat(list.map(function (p) { return ['paths[]', p]; })));
      status(r.name + ' · ' + r.files + ' · ' + r.sizeH);
    });
  }
  function selDelete() {
    var list = selectedList(); if (!list.length) return;
    var ul = $('fmDelList'); ul.innerHTML = '';
    list.forEach(function (p) {
      var e = entries[p] || {}, li = el('li');
      li.appendChild(el('i', 'bi ' + (e.type === 'dir' ? 'bi-folder-fill text-warning' : 'bi-file-earmark') + ' me-2'));
      li.appendChild(document.createTextNode('/' + p + (e.type === 'dir' ? '/' : '')));
      ul.appendChild(li);
    });
    $('fmDelTitleN').textContent = T('fm.confirm_delete_n').replace('%s', list.length);
    var m = bootstrap.Modal.getOrCreateInstance($('fmDelModal')); m.show();
    $('fmDelGo').onclick = function () {
      m.hide();
      postPaths('deletemulti', list).then(function (r) {
        tabs.filter(function (t) { return list.some(function (p) { return t.path === p || t.path.indexOf(p + '/') === 0; }); }).forEach(function (t) { closeTab(t, true); });
        var parents = {}; list.forEach(function (p) { var a = p.split('/'); a.pop(); parents[a.join('/')] = 1; });
        sel.clear();
        Promise.all(Object.keys(parents).map(refreshDir)).then(syncSel);
        if (!r.ok) status((r.error || T('fm.err_generic')) + (itemErrors(r) ? ' — ' + itemErrors(r) : ''), true); else status(r.message);
      });
    };
  }

  // ---------------- Árbol
  function loadDir(path, ul) {
    ul.innerHTML = ''; ul.appendChild(el('li', 'fm-loading', T('fm.loading')));
    return getJSON({ api: 'list', path: path }).then(function (r) {
      ul.innerHTML = '';
      if (!r.ok) { ul.appendChild(el('li', 'fm-err', r.error)); return; }
      r.entries.forEach(function (e) { ul.appendChild(treeItem(e)); });
      if (!r.entries.length) ul.appendChild(el('li', 'fm-emptydir', '∅'));
      syncSel();
      return r;
    });
  }
  function treeItem(e) {
    var li = el('li', 'fm-item ' + (e.type === 'dir' ? 'is-dir' : 'is-file'));
    li.dataset.path = e.path;
    var row = el('div', 'fm-row'); row.tabIndex = 0; row.title = e.path + (e.size != null ? ' · ' + human(e.size) : '') + (e.mtime ? ' · ' + e.mtime : '');
    var caret = el('i', 'bi fm-caret ' + (e.type === 'dir' ? 'bi-chevron-right' : ''));
    var ic = el('i', 'bi ' + icon(e) + ' fm-ic');
    var name = el('span', 'fm-name', e.name);
    var cb = el('input', 'form-check-input fm-check'); cb.type = 'checkbox'; cb.tabIndex = 0;
    cb.setAttribute('aria-label', T('fm.select') + ': ' + e.name); cb.checked = sel.has(e.path);
    cb.addEventListener('click', function (ev) { ev.stopPropagation(); selClick(e, ev, cb.checked); });
    cb.addEventListener('keydown', function (ev) { ev.stopPropagation(); });
    row.appendChild(cb);
    row.appendChild(caret); row.appendChild(ic); row.appendChild(name);
    entries[e.path] = e;
    // Ctrl/Cmd-clic = alternar; Mayús-clic = rango (antes que abrir/expandir)
    row.addEventListener('click', function (ev) {
      if (ev.target === cb) return;
      if (ev.ctrlKey || ev.metaKey || ev.shiftKey) {
        ev.preventDefault(); ev.stopImmediatePropagation();
        selClick(e, ev, ev.shiftKey ? true : !sel.has(e.path));
      }
    }, true);
    if (e.link) row.appendChild(el('i', 'bi bi-link-45deg text-muted ms-1'));
    if (!e.writable) row.appendChild(el('i', 'bi bi-lock fm-lock', ''));
    var acts = el('span', 'fm-acts');
    if (e.type === 'file') acts.appendChild(actBtn('bi-download', T('fm.download'), function () { window.location = rawUrl(e.path, true); }));
    if (e.type === 'dir') acts.appendChild(actBtn('bi-file-earmark-zip', T('fm.zip_folder') + ': ' + e.name, function () { doZip(e.path); }));
    if (e.writable) {
      acts.appendChild(actBtn('bi-pencil', T('fm.rename'), function () { doRename(e, li); }));
      acts.appendChild(actBtn('bi-trash', T('fm.delete'), function () { doDelete(e, li); }));
    }
    row.appendChild(acts);
    row.addEventListener('contextmenu', function (ev) { ev.preventDefault(); ctxMenu(ev, e, li); });
    li.appendChild(row);
    if (e.type === 'dir') {
      var sub = el('ul', 'fm-list'); sub.hidden = true; li.appendChild(sub);
      var toggle = function () {
        var open = sub.hidden; sub.hidden = !open;
        caret.className = 'bi fm-caret ' + (open ? 'bi-chevron-down' : 'bi-chevron-right');
        ic.className = 'bi ' + (open ? 'bi-folder2-open' : 'bi-folder-fill') + ' fm-ic';
        if (open && !li.dataset.loaded) { li.dataset.loaded = '1'; loadDir(e.path, sub); }
        selectRow(row); setTarget(e.path, e.writable);
      };
      row.addEventListener('click', toggle);
      row.addEventListener('keydown', function (ev) { if (ev.key === 'Enter') toggle(); });
    } else {
      var open = function () { selectRow(row); var p = e.path.split('/'); p.pop(); setTarget(p.join('/'), e.writable); openFile(e); };
      row.addEventListener('click', open);
      row.addEventListener('keydown', function (ev) { if (ev.key === 'Enter') open(); });
    }
    return li;
  }
  function actBtn(ic, title, fn) {
    var b = el('button', 'fm-act'); b.type = 'button'; b.title = title; b.setAttribute('aria-label', title);
    b.appendChild(el('i', 'bi ' + ic));
    b.addEventListener('click', function (ev) { ev.stopPropagation(); fn(); });
    return b;
  }
  function selectRow(row) { document.querySelectorAll('.fm-row.sel').forEach(function (r) { r.classList.remove('sel'); }); row.classList.add('sel'); }
  function findList(path) {
    if (!path) return $('fmRootList');
    var li = document.querySelector('.fm-item.is-dir[data-path="' + CSS.escape(path) + '"]');
    return li ? li.querySelector(':scope > ul') : null;
  }
  function refreshDir(path) {
    var ul = findList(path);
    if (!ul) return loadDir('', $('fmRootList'));
    if (ul !== $('fmRootList')) { ul.hidden = false; ul.parentNode.dataset.loaded = '1'; }
    return loadDir(path, ul);
  }

  // ---------------- Operaciones
  function doNew(kind) {
    var n = window.prompt(T('fm.ask_name') + ' (/' + target + ')', kind === 'mkdir' ? 'nueva-carpeta' : 'nuevo.html');
    if (!n) return;
    post(kind, { path: target, name: n.trim() }).then(function (r) {
      if (!r.ok) return status(r.error, true);
      status(r.message); refreshDir(target).then(function () { if (kind === 'newfile') openFile({ path: r.path, name: n.trim(), kind: 'text', type: 'file', writable: true }); });
    });
  }
  function doRename(e) {
    var n = window.prompt(T('fm.ask_new_name'), e.name); if (!n || n === e.name) return;
    post('rename', { path: e.path, name: n.trim() }).then(function (r) {
      if (!r.ok) return status(r.error, true);
      tabs.filter(function (t) { return t.path === e.path || t.path.indexOf(e.path + '/') === 0; }).forEach(function (t) { closeTab(t, true); });
      var p = e.path.split('/'); p.pop(); status(r.message); refreshDir(p.join('/'));
    });
  }
  function doDelete(e) {
    if (!window.confirm(T('fm.confirm_delete').replace('%s', e.path))) return;
    post('delete', { path: e.path }).then(function (r) {
      if (!r.ok) return status(r.error, true);
      tabs.filter(function (t) { return t.path === e.path || t.path.indexOf(e.path + '/') === 0; }).forEach(function (t) { closeTab(t, true); });
      var p = e.path.split('/'); p.pop(); status(r.message); refreshDir(p.join('/'));
    });
  }
  // ---------------- Descarga ZIP de carpeta (POST + CSRF; comprobación previa de límites)
  function doZip(path) {
    status(T('fm.zip_preparing'));
    post('zipcheck', { path: path }).then(function (r) {
      if (!r.ok) return status(r.error, true);
      var ifr = $('fmZipFrame');
      if (!ifr) { ifr = el('iframe'); ifr.id = 'fmZipFrame'; ifr.name = 'fmZipFrame'; ifr.hidden = true; document.body.appendChild(ifr); }
      var f = el('form'); f.method = 'post'; f.action = C.base; f.target = 'fmZipFrame'; f.hidden = true;
      [['csrf', C.csrf], ['api', 'zip'], ['domain', C.domain], ['path', path]].forEach(function (kv) {
        var i = el('input'); i.type = 'hidden'; i.name = kv[0]; i.value = kv[1]; f.appendChild(i);
      });
      document.body.appendChild(f); f.submit(); setTimeout(function () { f.remove(); }, 1000);
      status(r.name + ' · ' + r.files + ' · ' + r.sizeH);
    });
  }
  function ctxMenu(ev, e, li) {
    var old = $('fmCtx'); if (old) old.remove();
    var m = el('div', 'dropdown-menu show fm-ctx'); m.id = 'fmCtx'; m.setAttribute('role', 'menu');
    m.style.position = 'fixed'; m.style.left = ev.clientX + 'px'; m.style.top = ev.clientY + 'px';
    function item(ic, label, fn) {
      var b = el('button', 'dropdown-item'); b.type = 'button'; b.setAttribute('role', 'menuitem');
      b.appendChild(el('i', 'bi ' + ic + ' me-2')); b.appendChild(document.createTextNode(label));
      b.addEventListener('click', function () { m.remove(); fn(); }); m.appendChild(b);
    }
    if (e.type === 'dir') item('bi-file-earmark-zip', T('fm.zip_folder'), function () { doZip(e.path); });
    else item('bi-download', T('fm.download'), function () { window.location = rawUrl(e.path, true); });
    if (e.writable) {
      item('bi-pencil', T('fm.rename'), function () { doRename(e, li); });
      item('bi-trash', T('fm.delete'), function () { doDelete(e, li); });
    }
    document.body.appendChild(m);
    var close = function (x) { if (!m.contains(x.target)) { m.remove(); document.removeEventListener('mousedown', close); } };
    setTimeout(function () { document.addEventListener('mousedown', close); }, 0);
    document.addEventListener('keydown', function esc(k) { if (k.key === 'Escape') { m.remove(); document.removeEventListener('keydown', esc); } });
    var first = m.querySelector('button'); if (first) first.focus();
  }
  function doUpload(files) {
    files = Array.prototype.slice.call(files || []); if (!files.length) return;
    var big = files.filter(function (f) { return f.size > C.uploadMax; });
    if (big.length) return status(T('fm.err_upload_size').replace('%s', C.uploadMaxH) + ': ' + big[0].name, true);
    status(T('fm.loading'));
    post('upload', { path: target }, files).then(function (r) { if (!r.ok) return status(r.error, true); status(r.message); refreshDir(target); });
  }

  // ---------------- Pestañas y visores
  function modeFor(name) {
    var ext = (name.split('.').pop() || '').toLowerCase();
    var m = { php: 'application/x-httpd-php', phtml: 'application/x-httpd-php', html: 'htmlmixed', htm: 'htmlmixed', css: 'css', scss: 'text/x-scss',
      js: 'javascript', mjs: 'javascript', json: { name: 'javascript', json: true }, md: 'markdown', markdown: 'markdown', sql: 'text/x-sql',
      conf: 'nginx', ini: 'properties', env: 'properties', properties: 'properties', htaccess: 'properties', sh: 'shell', bash: 'shell',
      yml: 'yaml', yaml: 'yaml', xml: 'xml', svg: 'xml', ts: 'text/typescript', txt: null, log: null };
    if (name === '.htaccess') return 'properties';
    return Object.prototype.hasOwnProperty.call(m, ext) ? m[ext] : null;
  }
  function openFile(e) {
    var ex = tabs.filter(function (t) { return t.path === e.path; })[0];
    if (ex) return activate(ex);
    var tab = { path: e.path, name: e.name, kind: e.kind, dirty: false, file: e };
    tab.btn = el('div', 'fm-tab'); tab.btn.setAttribute('role', 'tab'); tab.btn.title = '/' + e.path;
    tab.btn.appendChild(el('i', 'bi ' + icon(e)));
    tab.label = el('span', 'fm-tab-name', e.name); tab.btn.appendChild(tab.label);
    var x = el('button', 'fm-tab-x'); x.type = 'button'; x.setAttribute('aria-label', 'x'); x.appendChild(el('i', 'bi bi-x'));
    x.addEventListener('click', function (ev) { ev.stopPropagation(); closeTab(tab); });
    tab.btn.appendChild(x);
    tab.btn.addEventListener('click', function () { activate(tab); });
    tab.btn.addEventListener('auxclick', function (ev) { if (ev.button === 1) closeTab(tab); });
    $('fmTabs').appendChild(tab.btn);
    tab.el = el('div', 'fm-pane'); $('fmView').appendChild(tab.el);
    tabs.push(tab); activate(tab);
    renderTab(tab);
  }
  function infoBar(tab, extra) {
    var bar = el('div', 'fm-infobar');
    var left = el('div', 'text-truncate'); left.appendChild(el('code', null, '/' + tab.path));
    var f = tab.file || {};
    if (f.size != null) left.appendChild(el('span', 'ms-2 text-muted', T('fm.size') + ': ' + human(f.size)));
    if (f.mtime) left.appendChild(el('span', 'ms-2 text-muted', T('fm.modified') + ': ' + f.mtime));
    if (f.writable === false) left.appendChild(el('span', 'badge badge-status-none ms-2', T('fm.readonly')));
    bar.appendChild(left);
    var right = el('div', 'd-flex gap-1 flex-shrink-0');
    (extra || []).forEach(function (b) { right.appendChild(b); });
    var dl = el('a', 'btn btn-sm btn-outline-secondary'); dl.href = rawUrl(tab.path, true); dl.appendChild(el('i', 'bi bi-download')); dl.title = T('fm.download');
    right.appendChild(dl); bar.appendChild(right);
    return bar;
  }
  function loadScript(src) {
    return new Promise(function (res, rej) { var s = document.createElement('script'); s.src = src; s.onload = res; s.onerror = rej; document.head.appendChild(s); });
  }
  function sandboxHtml(html) {
    var f = document.createElement('iframe'); f.className = 'fm-doc'; f.setAttribute('sandbox', ''); f.setAttribute('referrerpolicy', 'no-referrer');
    f.srcdoc = '<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src data:; style-src \'unsafe-inline\'">'
      + '<style>body{font-family:system-ui,sans-serif;color:#1d2b33;padding:1.25rem;line-height:1.5;max-width:960px;margin:auto}table{border-collapse:collapse;font-size:.85rem}td,th{border:1px solid #d7e2df;padding:.25rem .5rem}tr:nth-child(even) td{background:#f5faf8}img{max-width:100%}</style>'
      + html;
    return f;
  }
  function renderTab(tab) {
    var box = tab.el; box.innerHTML = '';
    var k = tab.kind;
    if (k === 'image' || k === 'audio' || k === 'video' || k === 'pdf') {
      box.appendChild(infoBar(tab));
      var wrap = el('div', 'fm-preview fm-preview-' + k), m;
      if (k === 'image') { m = el('img'); m.alt = tab.name; }
      else if (k === 'audio') { m = el('audio'); m.controls = true; }
      else if (k === 'video') { m = el('video'); m.controls = true; }
      else { m = el('iframe', 'fm-doc'); m.title = tab.name; }
      m.src = rawUrl(tab.path, false); wrap.appendChild(m); box.appendChild(wrap); return;
    }
    if (k === 'docx' || k === 'sheet' || k === 'csv') {
      box.appendChild(infoBar(tab));
      var holder = el('div', 'fm-preview fm-preview-doc'); holder.appendChild(el('div', 'text-muted p-3', T('fm.loading'))); box.appendChild(holder);
      var lib = k === 'docx' ? (window.mammoth ? Promise.resolve() : loadScript(ASSETS + 'vendor/mammoth/mammoth.browser.min.js'))
                             : (window.XLSX ? Promise.resolve() : loadScript(ASSETS + 'vendor/sheetjs/xlsx.full.min.js'));
      lib.then(function () { return fetch(rawUrl(tab.path, false), { credentials: 'same-origin' }).then(function (r) { if (!r.ok) throw new Error(r.status); return r.arrayBuffer(); }); })
        .then(function (buf) {
          if (k === 'docx') return window.mammoth.convertToHtml({ arrayBuffer: buf }).then(function (res) { return res.value; });
          var wb = k === 'csv' ? window.XLSX.read(new TextDecoder('utf-8').decode(buf), { type: 'string' }) : window.XLSX.read(new Uint8Array(buf), { type: 'array' });
          return wb.SheetNames.map(function (sn) {
            return '<h3 style="font-size:1rem;color:#0f3d35">' + sn.replace(/[<>&"]/g, '') + '</h3>' + window.XLSX.utils.sheet_to_html(wb.Sheets[sn], { header: '', footer: '' });
          }).join('');
        })
        .then(function (html) { holder.innerHTML = ''; holder.appendChild(sandboxHtml(html)); })
        .catch(function () { holder.innerHTML = ''; holder.appendChild(el('div', 'alert alert-warning m-3', T('fm.no_preview'))); });
      return;
    }
    if (k === 'binary') { renderNoPreview(tab, T('fm.no_preview')); return; }
    box.appendChild(el('div', 'text-muted p-3', T('fm.loading')));
    getJSON({ api: 'read', path: tab.path }).then(function (r) {
      if (!r.ok) { box.innerHTML = ''; box.appendChild(el('div', 'alert alert-danger m-3', r.error)); return; }
      tab.file = r.file;
      if (!r.text) { renderNoPreview(tab, r.reason); return; }
      box.innerHTML = '';
      var saveBtn = el('button', 'btn btn-sm btn-fresk-primary'); saveBtn.type = 'button';
      saveBtn.appendChild(el('i', 'bi bi-floppy me-1')); saveBtn.appendChild(document.createTextNode(T('fm.save') + ' (Ctrl+S)'));
      saveBtn.disabled = !r.file.writable; saveBtn.addEventListener('click', function () { save(tab); });
      tab.saveBtn = saveBtn;
      box.appendChild(infoBar(tab, [saveBtn]));
      var host = el('div', 'fm-editor'); box.appendChild(host);
      tab.cm = window.CodeMirror(host, {
        value: r.content, mode: modeFor(tab.name), lineNumbers: true, lineWrapping: false, indentUnit: 4, tabSize: 4,
        matchBrackets: true, autoCloseBrackets: true, autoCloseTags: true, styleActiveLine: true, readOnly: !r.file.writable,
        extraKeys: { 'Ctrl-S': function () { save(tab); }, 'Cmd-S': function () { save(tab); } }
      });
      tab.cm.setSize('100%', '100%');
      tab.cm.on('change', function () { setDirty(tab, true); });
      setTimeout(function () { tab.cm.refresh(); tab.cm.focus(); }, 30);
    });
  }
  function renderNoPreview(tab, reason) {
    var box = tab.el; box.innerHTML = ''; box.appendChild(infoBar(tab));
    var d = el('div', 'fm-empty'); d.appendChild(el('i', 'bi ' + icon(tab.file || tab) + ' display-5 text-success'));
    d.appendChild(el('p', 'mt-2 mb-2', reason || T('fm.no_preview')));
    var a = el('a', 'btn btn-fresk-primary btn-sm'); a.href = rawUrl(tab.path, true); a.appendChild(el('i', 'bi bi-download me-1')); a.appendChild(document.createTextNode(T('fm.download')));
    d.appendChild(a); box.appendChild(d);
  }
  function setDirty(tab, d) { tab.dirty = d; tab.btn.classList.toggle('dirty', d); tab.label.title = d ? T('fm.unsaved') : ''; }
  function save(tab) {
    if (!tab.cm || tab.cm.getOption('readOnly')) return;
    post('save', { path: tab.path, content: tab.cm.getValue() }).then(function (r) {
      if (!r.ok) return status(r.error, true);
      setDirty(tab, false); status(T('fm.saved') + ': /' + tab.path);
    });
  }
  function activate(tab) {
    active = tab;
    tabs.forEach(function (t) { var on = t === tab; t.btn.classList.toggle('active', on); t.btn.setAttribute('aria-selected', on ? 'true' : 'false'); t.el.hidden = !on; });
    $('fmEmpty').hidden = !!tab;
    if (tab && tab.cm) setTimeout(function () { tab.cm.refresh(); }, 10);
  }
  function closeTab(tab, force) {
    if (!force && tab.dirty && !window.confirm(T('fm.confirm_close'))) return;
    var i = tabs.indexOf(tab); if (i < 0) return;
    tabs.splice(i, 1); tab.btn.remove(); tab.el.remove();
    if (active === tab) activate(tabs[i] || tabs[i - 1] || null);
    if (!tabs.length) $('fmEmpty').hidden = false;
  }
  window.addEventListener('beforeunload', function (ev) { if (tabs.some(function (t) { return t.dirty; })) { ev.preventDefault(); ev.returnValue = ''; } });
  document.addEventListener('keydown', function (ev) {
    if ((ev.ctrlKey || ev.metaKey) && ev.key.toLowerCase() === 's' && active && active.cm) { ev.preventDefault(); save(active); }
  });

  // ---------------- Toolbar + drag & drop
  document.querySelectorAll('[data-fm]').forEach(function (b) {
    b.addEventListener('click', function () {
      var a = b.getAttribute('data-fm');
      if (a === 'newfile' || a === 'mkdir') doNew(a);
      else if (a === 'upload') $('fmUploadInput').click();
      else if (a === 'refresh') refreshDir(target);
      else if (a === 'zip') doZip(target);
    });
  });
  $('fmUploadInput').addEventListener('change', function () { doUpload(this.files); this.value = ''; });
  var shell = $('fmShell'), drop = $('fmDrop'), depth = 0;
  shell.addEventListener('dragenter', function (ev) { if (ev.dataTransfer && Array.prototype.indexOf.call(ev.dataTransfer.types, 'Files') >= 0) { depth++; drop.classList.add('on'); ev.preventDefault(); } });
  shell.addEventListener('dragover', function (ev) { if (drop.classList.contains('on')) ev.preventDefault(); });
  shell.addEventListener('dragleave', function () { depth = Math.max(0, depth - 1); if (!depth) drop.classList.remove('on'); });
  shell.addEventListener('drop', function (ev) { ev.preventDefault(); depth = 0; drop.classList.remove('on'); doUpload(ev.dataTransfer.files); });

  $('fmSelAll').addEventListener('change', function () {
    var on = this.checked; visibleRows().forEach(function (li) { setSel(li.dataset.path, on); }); syncSel();
  });
  $('fmSelDownload').addEventListener('click', selDownload);
  $('fmSelDelete').addEventListener('click', selDelete);
  $('fmSelClear').addEventListener('click', function () { sel.clear(); syncSel(); });
  document.querySelectorAll('[data-fm-zip]').forEach(function (b) { b.addEventListener('click', function () { doZip(b.getAttribute('data-fm-zip')); }); });
  document.querySelectorAll('[data-fm-root]').forEach(function (b) { b.addEventListener('click', function () { document.querySelectorAll('.fm-row.sel').forEach(function (r) { r.classList.remove('sel'); }); setTarget('', false); }); });
  // Inicio: raíz del dominio y abrir httpdocs
  setTarget('', false);
  loadDir('', $('fmRootList')).then(function () {
    var h = document.querySelector('.fm-item.is-dir[data-path="httpdocs"] > .fm-row');
    if (h) h.click();
  });
  // API mínima para pruebas automatizadas
  window.FLESK_FM_API = { selected: function () { return selectedList(); }, zip: function (p) { doZip(p); }, open: function (p, kind) { openFile({ path: p, name: p.split('/').pop(), kind: kind || 'text', type: 'file' }); } };
})();
