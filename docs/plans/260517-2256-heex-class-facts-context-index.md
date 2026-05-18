# HEEX Class Facts Context Index Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace permutation-heavy HEEX class analysis and cloned Node graph traversal with bounded class facts and lightweight contextual indexes.

**Architecture:** The Elixir analyzer will preserve the component graph output, but each node will serialize compact class facts instead of all class permutations. The Node CSS coverage script will keep canonical graph trees intact, build tiny rendered-context records with parent and sibling ids, and match CSS selectors against class facts without cloning subtrees or enumerating class power sets.

**Tech Stack:** Elixir Mix task modules under `lib/mix/tasks/heex_class_analyzer/*`, ExUnit tests under `test/mix/tasks/heex_class_analyzer/*`, Node.js ES modules in `lib/mix/tasks/css_coverage.mjs`, PostCSS selector parser, Node fixture tests under `test/*css_coverage*.mjs`.

---

## Status

- [x] Task 1: Add Class Facts Data Structure
- [x] Task 2: Serialize Class Facts Instead of Permutations
- [x] Task 3: Update Resolver Tests and Fixtures for Class Facts
- [x] Task 4: Replace Node Materialization With Context Index
- [x] Task 5: Match Selectors Against Class Facts
- [x] Task 6: Add Node Stats and Context Guard
- [x] Task 7: Keep and Test Cycle/Missing Ref Diagnostics
- [x] Task 8: Remove Dead Permutation Paths
- [x] Task 9: Full Project Verification

Verification completed after the follow-up selector fixes with `mix precommit`
passing 629 tests. Analyzer-specific verification also completed with
`mix heex_class_analyzer` and
`node lib/mix/tasks/css_coverage.mjs --list-unmatched --list-runtime --stats --output analysis/css-coverage.json`.

---

## Background

The graph analyzer plan in `docs/plans/260517-2105-heex-class-graph-analyzer.md` removed repeated component trees from the JSON output, but two memory risks remain:

1. `Mix.Tasks.HeexClassAnalyzer.Permutations.compute/2` still creates the full power set of classes per node. This is `2^n - 1` lists for `n` possible classes.
2. `lib/mix/tasks/css_coverage.mjs` reads the graph and expands it back into cloned rendered trees per entry. Each cloned node carries children, ancestors, sibling arrays, call stacks, and later match provenance.

This plan keeps the graph output, but changes the node payload and Node traversal so both phases are bounded.

## Implementation Notes Added After Follow-Up Fixes

- `permutations` output has been removed. CSS coverage reads compact
  `classes.static`, `classes.optional`, `classes.exclusive`, and
  `classes.dynamic` facts.
- Selector matching rejects impossible exclusive combinations without expanding
  full class power sets.
- The context index stores rendered contexts with parent and previous-sibling
  ids rather than cloned subtrees with embedded ancestor arrays.
- Raw HTML placeholders from helpers returning `Phoenix.HTML.raw/1` are
  classless contexts. They match exactly one selector segment below the HEEX
  parent, which keeps Markdown paragraph selectors useful while avoiding a
  blanket "raw HTML matches everything" result.
- `:not(.class)` contributes a negative class condition rather than a positive
  required class, so selectors such as
  `.media-library-card__danger-action:hover:not(.media-upload-btn-disabled)`
  can match known button classes.
- Runtime-matched selectors are kept out of unmatched mutation flows:
  `--remove-unmatched`, `--invalidate-unmatched`, and `--restore-unmatched`
  operate only on actual unmatched selectors and unused keyframes.

---

## Target JSON Shape

Each normal HEEX node should serialize class facts:

```json
{
  "tag": "button",
  "static": ["btn"],
  "variants": [],
  "classes": {
    "static": ["btn"],
    "optional": ["active"],
    "exclusive": [[["tone-danger"], ["tone-neutral"]]],
    "dynamic": [
      {
        "dynamic": true,
        "reason": "unresolved:unknown_fn",
        "expr": "button_class",
        "chain": "button_class (unknown)"
      }
    ]
  },
  "repeat": false,
  "children": []
}
```

`static` and `variants` may stay temporarily for compatibility while the Node script is migrated, but `permutations` must be removed from the output by the end of this plan.

Class facts mean:

- `classes.static`: classes always present together.
- `classes.optional`: classes that may be present and may co-exist with static and other optional classes.
- `classes.exclusive`: mutually exclusive options known from expression shape, e.g. `if ... else ...` or `case`.
  - Task 1 note: exclusive options may contain dynamic fact objects as well as class strings when an expression branch is dynamic, e.g. `[[["known"], [{"dynamic": true, ...}]]]`, so later selector matching can preserve branch exclusivity.
