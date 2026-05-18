# HEEX Runtime Class Evidence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Teach CSS coverage to distinguish rendered HEEX selector matches from runtime JavaScript class evidence, while resolving simple server-side assign-derived class facts such as `@tie_class`.

**Architecture:** The Elixir HEEX analyzer will carry narrow local assign facts from the function body into class expression resolution, so classes produced by helper functions assigned before `~H` can become normal HEEX facts. The Node CSS coverage script will add a separate JavaScript string-literal evidence index and report selectors explained by runtime class strings as `runtime-matched`, not `matched`.

**Tech Stack:** Elixir Mix task modules under `lib/mix/tasks/heex_class_analyzer/*`, ExUnit tests under `test/mix/tasks/heex_class_analyzer/*`, Node.js ES modules in `lib/mix/tasks/css_coverage.mjs`, Node fixture tests under `test/*css_coverage*.mjs`, Phoenix HEEX fixture snippets.

---

## Status

- [x] Task 1: Add HEEX Clause Assign Fact Discovery
- [x] Task 2: Resolve Assign References in Class Expressions
- [x] Task 3: Prove Parent/Child Selector Matching for Assign-Derived Classes
- [x] Task 4: Add JavaScript Runtime Class Evidence Scanner
- [x] Task 5: Add `runtime-matched` Selector Classification
- [x] Task 6: Wire Runtime Evidence Into Reports and CLI Output
- [x] Task 7: Verify Against Current Muqui Selectors
- [x] Task 8: Full Project Verification
- [x] Follow-up: Resolve Phoenix `<.link>` as rendered anchor nodes and keep tag selector matching precise
- [x] Follow-up: Preserve named slot placement for `render_slot(@media)` / `render_slot(@inner_block)`

Verification note: focused analyzer and CSS coverage tests pass, `mix ex_dna`
passes, `mix compile --warnings-as-errors` passes, and `mix precommit` passes.
Follow-up verification also passes for `mix test test/mix/tasks/heex_class_analyzer`,
`node test/css_coverage_graph_test.mjs`, `node test/css_coverage_runtime_js_test.mjs`,
`node test/css_coverage_node_modules_test.mjs`, `mix heex_class_analyzer`, and
`node lib/mix/tasks/css_coverage.mjs --list-unmatched --list-runtime --stats --output analysis/css-coverage.json`.

## Implementation Notes Added After Follow-Up Fixes

- `runtime-matched` is a separate status from `matched`, `possibly_dynamic`,
  and `unmatched`. `--list-unmatched` prints only actual unmatched selectors
  and unused keyframes; `--list-runtime` prints runtime-matched selectors.
- Runtime evidence can satisfy missing class atoms, but it cannot invent DOM
  structure. The selector must still have a HEEX-proven path for the
  non-runtime portions.
- Runtime evidence is gathered from JavaScript string literals, Phoenix
  built-in runtime classes such as `phx-drop-target-active`, and CSS class names
  discovered in imported `node_modules` CSS. Package CSS evidence covers library
  DOM such as Plyr classes used under `.display-uploaded-player .plyr`.
- JavaScript scanning reads string literals from `"..."`, `'...'`, and static
  template literal chunks. It does not execute code or infer dynamic template
  substitutions.
- Selectors involving runtime classes remain protected from destructive
  unmatched operations: `--remove-unmatched`, `--invalidate-unmatched`, and
  `--restore-unmatched` only operate on actual unmatched selectors and unused
  keyframes.
- Server-side assign-derived classes are normal HEEX matches when discovery can
  capture narrow `assign/3` facts before a `~H` sigil and the resolver can trace
  the assigned helper return.
- Helpers returning `Phoenix.HTML.raw/1` create raw HTML placeholders. These
  placeholders can satisfy immediate child selectors such as Markdown-generated
  `.reveal-answer-text p`, but no longer mark arbitrary deep descendant
  selectors as matched.

---

## Target Behavior

### HEEX Assign-Derived Classes

This code should let `.podium-tied .podium-name` match as a normal rendered HEEX selector:

```elixir
assigns =
  assigns
  |> assign(:tie_class, podium_tie_class(assigns.entries))

~H"""
<div class={["flex flex-col gap-1", @tie_class]}>
  <p class="podium-name">...</p>
</div>
"""

defp podium_tie_class(entries) do
  case length(entries) do
    0 -> nil
    1 -> nil
    2 -> "podium-tied podium-tied--two"
    _ -> "podium-tied podium-tied--many"
  end
end
```

