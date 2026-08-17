# The standard board layout

Reference for the components `bin/fm-board.sh` makes available to a board body.
The script's header owns the build mechanics and the no-network guard; this file owns the markup each component expects.

## The design language

Boards are set in **Tally**, this vessel's own design language, adopted 2026-08-17.
The full reference - the two laws, the seven marks, the three hues, the measured contrast figures, and the reasoning behind each component - is the scout report `data/coditan-design-language/report.md` and its specimen, which live in this home's private records rather than in this repository.
Read them before changing a token or adding a component, and re-measure rather than asserting; `bin/board-assets/layout.css` carries the figures a reader without those records still needs.

Two of its laws bind everything below.
Ink is the record, and colour is a claim on the captain and nothing else - three hues exist, and under way, landed, and failed get none of them.
Every sheet declares its own incompleteness, in the same instrument that carries its counts, which is what `.fm-reserve` is for.

Tally is this vessel's language and nobody else's.
Every other vessel applies the fleet's board rules with its own design and its own name, so nothing here is sent onward as a fleet standard.

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

The fragment is inserted inside `<div class="fm-wrap">`, after the header and the tally strip container.
It carries no `<style>`, no `<script>`, and no document scaffolding.

    bin/fm-board.sh --title "Entscheidungsbrett" --subtitle "31. Juli 2026" \
      --body body.html --out .lavish/decisionboard-2026-07-31.html

Then open it with `bin/fm-lavish.sh <file>` - never bare `lavish-axi`.

Two worked bodies are kept as the things to copy, and they are pinned by `tests/fm-board.test.sh` so neither can silently rot:

    docs/examples/board-body-decision.html   the DECISION shape
    docs/examples/board-body-report.html     the REPORT shape

Three things the builder writes and a body never does.
Writing any of them into a body creates a second copy of something that is already recorded, and the copy is the one that goes stale.

- **The vessel name**, in every board's header. `bin/fm-board.sh --help` owns how it is resolved; a board it cannot resolve is refused rather than written unattributed.
- **The mark set**, the seven symbols referenced as `<use href="#fm-mk-open">` and its siblings: `open`, `pencil`, `struck`, `gate`, `held`, `run`, `void`.
- **The tally strip**, container and contents both.

## Layout components

### Sections and containers

| Class | Use |
| --- | --- |
| `fm-wrap` | The sheet. Added by the builder; do not repeat it. |
| `fm-issue` | The header block. Added by the builder; do not repeat it. |
| `fm-vessel` | The building vessel's name. **Written by the builder only.** |
| `fm-sub` | One dim line beside the title. |
| `fm-note` | Dim secondary text anywhere. |
| `fm-cap` | A tracked uppercase caption, in the form's own smallest voice. |
| `fm-panel` | A bordered surface around a table or block. |
| `fm-scroll` | **The only sanctioned way to carry content wider than the viewport.** Wrap a wide table or diagram in it. Never put horizontal scrolling on the body. |
| `fm-table` | A plain `<table>` styling; it keeps a `min-width`, so put it inside `fm-scroll`. Numeric cells take `fm-num-col`. |
| `fm-mono` | Monospace a span of text without making it `<code>`. |
| `fm-foot` | Provenance stamp at the bottom; `--footer` writes one. |

### The tally strip - `fm-tally`

A live count of the entries that have not been sent back, one square each, above the entries.

**A board body writes nothing here.**
The builder emits `<div class="fm-tally" hidden></div>` and `bin/board-assets/board.js` fills it from the board's own question forms.
A count typed by hand is a count that can be wrong, and a wrong count of what reached the captain is the defect this component exists to make visible.
A board that asks no questions leaves the container hidden and prints nothing.

The semantics are the component, and they are not a preference:

- Choosing an option turns a square to **pencil** and **does not decrement** the count.
- Only a completed submit turns a square **struck** and decrements it.
- An empty submit, and a submit on a board opened with no Lavish server, send nothing and therefore move nothing.
- Changing an answer after sending returns its square to pencil and the count with it, because the answer now showing is one nobody has received.

That distinction is the same one "Decision controls" states below, and it is the captain's own recorded failure: a board where he pressed send and nobody heard.
`tests/fm-board-behavior.test.mjs` asserts both directions, because the wrong one is what this exists to fix.

### The reservation block - `fm-reserve`

What this sheet does **not** show, **above the entries and never after them**.
A declaration printed under the entries is one the captain reads after he has already decided.

    <div class="fm-reserve">
      <span class="fm-cap">Vorbehalt &middot; was dieses Blatt nicht zeigt</span>
      <ul><li>...</li></ul>
    </div>