- `classes.dynamic`: dynamic class sources with diagnostic metadata.

Do not infer exclusivity from class names like `size-sm` and `size-lg`. Only preserve exclusivity from expression analysis.

---

### Task 1: Add Class Facts Data Structure

**Files:**

- Create: `lib/mix/tasks/heex_class_analyzer/class_facts.ex`
- Test: `test/mix/tasks/heex_class_analyzer/class_facts_test.exs`

**Step 1: Write failing tests** ✅ Done

Create `test/mix/tasks/heex_class_analyzer/class_facts_test.exs`:

```elixir
defmodule Mix.Tasks.HeexClassAnalyzer.ClassFactsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.HeexClassAnalyzer.ClassFacts

  describe "from_static_and_variants/2" do
    test "splits static class strings" do
      facts = ClassFacts.from_static_and_variants(["btn inline-flex"], [])

      assert facts.static == ["btn", "inline-flex"]
      assert facts.optional == []
      assert facts.exclusive == []
      assert facts.dynamic == []
    end

    test "preserves toggle classes as optional" do
      facts = ClassFacts.from_static_and_variants(["btn"], [{:toggle, "active hidden"}])

      assert facts.static == ["btn"]
      assert facts.optional == ["active", "hidden"]
      assert facts.exclusive == []
    end

    test "preserves either options as exclusive groups" do
      facts =
        ClassFacts.from_static_and_variants(
          [],
          [{:either, [["tone-danger"], ["tone-neutral text-muted"]]}]
        )

      assert facts.exclusive == [[["tone-danger"], ["tone-neutral", "text-muted"]]]
    end

    test "preserves dynamic either options inside exclusive groups" do
      dynamic = {:dynamic, %{reason: "unresolved:unknown_fn", expr: "foo", chain: "foo"}}

      facts = ClassFacts.from_static_and_variants([], [{:either, ["known", dynamic]}])

      dynamic_fact = %{dynamic: true, reason: "unresolved:unknown_fn", expr: "foo", chain: "foo"}

      assert facts.exclusive == [[["known"], [dynamic_fact]]]
      assert facts.dynamic == [dynamic_fact]
    end

    test "keeps dynamic entries with metadata" do
      dynamic = {:dynamic, %{reason: "unresolved:unknown_fn", expr: "foo", chain: "foo"}}

      facts = ClassFacts.from_static_and_variants([dynamic], [])

      assert facts.static == []
      assert facts.dynamic == [
               %{dynamic: true, reason: "unresolved:unknown_fn", expr: "foo", chain: "foo"}
             ]
    end

    test "deduplicates classes within each fact bucket" do
      facts = ClassFacts.from_static_and_variants(["btn btn"], [{:toggle, "btn active active"}])

      assert facts.static == ["btn"]
      assert facts.optional == ["btn", "active"]
    end
  end
end
```

