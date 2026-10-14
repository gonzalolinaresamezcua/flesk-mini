/* Flesk UI: mostrar/ocultar contraseña y captcha deslizante. Sin dependencias. */
(function () {
  'use strict';
  // --- Modales: moverlos a <body> para que no queden atrapados en el contexto
  // de apilamiento de .fresk-main (z-index:1), que dejaba el backdrop encima.
  document.querySelectorAll('.modal').forEach(function (m) {
    if (m.parentNode !== document.body) document.body.appendChild(m);
  });
  // --- Ojo mostrar/ocultar contraseña ---
  document.querySelectorAll('[data-pw-toggle]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var inp = document.getElementById(btn.getAttribute('data-pw-toggle'));
      if (!inp) return;
      var show = inp.type === 'password';
      inp.type = show ? 'text' : 'password';
      var label = btn.getAttribute(show ? 'data-label-hide' : 'data-label-show');
      btn.setAttribute('aria-label', label); btn.title = label;
      btn.setAttribute('aria-pressed', show ? 'true' : 'false');
      var i = btn.querySelector('i'); if (i) i.className = 'bi ' + (show ? 'bi-eye-slash' : 'bi-eye');
      inp.focus();
    });
  });

  // --- Captcha deslizante (coordenadas lógicas W px escaladas al ancho real) ---
  document.querySelectorAll('[data-captcha]').forEach(function (box) {
    var W = parseInt(box.getAttribute('data-w'), 10), P = parseInt(box.getAttribute('data-piece'), 10), MAX = W - P;
    var stage = box.querySelector('.fresk-captcha-stage');
    var handle = box.querySelector('.fresk-captcha-handle'), piece = box.querySelector('.fresk-captcha-piece');
    var fill = box.querySelector('.fresk-captcha-fill');
    var inX = box.querySelector('input[name=captcha_x]'), inT = box.querySelector('input[name=captcha_trace]');
    var pos = 0, dragging = false, startX = 0, startPos = 0, t0 = null, trace = [];
    function scale() { return (stage.clientWidth || W) / W; }
    function now() { return Math.round(performance.now()); }
    function paint() {
      var px = pos * scale();
      handle.style.transform = piece.style.transform = 'translateX(' + px + 'px)';
      fill.style.width = (px + P * scale() / 2) + 'px';
    }
    function set(p, record) {
      pos = Math.max(0, Math.min(MAX, Math.round(p)));
      paint();
      handle.setAttribute('aria-valuenow', String(pos));
      if (record) {
        if (t0 === null) t0 = now();
        trace.push([now() - t0, pos]);
        if (trace.length > 500) trace.splice(1, 1);
      }
      inX.value = String(pos); inT.value = JSON.stringify(trace);
      box.classList.toggle('moved', pos > 0);
    }
    function pointX(ev) { return ev.touches && ev.touches.length ? ev.touches[0].clientX : ev.clientX; }
    function down(ev) {
      dragging = true; startX = pointX(ev); startPos = pos; box.classList.add('dragging');
      if (t0 === null) { t0 = now(); trace.push([0, pos]); }
      ev.preventDefault();
    }
    function move(ev) { if (!dragging) return; set(startPos + (pointX(ev) - startX) / scale(), true); ev.preventDefault(); }
    function up() { if (!dragging) return; dragging = false; box.classList.remove('dragging'); box.classList.add('done'); set(pos, true); }
    handle.addEventListener('mousedown', down); piece.addEventListener('mousedown', down);
    handle.addEventListener('touchstart', down, { passive: false }); piece.addEventListener('touchstart', down, { passive: false });
    window.addEventListener('mousemove', move); window.addEventListener('touchmove', move, { passive: false });
    window.addEventListener('mouseup', up); window.addEventListener('touchend', up); window.addEventListener('touchcancel', up);
    window.addEventListener('resize', paint);
    handle.addEventListener('keydown', function (ev) {
      var step = ev.shiftKey ? 10 : 2;
      if (ev.key === 'ArrowRight' || ev.key === 'ArrowUp') { set(pos + step, true); ev.preventDefault(); }
      else if (ev.key === 'ArrowLeft' || ev.key === 'ArrowDown') { set(pos - step, true); ev.preventDefault(); }
      else if (ev.key === 'Home') { set(0, true); ev.preventDefault(); }
    });
    set(0, false);
  });
})();
