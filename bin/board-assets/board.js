/* board.js - the single owner of Firstmate board behavior.
 *
 * bin/fm-board.sh inlines this file into every board, so a board carries its
 * own behavior and loads no script from the network.
 *
 * It implements the Lavish `input` playbook once, so a board body only has to
 * declare markup and never repeats a submit handler:
 *
 *   <form data-fm-question="upstream-strategy" data-fm-label="Upstream-Strategie">
 *     <div class="fm-opts">
 *       <label class="fm-opt"><input type="radio" name="upstream-strategy" value="selektiv"> ...</label>
 *     </div>
 *     <textarea class="fm-free" data-fm-note placeholder="..."></textarea>
 *     <button type="submit" class="fm-submit">Antwort vormerken</button>
 *     <div class="fm-queued">Vorgemerkt.</div>
 *   </form>
 *
 * Playbook obligations this file discharges:
 *   - radio changes only update LOCAL state; they never queue a prompt,
 *   - the explicit submit queues EXACTLY ONE prompt for the final answer,
 *   - queueKey is the question key, so re-answering replaces the earlier
 *     unsent answer for that question instead of appending a second one,
 *   - queued state is displayed separately from selected state.
 *
 * A board is also opened directly from disk, with no Lavish server and thus no
 * window.lavish. That is a supported way to read a board, so this file must not
 * throw there: it reveals the .fm-offline notice instead of failing on submit.
 * The notice is advisory and reversible - a Lavish runtime that lands late hides
 * it again, because a board that keeps saying answers cannot be sent back while
 * it is sending them is worse than one that says nothing.
 *
 * No submit is silent. An answer that carries neither a choice nor a note says
 * so in the form's own .fm-queued box rather than doing nothing at all, and a
 * form built without that box is named on the console at startup, so the one
 * position where nothing could be shown is still not a quiet one.
 *
 * Every string this file shows or queues follows the board's own --lang, read
 * off <html lang>. See STRINGS below.
 */
(function () {
  'use strict';

  // ---- the strings this file puts on a board, per language -----------------
  //
  // Every visible string here follows the board's own --lang, read off
  // <html lang>, which bin/fm-board.sh already writes from that flag. An
  // English board that answered in German is not a cosmetic defect: it tells
  // the captain the board was assembled by something that did not know what
  // language it was speaking, on the one surface he is asked to trust.
  //
  // To add a language, add an entry. An unknown one falls back to English and
  // SAYS SO on the console, rather than silently substituting a language the
  // board is not written in.
  var STRINGS = {
    de: {
      decision: 'Entscheidung',
      noChoice: '(keine Option gewählt)',
      note: 'Anmerkung des Captains',
      noteGoverns: 'Widerspricht die Anmerkung der gewählten Option, gilt die Anmerkung.',
      freeNote: 'freie Anmerkung',
      queued: 'Vorgemerkt',
      unanswered: 'Nichts vorgemerkt: bitte eine Option wählen oder eine Anmerkung schreiben.'
    },
    en: {
      decision: 'Decision',
      noChoice: '(no option selected)',
      note: 'Note from the captain',
      noteGoverns: 'Where the note contradicts the selected option, the note is the answer.',
      freeNote: 'a note only',
      queued: 'Queued',
      unanswered: 'Nothing queued: choose an option or write a note.'
    }
  };

  var langWarned = false;

  function t() {
    var el = document.documentElement;
    var raw = el && el.getAttribute ? (el.getAttribute('lang') || '') : '';
    var tag = String(raw).toLowerCase().split('-')[0];
    if (STRINGS[tag]) {
      return STRINGS[tag];
    }
    if (!langWarned && window.console && window.console.warn) {
      langWarned = true;
      window.console.warn('fm-board: no board strings for lang "' + raw +
        '"; using English. Add the language to board.js rather than letting a board mix two.');
    }
    return STRINGS.en;
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

  // The note is not a comment on the choice. Measured on one board of twenty
  // answers, two came back with a note that CONTRADICTED the selected option,
  // and in both cases the note carried what the captain actually meant. So a
  // note that is present is queued as the governing part of the answer, said
  // in words, rather than trailing the option as an aside an agent may skim.
  function promptFor(label, answer) {
    var s = t();
    var parts = [];
    parts.push(s.decision + ' "' + label + '": ');
    parts.push(answer.choice ? answer.choice : s.noChoice);
    if (answer.note) {
      parts.push('\n' + s.note + ': ' + answer.note);
      parts.push('\n' + s.noteGoverns);
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
    var s = t();
    say(form, s.queued + ': ' + (answer.choice ? answer.choice : s.freeNote), false);
  }

  function markUnanswered(form) {
    say(form, t().unanswered, true);
  }

  function onSubmit(event) {
    var form = event.target;
    if (!form || !form.matches || !form.matches('form[data-fm-question]')) {
      return;
    }
    event.preventDefault();

    var answer = answerOf(form);
    if (!answer) {
      markUnanswered(form);
      return;
    }

    var key = form.getAttribute('data-fm-question');
    var label = form.getAttribute('data-fm-label') || key;
    var lavish = bridge();
    if (!lavish) {
      // Opened without a running Lavish server: there is nowhere to queue to.
      // Say so rather than pretending the answer was recorded.
      revealOffline();
      return;
    }

    lavish.queuePrompt(promptFor(label, answer), {
      tag: 'decision',
      text: label + ': ' + (answer.choice || t().freeNote),
      // queueKey is what makes a changed answer REPLACE the previous unsent one.
      queueKey: key,
      element: form,
      data: { question: key, answer: answer.choice, note: answer.note }
    });
    // The queue just worked, so any offline notice on this board is stale.
    showOffline(false);
    markQueued(form, answer);
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

  // bin/fm-board.sh REFUSES a built board whose question offers fewer than two
  // options, or carries no note field or no .fm-queued box. These warnings are
  // the same checks at runtime, for the one case the builder cannot see: a
  // board file edited by hand after it was built. The radio-name rule is
  // checked only here, because breaking it costs nothing - answerOf falls back
  // to the form's own checked control - so it is not worth a refusal.
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
      window.console.warn('fm-board: the question "' + key +
        '" has no note field, so a note that contradicts the chosen option has nowhere to go.');
    }
    if (!form.querySelectorAll) {
      return;
    }
    var opts = form.querySelectorAll('input[type="radio"]');
    if (opts.length < 2) {
      window.console.warn('fm-board: the question "' + key + '" offers ' + opts.length +
        ' selectable option(s); a decision needs at least two real alternatives.');
    }
    for (var i = 0; i < opts.length; i++) {
      if (opts[i].name && opts[i].name !== key) {
        window.console.warn('fm-board: radio name "' + opts[i].name +
          '" does not match data-fm-question "' + key +
          '"; the answer is read from the form instead.');
        return;
      }
    }
  }

  function init() {
    // The playbook wants data-lavish-question on the question wrapper. Derive it
    // from data-fm-question so a board body declares the key exactly once.
    var forms = document.querySelectorAll('form[data-fm-question]');
    for (var i = 0; i < forms.length; i++) {
      if (!forms[i].hasAttribute('data-lavish-question')) {
        forms[i].setAttribute('data-lavish-question', forms[i].getAttribute('data-fm-question'));
      }
      reportFormDefects(forms[i]);
    }
    watchForBridge(6, 60);
  }

  document.addEventListener('submit', onSubmit);

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
}());