**Step 2: Run test to verify it fails** ✅ Done

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/class_facts_test.exs
```

Expected: compile failure because `Mix.Tasks.HeexClassAnalyzer.ClassFacts` does not exist.

**Step 3: Implement class facts module** ✅ Done

Create `lib/mix/tasks/heex_class_analyzer/class_facts.ex`:

```elixir
defmodule Mix.Tasks.HeexClassAnalyzer.ClassFacts do
  @moduledoc """
  Converts analyzed HEEX class data into compact facts for selector matching.
  """

  @type dynamic_fact :: %{
          dynamic: true,
          reason: String.t() | nil,
          expr: String.t() | nil,
          chain: String.t() | nil
        }

  @type exclusive_option :: [String.t() | dynamic_fact()]

  @type t :: %{
          static: [String.t()],
          optional: [String.t()],
          exclusive: [[exclusive_option()]],
          dynamic: [dynamic_fact()]
        }

  @spec from_static_and_variants([term()], [term()]) :: t()
  def from_static_and_variants(static_classes, variants) do
    {static, static_dynamic} = split_classes(static_classes)

    {optional, exclusive, variant_dynamic} =
      Enum.reduce(variants, {[], [], []}, fn
        {:toggle, class}, {optional, exclusive, dynamic} ->
          {classes, dynamics} = split_classes([class])
          {optional ++ classes, exclusive, dynamic ++ dynamics}

        {:either, options}, {optional, exclusive, dynamic} ->
          {group, dynamics} = split_exclusive_group(options)
          exclusive = if group == [], do: exclusive, else: exclusive ++ [group]
          {optional, exclusive, dynamic ++ dynamics}

        {:fn_call, _}, acc ->
          acc

        other, {optional, exclusive, dynamic} ->
          {optional, exclusive, dynamic ++ [dynamic_fact("unknown_variant", inspect(other), nil)]}
      end)

    %{
      static: Enum.uniq(static),
      optional: Enum.uniq(optional),
      exclusive: Enum.map(exclusive, &Enum.uniq/1),
      dynamic: static_dynamic ++ variant_dynamic
    }
  end

  defp split_exclusive_group(options) do
    Enum.reduce(options, {[], []}, fn option, {group, dynamics} ->
      {classes, option_dynamics} = split_classes(List.wrap(option))
      option_facts = Enum.uniq(classes) ++ option_dynamics
      group = if option_facts == [], do: group, else: group ++ [option_facts]
      {group, dynamics ++ option_dynamics}
    end)
  end

  defp split_classes(values) do
    Enum.reduce(values, {[], []}, fn
      value, {classes, dynamics} when is_binary(value) ->
        {classes ++ String.split(value, ~r/\s+/, trim: true), dynamics}

      {:dynamic, info}, {classes, dynamics} ->
        {classes, dynamics ++ [dynamic_fact(info.reason, info.expr, Map.get(info, :chain))]}

      value, {classes, dynamics} when is_list(value) ->
        {nested_classes, nested_dynamics} = split_classes(value)
        {classes ++ nested_classes, dynamics ++ nested_dynamics}

      nil, acc ->
        acc

      other, {classes, dynamics} ->
        {classes, dynamics ++ [dynamic_fact("non_string_class", inspect(other), nil)]}
    end)
  end

  defp dynamic_fact(reason, expr, chain) do
    %{dynamic: true, reason: reason, expr: expr, chain: chain}
  end
end
```

**Step 4: Run test to verify it passes** ✅ Done

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/class_facts_test.exs
```

Expected: pass.

**Step 5: Commit** Skipped by explicit task instruction: do not commit; leave changes in the worktree for controller review.

```bash
git add lib/mix/tasks/heex_class_analyzer/class_facts.ex test/mix/tasks/heex_class_analyzer/class_facts_test.exs
git commit -m "Add HEEX analyzer class facts

Introduce a compact representation for analyzed HEEX classes.
The structure preserves static, optional, exclusive, and dynamic class sources
without generating class permutations."
```

---

### Task 2: Serialize Class Facts Instead of Permutations

**Files:**

- Modify: `lib/mix/tasks/heex_class_analyzer/node.ex`
- Modify: `lib/mix/tasks/heex_class_analyzer/resolver.ex`
- Modify: `lib/mix/tasks/heex_class_analyzer/output.ex`
- Test: `test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs`
- Test: `test/mix/tasks/heex_class_analyzer/output_test.exs`

**Step 1: Write failing resolver assertion** ✅ Done

In `test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs`, add or update a test that resolves a node with a static class, a conditional toggle, and an either variant.

Expected assertion:

```elixir
node = graph.trees["fn:SampleWeb.Page:render:1:0"] |> hd()

assert node.classes.static == ["page"]
assert "active" in node.classes.optional
assert [[["tone-danger"], ["tone-neutral"]]] == node.classes.exclusive
refute Map.has_key?(node, :permutations)
```

If the current tests operate on `%Node{}`, assert:

```elixir
assert node.classes.static == ["page"]
assert node.permutations in [nil, []]
```

**Step 2: Write failing output assertion** ✅ Done

Create or update `test/mix/tasks/heex_class_analyzer/output_test.exs` to write a graph containing one `%Node{}` and assert the JSON has `"classes"` and does not have `"permutations"`.

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs test/mix/tasks/heex_class_analyzer/output_test.exs
```

Expected: fail because nodes still compute and serialize `permutations`.

**Step 3: Update node struct** ✅ Done

Modify `lib/mix/tasks/heex_class_analyzer/node.ex`:

- Add `classes: %{static: [], optional: [], exclusive: [], dynamic: []}` to the struct.
- Update types to include `classes`.
- Keep `static` and `variants` for now because tests and diagnostics may still use them.
- Remove or deprecate `permutations` from the struct if no existing code requires it. If removal creates broad compile failures, keep the field temporarily but stop populating it.

**Step 4: Update resolver** ✅ Done

Modify `lib/mix/tasks/heex_class_analyzer/resolver.ex`:

- Alias `ClassFacts`.
- Remove `Permutations` alias.
- Replace:

```elixir
permutations = Permutations.compute(all_statics, resolved_variants)
```

with:

```elixir
classes = ClassFacts.from_static_and_variants(all_statics, resolved_variants)
```

- Populate `%Node{classes: classes}`.
- Do not populate `permutations`.

**Step 5: Update output serialization** ✅ Done

Modify `lib/mix/tasks/heex_class_analyzer/output.ex`:

- Serialize `classes: node.classes`.
- Remove `permutations` from serialized JSON.
- Keep `static` and `variants` only if useful for debugging; otherwise remove them in Task 8 after Node migration.

**Step 6: Run focused tests** ✅ Done

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/class_facts_test.exs test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs test/mix/tasks/heex_class_analyzer/output_test.exs
```

