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
//   4. THE TALLY COUNT MOVES ON SUBMIT AND NOT ON SELECT. Both directions are
//      asserted, because the wrong one is the failure the strip exists to fix:
//      a mark the captain chose but never sent reaches nobody, and a count that
//      dropped when he merely chose would tell him it had.

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
    innerHTML: '',
    _parent: null,
    getAttribute: (n) => (n in el._attrs ? el._attrs[n] : null),
    setAttribute: (n, v) => { el._attrs[n] = v; },
    removeAttribute: (n) => { delete el._attrs[n]; },
    hasAttribute: (n) => n in el._attrs,
    appendChild: (c) => { c._parent = el; el.children.push(c); return c; },
    matches: (sel) => sel === 'form[data-fm-question]'
      && el.tagName === 'FORM' && 'data-fm-question' in el._attrs,
    // closest walks up the recorded parent chain; the stand-in only needs the
    // two selectors board.js actually asks for.
    closest: (sel) => {
      let node = el;
      while (node) {
        if (sel === 'form[data-fm-question]' && node.tagName === 'FORM'
          && 'data-fm-question' in node._attrs) return node;
        if (sel === '[id]' && node.id) return node;
        if (selectorsOf(node).includes(sel)) return node;
        node = node._parent;
      }
      return null;
    },
    classList: {
      add: (c) => el._classes.add(c),
      remove: (c) => el._classes.delete(c),
      contains: (c) => el._classes.has(c),
    },
    querySelector: (sel) => el.children.find((c) => selectorsOf(c).includes(sel)) || null,
    querySelectorAll: (sel) => el.children.filter((c) => selectorsOf(c).includes(sel)),
  };
  // className is what board.js sets on the elements it creates.
  Object.defineProperty(el, 'className', {
    get: () => [...el._classes].join(' '),
    set: (v) => { el._classes = new Set(String(v).split(/\s+/).filter(Boolean)); },
  });
  return el;
}

function buildForm(key, { choice, note, radio, entryId, noNote } = {}) {
  const form = makeElement('form', { 'data-fm-question': key, 'data-fm-label': 'Testfrage' });
  const queued = makeElement('div');
  queued._sel = '.fm-queued';
  form.appendChild(queued);
  let noteEl = null;
  if (!noNote) {
    noteEl = makeElement('textarea');
    noteEl._sel = '[data-fm-note]';
    noteEl.value = note || '';
    form.appendChild(noteEl);
  }
  if (radio) {
    const input = makeElement('input', { type: 'radio' });
    input.name = radio.name;
    input.value = radio.value;
    input._sel = radio.checked
      ? ['input[type="radio"]', 'input[type="radio"]:checked']
      : ['input[type="radio"]'];
    form.appendChild(input);
  }
  if (entryId) {
    const entry = makeElement('article');
    entry.id = entryId;
    entry.appendChild(form);
  }
  form._formData = new Map([[key, choice]]);
  return { form, queued, note: noteEl };
}

