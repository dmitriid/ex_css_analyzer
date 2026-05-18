# HEEX Class Graph Analyzer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the fully inlined HEEX class analyzer output with a single graph output that preserves real rendered DOM traversal for CSS coverage without recursively duplicating component trees.

**Architecture:** The Mix analyzer will discover modules as it does today, but the resolver will store each function/template HEEX tree once under a stable ref and emit component calls as graph edges. The Node CSS coverage script will eagerly traverse every entrypoint, splice component refs as real DOM children, create contextual node instances for every reachable node, and match selectors right-to-left against that rendered index.

**Tech Stack:** Elixir Mix task modules under `lib/mix/tasks/heex_class_analyzer/*`, ExUnit tests under `test/mix/tasks/heex_class_analyzer/*`, Node.js ES modules in `lib/mix/tasks/css_coverage.mjs`, PostCSS selector parser, and fixture-based Node verification.

---

## Status

- [x] Task 1: Add Graph Data Structures
- [x] Task 2: Resolve Graph Trees Without Component Inlining
- [x] Task 3: Write Only the Graph Output
- [x] Task 4: Rewrite CSS Coverage Loader for Graph Input
- [x] Task 5: Fix Sibling and Child Combinators Across Component Refs
- [x] Task 6: Add Cycle and Missing Ref Diagnostics to CSS Coverage
- [x] Task 7: Remove Legacy Analyzer Output Paths and Docs
- [x] Task 8: Full Project Verification

Verification completed after the follow-up graph fixes with `mix precommit`
passing 629 tests. Analyzer-specific verification also completed with
`mix heex_class_analyzer` and
`node lib/mix/tasks/css_coverage.mjs --list-unmatched --list-runtime --stats --output analysis/css-coverage.json`.

## Implementation Notes Added After Follow-Up Fixes

- Graph output remains version 2 and is the only supported CSS coverage input.
- Component refs are rendered as DOM children by CSS coverage, not as wrapper
  nodes.
- Named slots and `inner_block` slots are preserved as `slot_name`
  placeholders. CSS coverage binds placeholders to the caller's slot scope when
  it materializes a component ref, including nested slot passthrough where one
  component passes `render_slot(@inner_block)` into another component.
- Standalone `.heex` templates often do not have alias metadata. Remote
  component tags such as `Layouts.admin_content` are resolved by registry
  module suffix when normal alias resolution fails and the candidate module
  defines the requested component.
- Phoenix `<.link>` is modeled as an `a` tag so tag selectors like
  `.admin-user-menu a:hover` match rendered anchors.
- Expressions that call helpers returning `Phoenix.HTML.raw/1` are serialized
  as raw HTML placeholders. CSS coverage lets such placeholders satisfy one
  immediate child selector segment under their HEEX parent, e.g.
  `.reveal-answer-text p`, but does not assume arbitrary deep raw descendants.

---

## What, How, Why

**What changes**

`mix heex_class_analyzer` will stop writing one huge, fully expanded JSON file per module. It will write only `analysis/heex-class-graph.json`, containing:

- `version: 2`
- `entries`: public analysis roots for functions and templates
- `trees`: canonical HEEX node trees keyed by clause-aware refs
- `cycles`: component/function graph cycles found while resolving
- `unresolved`: unresolved component/function references that were handled as dynamic or skipped edges

Component calls inside node children will be represented as:

```json
{
  "component_refs": [
    "fn:MuquiWeb.CoreComponents:button:1:0"
  ],
  "callsite": {
    "tag": ".button",
    "from": "fn:MuquiWeb.PageLive:render:1:0"
  }
}
```

The CSS coverage script will require this graph output. It will no longer support legacy per-module analyzer JSON files.

**How it works**

The Elixir resolver will resolve every HEEX clause/template into one tree ref. Normal HTML children remain normal nodes. Local and remote function component tags become `component_refs` edges instead of inline-expanded child trees. Multiple HEEX clauses become multiple refs, e.g. `fn:Module:name:arity:0`, `fn:Module:name:arity:1`; calls to that component include all possible clause refs.

The JS analyzer will eagerly traverse every `entry.ref`. When it sees a `component_refs` edge, it will splice each referenced tree root into the current child list as if Phoenix rendered the component in place. It will index every concrete child node from every reachable ref, not only root nodes. Each index entry is contextual and includes its entry ref, definition ref, ancestors, siblings, and call stack.

