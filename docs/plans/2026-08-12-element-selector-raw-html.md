# Raw HTML Element Selector Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use @executing-plans to implement this plan task by task.

**Goal:** Match a class-qualified element selector when imported `Phoenix.HTML.raw/1` can create that element.

**Architecture:** Discovery already records module imports. The resolver will use this data when it inspects a local `raw/1` call. The CSS matcher will continue to apply its existing one-level raw HTML limit.

**Tech Stack:** Elixir, ExUnit, Node.js, PostCSS

---

### Task 1: Add the regression test

**Files:**

- Modify: `../rsvp/test/mix/tasks/heex_css_repeat_sibling_test.exs`

**Step 1: Add a graph fixture for imported raw HTML**

Add a test module source that imports `Phoenix.HTML`.
Add a HEEX function that calls `raw(markdown_to_html(@body))` below `.event-page`.
Add a helper function that returns text.

**Step 2: Add CSS selectors**

Add `.event-page ul`, `.event-page ol`, and `.event-page li:last-child`.
Add `.event-page ul li` as a deep selector that must not match.

**Step 3: Run the focused test**

Run: `mix test test/mix/tasks/heex_css_repeat_sibling_test.exs`

Expected: The new test fails because the three example selectors are unmatched.

### Task 2: Recognize imported raw HTML

**Files:**

- Modify: `heex_class_analyzer/resolver.ex`

**Step 1: Check the calling module imports**

Use `Registry.get_module/2` to read the module data.
Return true for local `raw/1` only when the module imports `Phoenix.HTML`.

**Step 2: Keep helper analysis precise**

Recognize a direct `Phoenix.HTML.raw/1` call in a helper clause.
Recognize an imported `raw/1` call only when the helper module imports `Phoenix.HTML`.
Do not treat an unrelated local `raw/1` function as Phoenix raw HTML.

**Step 3: Run the focused test**

Run: `mix test test/mix/tasks/heex_css_repeat_sibling_test.exs`

Expected: All tests in the file pass.

### Task 3: Verify the RSVP report

**Files:**

- Verify: `../rsvp/analysis/heex-class-graph.json`
- Verify: `../rsvp/analysis/css-coverage.json`

**Step 1: Generate the HEEX graph**

Run: `mix heex_class_analyzer`

Expected: The command exits with status 0.

**Step 2: Generate the CSS report**

Run: `node lib/mix/tasks/css_coverage.mjs --list-unmatched`

Expected: The six `.event-page` list selectors are not unmatched.

**Step 3: Inspect all changes**

Run: `git diff --check`

Expected: The command has no output and exits with status 0.

**Step 4: Stop before a commit**

Report the changed files.
Wait for explicit commit approval.
