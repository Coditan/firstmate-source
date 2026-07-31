// Runtime checks for bin/board-assets/board.js, driven by tests/fm-board.test.sh.
//
// This vessel has no working browser (an open captain decision), so these are
// LOGIC checks against a minimal DOM stand-in, not rendering checks. They prove
// what the script does; they say nothing about how a board looks.
//
// Behaviors worth pinning:
//   1. A board opened straight from disk has no window.lavish. That is a normal
//      way to read a board, so submitting there must not throw - it must reveal
//      the offline notice instead, and take it back down once a bridge appears.
//   2. On a served board, one submit queues exactly ONE prompt, carrying the
//      question key as queueKey so a changed answer replaces the earlier unsent
//      one instead of appending a second.
//   3. No submit is silent: an answer carrying neither a choice nor a note says
//      so, and a radio whose name does not match data-fm-question still yields
//      the captain's answer instead of swallowing it.

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

function selectorsOf(el) {
  if (Array.isArray(el._sel)) return el._sel;
  return el._sel ? [el._sel] : [];
}

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
    classList: {
      add: (c) => el._classes.add(c),
      remove: (c) => el._classes.delete(c),
      contains: (c) => el._classes.has(c),
    },
    querySelector: (sel) => el.children.find((c) => selectorsOf(c).includes(sel)) || null,
    querySelectorAll: (sel) => el.children.filter((c) => selectorsOf(c).includes(sel)),
  };
  return el;
}

function buildForm(key, { choice, note, radio }) {
  const form = makeElement('form', { 'data-fm-question': key, 'data-fm-label': 'Testfrage' });
  const queued = makeElement('div');
  queued._sel = '.fm-queued';
  const noteEl = makeElement('textarea');
  noteEl._sel = '[data-fm-note]';
  noteEl.value = note || '';
  form.children.push(queued, noteEl);
  if (radio) {
    const input = makeElement('input', { type: 'radio' });
    input.name = radio.name;
    input.value = radio.value;
    input._sel = radio.checked
      ? ['input[type="radio"]', 'input[type="radio"]:checked']
      : ['input[type="radio"]'];
    form.children.push(input);
  }
  form._formData = new Map([[key, choice]]);
  return { form, queued };
}

function install({ withLavish }) {
  const queued = [];
  const warnings = [];
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
    console: { warn: (m) => warnings.push(String(m)) },
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
  return { doc, queued, offline, warnings };
}

// reinit - re-run the script with these forms visible, so init() sees them.
function reinit(doc, forms, offline) {
  doc.querySelectorAll = (sel) => {
    if (sel === 'form[data-fm-question]') return forms;
    if (sel === '.fm-offline') return offline ? [offline] : [];
    return [];
  };
  new Function('window', 'document', 'FormData', source)(global.window, doc, global.FormData);
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

// --- 3. an empty answer is not submitted, and is not silent either ---------

{
  const { doc, queued } = install({ withLavish: true });
  const { form, queued: box } = buildForm('frage-c', { choice: undefined });
  doc._handlers.submit({ target: form, preventDefault() {} });
  check(queued.length === 0, 'an empty answer queues nothing');
  check(box._classes.has('is-shown') && box._classes.has('is-warn'),
    'an empty submit says so instead of being a silent no-op');
}

// --- 4. the wiring derives the Lavish question attribute -------------------

{
  const { doc } = install({ withLavish: true });
  const form = makeElement('form', { 'data-fm-question': 'frage-d' });
  doc._handlers.DOMContentLoaded ? doc._handlers.DOMContentLoaded() : null;
  // init() already ran at load with no forms; re-run it through the load path.
  reinit(doc, [form]);
  check(form.getAttribute('data-lavish-question') === 'frage-d',
    'data-lavish-question is derived from data-fm-question, declared once');
}

// --- 5. a radio name that does not match the question key ------------------

{
  // The name-must-match rule lives in prose, so a one-character mismatch has to
  // cost a console warning rather than the captain's answer.
  const { doc, queued, warnings } = install({ withLavish: true });
  const { form } = buildForm('frage-e', {
    choice: undefined,
    radio: { name: 'frage-E', value: 'Option E', checked: true },
  });
  reinit(doc, [form]);
  doc._handlers.submit({ target: form, preventDefault() {} });
  check(queued.length === 1 && queued[0].opts.data.answer === 'Option E',
    'a mismatched radio name still yields the answer, read from the form itself');
  check(warnings.some((w) => w.includes('frage-e')),
    'the mismatch is reported rather than swallowed');
}

// --- 6. a Lavish runtime that arrives late ---------------------------------

{
  // The offline notice is advisory. Leaving it up while answers are being sent
  // tells the captain the opposite of what is happening.
  const { doc, offline } = install({ withLavish: false });
  const { form } = buildForm('frage-f', { choice: 'Option F' });
  doc._handlers.submit({ target: form, preventDefault() {} });
  check(offline._classes.has('is-shown'), 'no bridge at submit reveals the offline notice');

  global.window.lavish = { queuePrompt: () => {} };
  doc._handlers.submit({ target: form, preventDefault() {} });
  check(!offline._classes.has('is-shown'),
    'a queue that succeeds takes the offline notice back down');
}

process.exit(failures === 0 ? 0 : 1);