**Why this fixes the issue**

The current analyzer inlines component trees into every caller. Caching can reduce repeated Elixir work, but the output and Node traversal still explode because the same trees are serialized and walked again and again. A graph output stores definitions once and lets CSS coverage traverse rendered contexts without duplicating storage. Matching remains correct because component refs are not fake wrapper nodes; they are spliced into the DOM shape used for ` `, `>`, `+`, and `~` selectors.

---

## Ref Format

Use stable, clause-aware refs:

```text
fn:<Module>:<function>:<arity>:<clause_index>
tpl:<Module-or-source>:<template_name>.html.heex
```

Examples:

```text
fn:MuquiWeb.DisplayLive.Components.Layout:shell:1:0
fn:MuquiWeb.CoreComponents:button:1:0
tpl:MuquiWeb.PageHTML:home.html.heex
```

`clause_index` is zero-based. Single-clause functions still use `:0`.

---

## Task 1: Add Graph Data Structures

**Files:**

- Create: `lib/mix/tasks/heex_class_analyzer/graph.ex`
- Modify: `lib/mix/tasks/heex_class_analyzer/node.ex`
- Test: `test/mix/tasks/heex_class_analyzer/graph_test.exs`

**Step 1: Write failing tests for refs and component edges**

Create `test/mix/tasks/heex_class_analyzer/graph_test.exs`:

```elixir
defmodule Mix.Tasks.HeexClassAnalyzer.GraphTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.HeexClassAnalyzer.Graph

  describe "function_ref/4" do
    test "builds clause-aware function refs" do
      assert Graph.function_ref(MuquiWeb.CoreComponents, :button, 1, 0) ==
               "fn:MuquiWeb.CoreComponents:button:1:0"
    end
  end

  describe "template_ref/2" do
    test "builds template refs from module and template name" do
      assert Graph.template_ref(MuquiWeb.PageHTML, "home") ==
               "tpl:MuquiWeb.PageHTML:home.html.heex"
    end
  end

  describe "component_edge/3" do
    test "stores all possible refs for a component callsite" do
      edge =
        Graph.component_edge(
          ["fn:MuquiWeb.Components:panel:1:0", "fn:MuquiWeb.Components:panel:1:1"],
          ".panel",
          "fn:MuquiWeb.PageLive:render:1:0"
        )

      assert edge.component_refs == [
               "fn:MuquiWeb.Components:panel:1:0",
               "fn:MuquiWeb.Components:panel:1:1"
             ]

      assert edge.callsite.tag == ".panel"
      assert edge.callsite.from == "fn:MuquiWeb.PageLive:render:1:0"
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/graph_test.exs
```

Expected: compile failure because `Mix.Tasks.HeexClassAnalyzer.Graph` does not exist.

**Step 3: Implement minimal graph module**

Create `lib/mix/tasks/heex_class_analyzer/graph.ex`:

```elixir
defmodule Mix.Tasks.HeexClassAnalyzer.Graph do
  @moduledoc """
  Shared graph helpers for HEEX class analyzer refs and component edges.
  """

  @type ref :: String.t()

  @type component_edge :: %{
          component_refs: [ref()],
          callsite: %{tag: String.t(), from: ref()}
        }

  @spec function_ref(module(), atom(), non_neg_integer(), non_neg_integer()) :: ref()
  def function_ref(module, name, arity, clause_index) do
    "fn:#{inspect(module)}:#{name}:#{arity}:#{clause_index}"
  end

  @spec template_ref(module() | nil | String.t(), String.t()) :: ref()
  def template_ref(module, name) when is_atom(module) do
    "tpl:#{inspect(module)}:#{name}.html.heex"
  end

  def template_ref(source, name) when is_binary(source) do
    "tpl:#{source}:#{name}.html.heex"
  end

  @spec component_edge([ref()], String.t(), ref()) :: component_edge()
  def component_edge(component_refs, tag, from_ref) do
    %{
      component_refs: component_refs,
      callsite: %{tag: tag, from: from_ref}
    }
  end
end
```

Modify `lib/mix/tasks/heex_class_analyzer/node.ex` type docs and struct to allow component edge children:

```elixir
@type child :: t() | Mix.Tasks.HeexClassAnalyzer.Graph.component_edge()
```

Keep the struct field as `children: []`.

