/* Atmovio – interakce (Alpine.js komponenty + pomocné funkce). */
(function () {
  'use strict';

  // Legacy server-rendered forms: associate adjacent labels with their existing controls.
  document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('.page label:not([for])').forEach(function (label, index) {
      if (label.querySelector('input,select,textarea')) return;
      var control = label.nextElementSibling;
      if (!control || !control.matches('input:not([type=hidden]),select,textarea')) return;
      if (!control.id) control.id = 'at-field-' + index;
      label.htmlFor = control.id;
    });
  });

  // ---------- Alpine komponenty ----------
  document.addEventListener('alpine:init', function () {
    Alpine.data('youtubeUpload', function (id, initial) {
      return {state:initial, offline:false, timer:null, stopped:false,
        init: function () { this.check(); },
        destroy: function () { this.stopped=true; clearTimeout(this.timer); },
        check: async function () {
          if (this.stopped) return;
          const controller=new AbortController(), timeout=setTimeout(()=>controller.abort(),10000);
          try {
            if (document.visibilityState!=='visible') return;
            const r=await fetch('/studio/v/'+id+'/youtube/progress', {cache:'no-store',signal:controller.signal});
            if (!r.ok || r.redirected) throw new Error('Unavailable');
            const state=await r.json();
            if (!state.label || !state.status) throw new Error('Invalid status');
            this.state=state; this.offline=false;
          } catch (_) { this.offline=true; }
          finally { clearTimeout(timeout); if (!this.stopped && ['queued','uploading'].includes(this.state.status)) this.timer=setTimeout(()=>this.check(),3000); }
        }
      };
    });
    Alpine.data('videoStatus', function (id, initial) {
      return {state:initial, offline:false, timer:null, stopped:false,
        init: function () { this.timer=setTimeout(()=>this.check(),20000); },
        destroy: function () { this.stopped=true; clearTimeout(this.timer); },
        check: async function () {
          if (this.stopped) return;
          const controller=new AbortController(), timeout=setTimeout(()=>controller.abort(),10000);
          try {
            if (document.visibilityState!=='visible') return;
            const response=await fetch('/detection/'+id+'/video-status', {cache:'no-store',signal:controller.signal});
            if (!response.ok || response.redirected) throw new Error('Status unavailable');
            const state=await response.json();
            if (!state.title || !state.tone) throw new Error('Invalid status');
            this.state=state; this.offline=false;
          } catch (_) { this.offline=true; }
          finally { clearTimeout(timeout); if (!this.stopped) this.timer=setTimeout(()=>this.check(),20000); }
        }
      };
    });
    Alpine.data('serviceStatus', function () {
      return {message:'', recovered:false, waiting:false, timer:null, stopped:false, dirty:false,
        init: function () {
          this.onEdit = () => { this.dirty = true; };
          document.addEventListener('input', this.onEdit); document.addEventListener('change', this.onEdit);
          this.check();
        },
        destroy: function () { this.stopped=true; clearTimeout(this.timer); document.removeEventListener('input',this.onEdit); document.removeEventListener('change',this.onEdit); },
        check: async function () {
          if (this.stopped) return;
          const controller=new AbortController(), timeout=setTimeout(()=>controller.abort(),12000);
          try {
            if (document.visibilityState!=='visible') return;
            const r=await fetch('/system/runtime-status',{credentials:'same-origin',cache:'no-store',signal:controller.signal});
            if (!r.ok || r.redirected) return;
            const state=await r.json();
            if (!state.ready) {
              this.waiting=true; this.recovered=false;
              this.message=state.storage.mode==='error' ? 'Nahrávání se nepodařilo obnovit: '+state.storage.reason : state.waiting ? 'Frigate se restartuje. Obraz a stav se po návratu obnoví automaticky.' :
                (!state.online ? 'Frigate nyní neodpovídá. Čekám na obnovení spojení.' : state.storage.reason);
            } else if (this.waiting) {
              this.message=state.storage.mode==='recording' ? 'Frigate opět odpovídá a disk je připravený pro nahrávání.' : 'Frigate opět odpovídá. '+state.storage.reason;
              this.recovered=true; this.waiting=false;
              if (!this.dirty && ['/system/maintenance','/storage','/videos','/live','/live/all','/'].includes(location.pathname)
                  && !Array.from(document.querySelectorAll('video')).some(v=>!v.paused) && !document.body.classList.contains('lb-open')) location.reload();
            } else if (state.storage.mode==='live') { this.message=state.storage.reason; }
          } catch(e) { this.waiting=true; this.message='Spojení s Atmovio je přerušené. Zkouším ho automaticky obnovit.'; }
          finally { clearTimeout(timeout); if (!this.stopped) this.timer=setTimeout(()=>this.check(),10000); }
        }
      };
    });
    Alpine.data('filmTiming', function (mode, active, sample, span, limit) {
      return {
        mode: mode, active: active, sample: sample, span: span, limit: limit || 36, automatic: Number(span) === Math.max(10,Math.min(180,(Number(limit || 36)-1)*Number(sample))),
        recommend: function () { this.active=true; this.mode='batch'; this.sample=5; this.limit=9; this.automatic=true; this.syncDuration(); },
        syncDuration: function () {
          if (!this.automatic || this.mode!=='batch' || !this.active) return;
          if (!Number.isInteger(Number(this.sample)) || Number(this.sample)<1 || !Number.isInteger(Number(this.limit)) || Number(this.limit)<3) return;
          this.span=Math.max(10,Math.min(180,(this.capacity-1)*Math.min(1440,Number(this.sample))));
        },
        get capacity() { return Math.max(3,Math.min(36,Math.floor(Number(this.limit)||36))); },
        get columns() { return Math.min(this.count<=9 ? 3 : 4,this.count); },
        get photoSize() { return this.count<=9 ? '720 × 405' : '480 × 270'; },
        get sheetSize() { return (this.columns*(this.count<=9 ? 720 : 480))+' × '+(Math.ceil(this.count/this.columns)*(this.count<=9 ? 435 : 300)); },
        get sheetTiles() {
          return Array.from({length:Math.ceil(this.count/this.columns)*this.columns},(_,i)=>({index:i,empty:i>=this.count,minute:Math.min(this.filmLength,i*this.interval)}));
        },
        get requestedLength() { return Math.max(10, Math.min(180, Math.floor(Number(this.span) || 60))); },
        get interval() { return Math.min(this.requestedLength, Math.max(1, Math.floor(Number(this.sample) || 5))); },
        get filmLength() { return Math.min(this.requestedLength, (this.capacity-1)*this.interval); },
        get count() { return Math.ceil(this.filmLength / this.interval) + 1; },
        get summary() { return `Za ${this.filmLength} minut přibližně ${this.count} fotografií → jeden závěr AI.`; },
        get frequency() { return `Při nepřetržitém 24hodinovém sběru přibližně ${Math.round(1440 / this.filmLength)} vyhodnocení za den na jednu kameru, bez výpadků, opakovaných pokusů a limitů. V denním režimu méně.`; },
        clock: function (minute) {
          const total = 18 * 60 + Math.round(minute), hour = Math.floor(total / 60) % 24, min = total % 60;
          return String(hour).padStart(2, '0') + ':' + String(min).padStart(2, '0') + (total >= 1440 ? ' (+1 den)' : '');
        },
        get previewFrames() {
          const n = Math.min(13, this.count);
          return Array.from({length:n}, (_, i) => {
            const index = Math.round(i * (this.count - 1) / (n - 1));
            return {index:index, minute:Math.min(this.filmLength,index*this.interval)};
          });
        }
      };
    });
    Alpine.data('clipRange', function (from, to, zone) {
      return {
        from: from, to: to, minutes: 0,
        local: function (stamp) {
          const parts = new Intl.DateTimeFormat('sv-SE', {timeZone: zone, year:'numeric', month:'2-digit', day:'2-digit', hour:'2-digit', minute:'2-digit', second:'2-digit', hourCycle:'h23'}).formatToParts(new Date(stamp));
          const p = Object.fromEntries(parts.map(x => [x.type, x.value]));
          return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:${p.second}`;
        },
        stamp: function (value) {
          if (!value) return NaN;
          const text = value.length === 16 ? value + ':00' : value;
          const wall = Date.parse(text + 'Z');
          if (!Number.isFinite(wall)) return NaN;
          let guess = wall;
          for (let i=0; i<3; i++) guess += wall - Date.parse(this.local(guess) + 'Z');
          // Match the server's first occurrence during the autumn clock change.
          const candidates = [-7200000,-3600000,-1800000,0,1800000,3600000,7200000].map(d => guess+d).filter(t => this.local(t)===text);
          return candidates.length ? Math.min(...candidates) : NaN;
        },
        init: function () { this.measure(); },
        measure: function () {
          const delta = (this.stamp(this.to) - this.stamp(this.from)) / 60000;
          this.minutes = Number.isFinite(delta) ? Math.round(delta * 100) / 100 : '';
        },
        resize: function () {
          const start = this.stamp(this.from), minutes = Number(this.minutes);
          if (Number.isFinite(start) && minutes > 0 && minutes <= 120)
            this.to = this.local(start + minutes * 60000);
        }
      };
    });
    Alpine.data('filmPlayer', function (frames) {
      return {
        frames: frames, index: 0, playing: false, timer: null,
        pause: function () { clearInterval(this.timer); this.timer = null; this.playing = false; },
        toggle: function () {
          if (this.playing) { this.pause(); return; }
          this.playing = true;
          this.timer = setInterval(() => { this.index = (this.index + 1) % this.frames.length; }, 900);
        },
        step: function (delta) { this.pause(); this.index = (this.index + delta + this.frames.length) % this.frames.length; },
        destroy: function () { this.pause(); }
      };
    });
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

    // Keep observing through restarts; success requires the installer's health-check marker.
    Alpine.data('updater', function (running, version, log) {
      return {
        running: !!running, version: version, log: log || '', phase: running ? 'run' : '',
        newVersion: '', idle: 0, disconnectedAt: 0, timer: null, controller: null, disposed: false,
        init: function () { if (this.running || this.log) this.poll(); },
        destroy: function () { this.disposed = true; clearTimeout(this.timer); if (this.controller) this.controller.abort(); },
        later: function () { var self = this; if (!self.disposed) self.timer = setTimeout(function () { self.poll(); }, 3000); },
        poll: async function () {
          if (this.disposed) return;
          this.controller = new AbortController();
          var controller = this.controller, timeout = setTimeout(function () { controller.abort(); }, 12000);
          try {
            var r = await fetch('/system/update/status', { credentials: 'same-origin', cache: 'no-store', signal: controller.signal });
            if (r.redirected || r.status === 401 || r.status === 403) { this.phase = 'auth'; return; }
            if (!r.ok) throw new Error('nedostupné');
            var s = await r.json();
            if (typeof s.running !== 'boolean' || !s.version) throw new Error('neplatná odpověď');
            this.disconnectedAt = 0;
            if (typeof s.log === 'string') this.log = s.log;
            this.newVersion = s.version;
            if (s.running) { this.running = true; this.phase = 'run'; this.idle = 0; this.later(); return; }
            // Log fallback supports a rollback to an older server without an outcome field.
            var outcome = s.outcome || (/Aktualizace selhala, obnovuji/.test(this.log) ? 'failed' :
              /✔ Atmovio aktualizován:/.test(this.log) ? 'done' : 'unknown');
            if (outcome === 'done' || outcome === 'failed') { this.phase = outcome; this.running = false; return; }
            if (++this.idle > 10) { this.phase = 'unknown'; this.running = false; return; }
            this.phase = 'run'; this.later();
          } catch (e) {
            if (!this.disconnectedAt) this.disconnectedAt = Date.now();
            this.phase = Date.now() - this.disconnectedAt >= 120000 ? 'offline' : 'restart';
            this.later();
          } finally { clearTimeout(timeout); }
        }
      };
    });

    // ---------- Návrh titulku přes AI (studio) ----------
    Alpine.data('titleIdeas', function (opts) {
      return {
        titles: [], msg: '', busy: false, proposal: null, metaMsg: '',
        askMetadata: function () {
          var self = this, fd = new FormData(), form = this.$el.closest('form'), csrf = document.querySelector('input[name=csrf_token]');
          var speed = form && form.querySelector('[name=speed]');
          fd.append('csrf_token', csrf ? csrf.value : '');
          fd.append('sid', opts.sid || 0); fd.append('vid', opts.vid || 0); fd.append('speed', speed ? speed.value : 20);
          self.busy = true; self.metaMsg = ''; self.proposal = null;
          fetch('/studio/metadata', {method: 'POST', body: fd, credentials: 'same-origin'})
            .then(function (r) { return r.json(); }).then(function (d) {
              if (!d.ok) { self.metaMsg = d.error || 'Návrh se nepodařil.'; return; }
              self.proposal = {title: d.title, description: d.description};
              self.metaMsg = 'Návrh je připravený. Použije se až po kliknutí na Použít návrh.';
            }).catch(function () { self.metaMsg = 'Spojení selhalo. Původní text zůstal zachován.'; })
            .finally(function () { self.busy = false; });
        },
        applyMetadata: function () {
          if (!this.proposal) return;
          this.$refs.title.value = this.proposal.title;
          this.$refs.description.value = this.proposal.description;
          this.$refs.title.dispatchEvent(new Event('input', {bubbles: true}));
          this.$refs.description.dispatchEvent(new Event('input', {bubbles: true}));
          this.proposal = null; this.metaMsg = 'Vloženo do formuláře. Změny ještě ulož.';
        },
        ask: function (speed) {
          var self = this, fd = new FormData(), csrf = document.querySelector('input[name=csrf_token]');
          fd.append('csrf_token', csrf ? csrf.value : ''); fd.append('sid', opts.sid || 0); fd.append('vid', opts.vid || 0); fd.append('speed', speed || 20);
          self.busy = true; self.msg = '';
          fetch('/studio/titles', { method: 'POST', body: fd, credentials: 'same-origin' }).then(function (r) { return r.json(); })
            .then(function (d) { if (!d.ok) { self.msg = d.error; return; } self.titles = d.titles; self.msg = 'Klikni na návrh, který se ti líbí:'; })
            .catch(function () { self.msg = 'Návrh selhal.'; }).finally(function () { self.busy = false; });
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
    function fallback() {
      // Hidden <pre> and input values cannot reliably be copied with a DOM range.
      var input = document.createElement('textarea');
      input.value = text; input.readOnly = true;
      input.setAttribute('aria-label', 'Text ke zkopírování');
      input.style.cssText = 'position:fixed;top:0;left:0;width:1px;height:1px;opacity:0;';
      document.body.appendChild(input);
      input.focus(); input.select(); input.setSelectionRange(0, input.value.length);
      var copied = false;
      try { copied = document.execCommand('copy') === true; } catch (e) {}
      if (copied) {
        input.remove(); if (btn) btn.focus(); done(true);
      } else {
        // Leave a visible, selected copy for manual Cmd+C, even when the source was hidden.
        input.style.cssText = 'position:fixed;z-index:10000;inset:20% 5%;width:90%;height:50%;padding:1rem;';
        input.focus(); input.select(); done(false);
        input.addEventListener('blur', function () { input.remove(); }, {once:true});
      }
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { done(true); }, fallback);
    } else { fallback(); }
  };

  // ---------- Náhledy kamer: když obrázek nejde, ukázat text místo prázdna ----------
  window.swImgFail = function (img, text) {
    img.style.display = 'none';
    let state=img.parentNode.querySelector('.camera-unavailable');
    if (!state) {
      state=document.createElement('span'); state.className='camera-unavailable'; state.setAttribute('role','status');
      const icon=document.createElement('span');icon.className='media-state-icon';icon.textContent='◉';icon.setAttribute('aria-hidden','true');
      const title=document.createElement('strong');title.textContent='Obraz není dostupný';
      const detail=document.createElement('span');detail.textContent=(text || 'Kamera nebo Frigate neodpovídá.')+' Spojení se automaticky obnovuje.';
      state.append(icon,title,detail);img.parentNode.appendChild(state);
      if (!img._recoveryInstalled) { img._recoveryInstalled=true; img.addEventListener('load',function(){clearTimeout(img._retry);img._retry=null;img.style.display='';img.parentNode.querySelector('.camera-unavailable')?.remove();}); }
    }
    if (!img._retry) img._retry=setTimeout(function(){img._retry=null;if(img.isConnected && document.visibilityState==='visible') { const url=new URL(img.src,location.href);url.searchParams.set('t',Date.now());img.src=url.href; } else if(img.isConnected) swImgFail(img,text);},10000);
  };

  window.swReviewStudio = function(form) {
    const data=new FormData(form), missing=[];
    if (!String(data.get('music') || '').trim()) missing.push('hudbu');
    if (!data.get('intro')) missing.push('intro');
    if (!String(data.get('title') || '').trim()) missing.push('nadpis');
    if (!String(data.get('description') || '').trim()) missing.push('popis');
    if (data.get('text_on') && !String(data.get('text') || '').trim()) missing.push('zapnutý text v obraze je prázdný');
    return !missing.length || confirm('Před vytvořením videa zkontroluj: '+missing.join(', ')+'.\n\nTyto prvky jsou volitelné. Opravdu pokračovat bez nich?');
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

// Native preview speed; unsupported rates do not interrupt playback.
window.swRecordingSpeed = function (button, rate) {
  var video = document.getElementById('clip');
  if (!video) return;
  try { video.playbackRate = rate; if (rate > 1) video.muted = true; }
  catch (_) { return; }
  button.parentElement.querySelectorAll('button').forEach(function (b) { b.setAttribute('aria-pressed', b === button ? 'true' : 'false'); });
};
