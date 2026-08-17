# The standard board layout

Reference for the components `bin/fm-board.sh` makes available to a board body.
The script's header owns the build mechanics and the no-network guard; this file owns the markup each component expects.

## Why boards are built, not hand-written

Every board used to carry its own layout, written from scratch per board.
Two things followed from that, and both were measured rather than assumed.

The layout drifted, because nothing was shared.
And the Lavish-recommended CDN snippet kept coming back with it: on 2026-07-31, eleven of the twelve boards under `.lavish/` pulled three files from `cdn.jsdelivr.net`, including `@tailwindcss/browser`, the Tailwind browser runtime that recompiles the CSS in the reader's browser on every open.
That is the load cost the captain asked to be rid of.

Lavish's own guidance puts that CDN snippet third, behind a named user preference and behind the subject project's design system.
A stated preference for a board that opens fast is a named user preference, so the third choice was no longer available.

The layout is therefore one versioned artifact:

    bin/board-assets/layout.css   styling   (one owner)
    bin/board-assets/board.js     behavior  (one owner)

`bin/fm-board.sh` inlines both into every board.
Inlining rather than linking siblings is deliberate: a board must render when opened straight from disk with no Lavish server, and `lavish-axi export` must keep producing one portable file.
A self-contained board satisfies both without a copying step.

## Guarantees

- **No network requests.** No CDN, no remote font, script, image, or stylesheet. Enforced by the builder, not by convention.
- **System fonts.** No webfont is loaded, so text paints immediately.
- **Light and dark**, following the reader's device via `prefers-color-scheme`, both directions readable.
- **Responsive** from a narrow phone to a wide desktop, with no horizontal scrolling at body level. Wide content scrolls inside its own container.
- **Navigational links stay allowed.** `<a href="https://...">` is not a network request.

## Writing a body fragment

The fragment is inserted inside `<div class="fm-wrap">`.
It carries no `<style>`, no `<script>`, and no document scaffolding.

    bin/fm-board.sh --title "Entscheidungsbrett" --subtitle "31. Juli 2026" \
      --body body.html --out .lavish/decisionboard-2026-07-31.html

Then open it with `bin/fm-lavish.sh <file>` - never bare `lavish-axi`.

## Layout components

### Sections and containers

| Class | Use |
| --- | --- |
| `fm-wrap` | Added by the builder; do not repeat it. |
| `fm-sub` | One dim line under the title. |
| `fm-note` | Dim secondary text anywhere. |
| `fm-panel` | A bordered surface around a table or block. |
| `fm-scroll` | **The only sanctioned way to carry content wider than the viewport.** Wrap a wide table or diagram in it. Never put horizontal scrolling on the body. |
| `fm-table` | A plain `<table>` styling; it keeps a `min-width`, so put it inside `fm-scroll`. |
| `fm-mono` | Monospace a span of text without making it `<code>`. |
| `fm-foot` | Provenance line at the bottom; `--footer` writes one. |

### Cards

    <div class="fm-grid">
      <div class="fm-card is-gate is-wide">
        <div class="fm-chead">
          <div class="fm-num">1</div>
          <div class="fm-ctitle">The question</div>
          <div class="fm-tags"><span class="fm-tag is-gate">gate for 2-5</span></div>
        </div>
        <p class="fm-stake">What is at stake.</p>
        <p class="fm-ev">The evidence under it.</p>
      </div>
    </div>

`fm-grid` reflows from one column on a phone to as many as fit.
`is-gate` marks a card as the one that decides others; `is-wide` makes it span the full row.
Tag variants: `is-gate`, `is-hot`, `is-calm`.

### Folded records

`fm-variants` is a `<details>` block for the records a card stands in for.

    <details class="fm-variants">
      <summary>2 weitere Aufzeichnungen zu dieser Untersuchung</summary>
      <ul>
        <li><code>panel-x-a-decision-store-location</code> - gleiche Frage, andere Formulierung</li>
        <li><code>panel-x-b-decision-store-location</code> - gleiche Frage, andere Formulierung</li>
      </ul>
    </details>

Use it wherever a board shows one item in place of several.
`bin/fm-decision-inventory.sh` folds a judged panel group down to the judge's records on an assumption it cannot verify, so a decision board renders this block on every decision card and lists the group's unpaired variants the same way.
A sea chart carries the same fold and renders the same block, for the same reason.
A folded record that is not rendered is a question the captain cannot see.