Expected: pass.

**Step 7: Commit** Skipped by explicit task instruction: do not commit; leave changes in the worktree.

```bash
git add lib/mix/tasks/heex_class_analyzer/node.ex lib/mix/tasks/heex_class_analyzer/resolver.ex lib/mix/tasks/heex_class_analyzer/output.ex test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs test/mix/tasks/heex_class_analyzer/output_test.exs
git commit -m "Serialize HEEX class facts instead of permutations

Stop generating power-set class permutations for analyzer nodes.
Emit compact class facts that preserve static, optional, exclusive, and dynamic
class sources for downstream CSS selector matching."
```

---

### Task 3: Update Resolver Tests and Fixtures for Class Facts

**Files:**

- Modify: `test/fixtures/css_coverage_graph/heex-class-graph.json`
- Modify: `test/fixtures/css_coverage_cycle/heex-class-graph.json`
- Modify: any test fixtures under `test/fixtures/**/heex-class-graph.json`
- Test: `test/css_coverage_graph_test.mjs`
- Test: `test/css_coverage_cycle_test.mjs`

**Step 1: Update fixture JSON** ✅ Done

For every normal node in graph fixtures:

- Add a `classes` object.
- Remove `permutations`.
- Keep `static` and `variants` only if the Node script still reads them during migration.

Example conversion:

```json
{
  "tag": "section",
  "static": ["page"],
  "variants": [],
  "classes": {
    "static": ["page"],
    "optional": [],
    "exclusive": [],
    "dynamic": []
  },
  "repeat": false,
  "children": []
}
```

**Step 2: Run Node fixture tests** ✅ Done

Run:

```bash
node test/css_coverage_graph_test.mjs
node test/css_coverage_cycle_test.mjs
```

Result: failed as expected because `css_coverage.mjs` still reads `permutations`; after fixture conversion the reports contain no matched selectors until Tasks 4/5 migrate the Node matcher to class facts.

**Step 3: Commit fixture updates after Node migration passes** Skipped by explicit task instruction: do not commit.

Do not commit this task yet if the Node tests fail. Commit fixture updates together with Task 5, after the Node matcher supports class facts.

---

### Task 4: Replace Node Materialization With Context Index

**Files:**

- Modify: `lib/mix/tasks/css_coverage.mjs`
- Test: `test/css_coverage_graph_test.mjs`
- Test: `test/css_coverage_cycle_test.mjs`

**Step 1: Add context-index fixture expectations** ✅ Done

Update existing Node tests to assert current behavior still works:

```js
assert.ok(matched.includes(".page .action"));
assert.ok(matched.includes(".page > .panel"));
assert.ok(matched.includes(".panel + .badge"));
assert.ok(matched.includes(".badge + .chip"));
assert.ok(unmatched.includes(".badge + .panel"));
assert.ok(unmatched.includes(".chip + .badge"));
```

Keep these as black-box behavior tests. Do not test private context object shapes.

**Step 2: Replace `materializeRef` traversal** ✅ Done

In `lib/mix/tasks/css_coverage.mjs`, replace:

- `materializeRef`
- `materializeNodeList`
- cloned `__coverage` tree mutation
- `indexNodeList`

with a context index builder:

```js
function buildGraphIndex(graph, opts = {}) {
  const index = {
    graph,
    contexts: [],
    classToContexts: new Map(),
    allContextIds: [],
    cycles: [],
    unresolvedRefs: [],
    stats: {
      entries: (graph.entries || []).length,
      treeRefs: Object.keys(graph.trees || {}).length,
      canonicalNodes: countCanonicalNodes(graph),
      contexts: 0,
      classIndexKeys: 0,
      selectorCount: 0,
      maxClassesPerNode: 0,
      maxCallStackDepth: 0,
      cycles: 0,
      unresolvedRefs: 0
    },
    maxContexts: opts.maxContexts || 250000
  };

  for (const entry of graph.entries || []) {
    expandRefIntoContexts(index, entry.ref, {
      entry,
      definitionRef: entry.ref,
      parentId: null,
      previousSiblingId: null,
      callStack: [],
      callsite: null
    });
  }

  index.stats.contexts = index.contexts.length;
  index.stats.classIndexKeys = index.classToContexts.size;
  index.stats.cycles = index.cycles.length;
  index.stats.unresolvedRefs = index.unresolvedRefs.length;
  return index;
}
```