The block is available to any board that has something to declare.
The one surface that currently **requires** it is the decision board, whose three sentences are owned by `.agents/skills/decisionboard`, in "What the board must not claim".

### The register and its entries

    <div class="fm-grid">
      <div class="fm-card is-gate" id="e1">
        <div class="fm-chead">
          <div class="fm-num">1</div>
          <div class="fm-ctitle">The question</div>
          <div class="fm-tags">
            <span class="fm-tag is-gate"><svg class="fm-mk" aria-hidden="true"><use href="#fm-mk-gate"></use></svg>gate for 2-5</span>
          </div>
        </div>
        <p class="fm-cid">the-record-id</p>
        <p class="fm-stake">What is at stake.</p>
        <p class="fm-ev">The evidence under it.</p>
      </div>
    </div>

Entries are rows in a register, not cards on a dashboard: `fm-grid` is one column and the entries alternate ground, which is how a wide row is tracked across with the eye.
Give each entry an `id` so its tally square can jump to it.
`is-gate` marks the entry that decides others; `is-void` strikes the title of a record that failed and is asking for nothing.
`is-wide` is accepted and now redundant, so a body written against the older grid keeps building.
Tag variants: `is-gate`, `is-hot`, `is-held`, `is-calm`.
A chip always spells its state out in a word and carries its mark; no chip is ever a bare colour.

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

**Standing bar** - how long something has waited.

    <div class="fm-age is-hot"><span>seit 29.07.</span>
      <div class="fm-agebar"><i style="width:60%"></i></div><span>3 Tage</span></div>

**Distribution bar** - `.fm-dist` with one `<span class="fm-d1">` per segment, proportional, and a `.fm-dist-legend` under it.
Fill classes are `fm-d1`, `fm-d2`, `fm-d3`, and `fm-dn` for the unclaimed remainder; widths are set inline by the generator.
**No text goes inside a fill**: no single label colour clears AA on every fill, so the counts are direct-labelled in ink above the bar and in the legend.

**Status line** - a run of steps with the reached ones struck and the current one barred.

    <div class="fm-statusline">
      <div class="fm-step is-done"><svg class="fm-mk" aria-hidden="true"><use href="#fm-mk-struck"></use></svg><span>reported</span></div>
      <div class="fm-step-link"></div>
      <div class="fm-step is-now"><svg class="fm-mk fm-mk-run" aria-hidden="true"><use href="#fm-mk-run"></use></svg><span>waiting on the captain</span></div>
    </div>

There are no numeric bullets: the marks already say what happened, and a number would say it twice.

**Stat strip** - `fm-stats` with `fm-stat` children (`is-hot`, `is-gate`, `is-calm`).

### Decision controls

`bin/board-assets/board.js` implements the Lavish `input` playbook once, so a board declares markup only and never repeats a submit handler.

    <form class="fm-field" data-fm-question="upstream-strategie" data-fm-label="Upstream-Strategie">
      <span class="fm-cap">Dein Zeichen</span>
      <div class="fm-opts">
        <label class="fm-opt">
          <input type="radio" name="upstream-strategie" value="selektiv">
          <span><b>Selektiv</b><span class="fm-rec">nächstliegend</span>
          <em>Only this category has ever merged there.</em></span>
        </label>
      </div>
      <textarea class="fm-free" data-fm-note placeholder="Begründung (optional)"></textarea>
      <button type="submit" class="fm-submit">Antwort vormerken</button>
      <div class="fm-queued"></div>
    </form>

**A board that asks the captain to decide something offers these controls, always.**
Stating the options in prose and leaving him to answer in chat puts the answer in the one channel with no memory.
`.agents/skills/decisionboard` owns that obligation; this file owns the markup that discharges it.

The note field is not optional decoration and it is read.
Measured on the board of 2026-08-16, two of twenty answers carried a note that contradicted the selected option, and the note held what the captain actually meant both times.
So every option set carries one, and `board.js` names a form built without one on the console at startup.

`is-void` on an option strikes it through: a settled option is struck, never removed, because a sheet that silently drops an answered option hides that it was ever asked.

The radio `name` must equal `data-fm-question`.
A board that breaks that rule still submits - `board.js` falls back to the form's own checked radio and warns on the console - but the two are meant to be one declared key.
Selecting an option only updates local state; the explicit submit queues exactly one prompt, under the question key as `queueKey`, so re-answering replaces the earlier unsent answer instead of appending a second one.
Queued state is shown separately from selected state, in the same `fm-queued` box, and it is the same distinction the tally strip counts.
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