The analyzer should not evaluate arbitrary Elixir. It should only preserve simple local assign/variable facts and reuse the existing function-return resolver.

### Runtime JavaScript Classes

These Sortable options should not become HEEX matches:

```js
new Sortable(this.el, {
  draggable: ".item-entry",
  ghostClass: "sortable-ghost",
  chosenClass: "sortable-chosen",
  dragClass: "sortable-drag"
});
```

Selectors that depend on those classes should be classified as `runtime-matched` with file/line evidence from `assets/js/app.js`.

Report statuses:

- `matched` - HEEX graph proves the selector can match rendered DOM.
- `runtime-matched` - HEEX graph alone does not prove the selector, but JavaScript string evidence explains missing classes.
- `dynamic` - unresolved HEEX class facts may explain the selector.
- `unmatched` - no HEEX, dynamic, or runtime evidence explains it.

---

## Design Rules

1. Do not mark JavaScript evidence as normal HEEX evidence.
2. Scan JavaScript files once, not once per unmatched class.
3. Extract string literals only. Do not execute JavaScript and do not add a JavaScript parser unless a test proves the regex approach is insufficient.
4. Only static chunks of template literals count. A literal like `` `sortable-${state}` `` does not prove `sortable-ghost`; `` `sortable-ghost ${extra}` `` does.
5. Runtime evidence can satisfy missing class atoms, but it cannot invent DOM structure.
6. Assign facts should be narrow and deterministic. Unknown assign expressions remain dynamic with provenance.
7. Preserve current graph version unless the JSON shape changes for consumers. If new fields are added to graph entries, update fixtures and tests explicitly.

---

## Task 1: Add HEEX Clause Assign Fact Discovery

**Files:**

- Modify: `lib/mix/tasks/heex_class_analyzer/discovery.ex`
- Test: create `test/mix/tasks/heex_class_analyzer/discovery_assign_facts_test.exs`

**Step 1: Write failing tests for assign fact extraction**

Create `test/mix/tasks/heex_class_analyzer/discovery_assign_facts_test.exs`:

```elixir
defmodule Mix.Tasks.HeexClassAnalyzer.DiscoveryAssignFactsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.HeexClassAnalyzer.Discovery

  test "captures pipe assign facts before a HEEX sigil" do
    source = ~S'''
    defmodule SampleWeb.Podium do
      use Phoenix.Component

      def podium(assigns) do
        assigns =
          assigns
          |> assign(:tie_class, podium_tie_class(assigns.entries))

        ~H"""
        <div class={["podium-wrapper", @tie_class]}></div>
        """
      end

      defp podium_tie_class(entries), do: "podium-tied"
    end
    '''

    [module_info] = Discovery.parse_ex_content_for_test(source, "lib/sample_web/podium.ex")
    [function] = Enum.filter(module_info.functions, &(&1.name == :podium))

    assert [%{tie_class: {:podium_tie_class, _, _}}] = function.heex_assign_facts
  end

  test "captures direct assign facts before a HEEX sigil" do
    source = ~S'''
    defmodule SampleWeb.Podium do
      use Phoenix.Component

      def podium(assigns) do
        assigns = assign(assigns, :tie_class, podium_tie_class(assigns.entries))

        ~H"""
        <div class={["podium-wrapper", @tie_class]}></div>
        """
      end

      defp podium_tie_class(entries), do: "podium-tied"
    end
    '''

    [module_info] = Discovery.parse_ex_content_for_test(source, "lib/sample_web/podium.ex")
    [function] = Enum.filter(module_info.functions, &(&1.name == :podium))

    assert [%{tie_class: {:podium_tie_class, _, _}}] = function.heex_assign_facts
  end
end
```

**Step 2: Run tests to verify they fail**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/discovery_assign_facts_test.exs
```

Expected: compile failure because `Discovery.parse_ex_content_for_test/2` and `:heex_assign_facts` do not exist.

**Step 3: Expose a test-only parse helper**

Modify `lib/mix/tasks/heex_class_analyzer/discovery.ex`:

```elixir
if Mix.env() == :test do
  @doc false
  def parse_ex_content_for_test(content, relative_path) do
    parse_ex_content(content, relative_path, File.cwd!())
  end