**Step 3: Add tiny context records** ✅ Done

Each rendered node context should be:

```js
{
  id,
  entryRef,
  entryModule,
  entrySourceFile,
  entryName,
  definitionRef,
  node,
  parentId,
  previousSiblingId,
  callStack
}
```

Use node object references from `graph.trees`; do not clone nodes.

Quality follow-up: implemented `previousSiblingId` instead of copied `previousSiblingIds`
prefix arrays so sibling metadata stays linear in the number of rendered contexts.

**Step 4: Expand children with component refs** ✅ Done

Implement `expandChildrenIntoContexts(index, children, context)`:

- Keep `previousSiblingId` for the rendered sibling stream.
- When a child is a component ref edge, expand each `component_refs` ref in place.
- The returned context ids from component refs must become siblings of following nodes.
- For a component that renders multiple root nodes, those root context ids are siblings in the caller's child stream.

Quality follow-up: multiple refs inside one `component_refs` edge are expanded
sequentially; later refs see roots from earlier refs as previous siblings.

**Step 5: Add context guard** ✅ Done

Before pushing a new context:

```js
if (index.contexts.length >= index.maxContexts) {
  throw new Error(
    `Context limit exceeded (${index.maxContexts}) while expanding ${definitionRef} from ${entry.ref}`
  );
}
```

**Step 6: Update `loadGraphAnalysis`** ✅ Done

Make `loadGraphAnalysis(analysisDir, opts)` return the graph index instead of `classToNodes`.

Preserve diagnostics:

```js
index.cycles = deduplicateDiagnostics([
  ...normalizeGraphCycles(graph.cycles || []),
  ...index.cycles
]);
```

**Step 7: Run Node tests** ✅ Done

Run:

```bash
node test/css_coverage_graph_test.mjs
node test/css_coverage_cycle_test.mjs
```

Expected: fail until selector matching is updated in Task 5.

Do not commit yet.

---

### Task 5: Match Selectors Against Class Facts

**Files:**

- Modify: `lib/mix/tasks/css_coverage.mjs`
- Test: `test/css_coverage_graph_test.mjs`
- Test: `test/css_coverage_cycle_test.mjs`
- Test: create `test/css_coverage_class_facts_test.mjs`
- Fixture: create `test/fixtures/css_coverage_class_facts/heex-class-graph.json`
- Fixture: create `test/fixtures/css_coverage_class_facts/app.css`

**Step 1: Add class facts fixture** ✅ Done

Create `test/fixtures/css_coverage_class_facts/heex-class-graph.json` with one entry containing nodes that prove:

- static + optional can match together
- two options from the same exclusive group cannot match together
- classes from different exclusive groups can match together
- dynamic class source produces `possibly_dynamic`

Example CSS in `test/fixtures/css_coverage_class_facts/app.css`:

```css
.btn.active {
  color: green;
}

.tone-danger.tone-neutral {
  color: red;
}

.size-sm.tone-danger {
  color: blue;
}

.btn.unknown-runtime-class {
  color: purple;
}
```

**Step 2: Add failing Node test** ✅ Done

Create `test/css_coverage_class_facts_test.mjs`:

```js
import assert from "node:assert/strict";
import { mkdtempSync, cpSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

const tmp = mkdtempSync(join(tmpdir(), "css-coverage-class-facts-"));
cpSync("test/fixtures/css_coverage_class_facts", tmp, { recursive: true });

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

assert.equal(result.status, 0, result.stderr);

const report = JSON.parse(readFileSync(join(tmp, "css-coverage.json"), "utf-8"));
const matched = report.matched.map((entry) => entry.selector);
const unmatched = report.unmatched.map((entry) => entry.selector);
const dynamic = report.possibly_dynamic.map((entry) => entry.selector);

assert.ok(matched.includes(".btn.active"));
assert.ok(unmatched.includes(".tone-danger.tone-neutral"));
assert.ok(matched.includes(".size-sm.tone-danger"));
assert.ok(dynamic.includes(".btn.unknown-runtime-class"));
```

