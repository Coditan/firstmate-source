// Runtime checks for bin/board-assets/board.js, driven by tests/fm-board.test.sh.
//
// This vessel has no working browser (an open captain decision), so these are
// LOGIC checks against a minimal DOM stand-in, not rendering checks. They prove
// what the script does; they say nothing about how a board looks.
//
// Two behaviors are worth pinning:
//   1. A board opened straight from disk has no window.lavish. That is a normal
//      way to read a board, so submitting there must not throw - it must reveal
//      the offline notice instead.
//   2. On a served board, one submit queues exactly ONE prompt, carrying the
//      question key as queueKey so a changed answer replaces the earlier unsent
//      one instead of appending a second.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '..', 'bin', 'board-assets', 'board.js'), 'utf8');

let failures = 0;
function check(ok, label) {
  console.log(`${ok ? 'ok' : 'not ok'} - ${label}`);
  if (!ok) failures++;
}

// --- a DOM stand-in with only what board.js touches ------------------------

function makeElement(tag, attrs = {}) {
  const el = {
    tagName: tag.toUpperCase(),
    _attrs: { ...attrs },
    _classes: new Set(),
    children: [],
    value: '',
    textContent: '',
    getAttribute: (n) => (n in el._attrs ? el._attrs[n] : null),
    setAttribute: (n, v) => { el._attrs[n] = v; },
    hasAttribute: (n) => n in el._attrs,
    matches: (sel) => sel === 'form[data-fm-question]'
      && el.tagName === 'FORM' && 'data-fm-question' in el._attrs,
    classList: { add: (c) => el._classes.add(c), contains: (c) => el._classes.has(c) },
    querySelector: (sel) => el.children.find((c) => c._sel === sel) || null,
  };
  return el;
}

function buildForm(key, { choice, note }) {
  const form = makeElement('form', { 'data-fm-question': key, 'data-fm-label': 'Testfrage' });
  const queued = makeElement('div');
  queued._sel = '.fm-queued';
  const noteEl = makeElement('textarea');
  noteEl._sel = '[data-fm-note]';
  noteEl.value = note || '';
  form.children.push(queued, noteEl);
  form._formData = new Map([[key, choice]]);
  return { form, queued };
}

function install({ withLavish }) {
  const queued = [];
  const offline = makeElement('div');
  const doc = {
    readyState: 'complete',
    _handlers: {},
    addEventListener: (t, fn) => { doc._handlers[t] = fn; },
    querySelectorAll: (sel) => (sel === '.fm-offline' ? [offline] : []),
  };
  global.document = doc;
  global.window = {
    setTimeout: (fn) => { /* never fire: keeps the poll from looping in-test */ },
    lavish: withLavish
      ? { queuePrompt: (text, opts) => queued.push({ text, opts }) }
      : undefined,
  };
  global.FormData = class {
    constructor(form) { this._m = form._formData; }
    get(k) { return this._m.get(k); }
  };
  // Evaluate the real script against these globals.
  // eslint-disable-next-line no-new-func
  new Function('window', 'document', 'FormData', source)(global.window, doc, global.FormData);
  return { doc, queued, offline };
}

// --- 1. opened from disk, no Lavish server ---------------------------------

{
  const { doc, queued, offline } = install({ withLavish: false });
  const { form } = buildForm('frage-a', { choice: 'Option A' });
  let threw = null;
  try {
    doc._handlers.submit({ target: form, preventDefault() {} });
  } catch (e) {
    threw = e;
  }
  check(threw === null, 'submitting without a Lavish server does not throw');
  check(queued.length === 0, 'nothing is queued when there is nowhere to queue to');
  check(offline._classes.has('is-shown'), 'the offline notice is revealed instead');
}

// --- 2. served board -------------------------------------------------------

{
  const { doc, queued } = install({ withLavish: true });
  const { form, queued: queuedBox } = buildForm('frage-b', { choice: 'Option B', note: 'weil' });
  doc._handlers.submit({ target: form, preventDefault() {} });

  check(queued.length === 1, 'one submit queues exactly one prompt');
  check(queued[0].opts.queueKey === 'frage-b',
    'the prompt carries the question key as queueKey, so a changed answer replaces it');
  check(queued[0].text.includes('Option B'), 'the queued prompt carries the chosen option');
  check(queued[0].text.includes('weil'), 'the queued prompt carries the free-text note');
  check(queued[0].opts.data.question === 'frage-b', 'the prompt reports which question it answers');
  check(queuedBox._classes.has('is-shown'), 'queued state is shown separately from selected state');

  // Re-answering must queue under the same key rather than inventing a second.
  const second = buildForm('frage-b', { choice: 'Option C' });
  doc._handlers.submit({ target: second.form, preventDefault() {} });
  check(queued.length === 2 && queued[1].opts.queueKey === 'frage-b',
    're-answering reuses the same queueKey so Lavish replaces the unsent answer');
}

// --- 3. an empty answer is not submitted -----------------------------------

{
  const { doc, queued } = install({ withLavish: true });
  const { form } = buildForm('frage-c', { choice: undefined });
  doc._handlers.submit({ target: form, preventDefault() {} });
  check(queued.length === 0, 'an empty answer queues nothing');
}

// --- 4. the wiring derives the Lavish question attribute -------------------

{
  const { doc } = install({ withLavish: true });
  const form = makeElement('form', { 'data-fm-question': 'frage-d' });
  doc.querySelectorAll = (sel) => (sel === 'form[data-fm-question]' ? [form] : []);
  doc._handlers.DOMContentLoaded ? doc._handlers.DOMContentLoaded() : null;
  // init() already ran at load with no forms; re-run it through the load path.
  new Function('window', 'document', 'FormData', source)(global.window, doc, global.FormData);
  check(form.getAttribute('data-lavish-question') === 'frage-d',
    'data-lavish-question is derived from data-fm-question, declared once');
}

process.exit(failures === 0 ? 0 : 1);