end
```

Keep the helper test-only so the public task API stays small.

**Step 4: Add `heex_assign_facts` to function metadata**

Update `Discovery.function_info` docs and type to include:

```elixir
heex_assign_facts: [map()]
```

Each entry in `heex_assign_facts` corresponds to the same index in `heex_clauses` / `function_heex_clauses/1`. For functions with one `~H`, this is a one-element list.

**Step 5: Implement narrow assign fact extraction**

Inside function extraction, when a function body contains a `~H` sigil, inspect preceding statements in the same block and collect facts from these patterns:

```elixir
{:assign, _, [{:assigns, _, _}, {:|>, _, [_, {:assign, _, [assign_name_ast, expr]}]}]}
```

and:

```elixir
{:=, _, [{:assigns, _, _}, {:assign, _, [{:assigns, _, _}, assign_name_ast, expr]}]}
```

Normalize only atom assign names:

```elixir
:tie_class
```

Store the raw expression AST as the value:

```elixir
%{tie_class: expr_ast}
```

If the shape is not recognized, ignore it.

**Step 6: Run tests to verify they pass**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/discovery_assign_facts_test.exs
```

Expected: pass.

**Step 7: Run existing discovery tests**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer
```

Expected: pass.

**Step 8: Commit**

```bash
git add lib/mix/tasks/heex_class_analyzer/discovery.ex test/mix/tasks/heex_class_analyzer/discovery_assign_facts_test.exs
git commit -m "Track HEEX assign facts during discovery

Capture narrow assign/3 facts that are visible before inline HEEX sigils.
These facts let later analyzer phases resolve class attributes like @tie_class
without evaluating arbitrary Elixir."
```

---

## Task 2: Resolve Assign References in Class Expressions

**Files:**

- Modify: `lib/mix/tasks/heex_class_analyzer/expression.ex`
- Modify: `lib/mix/tasks/heex_class_analyzer/resolver.ex`
- Test: modify `test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs`

**Step 1: Write failing expression test for assign refs**

Add to the appropriate describe block in `test/mix/tasks/heex_class_analyzer/expression_test.exs` if it exists; otherwise create it:

```elixir
test "class list assign references are returned as assign refs" do
  assert {[], [{:assign_ref, :tie_class}]} =
           Expression.analyze({:expr, ~S([@tie_class])})
end
```

**Step 2: Run test to verify it fails**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/expression_test.exs
```

Expected: failure because `@tie_class` is currently treated as a dynamic assign.

**Step 3: Implement assign ref expression classification**

In `lib/mix/tasks/heex_class_analyzer/expression.ex`, add a specific clause before the generic assign fallback:

```elixir
defp walk_expr({:@, _, [{name, _, _}]}) when is_atom(name) do
  {[], [{:assign_ref, name}]}
end
```

Update the `variant()` type and module docs to include:

```elixir
| {:assign_ref, atom()}
```

**Step 4: Run expression tests**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/expression_test.exs
```

Expected: pass.

**Step 5: Write failing resolver test for assign-derived class facts**

Add to `test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs`:

```elixir
test "resolves class assign refs through local helper return values" do
  module_infos = [
    %{
      module: SampleWeb.Podium,
      source_file: "lib/sample_web/podium.ex",
      imports: [],
      aliases: %{},
      uses: [],
      heex_templates: [],
      functions: [
        %{
          name: :podium,
          arity: 1,
          body: nil,
          clauses: [],
          heex: ~s(<div class={["flex", @tie_class]}><p class="podium-name"></p></div>),
          heex_clauses: [~s(<div class={["flex", @tie_class]}><p class="podium-name"></p></div>)],
          heex_assign_facts: [
            %{
              tie_class:
                {:podium_tie_class, [line: 1],
                 [
                   {{:., [line: 1], [{:assigns, [line: 1], nil}, :entries]},
                    [no_parens: true, line: 1], []}
                 ]}
            }
          ]
        },
        %{
          name: :podium_tie_class,
          arity: 1,
          body: nil,
          heex: nil,
          clauses: [
            {:case, [],
             [
               {:length, [], [{:entries, [], nil}]},
               [
                 do: [
                   {:->, [], [[0], nil]},
                   {:->, [], [[1], nil]},
                   {:->, [], [[2], "podium-tied podium-tied--two"]},
                   {:->, [], [[{:_, [], nil}], "podium-tied podium-tied--many"]}
                 ]
               ]
             ]}
          ]
        }
      ]
    }
  ]

  registry = Registry.build(module_infos)
  graph = Resolver.resolve_graph(module_infos, registry)

  [div] = graph.trees["fn:SampleWeb.Podium:podium:1:0"]

  assert div.classes.static == ["flex"]
  assert div.classes.exclusive == [
           [
             ["podium-tied", "podium-tied--two"],
             ["podium-tied", "podium-tied--many"]
           ]
         ]