function install({ withLavish, lang = 'de' } = {}) {
  const queued = [];
  const warnings = [];
  const offline = makeElement('div');
  const tally = makeElement('div', { hidden: '' });
  tally._sel = '.fm-tally';
  const root = makeElement('html', { lang });
  const doc = {
    documentElement: root,
    readyState: 'complete',
    _handlers: {},
    _byId: {},
    addEventListener: (t, fn) => { doc._handlers[t] = fn; },
    createElement: (tag) => makeElement(tag),
    getElementById: (id) => doc._byId[id] || null,
    querySelector: (sel) => (sel === '.fm-tally' ? tally : null),
    querySelectorAll: (sel) => (sel === '.fm-offline' ? [offline] : []),
  };
  global.document = doc;
  global.window = {
    setTimeout: () => { /* never fire: keeps the poll from looping in-test */ },
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
  return { doc, queued, offline, warnings, tally };
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

// The strip's parts, once board.js has built them into the container.
function stripParts(tally) {
  const count = tally.children.find((c) => c._classes.has('fm-tally-count')) || null;
  const row = tally.children.find((c) => c._classes.has('fm-tally-row')) || null;
  const legend = tally.children.find((c) => c._classes.has('fm-tally-legend')) || null;
  const number = count ? count.children.find((c) => c.tagName === 'B') : null;
  return { count, row, legend, number };
}

function tallyCount(tally) {
  const { number } = stripParts(tally);
  return number ? Number(number.textContent) : null;
}

function submit(doc, form) {
  doc._handlers.submit({ target: form, preventDefault() {} });
}

function change(doc, el) {
  doc._handlers.change({ target: el });
}

// --- 1. opened from disk, no Lavish server ---------------------------------

{
  const { doc, queued, offline } = install({ withLavish: false });
  const { form } = buildForm('frage-a', { choice: 'Option A' });
  let threw = null;
  try {
    submit(doc, form);
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
  submit(doc, form);

  check(queued.length === 1, 'one submit queues exactly one prompt');
  check(queued[0].opts.queueKey === 'frage-b',
    'the prompt carries the question key as queueKey, so a changed answer replaces it');
  check(queued[0].text.includes('Option B'), 'the queued prompt carries the chosen option');
  check(queued[0].text.includes('weil'), 'the queued prompt carries the free-text note');
  check(queued[0].opts.data.question === 'frage-b', 'the prompt reports which question it answers');
  check(queued[0].opts.data.note === 'weil', 'the note travels back beside the chosen option');
  check(queuedBox._classes.has('is-shown'), 'queued state is shown separately from selected state');

  // Re-answering must queue under the same key rather than inventing a second.
  const second = buildForm('frage-b', { choice: 'Option C' });
  submit(doc, second.form);
  check(queued.length === 2 && queued[1].opts.queueKey === 'frage-b',
    're-answering reuses the same queueKey so Lavish replaces the unsent answer');
}

// --- 3. an empty answer is not submitted, and is not silent either ---------

{
  const { doc, queued } = install({ withLavish: true });
  const { form, queued: box } = buildForm('frage-c', { choice: undefined });
  submit(doc, form);
  check(queued.length === 0, 'an empty answer queues nothing');
  check(box._classes.has('is-shown') && box._classes.has('is-warn'),
    'an empty submit says so instead of being a silent no-op');
}

// --- 4. the wiring derives the Lavish question attribute -------------------

{
  const { doc, warnings } = install({ withLavish: true });
  const form = makeElement('form', { 'data-fm-question': 'frage-d' });
  doc._handlers.DOMContentLoaded ? doc._handlers.DOMContentLoaded() : null;
  // init() already ran at load with no forms; re-run it through the load path.
  reinit(doc, [form]);
  check(form.getAttribute('data-lavish-question') === 'frage-d',
    'data-lavish-question is derived from data-fm-question, declared once');
  // This form carries no .fm-queued box, so nothing on it could ever report an
  // empty submit. That is the one remaining silent path, and it is named.
  check(warnings.some((w) => w.includes('.fm-queued') && w.includes('frage-d')),
    'a form with no .fm-queued box is reported at startup rather than left silent');
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
  submit(doc, form);
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
  submit(doc, form);
  check(offline._classes.has('is-shown'), 'no bridge at submit reveals the offline notice');

  global.window.lavish = { queuePrompt: () => {} };
  submit(doc, form);
  check(!offline._classes.has('is-shown'),
    'a queue that succeeds takes the offline notice back down');
}

// --- 7. a form with no note field is named ---------------------------------

{
  // The note beside a selection is not decoration. Measured on the board of
  // 2026-08-16, two of twenty answers carried a note contradicting the chosen
  // option, and the note held what the captain actually meant both times.
  const { doc, warnings } = install({ withLavish: true });
  const { form } = buildForm('frage-g', { choice: 'x', noNote: true });
  reinit(doc, [form]);
  check(warnings.some((w) => w.includes('note field') && w.includes('frage-g')),
    'an option set built without a note field is reported at startup');
}

// --- 8. the tally strip is built from the board's own questions ------------

{
  const { doc, tally } = install({ withLavish: true });
  const a = buildForm('q1', { choice: 'A', entryId: 'e1' });
  const b = buildForm('q2', { choice: 'B', entryId: 'e2' });
  const c = buildForm('q3', { choice: 'C', entryId: 'e3' });
  reinit(doc, [a.form, b.form, c.form]);

  const { row, legend } = stripParts(tally);
  check(!tally.hasAttribute('hidden'), 'a board that asks questions reveals its tally strip');
  check(tallyCount(tally) === 3, 'the count starts at one per question, none sent back');
  check((row.innerHTML.match(/fm-tally-sq/g) || []).length === 3,
    'the strip carries one square per question');
  check(row.innerHTML.includes('#fm-mk-open'), 'an untouched question shows an empty square');
  check(row.innerHTML.includes('data-fm-jump="e1"'),
    'each square jumps to the entry its question sits in');
  check(legend.innerHTML.includes('Bleistift'),
    'the legend states what each mark means, in the board\'s own language');
}

// --- 9. SELECTING does not decrement -------------------------------------

{
  // The whole point of the component. A mark he chose but never sent reaches
  // nobody, so choosing must change the SQUARE and never the COUNT.
  const { doc, tally } = install({ withLavish: true });
  const a = buildForm('q1', { choice: 'A', entryId: 'e1' });
  const b = buildForm('q2', { choice: 'B', entryId: 'e2' });
  reinit(doc, [a.form, b.form]);
  check(tallyCount(tally) === 2, 'both questions start in the count');

  change(doc, a.form.children.find((el) => el.tagName === 'TEXTAREA'));
  check(tallyCount(tally) === 2, 'choosing an option does NOT decrement the count');
  const { row } = stripParts(tally);
  check(row.innerHTML.includes('#fm-mk-pencil'), 'the chosen square turns to pencil');
  check(!row.innerHTML.includes('#fm-mk-struck'), 'and it is not struck, because nothing was sent');
}

// --- 10. SUBMITTING decrements -------------------------------------------

{
  const { doc, tally, queued } = install({ withLavish: true });
  const a = buildForm('q1', { choice: 'A', entryId: 'e1' });
  const b = buildForm('q2', { choice: 'B', entryId: 'e2' });
  reinit(doc, [a.form, b.form]);

  submit(doc, a.form);
  check(queued.length === 1, 'the submit queued the answer');
  check(tallyCount(tally) === 1, 'a completed submit DOES decrement the count');
  const { row, count } = stripParts(tally);
  check(row.innerHTML.includes('#fm-mk-struck'), 'the sent square is struck');
  check(!count._classes.has('is-clear'), 'one question is still outstanding, so the count still claims');

  submit(doc, b.form);
  check(tallyCount(tally) === 0, 'the last submit empties the count');
  check(stripParts(tally).count._classes.has('is-clear'),
    'a cleared count stops making a claim on the captain');
}

// --- 11. what does NOT strike a square ------------------------------------

{
  // An empty submit sends nothing, and a submit with no Lavish server sends
  // nothing. Neither may take a question out of the count, or the strip would
  // report as delivered exactly the answers that were not.
  const { doc: served, tally: servedTally } = install({ withLavish: true });
  const empty = buildForm('q1', { choice: undefined, entryId: 'e1' });
  reinit(served, [empty.form]);
  submit(served, empty.form);
  check(tallyCount(servedTally) === 1, 'an empty submit does not decrement the count');

  const { doc: offlineDoc, tally: offlineTally } = install({ withLavish: false });
  const answered = buildForm('q1', { choice: 'A', entryId: 'e1' });
  reinit(offlineDoc, [answered.form]);
  submit(offlineDoc, answered.form);
  check(tallyCount(offlineTally) === 1,
    'a submit with nowhere to send does not decrement the count either');
  check(!stripParts(offlineTally).row.innerHTML.includes('#fm-mk-struck'),
    'and it leaves the square unstruck, because it genuinely was not sent');
}

// --- 12. changing an answer after sending puts it back in the count --------

{
  // The count is of answers that have not been sent back. An answer edited
  // after it was sent is, in its current form, an answer nobody has received.
  const { doc, tally } = install({ withLavish: true });
  const a = buildForm('q1', { choice: 'A', entryId: 'e1' });
  reinit(doc, [a.form]);
  submit(doc, a.form);
  check(tallyCount(tally) === 0, 'sent, so out of the count');

  change(doc, a.form.children.find((el) => el.tagName === 'TEXTAREA'));
  check(tallyCount(tally) === 1, 'changing the answer afterwards puts it back in the count');
  check(stripParts(tally).row.innerHTML.includes('#fm-mk-pencil'),
    'and returns its square to pencil');
}

// --- 13. a board that asks nothing prints no strip ------------------------

{
  const { doc, tally, warnings } = install({ withLavish: true });
  reinit(doc, []);
  check(tally.hasAttribute('hidden'), 'a board with no questions leaves the strip hidden');
  check(tally.children.length === 0, 'and builds nothing into it');
  check(!warnings.some((w) => w.includes('fm-tally')),
    'a board with no questions is not warned about a strip it does not need');
}

// --- 14. the strip follows the document language --------------------------

{
  const { doc, tally } = install({ withLavish: true, lang: 'en' });
  const a = buildForm('q1', { choice: 'A', entryId: 'e1' });
  reinit(doc, [a.form]);
  check(stripParts(tally).legend.innerHTML.includes('Pencil'),
    'an English board gets an English legend rather than a half-translated one');
}

process.exit(failures === 0 ? 0 : 1);