### Graphics

Graphics are inline SVG and CSS - no diagram library, and nothing that only decorates.

**Gate map** - what decides what.
An inline `<svg>` inside `.fm-map`.
The SVG keeps a `min-width` so shapes stay legible on a phone and scroll inside the panel instead of squashing.
Node classes: `fm-map-node`, `fm-map-node-gate`, `fm-map-node-open`.
Edge classes: `fm-map-edge`, `fm-map-edge-gate`, and `fm-map-edge-soft` for a relationship that is weaker than a recorded one.
Label text is `fm-map-dim` where it should read as secondary.
Add a `.fm-legend` under it.

**Age bar** - how long something has waited.

    <div class="fm-age is-hot"><span>seit 29.07.</span>
      <div class="fm-agebar"><i style="width:60%"></i></div><span>3 Tage</span></div>

**Distribution bar** - `.fm-dist` with one `<span>` per segment, labelled and proportional, and a `.fm-dist-legend` under it.
Segment widths and colours are set inline by the generator.

**Status line** - a run of steps with the reached ones filled.

    <div class="fm-statusline">
      <div class="fm-step is-done"><b>&check;</b><span>reported</span></div>
      <div class="fm-step-link"></div>
      <div class="fm-step is-now"><b>2</b><span>waiting on the captain</span></div>
    </div>

**Stat strip** - `fm-stats` with `fm-stat` children (`is-hot`, `is-gate`, `is-calm`).

### Decision controls

`bin/board-assets/board.js` implements the Lavish `input` playbook once, so a board declares markup only and never repeats a submit handler.

    <form data-fm-question="upstream-strategie" data-fm-label="Upstream-Strategie">
      <div class="fm-opts">
        <label class="fm-opt">
          <input type="radio" name="upstream-strategie" value="selektiv">
          <span><b>Selektiv</b><span class="fm-rec">nächstliegend</span><br>
          <em>Only this category has ever merged there.</em></span>
        </label>
      </div>
      <textarea class="fm-free" data-fm-note placeholder="Begründung (optional)"></textarea>
      <button type="submit" class="fm-submit">Antwort vormerken</button>
      <div class="fm-queued"></div>
    </form>

The radio `name` must equal `data-fm-question`.
A board that breaks that rule still submits - `board.js` falls back to the form's own checked radio and warns on the console - but the two are meant to be one declared key.
Selecting an option only updates local state; the explicit submit queues exactly one prompt, under the question key as `queueKey`, so re-answering replaces the earlier unsent answer instead of appending a second one.
Queued state is shown separately from selected state, in the same `fm-queued` box.
A submit that carries neither a choice nor a note is never silent: the box says so, in `is-warn` colour.

Add one `<div class="fm-offline"></div>` per board.
It stays hidden on a served board and appears when the board was opened with no Lavish server, where queueing has nowhere to go.
It is advisory and reversible: a queue that succeeds takes it back down, and so does a Lavish runtime that appears while the board is still polling for one.
That poll gives up after about 122 seconds, so a runtime landing later leaves the notice standing until the captain's first successful submit clears it.

German boards are written with real umlauts - ä, ö, ü, and ß - never ae, oe, ue, or ss.
That applies to the board's own text, not to code identifiers, attribute names, or CSS values.

## Verifying a board

    bin/fm-board.sh --check <file>...

Runs the same guard over existing files.
`tests/fm-board.test.sh` pins the refusals, including the exact CDN regression above.

That checks what a board is made of, not whether it can be used.
To open a board in a real browser, read what its decisions actually carry, answer one, and see the answer arrive, load the `run-decisionboard` skill and run the driver beside it.
A board that was only built and looked at has never been shown to be answerable, which is how seven decisions once reached the captain with nothing on the page to click.

### What the guard covers

`bin/fm-board.sh --help` states the exact patterns and the limits it does not cover; read it there rather than here.

One asymmetry is worth knowing while writing a body: a navigational `<a href="https://...">` is allowed and must stay allowed, because AGENTS.md section 9 requires boards to carry full PR URLs, while an `href` on a subresource element is refused.

It is a guard against the regression that actually happened, not a sandbox.

## Maintaining this file

Keep it to what a board author needs: the component list and the markup each expects.
Build mechanics, flags, and the guard's exact patterns belong in `bin/fm-board.sh`'s header and `--help`, not here.