end
```

**Step 6: Run resolver test to verify it fails**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs
```

Expected: failure because resolver ignores `{:assign_ref, :tie_class}`.

**Step 7: Pass assign facts into graph tree resolution**

In `Resolver.graph_function_entries/1`, include per-clause assign facts:

```elixir
assign_facts =
  func_info
  |> Map.get(:heex_assign_facts, [])
  |> Enum.at(idx, %{})
```

Add `assign_facts: assign_facts` to the entry map.

Update `ensure_graph_tree/4`, `ensure_graph_tree_for_function/6`, `resolve_heex_tree/6`, `resolve_graph_children/6`, `resolve_graph_child/6`, `resolve_graph_node/6`, and component-call paths to carry an `assign_facts` map for the current tree.

**Step 8: Resolve `{:assign_ref, name}` variants**

Extend `resolve_fn_call_variants/5` or add a sibling helper that receives `assign_facts`:

```elixir
defp resolve_class_variants(variants, assign_facts, calling_module, registry, visited_fns, depth) do
  Enum.reduce(variants, {[], []}, fn
    {:assign_ref, name}, acc ->
      case Map.fetch(assign_facts, name) do
        {:ok, expr_ast} ->
          expr_ast
          |> assign_expr_to_resolution(calling_module, registry, visited_fns, depth)
          |> merge_resolved(acc)

        :error ->
          merge_resolved(
            {:statics, [{:dynamic, %{reason: "unresolved:assign_ref", expr: "@#{name}", chain: "@#{name}"}}]},
            acc
          )
      end

    variant, acc ->
      resolve_existing_variant(variant, acc)
  end)
end
```

The implementation should reuse existing function-call resolution:

- Local call AST becomes `resolve_fn_call({func_name, args}, ...)`.
- Remote call AST becomes `resolve_fn_call({module, func_name, args}, ...)`.
- String literal returns static classes.
- `nil` returns no classes.
- Unknown expression returns a dynamic fact.

Do not evaluate arbitrary expressions.

**Step 9: Run resolver tests**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs
```

Expected: pass.

**Step 10: Commit**

```bash
git add lib/mix/tasks/heex_class_analyzer/expression.ex lib/mix/tasks/heex_class_analyzer/resolver.ex test/mix/tasks/heex_class_analyzer
git commit -m "Resolve HEEX class assign references

Represent @assign class values as assign refs and resolve simple assign facts
through the existing helper return analyzer. Unknown assign refs remain dynamic
with explicit provenance."
```

---

## Task 3: Prove Parent/Child Selector Matching for Assign-Derived Classes

**Files:**

- Create: `test/fixtures/css_coverage_assign_facts/heex-class-graph.json`
- Create: `test/fixtures/css_coverage_assign_facts/app.css`
- Create: `test/css_coverage_assign_facts_test.mjs`

**Step 1: Add fixture graph**

Create `test/fixtures/css_coverage_assign_facts/heex-class-graph.json`:

```json
{
  "version": 2,
  "entries": [
    {
      "ref": "fn:SampleWeb.Podium:podium:1:0",
      "module": "SampleWeb.Podium",
      "source_file": "lib/sample_web/podium.ex",
      "name": "podium/1"
    }
  ],
  "trees": {
    "fn:SampleWeb.Podium:podium:1:0": [
      {
        "tag": "div",
        "static": ["flex"],
        "variants": [],
        "classes": {
          "static": ["flex"],
          "optional": [],
          "exclusive": [
            [
              ["podium-tied", "podium-tied--two"],
              ["podium-tied", "podium-tied--many"]
            ]
          ],
          "dynamic": []
        },
        "repeat": false,
        "children": [
          {
            "tag": "p",
            "static": ["podium-name"],
            "variants": [],
            "classes": {
              "static": ["podium-name"],
              "optional": [],
              "exclusive": [],
              "dynamic": []
            },
            "repeat": true,
            "children": []
          }
        ]
      }
    ]
  },
  "cycles": [],
  "unresolved": []
}
```

**Step 2: Add fixture CSS**

Create `test/fixtures/css_coverage_assign_facts/app.css`:

```css
.podium-tied .podium-name {
  font-size: 1rem;
}

