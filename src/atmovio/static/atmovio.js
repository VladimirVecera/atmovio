/* Atmovio – interakce (Alpine.js komponenty + pomocné funkce). */
(function () {
  'use strict';

  // ---------- Alpine komponenty ----------
  document.addEventListener('alpine:init', function () {
    // Kostra stránky: mobilní menu, rozbalená skupina Nastavení, toasty, lightbox.
    Alpine.data('shell', function (opts) {
      opts = opts || {};
      return {
        menu: false,
        settingsOpen: !!opts.settingsOpen,
        toasts: [],
        lb: { open: false, src: '', caption: '', items: [], index: -1 },
        init: function () {
          var self = this;
          (opts.flashes || []).forEach(function (f) { self.toast(f.text, f.kind); });
          document.addEventListener('keydown', function (e) {
            if (e.key === 'Escape') { self.lb.open = false; self.menu = false; document.body.classList.remove('lb-open'); }
            if (self.lb.open && e.key === 'ArrowRight') self.lbStep(1);
            if (self.lb.open && e.key === 'ArrowLeft') self.lbStep(-1);
          });
          document.addEventListener('click', function (e) {
            var a = e.target.closest('a[data-lightbox]');
            if (!a) return;
            e.preventDefault();
            var group = a.dataset.lightbox || '';
            var links = group ? Array.prototype.slice.call(document.querySelectorAll('a[data-lightbox="' + group + '"]')) : [a];
            self.lb.items = links.map(function (l) { return { src: l.href, caption: l.dataset.caption || '' }; });
            self.lb.index = Math.max(0, links.indexOf(a));
            self.lbShow();
          });
        },
        toast: function (text, kind) {
          var id = Date.now() + Math.random();
          this.toasts.push({ id: id, text: text, kind: kind || '' });
          if (kind !== 'err') {
            var self = this;
            setTimeout(function () { self.dismiss(id); }, 7000);
          }
        },
        dismiss: function (id) { this.toasts = this.toasts.filter(function (t) { return t.id !== id; }); },
        lbShow: function () {
          var it = this.lb.items[this.lb.index];
          if (!it) return;
          this.lb.src = it.src; this.lb.caption = it.caption; this.lb.open = true;
          document.body.classList.add('lb-open');
        },
        lbClose: function () { this.lb.open = false; this.lb.src = ''; document.body.classList.remove('lb-open'); },
        lbStep: function (d) {
          if (this.lb.items.length < 2) return;
          this.lb.index = (this.lb.index + d + this.lb.items.length) % this.lb.items.length;
          this.lbShow();
        }
      };
    });

    // Automatické obnovení stránky (dashboard, logy) – ne při otevřeném obrázku, menu nebo rozepsaném formuláři.
    Alpine.data('autorefresh', function (seconds) {
      return {
        init: function () {
          var self = this;
          function tick() {
            var busy = document.querySelector('form:focus-within') || document.body.classList.contains('lb-open') ||
              document.querySelector('details[open][data-keep]');
            if (!busy && document.visibilityState === 'visible') location.reload(); else setTimeout(tick, 15000);
          }
          setTimeout(tick, (seconds || 60) * 1000);
        }
      };
    });

    // Průběh aktualizace Atmovio (/system/update): každé 3 s se ptá /system/update/status.
    // Během restartu služby dotaz selže – to je normální fáze "restart"; hotovo = odpověď s jinou verzí.
    Alpine.data('updater', function (running, version, log) {
      return {
        running: !!running, version: version, log: log || '', phase: running ? 'run' : '', newVersion: '', idle: 0,
        init: function () { if (this.running) this.poll(); },
        later: function () { var self = this; setTimeout(function () { self.poll(); }, 3000); },
        poll: function () {
          var self = this;
          fetch('/system/update/status', { credentials: 'same-origin', cache: 'no-store' })
            .then(function (r) { if (!r.ok || r.redirected) throw new Error('nedostupné'); return r.json(); })
            .then(function (s) {
              if (s.log) self.log = s.log;
              if (s.version && s.version !== self.version) { self.phase = 'done'; self.newVersion = s.version; self.running = false; return; }
              if (s.running) { self.phase = 'run'; self.idle = 0; self.later(); return; }
              // Jednotka skončila a verze je stejná: buď rollback (poznáme z logu), nebo se ještě nerozběhla.
              if (/selhala|obnovuji|rollback/i.test(self.log) || ++self.idle > 10) { self.phase = 'failed'; self.running = false; return; }
              self.phase = 'run'; self.later();
            })
            .catch(function () { self.phase = 'restart'; self.later(); });
        }
      };
    });
  });

  // ---------- Odeslání formuláře: zablokovat tlačítko a ukázat, co se děje ----------
  var HINTS = [
    ['/cameras/add', 'Ověřuji kameru a čekám na skutečné snímky z každé adresy – může to trvat i několik minut, pak se restartuje nahrávání.'],
    ['/discover', 'Prohledávám síť a ověřuji každou nalezenou adresu – i několik minut.'],
    ['/storage/disk', 'Připravuji disk – formátování a připojení trvá do minuty.'],
    ['/ai/test', 'Beru snímek z kamery a posílám ho AI – do půl minuty.'],
    ['/ai/check', 'Ověřuji klíč u poskytovatele AI.'],
    ['/system/ctl', 'Provádím akci; služby se restartují.'],
    ['/system/update/check', 'Ptám se GitHubu na poslední vydání.'],
  ];
  function installBusy() {
    var busy = document.getElementById('busy');
    if (!busy) return;
    var txt = document.getElementById('busy-text'), hint = document.getElementById('busy-hint');
    document.addEventListener('submit', function (e) {
      var f = e.target;
      if (!(f instanceof HTMLFormElement) || f.dataset.nobusy !== undefined || f.method.toLowerCase() === 'get') return;
      var btn = e.submitter || f.querySelector('button:not([type=button]),[type=submit]');
      var label = (btn && (btn.dataset.busy || btn.textContent.trim())) || 'Odesílám';
      setTimeout(function () {
        if (e.defaultPrevented) return;
        if (btn) { btn.disabled = true; btn.dataset.label = btn.textContent; btn.textContent = label.replace(/^[^\wÀ-ž]+/, '') + '…'; }
        txt.textContent = label + '…';
        var action = f.getAttribute('action') || '';
        var h = HINTS.filter(function (x) { return action.indexOf(x[0]) > -1; })[0];
        hint.textContent = h ? h[1] : 'Stránka se sama obnoví, až bude hotovo.';
        busy.hidden = false;
      }, 0);
    }, true);
    window.addEventListener('pageshow', function () {
      busy.hidden = true;
      document.querySelectorAll('button[disabled][data-label]').forEach(function (b) { b.disabled = false; b.textContent = b.dataset.label; });
    });
  }

  // ---------- Kopírování do schránky (funguje i na http bez certifikátu) ----------
  window.swCopy = function (el, btn) {
    var node = typeof el === 'string' ? document.getElementById(el) : el;
    if (!node) return;
    var text = node.value !== undefined ? node.value : node.textContent;
    function done(ok) {
      if (!btn) return;
      var old = btn.textContent;
      btn.textContent = ok ? 'Zkopírováno ✓' : 'Vyber text a stiskni Ctrl/Cmd+C';
      setTimeout(function () { btn.textContent = old; }, 2500);
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(false); });
      return;
    }
    var r = document.createRange(); r.selectNodeContents(node);
    var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
    try { done(document.execCommand('copy')); } catch (e) { done(false); }
  };

  // ---------- Náhledy kamer: když obrázek nejde, ukázat text místo prázdna ----------
  window.swImgFail = function (img, text) {
    img.style.display = 'none';
    var s = document.createElement('span'); s.textContent = text || 'bez obrazu';
    img.parentNode.appendChild(s);
  };

  // ---------- Kamery: snímky se samy obnovují, živý přenos jen na kliknutí ----------
  function installSnapshots() {
    document.querySelectorAll('img[data-refresh]').forEach(function (img) {
      var sec = Math.max(3, parseInt(img.dataset.refresh, 10) || 10);
      var base = img.dataset.snap || img.getAttribute('src').replace(/[?&]t=\d+/, '');
      img.dataset.snap = base;
      setInterval(function () {
        if (document.visibilityState !== 'visible' || img.dataset.live === '1' || document.body.classList.contains('lb-open')) return;
        img.src = base + (base.indexOf('?') > -1 ? '&' : '?') + 't=' + Date.now();
      }, sec * 1000);
    });
  }
  window.swLiveToggle = function (btn) {
    var img = document.getElementById(btn.dataset.target);
    if (!img) return;
    if (img.dataset.live === '1') {
      img.dataset.live = '0';
      img.src = img.dataset.snap + (img.dataset.snap.indexOf('?') > -1 ? '&' : '?') + 't=' + Date.now();
      btn.textContent = '▶ Spustit živý přenos'; btn.classList.remove('sec');
    } else {
      img.dataset.live = '1';
      img.src = img.dataset.stream + '&t=' + Date.now();
      btn.textContent = '⏹ Zastavit živý přenos'; btn.classList.add('sec');
    }
  };
  // Při opuštění stránky přenos ukončit (prohlížeč jinak drží spojení do bfcache).
  window.addEventListener('pagehide', function () {
    document.querySelectorAll('img[data-live="1"]').forEach(function (img) { img.src = ''; });
  });

  // ---------- Přehrávač videa přes celou obrazovku (s rychlostí až 120×) ----------
  // Do 16× používá nativní playbackRate (víc prohlížeče nedovolí); vyšší rychlosti se dělají
  // skokovým posunem času (timelapse) – funguje i na 60× a 120×.
  var SPEEDS = [1, 2, 4, 8, 16, 30, 60, 120];
  window.swPlayVideo = function (src, title) {
    var old = document.getElementById('sw-player');
    if (old) old.remove();
    var box = document.createElement('div');
    box.id = 'sw-player'; box.className = 'lightbox player';
    box.innerHTML = '<button type="button" class="close" aria-label="Zavřít">×</button><figure><video controls autoplay muted playsinline preload="metadata"></video>' +
      '<div class="speeds"><span class="lbl">Rychlost</span>' +
      SPEEDS.map(function (v) { return '<button type="button" data-v="' + v + '"' + (v === 1 ? ' class="on"' : '') + '>' + v + '×</button>'; }).join('') +
      '<button type="button" class="pp" hidden>⏸</button><span class="pos"></span></div><figcaption></figcaption></figure>';
    var video = box.querySelector('video'), bar = box.querySelector('.speeds'), pp = box.querySelector('.pp'), pos = box.querySelector('.pos');
    video.src = src;
    box.querySelector('figcaption').textContent = title || '';
    var step = { speed: 0, timer: null, running: false, seekHandler: null };
    function fmt(t) { t = Math.max(0, Math.floor(t || 0)); return Math.floor(t / 60) + ':' + ('0' + t % 60).slice(-2); }
    function showPos() { if (isFinite(video.duration)) pos.textContent = fmt(video.currentTime) + ' / ' + fmt(video.duration); }
    function stopStep() {
      step.running = false;
      if (step.timer) { clearTimeout(step.timer); step.timer = null; }
      if (step.seekHandler) { video.removeEventListener('seeked', step.seekHandler); step.seekHandler = null; }
      pp.textContent = '▶';
    }
    function tick() {
      if (!step.running) return;
      if (!isFinite(video.duration) || video.currentTime >= video.duration - 0.05) { stopStep(); return; }
      var t0 = performance.now();
      step.seekHandler = function () {
        video.removeEventListener('seeked', step.seekHandler); step.seekHandler = null;
        showPos();
        if (!step.running) return;
        step.timer = setTimeout(tick, Math.max(0, 125 - (performance.now() - t0)));
      };
      video.addEventListener('seeked', step.seekHandler);
      video.currentTime = Math.min(video.duration, video.currentTime + step.speed * 0.125);
    }
    function startStep() { if (step.running) return; video.pause(); step.running = true; pp.textContent = '⏸'; tick(); }
    function setSpeed(v) {
      stopStep();
      bar.querySelectorAll('button[data-v]').forEach(function (b) { b.classList.toggle('on', +b.dataset.v === v); });
      if (v <= 16) {
        step.speed = 0; pp.hidden = true;
        video.playbackRate = v; video.muted = v > 1 || video.muted;
        if (video.paused) video.play().catch(function () {});
      } else {
        step.speed = v; pp.hidden = false;
        video.playbackRate = 1;
        startStep();
      }
    }
    bar.addEventListener('click', function (e) {
      var b = e.target.closest('button[data-v]');
      if (b) { setSpeed(+b.dataset.v); return; }
      if (e.target === pp) { if (step.running) stopStep(); else startStep(); }
    });
    // V režimu skoků nativní tlačítko Play jen znovu spustí skákání.
    video.addEventListener('play', function () { if (step.speed > 16 && !step.running) { video.pause(); startStep(); } });
    video.addEventListener('timeupdate', function () { if (!step.speed) showPos(); });
    video.addEventListener('loadedmetadata', showPos);
    function close() { stopStep(); video.pause(); video.removeAttribute('src'); video.load(); box.remove(); document.body.classList.remove('lb-open'); document.removeEventListener('keydown', onKey); }
    function onKey(e) {
      if (e.key === 'Escape') close();
      if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
        var cur = step.speed || video.playbackRate, i = SPEEDS.indexOf(cur);
        if (i < 0) i = 0;
        i = Math.max(0, Math.min(SPEEDS.length - 1, i + (e.key === 'ArrowUp' ? 1 : -1)));
        setSpeed(SPEEDS[i]); e.preventDefault();
      }
    }
    box.querySelector('.close').addEventListener('click', close);
    box.addEventListener('click', function (e) { if (e.target === box) close(); });
    document.addEventListener('keydown', onKey);
    document.body.appendChild(box); document.body.classList.add('lb-open');
    return false;
  };

  function boot() { installBusy(); installSnapshots(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
