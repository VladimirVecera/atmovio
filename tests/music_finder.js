/* Run the real Alpine component with controlled HTTP responses (no browser/network). */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const events = {}, components = {}, calls = [];
const timers = new Map();
let timerId = 0;
let reply = { items: [{ id: 'fixture', title: 'Run' }], error: '' };
let reject = false, hold = false;
const ctx = {
  document: { readyState: 'loading', addEventListener: (name, fn) => { events[name] = fn; } },
  window: { addEventListener: () => {} }, URLSearchParams, AbortController,
  setTimeout: (fn, delay) => { timers.set(++timerId, {fn, delay}); return timerId; },
  clearTimeout: id => timers.delete(id),
  Alpine: { data: (name, fn) => { components[name] = fn; } },
  fetch: async (url, options) => {
    calls.push({ url, options });
    if (reject) throw new Error('offline');
    if (hold) return new Promise((resolve, reject) => {
      options.signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')));
    });
    return { ok: true, json: async () => reply };
  },
};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../src/atmovio/static/atmovio.js'), 'utf8'), ctx);
events['alpine:init']();
const finder = components.musicFinder('saved.mp3');
const watchers = {};
finder.$watch = (key, fn) => { watchers[key] = fn; };
finder.init();
(async () => {
  await finder.search();
  assert.equal(calls.length, 0);
  finder.q = 'run'; finder.instruments = ['piano', 'orchestra']; finder.creator = 'A & B';
  const pending = finder.search();
  assert.equal(finder.busy, true);
  await finder.search();  // Enter/click while busy must not consume a second API request.
  await pending;
  assert.equal(calls.length, 1);
  const sent = new URL(calls[0].url, 'http://localhost').searchParams;
  assert.equal(sent.get('q'), 'run');
  assert.equal(sent.get('instruments'), 'piano,orchestra');
  assert.equal(sent.get('creator'), 'A & B');
  assert.equal(sent.get('search_in'), 'title');
  assert.equal(finder.q, 'run');
  assert.equal(finder.music, 'saved.mp3');
  assert.equal(finder.busy, false);
  assert.equal(finder.items.length, 1);
  assert.equal(timers.size, 0);
  finder.instruments = ['piano']; watchers.instruments();
  assert.equal(finder.items.length, 0); assert.equal(finder.msg, '');
  assert.equal(finder.q, 'run');
  finder.q = ''; finder.creator = '';
  await finder.search();
  assert.equal(calls.length, 2);  // Instruments-only search is valid.
  finder.instruments = []; finder.creator = 'Artist';
  await finder.search();
  assert.equal(calls.length, 3);
  reply = { items: [], error: 'Žádná skladba neodpovídá výběru.' };
  await finder.search();
  assert.equal(finder.items.length, 0); assert.equal(finder.msg, reply.error);
  reject = true;
  await finder.search();
  assert.equal(finder.busy, false); assert.match(finder.msg, /odpověď od Atmovia/);
  assert.equal(finder.retryable, true);
  for (const key of ['q', 'searchIn', 'len', 'creator', 'license', 'extension']) {
    finder.items = [{ id: 'old' }]; finder.msg = 'old'; watchers[key]();
    assert.equal(finder.items.length, 0); assert.equal(finder.msg, '');
    assert.equal(finder.retryable, false);
  }

  reject = false; hold = true; finder.q = 'run'; finder.instruments = ['piano', 'orchestra'];
  let searching = finder.search();
  [...timers.values()].find(t => t.delay === 10000).fn();
  assert.match(finder.msg, /odpovídá pomaleji/);
  assert.equal(finder.busy, true);
  [...timers.values()].find(t => t.delay === 95000).fn();
  await searching;
  assert.match(finder.msg, /trvá příliš dlouho/);
  assert.equal(finder.busy, false); assert.equal(finder.retryable, true);
  assert.equal(finder.q, 'run'); assert.equal(finder.instruments.join(','), 'piano,orchestra');
  assert.equal(finder.music, 'saved.mp3'); assert.equal(timers.size, 0);

  hold = false; reply = {items: [], error: 'Openverse neodpovědělo včas.', retryable: true};
  await finder.search();  // User can retry with the same filters after a timeout.
  assert.equal(finder.retryable, true); assert.equal(finder.msg, reply.error);
  reply = {items: [{id: 'recovered'}], error: ''};
  await finder.search();
  assert.equal(finder.retryable, false); assert.equal(finder.items[0].id, 'recovered');
  assert.equal(timers.size, 0);

  hold = true;
  searching = finder.search();
  const msgBeforeDestroy = finder.msg;
  finder.destroy();
  await searching;
  assert.equal(finder.msg, msgBeforeDestroy); assert.equal(timers.size, 0);
  assert.equal(finder.searchController, null);
  console.log('PASS: request filters, busy guard, slow feedback, timeout/unlock, manual retry, timer cleanup and unmount');
})().catch(error => { console.error(error); process.exitCode = 1; });