.podium-tied--two .podium-name {
  font-size: 0.9rem;
}

.missing-parent .podium-name {
  color: red;
}
```

**Step 3: Add Node test**

Create `test/css_coverage_assign_facts_test.mjs`:

```js
import assert from "node:assert/strict";
import { cpSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const tmp = mkdtempSync(join(tmpdir(), "css-coverage-assign-facts-"));
cpSync("test/fixtures/css_coverage_assign_facts", tmp, { recursive: true });

try {
  const result = spawnSync(
    "node",
    [
      "lib/mix/tasks/css_coverage.mjs",
      "--css",
      join(tmp, "app.css"),
      "--analysis",
      tmp,
      "--output",
      join(tmp, "report.json")
    ],
    { encoding: "utf-8" }
  );

  assert.equal(result.status, 0, result.stderr || result.stdout);

  const report = JSON.parse(readFileSync(join(tmp, "report.json"), "utf-8"));
  const matched = new Set(report.matched_selectors || []);
  const unmatched = new Set(report.unmatched_selectors || []);

  assert(matched.has(".podium-tied .podium-name"));
  assert(matched.has(".podium-tied--two .podium-name"));
  assert(unmatched.has(".missing-parent .podium-name"));
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
```

**Step 4: Run test**

Run:

```bash
node test/css_coverage_assign_facts_test.mjs
```

Expected: pass if Task 2 class facts are emitted correctly and existing selector matching handles ancestor relationships.

**Step 5: Commit**

```bash
git add test/fixtures/css_coverage_assign_facts test/css_coverage_assign_facts_test.mjs
git commit -m "Test CSS coverage for assign-derived parent classes

Add a focused fixture proving that helper-derived parent class facts satisfy
descendant selectors such as .podium-tied .podium-name."
```

---

## Task 4: Add JavaScript Runtime Class Evidence Scanner

**Files:**

- Modify: `lib/mix/tasks/css_coverage.mjs`
- Create: `test/fixtures/css_coverage_runtime_js/app.css`
- Create: `test/fixtures/css_coverage_runtime_js/heex-class-graph.json`
- Create: `test/fixtures/css_coverage_runtime_js/assets/js/app.js`
- Create: `test/css_coverage_runtime_js_test.mjs`

**Step 1: Add runtime fixture files**

Create `test/fixtures/css_coverage_runtime_js/heex-class-graph.json`:

```json
{
  "version": 2,
  "entries": [
    {
      "ref": "fn:SampleWeb.Editor:render:1:0",
      "module": "SampleWeb.Editor",
      "source_file": "lib/sample_web/editor.ex",
      "name": "render/1"
    }
  ],
  "trees": {
    "fn:SampleWeb.Editor:render:1:0": [
      {
        "tag": "div",
        "static": ["item-entry"],
        "variants": [],
        "classes": {
          "static": ["item-entry"],
          "optional": [],
          "exclusive": [],
          "dynamic": []
        },
        "repeat": true,
        "children": []
      }
    ]
  },
  "cycles": [],
  "unresolved": []
}
```

Create `test/fixtures/css_coverage_runtime_js/app.css`:

```css
.sortable-ghost {
  opacity: 0.4;
}

.sortable-chosen {
  cursor: grabbing;
}

.sortable-drag {
  transform: rotate(1deg);
}

.item-entry:not(.sortable-ghost):not(.sortable-drag) {
  transition: transform 120ms ease;
}

.runtime-missing {
  color: red;
}
```

Create `test/fixtures/css_coverage_runtime_js/assets/js/app.js`:

```js
new Sortable(this.el, {
  draggable: ".item-entry",
  ghostClass: "sortable-ghost",
  chosenClass: 'sortable-chosen',
  dragClass: `sortable-drag`
});

const partial = `sortable-${state}`;
```

**Step 2: Add failing runtime scanner test**

Create `test/css_coverage_runtime_js_test.mjs`:

```js
import assert from "node:assert/strict";
import { cpSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const tmp = mkdtempSync(join(tmpdir(), "css-coverage-runtime-js-"));
cpSync("test/fixtures/css_coverage_runtime_js", tmp, { recursive: true });

try {
  const result = spawnSync(
    "node",
    [
      "lib/mix/tasks/css_coverage.mjs",
      "--css",
      join(tmp, "app.css"),
      "--analysis",
      tmp,
      "--js",
      join(tmp, "assets/js"),
      "--output",
      join(tmp, "report.json")
    ],
    { encoding: "utf-8" }
  );

  assert.equal(result.status, 0, result.stderr || result.stdout);

  const report = JSON.parse(readFileSync(join(tmp, "report.json"), "utf-8"));
  const runtimeMatched = new Set(report.runtime_matched_selectors || []);
  const unmatched = new Set(report.unmatched_selectors || []);

  assert(runtimeMatched.has(".sortable-ghost"));
  assert(runtimeMatched.has(".sortable-chosen"));
  assert(runtimeMatched.has(".sortable-drag"));
  assert(runtimeMatched.has(".item-entry:not(.sortable-ghost):not(.sortable-drag)"));
  assert(unmatched.has(".runtime-missing"));

  const evidence = report.runtime_evidence || {};
  assert.equal(evidence["sortable-ghost"][0].file.endsWith("assets/js/app.js"), true);
  assert.equal(typeof evidence["sortable-ghost"][0].line, "number");

  assert.equal(evidence["sortable-ghost"][0].literal, "sortable-ghost");
  assert.equal(evidence["sortable-drag"][0].literal, "sortable-drag");
  assert.equal(evidence["sortable-"][0], undefined);
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
```

**Step 3: Run test to verify it fails**

Run:

```bash
node test/css_coverage_runtime_js_test.mjs
```

Expected: failure because `--js`, runtime evidence, and `runtime_matched_selectors` do not exist.

**Step 4: Add CLI option**

In `lib/mix/tasks/css_coverage.mjs`, extend argument parsing and help:

```text
--js PATH         JavaScript file or directory to scan for runtime class strings. Can be repeated.
```

Default behavior:

- If no `--js` is provided and `assets/js` exists, scan `assets/js`.
- If no `--js` is provided and `assets/js` does not exist, scan nothing.
- Do not scan `node_modules`.

**Step 5: Implement JS file discovery**

Add helpers:

```js
function discoverJavaScriptFiles(paths) {
  // Accept files or directories.
  // Recurse directories.
  // Include .js and .mjs.
  // Exclude node_modules.
  // Return sorted unique file paths.
}
```

Use `fs.readdirSync` / `fs.statSync` or existing project helper patterns in `css_coverage.mjs`.

**Step 6: Implement string literal extraction**

Add:

```js
function extractJavaScriptStringLiterals(sourceText) {
  // Return [{ literal, line }]
  // Support "...", '...', and `...`.
  // For template literals, split static chunks around ${...}.
  // Preserve enough escaping support for common escaped quotes.
}
```

This does not need to be a full JavaScript parser. It must be deterministic and tested by the fixture.

**Step 7: Implement class token indexing**

Add:

```js
function buildRuntimeClassEvidence(files) {
  // Return Map<className, [{ file, line, literal }]>
}
```

Tokenization rule:

```js
const CLASS_TOKEN_RE = /[A-Za-z_][A-Za-z0-9_-]*(?:\[[^\]\s]+\])?/g;
```

Also support dotted selector strings by indexing `.item-entry` as `item-entry`.

**Step 8: Run scanner test**

Run:

```bash
node test/css_coverage_runtime_js_test.mjs
```

Expected: still fail until Task 5 classifies selectors, but `--js` should parse without an unknown-option error.

Do not commit yet unless scanner helpers are independently tested/exported. Prefer committing with Task 5 when behavior is visible in report output.

---

## Task 5: Add `runtime-matched` Selector Classification

**Files:**

- Modify: `lib/mix/tasks/css_coverage.mjs`
- Test: `test/css_coverage_runtime_js_test.mjs`

**Step 1: Locate selector classification flow**

In `lib/mix/tasks/css_coverage.mjs`, find the code that builds:

- `matched_selectors`
- `dynamic_selectors`
- `unmatched_selectors`
- optional selector details / stats

Keep the existing HEEX matcher unchanged first.

**Step 2: Add positive class extraction for selectors**

Add or reuse a helper that returns positive class atoms required by a selector, including class names inside `:not(...)` as runtime evidence candidates:

```js
function requiredClassNamesForRuntimeEvidence(selectorAstOrSelector) {
  // Return sorted unique class names from selector parser output.
}
```

Do not include pseudo-class names, IDs, tag names, or attribute names.

**Step 3: Add runtime classification pass**

After HEEX matching and dynamic classification:

```js
if (selectorIsUnmatched) {
  const classes = requiredClassNamesForRuntimeEvidence(selector);
  const runtimeClasses = classes.filter((cls) => runtimeEvidence.has(cls));

  if (classes.length > 0 && runtimeClasses.length > 0 && runtimeCanExplainSelector(selector, classes, runtimeEvidence)) {
    markRuntimeMatched(selector, runtimeClasses);
  }
}
```

Conservative first rule:

- If all positive class names in a simple selector are runtime-evidenced, classify as `runtime-matched`.
- If some positive class names are already HEEX-proven somewhere and the remaining class names are runtime-evidenced, classify as `runtime-matched`.
- If the selector has descendant/child/sibling combinators and only runtime evidence exists for the left side, keep it `unmatched`.

This means:

- `.sortable-ghost` -> `runtime-matched`.
- `.item-entry:not(.sortable-ghost):not(.sortable-drag)` -> `runtime-matched`.
- `.sortable-ghost .child` -> `unmatched` unless `.child` and the relationship are otherwise proven.

**Step 4: Add report fields**

Output these fields:

```json
{
  "runtime_matched_selectors": [],
  "runtime_evidence": {
    "sortable-ghost": [
      {
        "file": "assets/js/app.js",
        "line": 280,
        "literal": "sortable-ghost"
      }
    ]
  }
}
```

Keep `runtime-matched` selectors out of `matched_selectors`.

**Step 5: Update stats**

If the report has stats, add:

```json
{
  "runtime_matched_selector_count": 4
}
```

Do not subtract runtime-matched from matched. They are separate.

**Step 6: Run runtime JS test**

Run:

```bash
node test/css_coverage_runtime_js_test.mjs
```

Expected: pass.

**Step 7: Run existing Node CSS coverage tests**

Run:

```bash
node test/css_coverage_graph_test.mjs
node test/css_coverage_cycle_test.mjs
node test/css_coverage_class_facts_test.mjs
node test/css_coverage_stats_test.mjs
node test/css_coverage_node_modules_test.mjs
```

Expected: pass.

**Step 8: Commit**

```bash
git add lib/mix/tasks/css_coverage.mjs test/css_coverage_runtime_js_test.mjs test/fixtures/css_coverage_runtime_js
git commit -m "Report runtime-matched CSS selectors from JavaScript evidence

Scan JavaScript string literals once, index class-looking tokens with file and
line provenance, and classify selectors explained by runtime-only classes as
runtime-matched instead of rendered HEEX matches."
```

---

## Task 6: Wire Runtime Evidence Into Reports and CLI Output

**Files:**

- Modify: `lib/mix/tasks/css_coverage.mjs`
- Test: modify `test/css_coverage_runtime_js_test.mjs`
- Test: modify `test/css_coverage_stats_test.mjs`

**Step 1: Add CLI output assertions**

Extend `test/css_coverage_runtime_js_test.mjs` to run with `--list-unmatched` or whichever CLI mode prints selector buckets, and assert stdout includes a `runtime-matched` section.

Use exact strings already present in `css_coverage.mjs` output style. If current CLI only prints unmatched selectors, add a minimal `--list-runtime-matched` flag instead of overloading unrelated output.

**Step 2: Add stats test coverage**

Extend `test/css_coverage_stats_test.mjs` or create a focused stats assertion in the runtime JS test:

```js
assert.equal(report.stats.runtime_matched_selector_count, 4);
```

If stats currently live at top-level instead of `report.stats`, follow the existing shape.

**Step 3: Run focused tests**

Run:

```bash
node test/css_coverage_runtime_js_test.mjs
node test/css_coverage_stats_test.mjs
```

Expected: pass.

**Step 4: Commit**

```bash
git add lib/mix/tasks/css_coverage.mjs test/css_coverage_runtime_js_test.mjs test/css_coverage_stats_test.mjs
git commit -m "Expose runtime CSS evidence in coverage output

Include runtime-matched selector counts and evidence in report and CLI output
without mixing runtime evidence into normal HEEX selector matches."
```

---

## Task 7: Verify Against Current Muqui Selectors

**Files:**

- No source edits expected unless verification exposes bugs.
- Generated analysis files may be ignored unless already tracked.

**Step 1: Generate HEEX graph**

Run:

```bash
mix heex_class_analyzer
```

Expected: completes and writes `analysis/heex-class-graph.json`.

**Step 2: Run CSS coverage with runtime evidence**

Run:

```bash
node lib/mix/tasks/css_coverage.mjs --list-unmatched --stats
```

Expected:

- `.podium-tied .podium-name` is no longer unmatched.
- `.sortable-ghost`, `.sortable-chosen`, and `.sortable-drag` are reported as `runtime-matched` or present in runtime evidence details.
- The remaining unmatched list does not grow unexpectedly.

**Step 3: If podium selectors still fail**

Inspect `analysis/heex-class-graph.json` for the `podium_place/1` tree:

```bash
rg -n "podium-tied|podium-name|tie_class|podium_place" analysis/heex-class-graph.json
```

Expected: the parent wrapper node contains `podium-tied` in class facts and the child node contains `podium-name`.

If not, fix Task 1 or Task 2 before continuing.

**Step 4: If Sortable selectors still fail**

Inspect runtime evidence:

```bash
node lib/mix/tasks/css_coverage.mjs --stats --output analysis/css-coverage.json
rg -n "sortable-ghost|runtime" analysis/css-coverage.json
```

Expected: runtime evidence includes `assets/js/app.js` lines for Sortable class strings.

If not, fix Task 4 or Task 5 before continuing.

**Step 5: Commit fixes if needed**

If verification required source changes:

```bash
git add <changed files>
git commit -m "Fix Muqui runtime class coverage verification

Address issues found while validating podium assign classes and Sortable
runtime class evidence against the real project selectors."
```

If no changes were needed, do not create an empty commit.

---

## Task 8: Full Project Verification

**Files:**

- Plan status update: `docs/plans/260518-1116-heex-runtime-class-evidence.md`

**Step 1: Run focused analyzer tests**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer
```

Expected: pass.

**Step 2: Run focused Node tests**

Run:

```bash
node test/css_coverage_graph_test.mjs
node test/css_coverage_cycle_test.mjs
node test/css_coverage_class_facts_test.mjs
node test/css_coverage_assign_facts_test.mjs
node test/css_coverage_runtime_js_test.mjs
node test/css_coverage_stats_test.mjs
node test/css_coverage_node_modules_test.mjs
```

Expected: pass.

**Step 3: Run required project checks**

Run:

```bash
mix format
mix ex_dna
mix credo
mix compile --warnings-as-errors
```

Expected: pass.

If Credo reports issues, run:

```bash
mix credo explain <file:line:position>
```

Then fix based on the explanation and rerun Credo.

**Step 4: Run precommit**

Run:

```bash
mix precommit
```

Expected: pass.

Do not run `mix heex_class_analyzer` as part of precommit unless the alias already does. `mix heex_class_analyzer` was already run for this analyzer-specific verification.

**Step 5: Update plan status**

Update this plan's Status section to mark all completed tasks:

```markdown
- [x] Task 1: Add HEEX Clause Assign Fact Discovery
...
```

**Step 6: Commit plan status update**

```bash
git add docs/plans/260518-1116-heex-runtime-class-evidence.md
git commit -m "Mark runtime class evidence plan complete

Record completion of HEEX assign class resolution and runtime JavaScript class
evidence work after focused tests and project checks pass."
```

---

## Notes for Implementation

- Use `Req` for HTTP only if new HTTP work appears; this plan should not need HTTP.
- Do not use Ecto. This plan should not touch Ash resources or database migrations.
- Do not add CSS-only tests that compare class strings without behavioral analyzer value.
- Keep `mix heex_class_analyzer` optional outside this CSS analyzer task; here it is required because the task is specifically about analyzer coverage.
- The runtime evidence scanner should not auto-install Node dependencies. Use only Node built-ins and dependencies already used by `css_coverage.mjs`.
