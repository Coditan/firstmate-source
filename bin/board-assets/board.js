/* board.js - the single owner of Firstmate board behavior.
 *
 * bin/fm-board.sh inlines this file into every board, so a board carries its
 * own behavior and loads no script from the network.
 *
 * It implements the Lavish `input` playbook once, so a board body only has to
 * declare markup and never repeats a submit handler:
 *
 *   <form class="fm-field" data-fm-question="upstream-strategy" data-fm-label="Upstream-Strategie">
 *     <span class="fm-cap">Dein Zeichen</span>
 *     <div class="fm-opts">
 *       <label class="fm-opt"><input type="radio" name="upstream-strategy" value="selektiv"> ...</label>
 *     </div>
 *     <textarea class="fm-free" data-fm-note placeholder="..."></textarea>
 *     <button type="submit" class="fm-submit">Antwort vormerken</button>
 *     <div class="fm-queued"></div>
 *   </form>
 *
 * Playbook obligations this file discharges:
 *   - radio changes only update LOCAL state; they never queue a prompt,
 *   - the explicit submit queues EXACTLY ONE prompt for the final answer,
 *   - queueKey is the question key, so re-answering replaces the earlier
 *     unsent answer for that question instead of appending a second one,
 *   - queued state is displayed separately from selected state.
 *
 * THE TALLY STRIP
 * This file also owns the tally strip, Tally's signature component and the one
 * place in the fleet's surfaces where the difference between chosen and SENT is
 * counted rather than merely described. The count is of entries that have not
 * been sent back, so:
 *
 *   choosing an option turns a square to PENCIL and does NOT decrement,
 *   only a completed submit turns a square STRUCK and decrements.
 *
 * That is not a preference. It is the captain's own recorded failure: a board
 * where he pressed send and nobody heard. Changing an answer after sending
 * returns its square to pencil and the count with it, for the same reason - the
 * answer now showing is one nobody has received.
 *
 * The strip is BUILT here rather than declared in a board body. A count that is
 * typed by hand is a count that can be wrong, and this one exists precisely
 * because a wrong count about what reached the captain is the defect. The
 * builder emits an empty hidden container; a board that asks no questions keeps
 * it hidden and prints nothing.
 *
 * A board is also opened directly from disk, with no Lavish server and thus no
 * window.lavish. That is a supported way to read a board, so this file must not
 * throw there: it reveals the .fm-offline notice instead of failing on submit.
 * Nothing was sent in that case, so no square is struck and the count does not
 * move. The notice is advisory and reversible - a Lavish runtime that lands late
 * hides it again, because a board that keeps saying answers cannot be sent back
 * while it is sending them is worse than one that says nothing.
 *
 * No submit is silent. An answer that carries neither a choice nor a note says
 * so in the form's own .fm-queued box rather than doing nothing at all, and a
 * form built without that box is named on the console at startup, so the one
 * position where nothing could be shown is still not a quiet one.
 */