**Step 4: Run test to verify it passes**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/graph_test.exs
```

Expected: pass.

**Step 5: Commit**

```bash
git add lib/mix/tasks/heex_class_analyzer/graph.ex lib/mix/tasks/heex_class_analyzer/node.ex test/mix/tasks/heex_class_analyzer/graph_test.exs
git commit -m "Add HEEX analyzer graph reference helpers

Introduce stable refs and component edge helpers for the graph analyzer output.
These are the base data structures for replacing fully inlined component trees."
```

---

## Task 2: Resolve Graph Trees Without Component Inlining

**Files:**

- Modify: `lib/mix/tasks/heex_class_analyzer/resolver.ex`
- Test: `test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs`

**Step 1: Write failing resolver tests**

Create `test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs`:

```elixir
defmodule Mix.Tasks.HeexClassAnalyzer.ResolverGraphTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.HeexClassAnalyzer.Registry
  alias Mix.Tasks.HeexClassAnalyzer.Resolver

  test "emits component refs instead of inlining component children" do
    module_infos = [
      %{
        module: SampleWeb.Page,
        source_file: "lib/sample_web/page.ex",
        imports: [],
        aliases: %{},
        uses: [],
        heex_templates: [],
        functions: [
          %{
            name: :render,
            arity: 1,
            body: nil,
            clauses: [],
            heex: ~s(<section class="page"><.button /></section>)
          },
          %{
            name: :button,
            arity: 1,
            body: nil,
            clauses: [],
            heex: ~s(<button class="btn">OK</button>)
          }
        ]
      }
    ]

    registry = Registry.build(module_infos)
    graph = Resolver.resolve_graph(module_infos, registry)

    assert Map.has_key?(graph.trees, "fn:SampleWeb.Page:render:1:0")
    assert Map.has_key?(graph.trees, "fn:SampleWeb.Page:button:1:0")

    [section] = graph.trees["fn:SampleWeb.Page:render:1:0"]
    assert [%{component_refs: ["fn:SampleWeb.Page:button:1:0"]}] = section.children
  end

  test "records component cycles and stops recursive edges" do
    module_infos = [
      %{
        module: SampleWeb.Loops,
        source_file: "lib/sample_web/loops.ex",
        imports: [],
        aliases: %{},
        uses: [],
        heex_templates: [],
        functions: [
          %{name: :a, arity: 1, body: nil, clauses: [], heex: ~s(<div class="a"><.b /></div>)},
          %{name: :b, arity: 1, body: nil, clauses: [], heex: ~s(<div class="b"><.a /></div>)}
        ]
      }
    ]

    registry = Registry.build(module_infos)
    graph = Resolver.resolve_graph(module_infos, registry)

    assert [
             %{
               type: "component",
               path: [
                 "fn:SampleWeb.Loops:a:1:0",
                 "fn:SampleWeb.Loops:b:1:0",
                 "fn:SampleWeb.Loops:a:1:0"
               ]
             }
           ] = graph.cycles
  end
end
```

**Step 2: Run test to verify it fails**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs
```

Expected: failure because `Resolver.resolve_graph/2` does not exist.

**Step 3: Implement graph resolver entrypoint**

Add `resolve_graph/2` to `lib/mix/tasks/heex_class_analyzer/resolver.ex`.

Implementation requirements:

- Return a map:

  ```elixir
  %{
    version: 2,
    entries: entries,
    trees: trees,
    cycles: cycles,
    unresolved: unresolved
  }
  ```

- Build one entry per function HEEX clause and template:

  ```elixir
  %{
    ref: ref,
    module: inspect(module_info.module),
    source_file: module_info.source_file,
    name: "render/1"
  }
  ```

- Add private `resolve_heex_tree/5` that parses and resolves node classes like `parse_and_resolve/3`, but passes the current tree ref and traversal stack.
- Replace `resolve_component/5` usage for graph mode with `component_edge_for_tag/6`.
- `component_edge_for_tag/6` should:
  - resolve local `.func` and remote `Module.func` tags via `Registry`
  - build all clause refs for the resolved function
  - ensure each target tree is present in `trees`
  - detect `target_ref in stack` and append a cycle instead of recursing
  - return `%{component_refs: refs, callsite: %{tag: tag, from: current_ref}}`
- Preserve existing function-call class resolution for now; only component tree inlining changes.

Avoid adding GenServer/Task concurrency in this task. First make the graph behavior correct and testable. Concurrency/memoized running state can be added after correctness if the graph output still needs speedup.

