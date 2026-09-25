/* Atmovio – interakce (Alpine.js komponenty + pomocné funkce). */
(function () {
  'use strict';

  // ---------- Alpine komponenty ----------
  document.addEventListener('alpine:init', function () {
    // Kostra stránky: mobilní menu, rozbalovací nabídky v hlavičce (dd), přepínač vzhledu, toasty, lightbox.
    Alpine.data('shell', function (opts) {
      opts = opts || {};
      return {
        menu: false,
        dd: '',
        theme: document.documentElement.getAttribute('data-theme') || 'dark',
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
        toggleTheme: function () {
          this.theme = this.theme === 'dark' ? 'light' : 'dark';
          document.documentElement.setAttribute('data-theme', this.theme);
          try { localStorage.setItem('atmovio-theme', this.theme); } catch (e) { /* soukromý režim */ }
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

    // ---------- Odpočet „zbývá asi …“ mezi obnoveními stránky ----------
    Alpine.data('countdown', function (seconds) {
      return {
        left: Math.max(0, seconds || 0), txt: '',
        fmt: function () { var s = this.left; if (s <= 0) return 'už jen chvilku…'; return 'zbývá asi ' + (s >= 90 ? Math.round(s / 60) + ' min' : (s >= 10 ? Math.round(s / 5) * 5 : s) + ' s'); },
        init: function () { var self = this; self.txt = self.fmt(); setInterval(function () { if (self.left > 0) self.left -= 1; self.txt = self.fmt(); }, 1000); }
      };
    });

    // ---------- Propojení YouTube: sleduje stav zadání kódu na google.com/device ----------
    Alpine.data('ytLink', function (active) {
      return {
        st: {},
        init: function () {
          var self = this;
          function poll() {
            fetch('/studio/youtube/status', { credentials: 'same-origin' }).then(function (r) { return r.json(); }).then(function (d) {
              self.st = d || {};
              if (d.status === 'done') { location.href = '/studio/settings#youtube'; location.reload(); return; }
              if (d.status === 'waiting') setTimeout(poll, 4000);
            }).catch(function () { setTimeout(poll, 8000); });
          }
          if (active) poll();
        }
      };
    });

    // ---------- Hledání hudby (Openverse) přímo u videa ----------
    Alpine.data('musicFinder', function (initial) {
      return {
        q: '', len: '', items: [], msg: '', busy: false, open: false, music: initial || '',
        search: function () {
          var self = this;
          if (self.q.trim().length < 2) { self.msg = 'Zadej aspoň dvě písmena.'; return; }
          self.busy = true; self.msg = 'Hledám…'; self.items = [];
          fetch('/studio/music/search?q=' + encodeURIComponent(self.q.trim()) + '&length=' + encodeURIComponent(self.len), { credentials: 'same-origin' })
            .then(function (r) { return r.json(); })
            .then(function (d) { self.items = d.items || []; self.msg = d.error || (self.items.length + ' skladeb – přehraj si je a klikni Použít'); })
            .catch(function () { self.msg = 'Hledání selhalo – RPi nejspíš nemá přístup na internet.'; })
            .finally(function () { self.busy = false; });
        },
        use: function (t) {
          var self = this, fd = new FormData();
          var csrf = document.querySelector('input[name=csrf_token]');
          fd.append('csrf_token', csrf ? csrf.value : '');
          ['id', 'url', 'title', 'creator', 'license', 'attribution', 'page', 'filetype'].forEach(function (k) { fd.append(k, t[k] || ''); });
          self.busy = true; self.msg = 'Stahuji „' + t.title + '“ na RPi…';
          fetch('/studio/music/fetch', { method: 'POST', body: fd, credentials: 'same-origin' })
            .then(function (r) { return r.json(); })
            .then(function (d) {
              if (!d.ok) { self.msg = d.error || 'Stažení selhalo.'; return; }
              var sel = self.$refs.sel;
              if (![].some.call(sel.options, function (o) { return o.value === d.name; })) { var o = document.createElement('option'); o.value = d.name; o.textContent = d.name; sel.appendChild(o); }
              self.music = d.name; sel.value = d.name; t.name = d.name;
              self.msg = 'Vybráno: ' + d.name + '. Autor se doplní do popisu videa.';
            })
            .catch(function () { self.msg = 'Stažení selhalo.'; })
            .finally(function () { self.busy = false; });
        }
      };
    });

  // ---------- Náhled rychlosti ve studiu: přehraje zdrojové video tak, jak bude vypadat zrychlené ----------
    // Do 16× nativně, výš skoky v čase (jako v přehrávači). Orientační – hotové video je plynulé.
    Alpine.data('speedPreview', function (src, speed) {
      return {
        src: src, on: false, speed: speed || 20, running: false, timer: null, seekHandler: null, pos: '',
        fmt: function (t) { t = Math.max(1, Math.round(t || 0)); return Math.floor(t / 60) + ':' + ('0' + t % 60).slice(-2); },
      // Odhad doby vytváření na RPi 5: dekódování všech snímků (do 120×) nebo jen klíčových, + kódování ~35 sn./s v 1080p.
      eta: function (dur, fps, width) {
        var px = Math.min(1, (width || 1920) / 1920) || 1;
        var decode = this.speed >= 120 ? dur / 40 : dur * (fps || 25) / (260 / px);
        var encode = (dur / this.speed) * 30 / (35 / px);
        var s = Math.max(5, decode + encode + 3);
        return s < 90 ? 'asi ' + Math.round(s / 10) * 10 + ' s' : 'asi ' + Math.round(s / 60) + ' min';
      },
        get video() { return this.$refs.v; },
        stop: function () {
          this.running = false;
          if (this.timer) { clearTimeout(this.timer); this.timer = null; }
          if (this.seekHandler) { this.video.removeEventListener('seeked', this.seekHandler); this.seekHandler = null; }
          this.video.pause();
        },
        tick: function () {
          var self = this, v = this.video, ms = this.speed >= 120 ? 250 : 125;
          if (!self.running) return;
          if (!isFinite(v.duration)) { self.stop(); return; }
        if (v.currentTime >= v.duration - 0.05) { v.currentTime = 0; }   // dokola, dokud to uživatel nezavře
          var t0 = performance.now();
          self.seekHandler = function () {
            v.removeEventListener('seeked', self.seekHandler); self.seekHandler = null;
            self.pos = self.fmt(v.currentTime) + ' / ' + self.fmt(v.duration);
            if (!self.running) return;
            self.timer = setTimeout(function () { self.tick(); }, Math.max(0, ms - (performance.now() - t0)));
          };
          v.addEventListener('seeked', self.seekHandler);
          v.currentTime = Math.min(v.duration, v.currentTime + self.speed * ms / 1000);
        },
        play: function (speed) {
          var self = this, v = this.video;
          this.speed = speed; this.on = true; this.stop();
          if (!v.src) { v.src = this.src; }
          v.muted = true; v.loop = true;
          var go = function () {
            v.currentTime = 0;
            if (self.speed <= 16) { v.playbackRate = self.speed; v.play().catch(function () {}); }
            else { v.playbackRate = 1; self.running = true; self.tick(); }
          };
          if (v.readyState >= 1) go(); else v.addEventListener('loadedmetadata', go, { once: true });
        },
        init: function () {
          var self = this;
          this.$watch('speed', function (s) { if (self.on) self.play(s); });
          this.$refs.v.addEventListener('timeupdate', function () { if (self.speed <= 16) self.pos = self.fmt(self.video.currentTime) + ' / ' + self.fmt(self.video.duration); });
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
