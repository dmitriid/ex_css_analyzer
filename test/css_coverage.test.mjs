// Integration tests for `css_coverage.mjs`.
//
// Each test makes a small Phoenix project in a temporary directory and runs
// the script in that directory. The script loads PostCSS from the project
// `node_modules` directory. Set `CSS_COVERAGE_NODE_MODULES` to a `node_modules` directory that
// contains `postcss`, `postcss-import`, and `postcss-selector-parser`:
//
//     CSS_COVERAGE_NODE_MODULES=../my_app/node_modules node --test test/*.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const NODE_MODULES = process.env.CSS_COVERAGE_NODE_MODULES
  ? resolve(process.env.CSS_COVERAGE_NODE_MODULES)
  : null;
const SKIP = NODE_MODULES && existsSync(join(NODE_MODULES, "postcss"))
  ? false
  : "set CSS_COVERAGE_NODE_MODULES to a node_modules directory with postcss";

// One template: <div class="used"><span class="child"></span></div>
const GRAPH = {
  version: 2,
  entries: [{ module: "AppWeb.Page", name: "render/1", ref: "fn:AppWeb.Page:render:1:0" }],
  trees: {
    "fn:AppWeb.Page:render:1:0": [
      node("div", ["used"], [node("span", ["child"], [])]),
    ],
  },
  cycles: [],
  unresolved: [],
};

function node(tag, classes, children) {
  return {
    tag,
    static: classes,
    variants: [],
    classes: { static: classes, optional: [], exclusive: [], dynamic: [] },
    repeat: false,
    children,
  };
}

function makeProject(css) {
  const root = mkdtempSync(join(tmpdir(), "css-coverage-"));
  mkdirSync(join(root, "lib/mix/tasks"), { recursive: true });
  mkdirSync(join(root, "assets/css"), { recursive: true });
  mkdirSync(join(root, "analysis"));
  writeFileSync(join(root, "mix.exs"), "");
  writeFileSync(join(root, "package.json"), "{}");
  symlinkSync(NODE_MODULES, join(root, "node_modules"));
  copyFileSync(join(REPO_ROOT, "css_coverage.mjs"), join(root, "lib/mix/tasks/css_coverage.mjs"));
  writeFileSync(join(root, "analysis/heex-class-graph.json"), JSON.stringify(GRAPH));
  writeFileSync(join(root, "assets/css/app.css"), css);
  return root;
}

function run(css, args = []) {
  const root = makeProject(css);
  try {
    const result = spawnSync("node", ["lib/mix/tasks/css_coverage.mjs", ...args], {
      cwd: root,
      encoding: "utf-8",
    });
    const report = JSON.parse(readFileSync(join(root, "analysis/css-coverage.json"), "utf-8"));
    const cssAfter = readFileSync(join(root, "assets/css/app.css"), "utf-8");
    return { status: result.status, stdout: result.stdout, stderr: result.stderr, report, cssAfter };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("an @@ignore comment moves the next rule to the ignored category", { skip: SKIP }, () => {
  const { report, stdout } = run(`
.used .child { color: red; }

/* @@ignore The PDF viewer hook creates this element */
.pdf-layer span, .pdf-layer br { color: blue; }

.missing { color: green; }
`);

  assert.deepEqual(report.matched_selectors, [".used .child"]);
  assert.deepEqual(report.unmatched_selectors, [".missing"]);
  assert.deepEqual(
    report.ignored.map((entry) => [entry.selector, entry.reason]),
    [
      [".pdf-layer span", "The PDF viewer hook creates this element"],
      [".pdf-layer br", "The PDF viewer hook creates this element"],
    ]
  );
  assert.equal(report.summary.ignored, 2);
  assert.match(stdout, /1 unmatched, .* 2 ignored/);
});

test("an @@ignore comment applies only to the rule immediately after it", { skip: SKIP }, () => {
  const { report } = run(`
/* @@ignore Inserted HTML */
.first-missing { color: red; }
.second-missing { color: blue; }

/* A plain comment */
.third-missing { color: green; }
`);

  assert.deepEqual(report.ignored.map((entry) => entry.selector), [".first-missing"]);
  assert.deepEqual(report.unmatched_selectors, [".second-missing", ".third-missing"]);
});

test("an @@ignore comment works inside an at-rule and before a keyframes rule", { skip: SKIP }, () => {
  const { report } = run(`
@media (min-width: 640px) {
  /* @@ignore Inserted HTML */
  .wide-missing { color: red; }
}

/* @@ignore The JS hook sets this animation */
@keyframes spin-js { to { rotate: 1turn; } }

@keyframes unused-spin { to { rotate: 1turn; } }
`);

  assert.deepEqual(report.ignored.map((entry) => entry.selector), [".wide-missing"]);
  assert.deepEqual(report.unmatched_selectors, []);
  assert.deepEqual(
    report.ignored_keyframes.map((entry) => [entry.name, entry.reason]),
    [["spin-js", "The JS hook sets this animation"]]
  );
  assert.deepEqual(report.unused_keyframes.map((entry) => entry.name), ["unused-spin"]);
  assert.equal(report.summary.keyframes_ignored, 1);
});

test("--fail-on-unmatched sets the exit status from unmatched selectors and unused keyframes", { skip: SKIP }, () => {
  const unmatched = ".used { color: red; }\n.missing { color: blue; }\n";
  const ignored = ".used { color: red; }\n/* @@ignore Inserted HTML */\n.missing { color: blue; }\n";
  const unusedKeyframes = ".used { color: red; }\n@keyframes unused-spin { to { rotate: 1turn; } }\n";

  assert.equal(run(unmatched).status, 0);

  const failed = run(unmatched, ["--fail-on-unmatched"]);
  assert.equal(failed.status, 1);
  assert.match(failed.stderr, /1 unmatched selectors, 0 unused keyframes/);

  assert.equal(run(unusedKeyframes, ["--fail-on-unmatched"]).status, 1);
  assert.equal(run(ignored, ["--fail-on-unmatched"]).status, 0);
});

test("--remove-unmatched keeps the ignored rules", { skip: SKIP }, () => {
  const { cssAfter } = run(
    ".used { color: red; }\n/* @@ignore Inserted HTML */\n.kept { color: blue; }\n.removed { color: green; }\n",
    ["--remove-unmatched"]
  );

  assert.match(cssAfter, /\.kept/);
  assert.doesNotMatch(cssAfter, /\.removed/);
});