(function () {
  'use strict';

  // Boards are written in the language the task was set in, so the strip's own
  // captions follow the document's declared language rather than being pinned
  // to one. German is the default because that is what this fleet's captain
  // reads; an undeclared or unknown language falls back to it rather than to a
  // half-translated strip.
  var TEXT = {
    de: {
      queued: 'Vorgemerkt: ',
      queuedNote: 'Vorgemerkt: freie Anmerkung',
      empty: 'Nichts vorgemerkt: bitte eine Option wählen oder eine Anmerkung schreiben.',
      decision: 'Entscheidung "',
      noChoice: '(keine Option gewählt)',
      captainNote: ' - Anmerkung des Captains: ',
      of: 'von ',
      notSent: ' noch nicht zurückgeschickt',
      allSent: 'alles zurückgeschickt',
      warning: 'Ein Zeichen, das nie gesendet wurde, erreicht niemanden',
      legendBlank: 'Leer = unberührt',
      legendPencil: 'Bleistift = gewählt, nicht gesendet - zählt weiter',
      legendStruck: 'Gestrichen = zurückgeschickt',
      sqBlank: ', unberührt',
      sqPencil: ', gewählt aber nicht gesendet',
      sqStruck: ', zurückgeschickt'
    },
    en: {
      queued: 'Queued: ',
      queuedNote: 'Queued: note only',
      empty: 'Nothing queued: choose an option or write a note.',
      decision: 'Decision "',
      noChoice: '(no option chosen)',
      captainNote: ' - captain\'s note: ',
      of: 'of ',
      notSent: ' not sent back yet',
      allSent: 'all sent back',
      warning: 'A mark you chose but never sent reaches nobody',
      legendBlank: 'Empty = untouched',
      legendPencil: 'Pencil = chosen, not sent - still counted',
      legendStruck: 'Struck = sent back',
      sqBlank: ', blank',
      sqPencil: ', chosen but not sent',
      sqStruck: ', sent back'
    }
  };

  var T = TEXT.de;

  function pickLanguage() {
    var root = document.documentElement;
    var lang = root && root.getAttribute ? (root.getAttribute('lang') || '') : '';
    lang = String(lang).toLowerCase().split('-')[0];
    if (TEXT[lang]) {
      T = TEXT[lang];
    }
  }

  function esc(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function bridge() {
    var l = window.lavish;
    return l && typeof l.queuePrompt === 'function' ? l : null;
  }

  function answerOf(form) {
    var data = new FormData(form);
    var key = form.getAttribute('data-fm-question');
    var choice = data.get(key);
    if (choice === null || choice === undefined || choice === '') {
      // The radio name is meant to equal data-fm-question, but nothing enforces
      // that at build time. Read the checked control out of the form itself so a
      // mismatched name costs a console warning and never the captain's answer.
      var checked = form.querySelector('input[type="radio"]:checked');
      choice = checked ? checked.value : '';
    }
    var note = form.querySelector('[data-fm-note]');
    var text = note && note.value ? note.value.trim() : '';
    if (!choice && !text) {
      return null;
    }
    return { choice: choice ? String(choice) : '', note: text };
  }

  function promptFor(label, answer) {
    var parts = [];
    parts.push(T.decision + label + '": ');
    parts.push(answer.choice ? answer.choice : T.noChoice);
    if (answer.note) {
      parts.push(T.captainNote + answer.note);
    }
    return parts.join('');
  }

  function say(form, text, warn) {
    var box = form.querySelector('.fm-queued');
    if (!box) {
      return;
    }
    box.textContent = text;
    if (warn) {
      box.classList.add('is-warn');
    } else {
      box.classList.remove('is-warn');
    }
    box.classList.add('is-shown');
  }

  function markQueued(form, answer) {
    say(form, answer.choice ? T.queued + answer.choice : T.queuedNote, false);
  }

  function markUnanswered(form) {
    say(form, T.empty, true);
  }

  // --- the tally strip -----------------------------------------------------
  //
  // QUESTIONS is the sheet's own manifest, in document order. STATE holds one
  // of 'blank', 'pencil' or 'struck' per question key. Only 'struck' is out of
  // the count, because only 'struck' means the captain's answer left the board.

  var QUESTIONS = [];
  var STATE = {};
  var strip = null;
  var stripCount = null;
  var stripNumber = null;
  var stripCaption = null;
  var stripRow = null;

  function questionKey(form) {
    return form.getAttribute('data-fm-question');
  }

  function questionLabel(form) {
    return form.getAttribute('data-fm-label') || questionKey(form);
  }

  // Where a square jumps to. An explicit data-fm-entry wins; otherwise the
  // nearest ancestor carrying an id, which is the entry the question sits in.
  // A question in no identified container simply gets a square that does not
  // scroll, rather than one that scrolls somewhere wrong.
  function jumpTarget(form) {
    var explicit = form.getAttribute('data-fm-entry');
    if (explicit) {
      return explicit;
    }
    if (typeof form.closest !== 'function') {
      return '';
    }
    var host = form.closest('[id]');
    return host && host.id ? host.id : '';
  }

  function markFor(state) {
    if (state === 'struck') { return 'struck'; }
    if (state === 'pencil') { return 'pencil'; }
    return 'open';
  }

  function squareLabel(index, state) {
    var tail = state === 'struck' ? T.sqStruck : state === 'pencil' ? T.sqPencil : T.sqBlank;
    return String(index + 1) + '. ' + QUESTIONS[index].label + tail;
  }

  function buildStrip() {
    strip = document.querySelector('.fm-tally');
    if (!strip) {
      if (QUESTIONS.length && window.console && window.console.warn) {
        window.console.warn('fm-board: this board asks ' + QUESTIONS.length +
          ' question(s) but carries no .fm-tally container, so nothing counts what is still unsent.');
      }
      return;
    }
    if (!QUESTIONS.length) {
      // A board that asks nothing needs no count of what is unanswered.
      return;
    }

    stripCount = document.createElement('div');
    stripCount.className = 'fm-tally-count';
    // The number changes without the page reloading, so it is announced.
    stripCount.setAttribute('aria-live', 'polite');

    stripNumber = document.createElement('b');
    var words = document.createElement('div');
    stripCaption = document.createElement('strong');
    var warn = document.createElement('span');
    warn.textContent = T.warning;
    words.appendChild(stripCaption);
    words.appendChild(warn);
    stripCount.appendChild(stripNumber);
    stripCount.appendChild(words);

    stripRow = document.createElement('div');
    stripRow.className = 'fm-tally-row';

    var legend = document.createElement('div');
    legend.className = 'fm-tally-legend';
    legend.innerHTML = '<span>' + esc(T.legendBlank) + '</span>' +
      '<span>' + esc(T.legendPencil) + '</span>' +
      '<span>' + esc(T.legendStruck) + '</span>';

    strip.appendChild(stripCount);
    strip.appendChild(stripRow);
    strip.appendChild(legend);
    strip.removeAttribute('hidden');
    paintStrip();
  }

  // The squares are rebuilt wholesale and the count block is not, which is
  // deliberate: the count is the aria-live region, and re-creating a live region
  // is how an announcement gets lost. The cost is that a rebuild drops keyboard
  // focus from a square, and that is accepted because the state changes that
  // trigger it all happen inside a form, never with a square focused.
  function paintStrip() {
    if (!strip || !stripRow) {
      return;
    }
    var unsent = 0;
    var html = '';
    for (var i = 0; i < QUESTIONS.length; i++) {
      var q = QUESTIONS[i];
      var state = STATE[q.key] || 'blank';
      if (state !== 'struck') {
        unsent++;
      }
      var mark = markFor(state);
      // The struck mark is drawn in ink; the other two are the open red, so a
      // square that still wants something is the loud one.
      var tone = state === 'struck' ? 'fm-mk-struck' : 'fm-mk-open';
      html += '<button class="fm-tally-sq" type="button" data-fm-jump="' + esc(q.jump) +
        '" aria-label="' + esc(squareLabel(i, state)) + '">' +
        '<svg class="fm-mk ' + tone + '" aria-hidden="true" focusable="false">' +
        '<use href="#fm-mk-' + mark + '"></use></svg></button>';
    }
    stripRow.innerHTML = html;
    stripNumber.textContent = String(unsent);
    stripCaption.textContent = unsent === 0
      ? T.allSent
      : T.of + QUESTIONS.length + T.notSent;
    if (unsent === 0) {
      stripCount.classList.add('is-clear');
    } else {
      stripCount.classList.remove('is-clear');
    }
  }

  function setState(form, state) {
    var key = questionKey(form);
    if (!key || !(key in STATE)) {
      return;
    }
    if (STATE[key] === state) {
      return;
    }
    STATE[key] = state;
    paintStrip();
  }

  // A change is a change of mind, whatever came before it. An answer edited
  // after it was sent has NOT been sent in its current form, so its square
  // returns to pencil and the count goes back up with it.
  function onChange(event) {
    var el = event.target;
    if (!el || typeof el.closest !== 'function') {
      return;
    }
    var form = el.closest('form[data-fm-question]');
    if (form) {
      setState(form, 'pencil');
    }
  }

  function onStripClick(event) {
    var el = event.target;
    if (!el || typeof el.closest !== 'function') {
      return;
    }
    var square = el.closest('.fm-tally-sq');
    if (!square) {
      return;
    }
    var id = square.getAttribute('data-fm-jump');
    if (!id) {
      return;
    }
    var target = document.getElementById(id);
    if (target && typeof target.scrollIntoView === 'function') {
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  }

  function onSubmit(event) {
    var form = event.target;
    if (!form || !form.matches || !form.matches('form[data-fm-question]')) {
      return;
    }
    event.preventDefault();

    var answer = answerOf(form);
    if (!answer) {
      // Nothing to send, so nothing left the board and the count does not move.
      markUnanswered(form);
      return;
    }

    var key = form.getAttribute('data-fm-question');
    var label = form.getAttribute('data-fm-label') || key;
    var lavish = bridge();
    if (!lavish) {
      // Opened without a running Lavish server: there is nowhere to queue to.
      // Say so rather than pretending the answer was recorded, and leave the
      // square unstruck, because it genuinely was not sent.
      revealOffline();
      return;
    }

    lavish.queuePrompt(promptFor(label, answer), {
      tag: 'decision',
      text: label + ': ' + (answer.choice || 'note'),
      // queueKey is what makes a changed answer REPLACE the previous unsent one.
      queueKey: key,
      element: form,
      data: { question: key, answer: answer.choice, note: answer.note }
    });
    // The queue just worked, so any offline notice on this board is stale.
    showOffline(false);
    markQueued(form, answer);
    // Only here. This is the completed submit, and the only transition that
    // takes a square out of the count.
    setState(form, 'struck');
  }

  function showOffline(show) {
    var notes = document.querySelectorAll('.fm-offline');
    for (var i = 0; i < notes.length; i++) {
      if (show) {
        notes[i].classList.add('is-shown');
      } else {
        notes[i].classList.remove('is-shown');
      }
    }
  }

  function revealOffline() {
    showOffline(true);
  }

  // Lavish injects its own runtime, and this inlined script may run before that
  // injection lands. A single check at startup would therefore report a served
  // board as offline. Poll briefly instead, and keep checking at a slower
  // cadence after the notice appears, so a runtime that lands late takes the
  // notice back down rather than leaving the captain reading that his answers
  // cannot be sent back while they are in fact being sent.
  //
  // The poll gives up after about 122 seconds - 6 tries at 400ms, then 60 at
  // 2000ms. A runtime that lands after that leaves the notice standing until the
  // captain's first successful submit clears it; the submit path is the backstop
  // here, not the poll.
  function watchForBridge(quietLeft, slowLeft) {
    if (bridge()) {
      showOffline(false);
      return;
    }
    if (quietLeft > 0) {
      window.setTimeout(function () {
        watchForBridge(quietLeft - 1, slowLeft);
      }, 400);
      return;
    }
    revealOffline();
    if (slowLeft <= 0) {
      return;
    }
    window.setTimeout(function () {
      watchForBridge(0, slowLeft - 1);
    }, 2000);
  }

  // docs/board-layout.md states two rules a board body has to follow: the radio
  // name equals data-fm-question, and every question form carries a .fm-queued
  // box. Neither can be enforced from prose, and a board that breaks either one
  // builds and renders, so both are named on the console at startup. Breaking
  // the first costs nothing, because answerOf falls back to the form's own
  // checked control; breaking the second is what would make a submit silent.
  function reportFormDefects(form) {
    if (!window.console || !window.console.warn) {
      return;
    }
    var key = form.getAttribute('data-fm-question');
    if (form.querySelector && !form.querySelector('.fm-queued')) {
      window.console.warn('fm-board: the form for "' + key +
        '" has no .fm-queued box, so nothing on it can report a queued or an empty answer.');
    }
    if (form.querySelector && !form.querySelector('[data-fm-note]')) {
      // A note beside a selection is not decoration: measured on the board of
      // 2026-08-16, two of twenty answers carried a note that contradicted the
      // chosen option and held what the captain actually meant.
      window.console.warn('fm-board: the form for "' + key +
        '" has no note field, so the captain can only pick an option and cannot say what he meant.');
    }
    if (!form.querySelectorAll) {
      return;
    }
    var radios = form.querySelectorAll('input[type="radio"]');
    for (var i = 0; i < radios.length; i++) {
      if (radios[i].name && radios[i].name !== key) {
        window.console.warn('fm-board: radio name "' + radios[i].name +
          '" does not match data-fm-question "' + key +
          '"; the answer is read from the form instead.');
        return;
      }
    }
  }

  function init() {
    pickLanguage();
    QUESTIONS = [];
    STATE = {};
    // The playbook wants data-lavish-question on the question wrapper. Derive it
    // from data-fm-question so a board body declares the key exactly once.
    var forms = document.querySelectorAll('form[data-fm-question]');
    for (var i = 0; i < forms.length; i++) {
      var key = forms[i].getAttribute('data-fm-question');
      if (!forms[i].hasAttribute('data-lavish-question')) {
        forms[i].setAttribute('data-lavish-question', key);
      }
      reportFormDefects(forms[i]);
      if (key && !(key in STATE)) {
        QUESTIONS.push({ key: key, label: questionLabel(forms[i]), jump: jumpTarget(forms[i]) });
        STATE[key] = 'blank';
      }
    }
    buildStrip();
    watchForBridge(6, 60);
  }

  document.addEventListener('submit', onSubmit);
  document.addEventListener('change', onChange);
  document.addEventListener('click', onStripClick);

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
}());
