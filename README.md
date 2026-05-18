# ex_css_analyzer

This is a Phoenix HEEX CSS coverage analyzer extracted from a real app. It has
two parts:

1. `mix heex_class_analyzer` builds a static graph of HEEX-rendered classes.
2. `css_coverage.mjs` compares `assets/css/app.css` against that graph and
   reports matched, runtime-matched, dynamic, unmatched, and skipped selectors.

Parts of this repository are written or updated with LLMs.

## Caveat

This is practical tooling, not a polished package. It is intentionally shipped
as source files you copy into an app. It works for the Phoenix/HEEX patterns it
was built against, and it is conservative where static analysis would otherwise
guess too much.

## Install

Copy these files into your Phoenix app:

```text
lib/mix/tasks
├── css_coverage.mjs
├── heex_class_analyzer.ex
└── heex_class_analyzer
    ├── class_facts.ex
    ├── discovery.ex
    ├── expression.ex
    ├── graph.ex
    ├── heex_parser.ex
    ├── node.ex
    ├── output.ex
    ├── registry.ex
    └── resolver.ex
```

Install the Node dependencies in the target project:

```bash
npm install --save-dev postcss postcss-import postcss-selector-parser
```

Add generated analysis output to `.gitignore`:

```text
analysis/
```

## Usage

Run the HEEX analyzer first:

```bash
mix heex_class_analyzer
```

That writes graph v2 output to:

```text
analysis/heex-class-graph.json
```

Then run CSS coverage:

```bash
node lib/mix/tasks/css_coverage.mjs
```

Useful flags:

```bash
node lib/mix/tasks/css_coverage.mjs --list-unmatched
node lib/mix/tasks/css_coverage.mjs --list-runtime
node lib/mix/tasks/css_coverage.mjs --stats
node lib/mix/tasks/css_coverage.mjs --output analysis/css-coverage.json
```

Destructive cleanup flags operate only on actual unmatched selectors and unused
keyframes. Runtime-matched selectors are not removed or invalidated.

```bash
node lib/mix/tasks/css_coverage.mjs --invalidate-unmatched
node lib/mix/tasks/css_coverage.mjs --restore-unmatched
node lib/mix/tasks/css_coverage.mjs --remove-unmatched
```

## HEEX Analyzer

`mix heex_class_analyzer` scans `lib/*_web/**/*.ex` and `.heex` templates. It
discovers modules, imports, aliases, `use` declarations, function components,
embedded templates, and inline `~H` sigils.

The output is a single graph:

```json
{
  "version": 2,
  "entries": [{ "ref": "fn:MyAppWeb.PageLive:render:1:0" }],
  "trees": {
    "fn:MyAppWeb.PageLive:render:1:0": []
  },
  "cycles": [],
  "unresolved": []
}
```

Component calls are stored as graph edges instead of duplicated inline trees:

```json
{
  "component_refs": ["fn:MyAppWeb.Components:button:1:0"],
  "callsite": {
    "tag": ".button",
    "from": "fn:MyAppWeb.PageLive:render:1:0"
  }
}
```

Each normal node stores compact class facts instead of class permutations:

```json
{
  "tag": "button",
  "static": ["btn"],
  "variants": [],
  "classes": {
    "static": ["btn"],
    "optional": ["is-active"],
    "exclusive": [[["tone-danger"], ["tone-neutral"]]],
    "dynamic": []
  },
  "repeat": false,
  "children": []
}
```

Class fact buckets mean:

- `static`: always present together.
- `optional`: may be present and may co-exist with other optional classes.
- `exclusive`: mutually exclusive branch options from `if`, `case`, `cond`, etc.
- `dynamic`: unresolved runtime class sources with provenance.

The analyzer also handles several Phoenix-specific cases:

- `<.link>` is modeled as an `a` tag for selectors such as `.menu a:hover`.
- `render_slot(@inner_block)` and named slots are preserved as slot
  placeholders. CSS coverage places caller slot content under the component
  node that renders it.
- Standalone templates can resolve tags like `Layouts.admin_content` by module
  suffix if alias metadata is unavailable.
- Helpers returning `Phoenix.HTML.raw/1` produce raw HTML placeholders. CSS
  coverage lets those placeholders satisfy one immediate child selector segment
  under the HEEX parent, such as `.markdown p`, without assuming arbitrary deep
  descendants.

## CSS Coverage

`css_coverage.mjs` parses CSS with PostCSS and matches selectors right-to-left
against rendered HEEX contexts. Component refs are materialized as DOM children,
not wrapper nodes. Context records store parent and previous-sibling ids, so
descendant, child, adjacent sibling, and general sibling combinators can be
checked structurally.

Report buckets:

- `matched`: the HEEX graph proves the selector can match rendered DOM.
- `runtime_matched`: HEEX proves the surrounding structure, and runtime evidence
  explains missing class atoms.
- `possibly_dynamic`: unresolved HEEX class facts could explain the selector.
- `unmatched`: no static, dynamic, or runtime evidence explains the selector.
- `skipped`: selectors that are not class-matchable, such as `:root` or
  element-only selectors.

Runtime evidence comes from:

- JavaScript string literals in asset JS files or explicit `--js` paths.
- Phoenix built-in runtime classes such as `phx-drop-target-active`.
- CSS imported from `node_modules`, which covers library-generated DOM such as
  Plyr classes.

Runtime evidence can satisfy missing class names, but it cannot invent DOM
structure. For example, `.display-uploaded-player .plyr` can be
`runtime_matched` if `.display-uploaded-player` is in HEEX and `.plyr` comes
from package CSS, but a selector with no HEEX-supported path remains unmatched.

## Pseudo-Selectors

State pseudo-classes and pseudo-elements such as `:hover`, `:focus`, `::before`,
and `::after` do not add class requirements.

`:not(.class)` is treated as a negative class condition rather than a positive
required class. That lets selectors like this match known button classes:

```css
.media-library-card__danger-action:hover:not(.media-upload-btn-disabled)
```

Unsupported structural pseudo-classes that require subtree reasoning remain
conservative.

## Removing Dead CSS

`--remove-unmatched` removes unmatched selectors and unused keyframes from the
CSS source:

- If a rule has multiple selectors, only unmatched selectors are removed.
- If all selectors in a rule are unmatched, the whole rule is removed.
- Empty `@media` or similar at-rules are removed after their contents are
  removed.
- Runtime-matched selectors are left alone.

Use `--invalidate-unmatched` first if you want a reversible browser check. It
prefixes unmatched selectors with `____unmatched___`; `--restore-unmatched`
removes that marker.

## Plans

The implementation plans copied with this repository document the major design
steps and follow-up fixes:

- `docs/plans/260517-2105-heex-class-graph-analyzer.md`
- `docs/plans/260517-2256-heex-class-facts-context-index.md`
- `docs/plans/260518-1116-heex-runtime-class-evidence.md`

## Contributing

Issues and PRs are welcome. If a PR is generated or heavily assisted by an LLM,
include the prompt or a short explanation of the bug or edge case it addresses.