**Step 3: Implement class fact matching** ✅ Done

Replace `nodeMatchesSegment(node, requiredClasses)` with class-fact logic:

```js
function nodeMatchesSegment(node, requiredClasses) {
  if (requiredClasses.length === 0) return "static";

  const facts = node.classes || factsFromLegacyNode(node);
  const concrete = new Set([...facts.static, ...facts.optional]);
  const dynamic = facts.dynamic || [];

  for (const group of facts.exclusive || []) {
    for (const option of group) {
      for (const cls of option) concrete.add(cls);
    }
  }

  const allKnown = requiredClasses.every((cls) => concrete.has(cls));
  if (allKnown && !violatesExclusiveGroup(requiredClasses, facts.exclusive || [])) {
    return "static";
  }

  const hasPartialStatic = requiredClasses.some((cls) => concrete.has(cls));
  if (dynamic.length > 0 && hasPartialStatic) return "dynamic";

  return false;
}
```

Implement:

```js
function violatesExclusiveGroup(requiredClasses, exclusiveGroups) {
  const required = new Set(requiredClasses);

  for (const group of exclusiveGroups) {
    let matchingOptions = 0;

    for (const option of group) {
      if (option.some((cls) => required.has(cls))) {
        matchingOptions++;
      }
    }

    if (matchingOptions > 1) return true;
  }

  return false;
}
```

**Step 4: Update indexes** ✅ Done

Index every known class from:

- `facts.static`
- `facts.optional`
- every class inside `facts.exclusive`

Do not index dynamic unknowns as concrete classes.

**Step 5: Update related candidate traversal** ✅ Done

Replace `ancestors` and `siblings` based APIs with context ids:

```js
function relatedCandidates(comb, context, index) {
  if (comb === ">") return context.parentId == null ? [] : [index.contexts[context.parentId]];
  if (comb === "+" || comb === "~") return previousSiblingCandidates(comb, context, index);
  return ancestorCandidates(context, index);
}
```

`ancestorCandidates` walks `parentId` until null.

`previousSiblingCandidates` uses `context.previousSiblingId`; for `+`, use only the direct previous id, and for `~`, walk the previous-sibling link chain. If `context.node.repeat` is true, include `context` as a possible previous sibling.

**Step 6: Update provenance builders** ✅ Done

Replace `buildPath(ancestors, node)` with:

```js
function buildPath(context, index) {
  return [...ancestorContexts(context, index).reverse(), context].map((ctx) => nodeLabel(ctx.node));
}
```

Replace `buildChain(functionName, ancestors, node)` with context-based entry name and path.

**Step 7: Run all Node tests** ✅ Done

Run:

```bash
node test/css_coverage_graph_test.mjs
node test/css_coverage_cycle_test.mjs
node test/css_coverage_class_facts_test.mjs
```

Expected: pass.

**Step 8: Commit** ⏭️ Skipped per latest user instruction: do not commit

```bash
git add lib/mix/tasks/css_coverage.mjs test/css_coverage_graph_test.mjs test/css_coverage_cycle_test.mjs test/css_coverage_class_facts_test.mjs test/fixtures/css_coverage_graph test/fixtures/css_coverage_cycle test/fixtures/css_coverage_class_facts
git commit -m "Match CSS coverage selectors with class facts

Replace cloned graph materialization with lightweight rendered context records.
Match selectors directly against static, optional, exclusive, and dynamic class
facts without generating permutations."
```

---

### Task 6: Add Node Stats and Context Guard

**Files:**

- Modify: `lib/mix/tasks/css_coverage.mjs`
- Test: create `test/css_coverage_stats_test.mjs`
- Fixture: reuse `test/fixtures/css_coverage_graph`

**Step 1: Add CLI tests** ✅ Done

Create `test/css_coverage_stats_test.mjs`:

```js
import assert from "node:assert/strict";
import { mkdtempSync, cpSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

const tmp = mkdtempSync(join(tmpdir(), "css-coverage-stats-"));
cpSync("test/fixtures/css_coverage_graph", tmp, { recursive: true });

const ok = spawnSync(
  "node",
  [
    "lib/mix/tasks/css_coverage.mjs",
    "--css",
    join(tmp, "app.css"),
    "--analysis",
    tmp,
    "--output",
    join(tmp, "css-coverage.json"),
    "--stats"
  ],
  { encoding: "utf-8" }
);

assert.equal(ok.status, 0, ok.stderr);
assert.match(ok.stdout, /Analysis stats:/);

const report = JSON.parse(readFileSync(join(tmp, "css-coverage.json"), "utf-8"));
assert.equal(typeof report.analysis_stats.contexts, "number");
assert.equal(typeof report.analysis_stats.canonical_nodes, "number");

const limited = spawnSync(
  "node",
  [
    "lib/mix/tasks/css_coverage.mjs",
    "--css",
    join(tmp, "app.css"),
    "--analysis",
    tmp,
    "--output",
    join(tmp, "limited.json"),
    "--max-contexts",
    "1"
  ],
  { encoding: "utf-8" }
);

assert.notEqual(limited.status, 0);
assert.match(limited.stderr, /Context limit exceeded/);
```

