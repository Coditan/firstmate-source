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
 * throw there: it detects the missing bridge once and reveals the .fm-offline
 * notice instead of failing on submit.
 */
(function () {
  'use strict';

  function bridge() {
    var l = window.lavish;
    return l && typeof l.queuePrompt === 'function' ? l : null;
  }

  function answerOf(form) {
    var data = new FormData(form);
    var key = form.getAttribute('data-fm-question');
    var choice = data.get(key);
    var note = form.querySelector('[data-fm-note]');
    var text = note && note.value ? note.value.trim() : '';
    if (!choice && !text) {
      return null;
    }
    return { choice: choice ? String(choice) : '', note: text };
  }

  function promptFor(label, answer) {
    var parts = [];
    parts.push('Entscheidung "' + label + '": ');
    parts.push(answer.choice ? answer.choice : '(keine Option gewaehlt)');
    if (answer.note) {
      parts.push(' - Anmerkung des Captains: ' + answer.note);
    }
    return parts.join('');
  }

  function markQueued(form, answer) {
    var box = form.querySelector('.fm-queued');
    if (!box) {
      return;
    }
    box.textContent = answer.choice
      ? 'Vorgemerkt: ' + answer.choice
      : 'Vorgemerkt: freie Anmerkung';
    box.classList.add('is-shown');
  }

  function onSubmit(event) {
    var form = event.target;
    if (!form || !form.matches || !form.matches('form[data-fm-question]')) {
      return;
    }
    event.preventDefault();

    var answer = answerOf(form);
    if (!answer) {
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
      text: label + ': ' + (answer.choice || 'freie Anmerkung'),
      // queueKey is what makes a changed answer REPLACE the previous unsent one.
      queueKey: key,
      element: form,
      data: { question: key, answer: answer.choice, note: answer.note }
    });
    markQueued(form, answer);
  }

  function revealOffline() {
    var notes = document.querySelectorAll('.fm-offline');
    for (var i = 0; i < notes.length; i++) {
      notes[i].classList.add('is-shown');
    }
  }

  // Lavish injects its own runtime, and this inlined script may run before that
  // injection lands. A single check at startup would therefore report a served
  // board as offline. Poll briefly instead and give up only after the bridge has
  // had a fair chance to appear; the submit path re-checks live regardless, so a
  // wrong guess here costs an advisory line and never a lost answer.
  function watchForBridge(triesLeft) {
    if (bridge()) {
      return;
    }
    if (triesLeft <= 0) {
      revealOffline();
      return;
    }
    window.setTimeout(function () {
      watchForBridge(triesLeft - 1);
    }, 400);
  }

  function init() {
    // The playbook wants data-lavish-question on the question wrapper. Derive it
    // from data-fm-question so a board body declares the key exactly once.
    var forms = document.querySelectorAll('form[data-fm-question]');
    for (var i = 0; i < forms.length; i++) {
      if (!forms[i].hasAttribute('data-lavish-question')) {
        forms[i].setAttribute('data-lavish-question', forms[i].getAttribute('data-fm-question'));
      }
    }
    watchForBridge(6);
  }

  document.addEventListener('submit', onSubmit);

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
}());