**Step 4: Run resolver graph tests**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs
```

Expected: pass.

**Step 5: Run existing analyzer-related compile checks**

Run:

```bash
mix compile --warnings-as-errors
```

Expected: pass.

**Step 6: Commit**

```bash
git add lib/mix/tasks/heex_class_analyzer/resolver.ex test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs
git commit -m "Resolve HEEX analyzer output as component graph

Add graph resolution that stores each HEEX function clause once and represents
component calls as refs. Record recursive component cycles instead of inlining
trees repeatedly."
```

---

## Task 3: Write Only the Graph Output

**Files:**

- Modify: `lib/mix/tasks/heex_class_analyzer.ex`
- Modify: `lib/mix/tasks/heex_class_analyzer/output.ex`
- Test: `test/mix/tasks/heex_class_analyzer/output_graph_test.exs`

**Step 1: Write failing output tests**

Create `test/mix/tasks/heex_class_analyzer/output_graph_test.exs`:

```elixir
defmodule Mix.Tasks.HeexClassAnalyzer.OutputGraphTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.HeexClassAnalyzer.Output

  test "writes a single graph file and removes legacy module json files" do
    tmp = Path.join(System.tmp_dir!(), "heex-class-output-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "Legacy.Module.json"), "{}")

    graph = %{
      version: 2,
      entries: [],
      trees: %{},
      cycles: [],
      unresolved: []
    }

    Output.write_graph!(graph, tmp)

    assert File.exists?(Path.join(tmp, "heex-class-graph.json"))
    refute File.exists?(Path.join(tmp, "Legacy.Module.json"))

    decoded =
      tmp
      |> Path.join("heex-class-graph.json")
      |> File.read!()
      |> Jason.decode!()

    assert decoded["version"] == 2
  after
    if tmp = Process.get(:tmp_output_dir), do: File.rm_rf!(tmp)
  end
end
```

If the `after` block cannot see `tmp`, replace with explicit `on_exit(fn -> File.rm_rf!(tmp) end)` inside the test.

**Step 2: Run test to verify it fails**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/output_graph_test.exs
```

Expected: failure because `Output.write_graph!/2` does not exist.

**Step 3: Implement graph output**

Modify `lib/mix/tasks/heex_class_analyzer/output.ex`:

- Add `write_graph!/2`.
- Clean `*.json` in output dir before writing.
- Serialize nodes and component edges:

  ```elixir
  defp serialize_child(%Node{} = node), do: serialize_node(node)
  defp serialize_child(%{component_refs: refs, callsite: callsite}) do
    %{component_refs: refs, callsite: callsite}
  end
  ```

- Update `serialize_node/1` to call `serialize_child/1` for children.
- Keep old `write_all/2` only if temporarily needed by tests during the same task, but stop calling it from the Mix task. If no code uses it after this task, delete it to avoid v1 compatibility.

Modify `lib/mix/tasks/heex_class_analyzer.ex`:

- Replace per-module `Resolver.resolve_module/2` loop with:

  ```elixir
  graph = Resolver.resolve_graph(module_infos, registry)
  Output.write_graph!(graph, output_dir)
  ```

- Update summary to print graph stats:

  ```text
  Analyzed <entries> entries, <trees> trees, <cycles> cycles. Output: analysis/heex-class-graph.json
  ```

**Step 4: Run output tests**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/output_graph_test.exs
```

Expected: pass.

**Step 5: Run Mix task on project**

Run:

```bash
mix heex_class_analyzer
```

Expected:

- command completes
- `analysis/heex-class-graph.json` exists
- no `analysis/MuquiWeb.*.json` files are created
- output summary includes entries/trees/cycles

Check:

```bash
find analysis -maxdepth 1 -type f -name '*.json' | sort | head
```

Expected: includes `analysis/heex-class-graph.json`; does not include legacy module JSON files except `css-coverage.json` if it existed before and was not cleaned by this output dir cleanup. Prefer cleaning all analyzer JSON and letting CSS coverage rewrite its own report.

**Step 6: Commit**

```bash
git add lib/mix/tasks/heex_class_analyzer.ex lib/mix/tasks/heex_class_analyzer/output.ex test/mix/tasks/heex_class_analyzer/output_graph_test.exs analysis/heex-class-graph.json
git commit -m "Write HEEX analyzer graph output only

Replace legacy per-module analyzer JSON with a single graph file. The output
stores entries, canonical trees, cycles, and unresolved refs for downstream CSS
coverage analysis."
```

Do not commit generated `analysis/heex-class-graph.json` if `analysis/` is ignored or project convention excludes generated analyzer output. Check `git status --short` before staging.

---

## Task 4: Rewrite CSS Coverage Loader for Graph Input

**Files:**

- Modify: `lib/mix/tasks/css_coverage.mjs`
- Create: `test/fixtures/css_coverage_graph/heex-class-graph.json`
- Create: `test/fixtures/css_coverage_graph/app.css`
- Create: `test/css_coverage_graph_test.mjs`

**Step 1: Add graph fixture**

Create `test/fixtures/css_coverage_graph/heex-class-graph.json`:

```json
{
  "version": 2,
  "entries": [
    {
      "ref": "fn:SampleWeb.Page:render:1:0",
      "module": "SampleWeb.Page",
      "source_file": "lib/sample_web/page.ex",
      "name": "render/1"
    }
  ],
  "trees": {
    "fn:SampleWeb.Page:render:1:0": [
      {
        "tag": "section",
        "static": ["page"],
        "variants": [],
        "permutations": [["page"]],
        "repeat": false,
        "children": [
          {
            "component_refs": ["fn:SampleWeb.Components:panel:1:0"],
            "callsite": {
              "tag": ".panel",
              "from": "fn:SampleWeb.Page:render:1:0"
            }
          }
        ]
      }
    ],
    "fn:SampleWeb.Components:panel:1:0": [
      {
        "tag": "article",
        "static": ["panel"],
        "variants": [],
        "permutations": [["panel"]],
        "repeat": false,
        "children": [
          {
            "tag": "button",
            "static": ["action"],
            "variants": [],
            "permutations": [["action"]],
            "repeat": false,
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

Create `test/fixtures/css_coverage_graph/app.css`:

```css
.page .action {
  color: red;
}

.page > .panel {
  display: block;
}

.missing {
  color: blue;
}
```

**Step 2: Add failing Node test**

Create `test/css_coverage_graph_test.mjs`:

```js
import assert from "node:assert/strict";
import { mkdtempSync, cpSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const tmp = mkdtempSync(join(tmpdir(), "css-coverage-graph-"));
cpSync("test/fixtures/css_coverage_graph", tmp, { recursive: true });

const result = spawnSync(
  "node",
  [
    "lib/mix/tasks/css_coverage.mjs",
    "--css",
    join(tmp, "app.css"),
    "--analysis",
    tmp,
    "--output",
    join(tmp, "css-coverage.json")
  ],
  { encoding: "utf-8" }
);

assert.equal(result.status, 0, result.stderr || result.stdout);

const report = JSON.parse(readFileSync(join(tmp, "css-coverage.json"), "utf-8"));
const matched = report.matched.map((entry) => entry.selector);
const unmatched = report.unmatched.map((entry) => entry.selector);

assert.ok(matched.includes(".page .action"));
assert.ok(matched.includes(".page > .panel"));
assert.ok(unmatched.includes(".missing"));
```

**Step 3: Run test to verify it fails**

Run:

```bash
node test/css_coverage_graph_test.mjs
```

Expected: failure because current script reads all `*.json` as legacy module files and does not understand graph `trees`.

**Step 4: Implement graph-only loading**

Modify `lib/mix/tasks/css_coverage.mjs`:

- Update CLI help to state `--analysis` is a directory containing `heex-class-graph.json`.
- Replace `loadAnalysisTrees(analysisDir)` with `loadGraphAnalysis(analysisDir)`.
- `loadGraphAnalysis` must:
  - read `join(analysisDir, "heex-class-graph.json")`
  - fail clearly if missing or `version !== 2`
  - build `classToNodes` and `allEntries` by eagerly traversing every entry ref
- Remove legacy per-module JSON loading logic. Do not keep v1 compatibility.

Core traversal shape:

```js
function loadGraphAnalysis(analysisDir) {
  const graphPath = join(analysisDir, "heex-class-graph.json");
  const graph = JSON.parse(readFileSync(graphPath, "utf-8"));
  if (graph.version !== 2) throw new Error("Expected HEEX class graph version 2");

  const classToNodes = new Map();
  const allEntries = [];
  const cycles = [];

  for (const entry of graph.entries || []) {
    walkRef(graph, entry.ref, {
      entry,
      definitionRef: entry.ref,
      ancestors: [],
      callStack: [],
      cycles
    }, classToNodes, allEntries);
  }

  classToNodes.allEntries = allEntries;
  classToNodes.cycles = cycles;
  return classToNodes;
}
```

Implementation requirements:

- `walkRef` must stop if `ref` is already in `context.callStack`, record a cycle, and return no nodes for that edge.
- `walkNodeList` must materialize siblings from the same rendered parent.
- `materializeChildren(children, context)` must splice `component_refs` to referenced tree roots.
- Every concrete node gets indexed even if it is several refs deep.
- Entry objects passed to matches should include `entryRef`, `definitionRef`, and `callStack`.

Do not treat component refs as wrapper nodes.

**Step 5: Run Node graph fixture test**

Run:

```bash
node test/css_coverage_graph_test.mjs
```

Expected: pass.

**Step 6: Commit**

```bash
git add lib/mix/tasks/css_coverage.mjs test/fixtures/css_coverage_graph/heex-class-graph.json test/fixtures/css_coverage_graph/app.css test/css_coverage_graph_test.mjs
git commit -m "Load HEEX graph output in CSS coverage analyzer

Replace legacy module JSON loading with eager graph traversal. Splice component
refs as real rendered DOM so descendant and child selectors match across
function component boundaries."
```

---

## Task 5: Fix Sibling and Child Combinators Across Component Refs

**Files:**

- Modify: `lib/mix/tasks/css_coverage.mjs`
- Modify: `test/fixtures/css_coverage_graph/heex-class-graph.json`
- Modify: `test/fixtures/css_coverage_graph/app.css`
- Modify: `test/css_coverage_graph_test.mjs`

**Step 1: Extend fixture for sibling cases**

Add a second component ref and sibling selector fixture:

```json
{
  "component_refs": ["fn:SampleWeb.Components:badge:1:0"],
  "callsite": {
    "tag": ".badge",
    "from": "fn:SampleWeb.Page:render:1:0"
  }
}
```

Add tree:

```json
"fn:SampleWeb.Components:badge:1:0": [
  {
    "tag": "span",
    "static": ["badge"],
    "variants": [],
    "permutations": [["badge"]],
    "repeat": false,
    "children": []
  }
]
```

Add CSS:

```css
.panel + .badge {
  margin-left: 4px;
}
```

Add assertion:

```js
assert.ok(matched.includes(".panel + .badge"));
```

**Step 2: Run test**

Run:

```bash
node test/css_coverage_graph_test.mjs
```

Expected: fail if siblings are still based on raw JSON children instead of materialized rendered children.

**Step 3: Fix rendered sibling contexts**

In `css_coverage.mjs`:

- Ensure `walkNodeList(nodes, context)` receives a fully materialized list.
- For each node in that materialized list, compute siblings from that same materialized list.
- For refs with multiple root nodes, those root nodes are siblings at the callsite position.
- For adjacent refs in the parent child list, the roots of the first referenced tree and roots of the second referenced tree are siblings in rendered order.

**Step 4: Run test**

Run:

```bash
node test/css_coverage_graph_test.mjs
```

Expected: pass.

**Step 5: Commit**

```bash
git add lib/mix/tasks/css_coverage.mjs test/fixtures/css_coverage_graph/heex-class-graph.json test/fixtures/css_coverage_graph/app.css test/css_coverage_graph_test.mjs
git commit -m "Match CSS sibling selectors across component refs

Compute siblings from materialized rendered children so adjacent and general
sibling selectors behave like real DOM across component boundaries."
```

---

## Task 6: Add Cycle and Missing Ref Diagnostics to CSS Coverage

**Files:**

- Modify: `lib/mix/tasks/css_coverage.mjs`
- Create: `test/fixtures/css_coverage_cycle/heex-class-graph.json`
- Create: `test/fixtures/css_coverage_cycle/app.css`
- Create: `test/css_coverage_cycle_test.mjs`

**Step 1: Add cycle fixture**

Create `test/fixtures/css_coverage_cycle/heex-class-graph.json` with two refs pointing to each other:

```json
{
  "version": 2,
  "entries": [
    {
      "ref": "fn:SampleWeb.Loops:a:1:0",
      "module": "SampleWeb.Loops",
      "source_file": "lib/sample_web/loops.ex",
      "name": "a/1"
    }
  ],
  "trees": {
    "fn:SampleWeb.Loops:a:1:0": [
      {
        "tag": "div",
        "static": ["a"],
        "variants": [],
        "permutations": [["a"]],
        "repeat": false,
        "children": [
          {
            "component_refs": ["fn:SampleWeb.Loops:b:1:0"],
            "callsite": {"tag": ".b", "from": "fn:SampleWeb.Loops:a:1:0"}
          }
        ]
      }
    ],
    "fn:SampleWeb.Loops:b:1:0": [
      {
        "tag": "div",
        "static": ["b"],
        "variants": [],
        "permutations": [["b"]],
        "repeat": false,
        "children": [
          {
            "component_refs": ["fn:SampleWeb.Loops:a:1:0"],
            "callsite": {"tag": ".a", "from": "fn:SampleWeb.Loops:b:1:0"}
          }
        ]
      }
    ]
  },
  "cycles": [],
  "unresolved": []
}
```

Create `test/fixtures/css_coverage_cycle/app.css`:

```css
.a .b {
  color: red;
}
```

**Step 2: Add failing cycle test**

Create `test/css_coverage_cycle_test.mjs`:

```js
import assert from "node:assert/strict";
import { mkdtempSync, cpSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const tmp = mkdtempSync(join(tmpdir(), "css-coverage-cycle-"));
cpSync("test/fixtures/css_coverage_cycle", tmp, { recursive: true });

const result = spawnSync(
  "node",
  [
    "lib/mix/tasks/css_coverage.mjs",
    "--css",
    join(tmp, "app.css"),
    "--analysis",
    tmp,
    "--output",
    join(tmp, "css-coverage.json")
  ],
  { encoding: "utf-8" }
);

assert.equal(result.status, 0, result.stderr || result.stdout);

const report = JSON.parse(readFileSync(join(tmp, "css-coverage.json"), "utf-8"));
assert.ok(report.matched.some((entry) => entry.selector === ".a .b"));
assert.ok(report.cycles.length > 0);
assert.deepEqual(report.cycles[0].path, [
  "fn:SampleWeb.Loops:a:1:0",
  "fn:SampleWeb.Loops:b:1:0",
  "fn:SampleWeb.Loops:a:1:0"
]);
```

**Step 3: Run test**

Run:

```bash
node test/css_coverage_cycle_test.mjs
```

Expected: failure until CSS coverage emits `cycles` in output.

**Step 4: Implement diagnostics**

Modify `css_coverage.mjs`:

- Include `cycles` from graph plus traversal-discovered cycles in report output.
- Include `unresolved_refs` for component refs missing from `graph.trees`.
- Print a warning summary:

  ```text
  Graph diagnostics: <n> cycles, <n> unresolved refs
  ```

Do not let cycles recurse indefinitely. Stop at the repeated edge.

**Step 5: Run cycle test**

Run:

```bash
node test/css_coverage_cycle_test.mjs
```

Expected: pass.

**Step 6: Commit**

```bash
git add lib/mix/tasks/css_coverage.mjs test/fixtures/css_coverage_cycle/heex-class-graph.json test/fixtures/css_coverage_cycle/app.css test/css_coverage_cycle_test.mjs
git commit -m "Report graph traversal diagnostics in CSS coverage

Stop recursive component refs during rendered-tree traversal and include cycle
and missing-ref diagnostics in the CSS coverage report."
```

---

## Task 7: Remove Legacy Analyzer Output Paths and Docs

**Files:**

- Modify: `lib/mix/tasks/heex_class_analyzer.ex`
- Modify: `lib/mix/tasks/heex_class_analyzer/output.ex`
- Modify: `lib/mix/tasks/css_coverage.mjs`
- Modify docs in module moduledocs only; do not update broader product docs unless behavior is documented there.

**Step 1: Search for v1 assumptions**

Run:

```bash
rg -n "per module|one JSON file per module|write_all|loadAnalysisTrees|module JSON|functions.*tree|heex-class-graph|css-coverage.json" lib/mix/tasks docs/plans docs/muqui
```

Expected: find old docs/comments in analyzer and CSS coverage modules.

**Step 2: Delete dead v1 functions**

Remove unused legacy functions:

- `Output.write_all/2` if no callers remain
- old per-module filename helpers if only used by `write_all/2`
- old `loadAnalysisTrees` legacy JSON reader in `css_coverage.mjs`

Keep serialization helpers that are reused by graph output.

**Step 3: Update help text and moduledocs**

Update:

- `Mix.Tasks.HeexClassAnalyzer` moduledoc pipeline/output sections
- `Output` moduledoc
- `css_coverage.mjs` top comment and CLI help

State clearly:

```text
Run mix heex_class_analyzer first. It writes analysis/heex-class-graph.json.
css_coverage.mjs requires graph version 2 and does not support legacy per-module JSON.
```

**Step 4: Run search again**

Run:

```bash
rg -n "one JSON file per module|write_all|loadAnalysisTrees|legacy per-module|version 1" lib/mix/tasks
```

Expected: no stale references except migration notes if intentionally kept. Prefer no migration notes because v1 compatibility is intentionally dropped.

**Step 5: Run tests**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer
node test/css_coverage_graph_test.mjs
node test/css_coverage_cycle_test.mjs
```

Expected: pass.

**Step 6: Commit**

```bash
git add lib/mix/tasks/heex_class_analyzer.ex lib/mix/tasks/heex_class_analyzer/output.ex lib/mix/tasks/css_coverage.mjs
git commit -m "Remove legacy HEEX analyzer JSON assumptions

Delete stale per-module output paths and update analyzer documentation for the
single graph output consumed by CSS coverage."
```

---

## Task 8: Full Project Verification

**Files:**

- No code changes unless verification finds issues.

**Step 1: Run formatter**

Run:

```bash
mix format
```

Expected: completes. Stage any formatting changes.

**Step 2: Run focused tests**

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer
node test/css_coverage_graph_test.mjs
node test/css_coverage_cycle_test.mjs
```

Expected: pass.

**Step 3: Run analyzer**

Run:

```bash
mix heex_class_analyzer
```

Expected:

- completes without infinite recursion
- writes `analysis/heex-class-graph.json`
- graph file is much smaller than the current 945 MB legacy `analysis/` output
- summary reports entries, trees, and cycles

Check size:

```bash
du -h analysis/heex-class-graph.json
```

Expected: substantially below prior `analysis/` directory size. Do not hardcode an exact threshold.

**Step 4: Run CSS coverage**

Run:

```bash
node lib/mix/tasks/css_coverage.mjs --list-unmatched
```

Expected:

- completes
- reads `analysis/heex-class-graph.json`
- writes `analysis/css-coverage.json`
- prints matched/unmatched summary plus graph diagnostics if present

**Step 5: Run required project checks**

Run:

```bash
mix format --check-formatted
mix ex_dna
mix credo
mix compile --warnings-as-errors
```

Expected: pass.

If `mix credo` reports issues, run:

```bash
mix credo explain <file:line:position>
```

Fix according to the explanation, then rerun `mix credo`.

**Step 6: Run precommit**

Run:

```bash
mix precommit
```

Expected: pass.

Do not run `mix heex_class_analyzer` again inside precommit unless project alias already does it. This task specifically changes CSS cleanup tooling, so the explicit analyzer and CSS coverage runs above are required.

**Step 7: Final commit**

```bash
git status --short
git add <changed files>
git commit -m "Replace HEEX class analysis with graph traversal

Write a single graph output for HEEX class analysis and consume it from CSS
coverage with eager rendered-DOM indexing. Component refs are spliced as real
DOM children, cycles are reported, and legacy per-module analyzer JSON support
is removed.

Verification:
- mix test test/mix/tasks/heex_class_analyzer
- node test/css_coverage_graph_test.mjs
- node test/css_coverage_cycle_test.mjs
- mix heex_class_analyzer
- node lib/mix/tasks/css_coverage.mjs --list-unmatched
- mix format --check-formatted
- mix ex_dna
- mix credo
- mix compile --warnings-as-errors
- mix precommit"
```

---

## Implementation Notes

- Do not add v1 compatibility. If `heex-class-graph.json` is missing, `css_coverage.mjs` should fail with a clear message telling the user to run `mix heex_class_analyzer`.
- Do not create a fake wrapper node for component refs. Refs are storage edges only; matching sees referenced roots as real children at the callsite.
- Do not memoize contextual CSS index entries globally. The same component definition can be rendered under different parents, and selectors may depend on those parents.
- It is acceptable to memoize static definition summaries later, but not needed for the first implementation.
- Keep `permutations` in graph node output for now. Changing graph shape and permutation semantics at the same time is unnecessary risk.
- Prefer correctness first, then concurrency. The graph output should remove the main explosion. Add Task.Supervisor/in-flight registry only if the new resolver still needs it after measurement.