**Step 2: Run test to verify it fails** ✅ Done

Run:

```bash
node test/css_coverage_stats_test.mjs
```

Expected: fail because `--stats` and `--max-contexts` do not exist.

**Step 3: Add CLI options** ✅ Done

Update `parseArgs()`:

- Add `stats: false`
- Add `maxContexts: 250000`
- Add `--stats` boolean flag.
- Add `--max-contexts <number>` value flag.
- Validate `--max-contexts` is a positive integer.

**Step 4: Include stats in output** ✅ Done

Add:

```js
analysis_stats: {
  entries: index.stats.entries,
  tree_refs: index.stats.treeRefs,
  canonical_nodes: index.stats.canonicalNodes,
  contexts: index.stats.contexts,
  class_index_keys: index.stats.classIndexKeys,
  selector_count: parsedSelectors.length,
  max_classes_per_node: index.stats.maxClassesPerNode,
  max_call_stack_depth: index.stats.maxCallStackDepth,
  cycles: index.cycles.length,
  unresolved_refs: index.unresolvedRefs.length
}
```

**Step 5: Print stats when requested** ✅ Done

If `opts.stats`, print a compact block:

```text
Analysis stats:
  entries: 2
  tree refs: 3
  canonical nodes: 4
  contexts: 5
  class index keys: 6
  selectors: 9
  max classes per node: 12
  max call stack depth: 3
```

**Step 6: Run stats test** ✅ Done

Run:

```bash
node test/css_coverage_stats_test.mjs
```

Expected: pass.

**Step 7: Commit** Skipped by explicit task instruction: do not commit; leave changes in the worktree.

```bash
git add lib/mix/tasks/css_coverage.mjs test/css_coverage_stats_test.mjs
git commit -m "Add CSS coverage graph stats and context guard

Report analyzer size metrics in coverage output and optionally on stdout.
Fail early with a clear context-limit error instead of allowing unbounded graph
expansion to exhaust process memory."
```

---

### Task 7: Keep and Test Cycle/Missing Ref Diagnostics

**Files:**

- Modify: `lib/mix/tasks/css_coverage.mjs`
- Modify: `test/css_coverage_cycle_test.mjs`
- Create fixture or extend existing cycle fixture for missing refs

**Step 1: Extend cycle test assertions** ✅ Done

In `test/css_coverage_cycle_test.mjs`, assert:

```js
assert.ok(report.cycles.length > 0);
assert.equal(report.summary.cycles, report.cycles.length);
```

If `summary.cycles` is not currently present, add it in this task.

**Step 2: Add missing ref fixture assertion** ✅ Done

Extend a fixture with:

```json
{
  "component_refs": ["fn:MissingWeb.Components:nope:1:0"],
  "callsite": {
    "tag": ".nope",
    "from": "fn:SampleWeb.Page:render:1:0"
  }
}
```

Assert:

```js
assert.ok(report.unresolved_refs.some((entry) => entry.ref === "fn:MissingWeb.Components:nope:1:0"));
assert.equal(report.summary.unresolved_refs, report.unresolved_refs.length);
```

**Step 3: Verify Elixir cycle checks still exist** ✅ Done

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer/resolver_graph_test.exs
```

Expected: pass, including any cycle diagnostic assertions already present.

**Step 4: Run Node diagnostics tests** ✅ Done

Run:

```bash
node test/css_coverage_cycle_test.mjs
```

Expected: pass.

**Step 5: Commit** Skipped per current instruction: do not commit.

```bash
git add lib/mix/tasks/css_coverage.mjs test/css_coverage_cycle_test.mjs test/fixtures/css_coverage_cycle
git commit -m "Preserve graph cycle and missing ref diagnostics

Keep cycle protection in both Elixir graph resolution and Node context
expansion. Surface missing refs and cycles in coverage summaries so graph
growth failures remain diagnosable."
```

---

### Task 8: Remove Dead Permutation Paths

**Files:**

- Delete or stop using: `lib/mix/tasks/heex_class_analyzer/permutations.ex`
- Modify: `lib/mix/tasks/heex_class_analyzer/node.ex`
- Modify: `lib/mix/tasks/heex_class_analyzer/resolver.ex`
- Modify: `lib/mix/tasks/heex_class_analyzer/output.ex`
- Modify: `lib/mix/tasks/css_coverage.mjs`
- Modify: docs/comments mentioning permutations
- Test: all analyzer and coverage tests

**Step 1: Search for remaining permutation references** ✅ Done

Run:

```bash
rg -n "Permutations|permutations|permutation" lib test docs/plans/260517-2256-heex-class-facts-context-index.md
```

Expected: references only in this plan and possibly historical docs.

**Step 2: Remove runtime references** ✅ Done

Remove any production code references to:

- `Mix.Tasks.HeexClassAnalyzer.Permutations`
- `node.permutations`
- JSON `"permutations"`
- Node fallback matching based on `permutations`

Historical docs may remain if clearly historical. Current module docs must describe class facts.

**Step 3: Delete obsolete tests** ✅ Done

If `test/mix/tasks/heex_class_analyzer/permutations_test.exs` exists, delete it or replace it with class facts tests. Do not keep tests for a removed runtime abstraction.

**Step 4: Run focused tests** ✅ Done

Run:

```bash
mix test test/mix/tasks/heex_class_analyzer
node test/css_coverage_graph_test.mjs
node test/css_coverage_cycle_test.mjs
node test/css_coverage_class_facts_test.mjs
node test/css_coverage_stats_test.mjs
```

Expected: pass.

**Step 5: Commit** Skipped by request

```bash
git add lib/mix/tasks/heex_class_analyzer lib/mix/tasks/css_coverage.mjs test docs
git commit -m "Remove HEEX class permutation runtime paths

Delete obsolete power-set class matching paths after migrating analyzer output
and CSS coverage matching to class facts."
```

---

### Task 9: Full Project Verification

**Files:**

- No planned code changes.

**Step 1: Generate analyzer output** ✅ Done

Run:

```bash
mix heex_class_analyzer
```

Expected:

- Command exits successfully.
- `analysis/heex-class-graph.json` exists.
- Output summary reports entries, trees, and cycles.
- The generated JSON contains `"classes"` and does not contain `"permutations"`.

Verify:

```bash
rg -n '"classes"|"permutations"' analysis/heex-class-graph.json
```

Expected: many `"classes"` matches and zero `"permutations"` matches.

**Step 2: Run CSS coverage with stats** ✅ Done

Run:

```bash
node lib/mix/tasks/css_coverage.mjs --list-unmatched --stats
```

Expected:

- Command exits successfully.
- Prints coverage summary.
- Prints analysis stats.
- Does not exhaust memory.

**Step 3: Run required project checks**

Run:

```bash
mix format
mix ex_dna
mix credo
mix compile --warnings-as-errors
```

Expected: all pass.

If Credo reports issues, run:

```bash
mix credo explain <file:line:position>
```

Fix the issue using Credo's explanation, then rerun Credo.

**Step 4: Run precommit** ✅ Done

Run:

```bash
mix precommit
```

Expected: pass.

Do not run `mix heex_class_analyzer` as part of `mix precommit` unless the alias already does. Do not run `mix heex_class_analyzer` again unless needed for this CSS analyzer work.

**Step 5: Inspect git status** ✅ Done

Run:

```bash
git status --short
```

Expected: only intentional changes are present.

**Step 6: Final commit**

If any verification-only updates were made, commit them:

```bash
git add .
git commit -m "Verify class facts CSS coverage analyzer

Regenerate analyzer artifacts where appropriate and complete project
verification for the class facts and context-index CSS coverage migration."
```

---

## Implementation Notes

- Keep cycle checks in both Elixir and Node.
- Do not infer exclusive groups from class naming conventions.
- Keep matching conservative: if the analyzer cannot prove a class combination is impossible, treat it as possible unless dynamic metadata means it should be reported as `possibly_dynamic`.
- Do not add CSS-only tests that compare class strings. The meaningful tests here are analyzer data-shape tests and CSS selector coverage behavior tests.
- `mix heex_class_analyzer` can take time. `mix heex_class_analyzer` is appropriate for this task because this task is specifically CSS analyzer work.
- `mix heex_class_analyzer` and `node lib/mix/tasks/css_coverage.mjs --list-unmatched --stats` are the key memory regression checks.
