/*
 * ============================================================================
 * CSS Coverage Analyzer — Dead CSS Detection via HEEX Class Analysis
 * ============================================================================
 *
 * PURPOSE
 * -------
 * This script cross-references CSS selectors from the project's `app.css`
 * against the HEEX class analyzer graph output in `analysis/` to find
 * CSS rules that are never referenced by any template. The goal is to identify
 * dead CSS — rules whose selectors don't match any class combination that could
 * ever appear in the rendered HTML.
 *
 * PREREQUISITES
 * -------------
 * 1. Run the HEEX class analyzer first:
 *
 *        mix heex_class_analyzer
 *
 *    This produces `analysis/heex-class-graph.json`, containing entry refs
 *    and canonical HEEX trees with component refs as graph edges.
 *    css_coverage.mjs requires graph version 2 and does not support legacy
 *    per-module analyzer JSON.
 *
 * 2. Node.js dependencies must be installed at the project root:
 *
 *        npm install
 *
 *    Required packages: postcss, postcss-import, postcss-selector-parser
 *
 * HOW TO RUN
 * ----------
 *    # From the project root:
 *    node lib/mix/tasks/css_coverage.mjs
 *
 *    # With custom paths:
 *    node lib/mix/tasks/css_coverage.mjs --css assets/css/app.css --analysis analysis/ --output analysis/css-coverage.json
 *
 *    # Show help:
 *    node lib/mix/tasks/css_coverage.mjs --help
 *
 * CLI FLAGS
 * ---------
 *    --css <path>        Path to the CSS entry file (default: assets/css/app.css)
 *    --analysis <dir>    Directory containing graph v2 heex-class-graph.json (default: analysis/)
 *    --output <path>     Path for the output JSON report (default: analysis/css-coverage.json)
 *    --js <path>         JavaScript file or directory to scan for runtime class strings. Can be repeated.
 *    --remove-unmatched     Remove unmatched selectors (and already-invalidated ones) from CSS source
 *    --list-unmatched       List all unmatched selectors (including already-invalidated ones) to stdout
 *    --list-runtime         List runtime-matched selectors to stdout
 *    --stats                Print graph/context analysis statistics
 *    --max-contexts <n>     Maximum rendered contexts to expand before failing (default: 250000)
 *    --include-node-modules-css
 *                          Include selectors from CSS imported from node_modules
 *    --help              Show usage information
 *
 *    All paths are resolved relative to the project root (detected by walking
 *    up from the script's location looking for mix.exs).
 *
 * ALGORITHM — THREE PHASES
 * ========================
 *
 * Phase 1: Parse CSS
 * ------------------
 * The CSS file is parsed using PostCSS with the postcss-import plugin to
 * resolve any local @import statements. Tailwind-specific directives are
 * skipped entirely:
 *
 *   - @import "tailwindcss" (and any non-file import that can't be resolved)
 *   - @source, @plugin, @custom-variant
 *
 * @keyframes at-rules are separately analyzed for usage — their animation
 * names are checked against animation/animation-name properties in the CSS.
 *
 * For each CSS rule node, postcss-selector-parser decomposes the selector
 * into its constituent parts. State-only pseudo-classes (:hover, :focus, etc.)
 * and pseudo-elements (::before, ::after) don't contribute classes. Classless
 * structural selector pieces such as `:not(...)`, `:has(...)`, `:is(...)`,
 * tags, attributes, and `*` are preserved as wildcard segments when they sit
 * between classed selector pieces. This keeps combinator structure intact for
 * selectors like `.stack > * + *` and `.x > :not(.a) .b` without trying to
 * prove the inner pseudo condition.
 *
 * Each selector is decomposed into an ordered list of "segments", where each
 * segment has:
 *   - classes: array of class names required at that position
 *   - tag: optional element tag required at that position
 *   - combinator: the combinator that connects this segment to the previous
 *     one (null for the first segment, " " for descendant, ">" for child,
 *     "+" for adjacent sibling, "~" for general sibling)
 *   - wildcard: true for classless structural segments that can match any
 *     analyzed node but still enforce their combinator
 *
 * Example decompositions:
 *   `.a.b > .c`  →  [{classes:["a","b"], tag:null, combinator:null}, {classes:["c"], tag:null, combinator:">"}]
 *   `.event-page .event-hero__title`  →  [{classes:["event-page"], tag:null, combinator:null}, {classes:["event-hero__title"], tag:null, combinator:" "}]
 *   `.x > a .b` → [{classes:["x"], tag:null, combinator:null}, {classes:[], tag:"a", combinator:">"}, {classes:["b"], tag:null, combinator:" "}]
 *
 * Comma-separated selectors like `.input, .select, .textarea {}` are split
 * into independent selectors, each evaluated separately — if `.input` matches
 * but `.textarea` doesn't, they get different categories.
 *
 * Selectors with no class component (element-only like `html`, `body`;
 * attribute selectors like `[data-phx-session]`; `:root`) go into the
 * "skipped" category since we can't class-match them.
 *
 * `:not(.class)` is modeled as a negative class requirement, not as a positive
 * class that must exist on the element. A selector like
 * `.btn:hover:not(.disabled)` can therefore match a `.btn` node that is not
 * always known to have `.disabled`. Unsupported structural pseudo-classes that
 * require subtree reasoning remain conservative and are skipped.
 *
 * Phase 2: Load Analysis Graph
 * ----------------------------
 * heex-class-graph.json is read from the analysis directory. It must be graph
 * version 2; legacy per-module analyzer JSON is not supported. It has the
 * structure:
 *
 *   {
 *     "version": 2,
 *     "entries": [{ "ref": "fn:...", "module": "...", "name": "render/1" }],
 *     "trees": { "fn:...": [ { tag, static, variants, classes, children }, ... ] }
 *   }
 *
 * Each node in the tree represents an HTML element and contains:
 *   - tag: the element tag (e.g. "div", "nav", ".link" for Phoenix components)
 *   - static: array of always-present class names
 *   - variants: array of conditional classes ({type:"toggle", value:...} or
 *     {type:"either", values:[...]})
 *   - classes: compact class facts with static, optional, exclusive, and
 *     dynamic buckets used for selector matching
 *   - repeat: whether the element comes from a HEEx :for and may render
 *     multiple sibling copies of itself
 *   - children: nested child nodes with the same structure
 *
 * DYNAMIC ENTRIES: Objects with {dynamic: true, reason, expr, chain} can
 * appear in class fact dynamic buckets and exclusive branch options.
 * These represent classes computed at runtime (e.g. from an assign like
 * @btn_class) that could be any value. Nodes containing dynamic entries
 * are flagged so that CSS selectors that partially match are categorized
 * as "possibly_dynamic" (with the original reason/expr metadata) rather
 * than "unmatched".
 *
 * Component refs are spliced in as rendered DOM children, not wrapper nodes.
 * A rendered context index maps each class name to tiny context records that
 * reference canonical graph nodes and store parent/previous-sibling links. A
 * separate allContextIds list is kept for selectors whose rightmost segment is
 * classless (for example `.stack > * + *`).
 *
 * Slot placeholders are materialized against the caller's slot scope. This is
 * important for nested layouts where component A passes `render_slot(@inner_block)`
 * into component B: the placeholder must still refer to A's caller, not B's
 * inner block. Raw HTML placeholders emitted by helpers returning
 * `Phoenix.HTML.raw/1` are indexed as classless nodes and can satisfy one
 * immediate child selector segment below their HEEX parent.
 *
 * Phase 3: Match Selectors (Right-to-Left)
 * -----------------------------------------
 * CSS selectors are matched right-to-left, mirroring how browser engines
 * evaluate selectors. For each parsed selector:
 *
 * 1. Start from the RIGHTMOST segment (the "key selector"). If that segment is
 *    classless/wildcard, all analyzed nodes are potential candidates.
 *
 * 2. Find all tree nodes whose class facts can satisfy ALL classes required by
 *    that segment. Known static, optional, and exclusive classes are checked
 *    without expanding power sets; exclusive branch conflicts are rejected.
 *    Wildcard segments match any analyzed node.
 *
 * 3. For each candidate node from step 2, recursively walk LEFT through the
 *    remaining selector segments, checking combinator constraints against the
 *    node's ancestor chain and siblings. Recursion lets wildcard/descendant
 *    segments try every valid ancestor position instead of greedily accepting
 *    the nearest one:
 *
 *    - Descendant combinator (" "): ANY ancestor in the chain must have a
 *      class facts satisfying the segment's classes.
 *    - Child combinator (">"): the IMMEDIATE parent must satisfy the segment.
 *    - Adjacent sibling combinator ("+"): a sibling node (another child of
 *      the same parent), or another rendered copy of the same repeatable
 *      node, must satisfy the segment.
 *    - General sibling combinator ("~"): same as "+", any sibling works.
 *
 *    "Satisfies a segment" means: can that node's class facts contain ALL
 *    classes in the segment? Wildcard segments satisfy any analyzed node.
 *
 * 4. Results are categorized:
 *    - matched: all segments satisfied statically, with full provenance.
 *    - runtime-matched: HEEX graph does not prove the selector, but runtime
 *      class evidence explains the missing class atoms without inventing DOM
 *      structure.
 *    - possibly_dynamic: couldn't match statically, but a candidate path
 *      involves nodes with dynamic ("<dynamic>") entries.
 *    - unmatched: no match found and no dynamic entries involved.
 *    - skipped: selectors with no class components.
 *
 * Runtime evidence comes from:
 *   - JavaScript string literals in configured `--js` paths, defaulting to
 *     project asset JS locations.
 *   - CSS imported from `node_modules` when package CSS is imported. Those
 *     classes explain browser/runtime library DOM such as Plyr markup.
 *   - Built-in Phoenix runtime classes that Phoenix itself may add, such as
 *     `phx-drop-target-active`.
 *
 * Runtime evidence can satisfy missing class atoms for selectors whose
 * remaining structure is already known from HEEX. It cannot create parent,
 * child, or sibling relationships that the graph does not contain.
 *
 * OUTPUT FORMAT
 * -------------
 * The script writes JSON to analysis/css-coverage.json (configurable) with
 * arrays for matched, runtime_matched, possibly_dynamic, unmatched, and skipped
 * selectors plus a summary object with counts. It also prints a one-line
 * summary to stdout.
 *
 * Each matched entry includes:
 *   - selector: the original CSS selector text
 *   - file: source CSS file path
 *   - line: line number in the CSS file
 *   - matches: array of match objects with module, function, path (ancestor
 *     chain as tag.classes strings), chain (human-readable string), and
 *     dynamic info if applicable
 *
 * DYNAMIC HANDLING
 * ----------------
 * When a node has "<dynamic>" in any of its class lists, it is treated as
 * potentially matching ANY class. During right-to-left matching, if a segment
 * cannot be satisfied by static classes alone but a dynamic node is in the
 * path, the selector is classified as "possibly_dynamic" with metadata about
 * which part was unresolved.
 *
 * MUTATION FLAGS
 * --------------
 * `--remove-unmatched`, `--invalidate-unmatched`, and `--restore-unmatched`
 * operate only on actual unmatched selectors and unused keyframes. They do not
 * touch runtime-matched selectors.
 *
 * ============================================================================
 */

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { resolve, dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import postcss from "postcss";
import postcssImport from "postcss-import";
import selectorParser from "postcss-selector-parser";

// ---------------------------------------------------------------------------
// Utility: find project root by walking up looking for mix.exs
// ---------------------------------------------------------------------------
function findProjectRoot() {
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  let dir = scriptDir;
  while (dir !== "/") {
    if (existsSync(join(dir, "mix.exs"))) return dir;
    dir = dirname(dir);
  }
  // Fallback to CWD
  if (existsSync(join(process.cwd(), "mix.exs"))) return process.cwd();
  console.error("ERROR: Could not find project root (no mix.exs found).");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// CLI argument parsing
// ---------------------------------------------------------------------------
function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {
    css: "assets/css/app.css",
    analysis: "analysis/",
    output: "analysis/css-coverage.json",
    invalidateUnmatched: false,
    restoreUnmatched: false,
    removeUnmatched: false,
    listUnmatched: false,
    listRuntime: false,
    stats: false,
    maxContexts: 250000,
    includeNodeModulesCss: false,
    jsPaths: [],
  };

  const HELP = `Usage: node css_coverage.mjs [options]
  --css <path>              CSS file (default: assets/css/app.css)
  --analysis <dir>          Directory containing graph v2 heex-class-graph.json (default: analysis/)
  --output <path>           Output file (default: analysis/css-coverage.json)
  --js <path>               JavaScript file or directory to scan for runtime class strings. Can be repeated.
  --invalidate-unmatched    Prepend ${UNMATCHED_MARKER} to unmatched selectors in the CSS source
  --restore-unmatched       Remove ${UNMATCHED_MARKER} markers from all selectors in the CSS source
  --remove-unmatched           Remove unmatched selectors (and already-invalidated ones) from CSS source
  --list-unmatched             List all unmatched selectors (including already-invalidated ones) to stdout
  --list-runtime               List all runtime-matched selectors to stdout
  --stats                      Print graph/context analysis statistics
  --max-contexts <n>           Maximum rendered contexts to expand before failing (default: 250000)
  --include-node-modules-css   Include selectors from CSS imported from node_modules
  --help                    Show this message`;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    if (arg === "--help") {
      console.log(HELP);
      process.exit(0);
    } else if (arg === "--css") {
      opts.css = args[++i];
    } else if (arg === "--analysis") {
      opts.analysis = args[++i];
    } else if (arg === "--output") {
      opts.output = args[++i];
    } else if (arg === "--js") {
      opts.jsPaths.push(args[++i]);
    } else if (arg === "--invalidate-unmatched") {
      opts.invalidateUnmatched = true;
    } else if (arg === "--restore-unmatched") {
      opts.restoreUnmatched = true;
    } else if (arg === "--remove-unmatched") {
      opts.removeUnmatched = true;
    } else if (arg === "--list-unmatched") {
      opts.listUnmatched = true;
    } else if (arg === "--list-runtime") {
      opts.listRuntime = true;
    } else if (arg === "--stats") {
      opts.stats = true;
    } else if (arg === "--max-contexts") {
      opts.maxContexts = parsePositiveIntegerFlag(arg, args[++i]);
    } else if (arg === "--include-node-modules-css") {
      opts.includeNodeModulesCss = true;
    } else {
      console.error(`Unknown option: ${arg}\n`);
      console.error(HELP);
      process.exit(1);
    }
  }
  return opts;
}

function parsePositiveIntegerFlag(flag, value) {
  if (value === undefined || value.startsWith("--")) {
    console.error(`${flag} requires a positive decimal integer value`);
    process.exit(1);
  }

  if (!/^[0-9]+$/.test(value)) {
    console.error(`${flag} must be a positive decimal integer`);
    process.exit(1);
  }

  const parsed = Number(value);

  if (!Number.isSafeInteger(parsed) || parsed < 1) {
    console.error(`${flag} must be a positive decimal integer`);
    process.exit(1);
  }

  return parsed;
}

// ---------------------------------------------------------------------------
// PHASE 1: Parse CSS
// ---------------------------------------------------------------------------

/** Tailwind / non-standard at-rules to skip entirely */
const SKIP_AT_RULES = new Set([
  "source",
  "plugin",
  "custom-variant",
]);

const UNMATCHED_PREFIX = "____unmatched___";
const UNMATCHED_MARKER = "." + UNMATCHED_PREFIX;
const PHOENIX_RUNTIME_CLASSES = ["phx-drop-target-active"];

/**
 * Parse a CSS file and return an array of parsed selector descriptors.
 *
 * Each descriptor:
 *   { selectorText, file, line, segments: [{classes:[], combinator:null|string}] }
 *
 * Comma-separated selectors produce separate descriptors.
 */
async function parseCss(cssPath, projectRoot, opts = {}) {
  const cssContent = readFileSync(cssPath, "utf-8");
  const relCssPath = relative(projectRoot, cssPath);
  const nodeModulesCssEvidence = opts.nodeModulesCssEvidence || new Map();

  // Pre-filter: strip lines that postcss-import can't handle and that
  // aren't standard @import directives pointing to local files.
  // This avoids errors from non-file imports like @import "tailwindcss".
  const filteredCss = cssContent
    .split("\n")
    .map((line) => {
      const trimmed = line.trim();
      // Skip imports that postcss-import cannot resolve as local files.
      // Package-style imports are left intact so node_modules CSS can be
      // harvested as runtime class evidence.
      if (
        /^@import\s+["']tailwindcss["']/.test(trimmed) ||
        /^@import\s+(url\()?["']?https?:\/\//.test(trimmed)
      ) {
        return "/* [css-coverage: skipped] " + trimmed + " */";
      }
      // Skip Tailwind-specific at-rules that postcss can't parse
      if (/^@(source|plugin)\s/.test(trimmed)) {
        return "/* [css-coverage: skipped] " + trimmed + " */";
      }
      return line;
    })
    .join("\n");

  const result = await postcss([
    postcssImport({
      load(filename) {
        if (!filename || !existsSync(filename)) return "";
        if (!opts.includeNodeModulesCss && isNodeModulesPath(filename)) {
          collectNodeModulesCssRuntimeEvidence(
            readFileSync(filename, "utf-8"),
            filename,
            projectRoot,
            nodeModulesCssEvidence
          );

          return "";
        }

        return readFileSync(filename, "utf-8");
      },
    }),
  ]).process(filteredCss, { from: cssPath });

  const selectors = [];

  // Collect rules to skip: those nested inside @keyframes or other skippable at-rules
  const skippableAtRuleParents = new Set();
  result.root.walk((node) => {
    if (
      node.type === "atrule" &&
      (SKIP_AT_RULES.has(node.name) ||
        (node.name === "import" &&
          node.params &&
          node.params.includes("tailwindcss")))
    ) {
      skippableAtRuleParents.add(node);
    }
  });

  /**
   * Check if a node is nested inside a skippable at-rule.
   */
  function isInsideSkippableAtRule(node) {
    let parent = node.parent;
    while (parent) {
      if (skippableAtRuleParents.has(parent)) return true;
      parent = parent.parent;
    }
    return false;
  }

  result.root.walkRules((node) => {
    if (isInsideSkippableAtRule(node)) return;

    const line =
      node.source && node.source.start ? node.source.start.line : null;
    // Determine the source file — postcss-import may have inlined from another file
    const sourceFile =
      node.source && node.source.input && node.source.input.file
        ? relative(projectRoot, node.source.input.file)
        : relCssPath;

    // Parse the selector
    try {
      const parsed = selectorParser().astSync(node.selector);

      for (const sel of parsed.nodes) {
        const selectorText = stringifySelector(sel);

        // Skip previously invalidated selectors
        if (selectorText.includes(UNMATCHED_MARKER)) {
          continue;
        }

        if (selectorHasUnsupportedRuntimePseudo(sel)) {
          selectors.push({
            selectorText,
            file: sourceFile,
            line,
            segments: null,
            skipReason: "unsupported structural pseudo-class",
          });
          continue;
        }

        const segments = extractSegments(sel);

        if (segments === null) {
          selectors.push({
            selectorText,
            file: sourceFile,
            line,
            segments: null,
            skipReason: "no class selectors",
          });
        } else {
          selectors.push({
            selectorText,
            file: sourceFile,
            line,
            segments,
          });
        }
      }
    } catch {
      // If selector parsing fails, skip it
      selectors.push({
        selectorText: node.selector,
        file: sourceFile,
        line,
        segments: null,
        skipReason: "unparseable selector",
      });
    }
  });

  return selectors;
}

function isNodeModulesPath(filename) {
  return /(^|[/\\])node_modules([/\\]|$)/.test(filename);
}

function collectNodeModulesCssRuntimeEvidence(cssContent, cssPath, projectRoot, evidence) {
  let root;

  try {
    root = postcss.parse(cssContent, { from: cssPath });
  } catch {
    return;
  }

  root.walkRules((rule) => {
    const line = rule.source && rule.source.start ? rule.source.start.line : null;

    try {
      const parsed = selectorParser().astSync(rule.selector);

      parsed.walkClasses((classNode) => {
        addRuntimeEvidence(evidence, classNode.value, {
          file: relative(projectRoot, cssPath),
          line,
          literal: rule.selector,
          source: "node_modules_css",
        });
      });
    } catch {
      // Ignore vendor selectors that postcss-selector-parser cannot parse.
    }
  });
}

// ---------------------------------------------------------------------------
// Runtime JavaScript Class Evidence
// ---------------------------------------------------------------------------

const CLASS_TOKEN_RE = /[A-Za-z_][A-Za-z0-9_-]*(?:\[[^\]\s]+\])?/g;

function discoverJavaScriptFiles(paths) {
  const files = new Set();

  function visit(path) {
    if (!path || !existsSync(path) || isNodeModulesPath(path)) return;

    const stat = statSync(path);

    if (stat.isDirectory()) {
      for (const entry of readdirSync(path)) {
        visit(join(path, entry));
      }
    } else if (stat.isFile() && /\.(m?js)$/.test(path)) {
      files.add(path);
    }
  }

  for (const path of paths) visit(path);

  return [...files].sort();
}

function extractJavaScriptStringLiterals(sourceText) {
  const literals = [];
  let i = 0;
  let line = 1;

  while (i < sourceText.length) {
    const ch = sourceText[i];

    if (ch === "\n") {
      line++;
      i++;
      continue;
    }

    if (ch === "/" && sourceText[i + 1] === "/") {
      i += 2;
      while (i < sourceText.length && sourceText[i] !== "\n") i++;
      continue;
    }

    if (ch === "/" && sourceText[i + 1] === "*") {
      i += 2;
      while (i < sourceText.length) {
        if (sourceText[i] === "\n") line++;
        if (sourceText[i] === "*" && sourceText[i + 1] === "/") {
          i += 2;
          break;
        }
        i++;
      }
      continue;
    }

    if (ch === '"' || ch === "'") {
      const startLine = line;
      const { value, nextIndex, line: nextLine } = readQuotedLiteral(sourceText, i, ch, line);
      literals.push({ literal: value, line: startLine });
      i = nextIndex;
      line = nextLine;
      continue;
    }

    if (ch === "`") {
      const { chunks, nextIndex, line: nextLine } = readTemplateLiteral(sourceText, i, line);
      literals.push(...chunks);
      i = nextIndex;
      line = nextLine;
      continue;
    }

    i++;
  }

  return literals.filter(({ literal }) => literal.length > 0);
}

function readQuotedLiteral(sourceText, startIndex, quote, startLine) {
  let value = "";
  let i = startIndex + 1;
  let line = startLine;

  while (i < sourceText.length) {
    const ch = sourceText[i];

    if (ch === "\n") line++;

    if (ch === "\\") {
      if (i + 1 < sourceText.length) {
        value += sourceText[i + 1];
        if (sourceText[i + 1] === "\n") line++;
        i += 2;
        continue;
      }
    }

    if (ch === quote) {
      return { value, nextIndex: i + 1, line };
    }

    value += ch;
    i++;
  }

  return { value, nextIndex: i, line };
}

function readTemplateLiteral(sourceText, startIndex, startLine) {
  const chunks = [];
  let current = "";
  let currentLine = startLine;
  let i = startIndex + 1;
  let line = startLine;

  while (i < sourceText.length) {
    const ch = sourceText[i];

    if (ch === "\n") line++;

    if (ch === "\\") {
      if (i + 1 < sourceText.length) {
        current += sourceText[i + 1];
        if (sourceText[i + 1] === "\n") line++;
        i += 2;
        continue;
      }
    }

    if (ch === "`") {
      if (current.length > 0) chunks.push({ literal: current, line: currentLine });
      return { chunks, nextIndex: i + 1, line };
    }

    if (ch === "$" && sourceText[i + 1] === "{") {
      if (current.length > 0) chunks.push({ literal: current, line: currentLine });
      current = "";
      i += 2;
      const skipped = skipTemplateExpression(sourceText, i, line);
      i = skipped.nextIndex;
      line = skipped.line;
      currentLine = line;
      continue;
    }

    if (current.length === 0) currentLine = line;
    current += ch;
    i++;
  }

  if (current.length > 0) chunks.push({ literal: current, line: currentLine });
  return { chunks, nextIndex: i, line };
}

function skipTemplateExpression(sourceText, startIndex, startLine) {
  let depth = 1;
  let i = startIndex;
  let line = startLine;

  while (i < sourceText.length && depth > 0) {
    const ch = sourceText[i];

    if (ch === "\n") line++;

    if (ch === '"' || ch === "'") {
      const quoted = readQuotedLiteral(sourceText, i, ch, line);
      i = quoted.nextIndex;
      line = quoted.line;
      continue;
    }

    if (ch === "`") {
      const template = readTemplateLiteral(sourceText, i, line);
      i = template.nextIndex;
      line = template.line;
      continue;
    }

    if (ch === "{") depth++;
    if (ch === "}") depth--;
    i++;
  }

  return { nextIndex: i, line };
}

function buildRuntimeClassEvidence(files, projectRoot) {
  const evidence = new Map();

  for (const file of files) {
    const sourceText = readFileSync(file, "utf-8");

    for (const { literal, line } of extractJavaScriptStringLiterals(sourceText)) {
      for (const token of classTokensFromLiteral(literal)) {
        addRuntimeEvidence(evidence, token, {
          file: relative(projectRoot, file),
          line,
          literal,
        });
      }
    }
  }

  return evidence;
}

function buildPhoenixRuntimeClassEvidence() {
  const evidence = new Map();

  for (const token of PHOENIX_RUNTIME_CLASSES) {
    addRuntimeEvidence(evidence, token, {
      file: "<phoenix-runtime>",
      line: null,
      literal: token,
    });
  }

  return evidence;
}

function addRuntimeEvidence(evidence, token, entry) {
  if (!token) return;
  if (!evidence.has(token)) evidence.set(token, []);
  evidence.get(token).push(entry);
}

function mergeRuntimeEvidence(...evidenceMaps) {
  const merged = new Map();

  for (const evidence of evidenceMaps) {
    for (const [token, entries] of evidence) {
      for (const entry of entries) {
        addRuntimeEvidence(merged, token, entry);
      }
    }
  }

  return merged;
}

function classTokensFromLiteral(literal) {
  const tokens = new Set();

  for (const match of literal.matchAll(CLASS_TOKEN_RE)) {
    const token = match[0].replace(/^\./, "");
    if (token && !token.endsWith("-")) tokens.add(token);
  }

  return tokens;
}

function serializeRuntimeEvidence(evidence) {
  return Object.fromEntries(
    [...evidence.entries()].sort(([a], [b]) => a.localeCompare(b))
  );
}

/**
 * Analyze @keyframes declarations in the CSS source and find which ones are
 * referenced by animation or animation-name properties.
 *
 * Returns { declarations: Map<name, {file, line, node}>, references: Set<name>, invalidated: [{name, file, line}] }
 */
function analyzeKeyframes(cssPath, projectRoot) {
  const cssContent = readFileSync(cssPath, "utf-8");
  const relCssPath = relative(projectRoot, cssPath);
  const root = postcss.parse(cssContent, { from: cssPath });

  const declarations = new Map();
  const references = new Set();
  const invalidated = [];

  root.walkAtRules("keyframes", (atRule) => {
    const name = atRule.params;
    const line = atRule.source && atRule.source.start ? atRule.source.start.line : null;

    if (name.startsWith(UNMATCHED_PREFIX)) {
      const originalName = name.replace(UNMATCHED_PREFIX, "");
      invalidated.push({ name: originalName, file: relCssPath, line });
    } else {
      declarations.set(name, { file: relCssPath, line, node: atRule });
    }
  });

  root.walkDecls((decl) => {
    if (decl.prop === "animation-name") {
      for (const part of decl.value.split(",")) {
        const trimmed = part.trim();
        if (trimmed && trimmed !== "none") references.add(trimmed);
      }
    } else if (decl.prop === "animation") {
      for (const [name] of declarations) {
        const tokens = decl.value.split(/[\s,]+/);
        if (tokens.includes(name)) references.add(name);
      }
    }
  });

  return { declarations, references, invalidated };
}

/**
 * Reconstruct a human-readable selector string from a postcss-selector-parser
 * selector node, omitting pseudo-classes and pseudo-elements.
 */
function stringifySelector(selectorNode) {
  return String(selectorNode).trim();
}

function selectorHasUnsupportedRuntimePseudo(selectorNode) {
  let unsupported = false;

  selectorNode.walkPseudos((pseudoNode) => {
    if (pseudoNode.value === ":has" && pseudoContainsClass(pseudoNode)) {
      unsupported = true;
    }
  });

  return unsupported;
}

function pseudoContainsClass(pseudoNode) {
  let containsClass = false;
  pseudoNode.walkClasses(() => {
    containsClass = true;
  });
  return containsClass;
}

/**
 * Extract segments from a postcss-selector-parser selector node.
 *
 * Returns an array of {classes:string[], notClasses:string[], tag:string|null, combinator:string|null} or null
 * if the selector contains no class selectors at all.
 */
function extractSegments(selectorNode) {
  const segments = [];
  let currentClasses = [];
  let currentNotClasses = [];
  let currentTag = null;
  let currentCombinator = null;
  let currentHasClasslessStructure = false;
  let hasAnyClass = false;

  function flushCurrentSegment() {
    if (currentClasses.length > 0 || currentNotClasses.length > 0 || currentTag) {
      segments.push({
        classes: currentClasses,
        notClasses: currentNotClasses,
        tag: currentTag,
        combinator: currentCombinator,
        wildcard: false,
      });
    } else if (currentHasClasslessStructure && currentCombinator !== null) {
      segments.push({
        classes: [],
        notClasses: [],
        tag: null,
        combinator: currentCombinator,
        wildcard: true,
      });
    }

    currentClasses = [];
    currentNotClasses = [];
    currentTag = null;
    currentHasClasslessStructure = false;
  }

  for (const node of selectorNode.nodes) {
    switch (node.type) {
      case "class":
        currentClasses.push(node.value);
        hasAnyClass = true;
        break;

      case "combinator": {
        // Flush current segment
        flushCurrentSegment();
        currentCombinator = node.value.trim() || " ";
        break;
      }

      case "tag":
        currentTag = node.value;
        currentHasClasslessStructure = true;
        break;

      case "id":
      case "attribute":
      case "universal":
        // We ignore these for matching, but they create segment boundaries
        // if followed by a combinator. We keep accumulating classes.
        currentHasClasslessStructure = true;
        break;

      case "pseudo":
        if (node.value === ":not") {
          const notClasses = classNamesInsidePseudo(node);
          if (notClasses.length > 0) {
            currentNotClasses.push(...notClasses);
            hasAnyClass = true;
          }
        } else {
          // Skip pseudo-classes and pseudo-elements entirely.
          // Don't descend into :where(), etc.
          currentHasClasslessStructure = true;
        }
        break;

      case "selector":
        // Nested selector inside :not(), :where(), etc. — skip
        break;

      default:
        break;
    }
  }

  // Flush last segment
  flushCurrentSegment();

  if (!hasAnyClass) return null;

  // Keep wildcard segments between classed segments because they preserve
  // structural combinators like `.x > :not(...) .y`.
  return segments.filter(
    (s) => s.wildcard || s.classes.length > 0 || s.notClasses.length > 0 || s.tag
  );
}

function classNamesInsidePseudo(pseudoNode) {
  const classes = [];
  pseudoNode.walkClasses((classNode) => classes.push(classNode.value));
  return classes;
}

// ---------------------------------------------------------------------------
// PHASE 2: Load Analysis Graph and Build Index
// ---------------------------------------------------------------------------

/**
 * Check whether a value is a dynamic entry.
 * Dynamic entries are objects with {dynamic: true, reason, expr, chain}.
 */
function isDynamic(value) {
  return typeof value === "object" && value !== null && value.dynamic === true;
}

function classFactsForNode(node) {
  return node.classes && typeof node.classes === "object" ? node.classes : null;
}

/**
 * Check whether a node has any dynamic class facts.
 */
function nodeHasDynamic(node) {
  const facts = classFactsForNode(node);
  if (facts) {
    if ((facts.dynamic || []).length > 0) return true;

    for (const group of facts.exclusive || []) {
      for (const option of group || []) {
        if ((option || []).some(isDynamic)) return true;
      }
    }

    return false;
  }

  return false;
}

/**
 * Extract dynamic entry metadata from a node's class facts.
 * Returns the first dynamic object found (with reason, expr, chain fields),
 * or a generic fallback.
 */
function extractDynamicInfo(node) {
  const facts = classFactsForNode(node);
  if (facts) {
    const direct = (facts.dynamic || []).find(isDynamic);
    if (direct) return { reason: direct.reason, expr: direct.expr, chain: direct.chain };

    for (const group of facts.exclusive || []) {
      for (const option of group || []) {
        const dynamic = (option || []).find(isDynamic);
        if (dynamic) return { reason: dynamic.reason, expr: dynamic.expr, chain: dynamic.chain };
      }
    }

    return { reason: "dynamic", expr: "<unknown>", chain: null };
  }

  return { reason: "dynamic", expr: "<unknown>", chain: null };
}

/**
 * Build a label for a node: "tag.class1.class2"
 * Uses known non-dynamic classes from class facts for the label.
 */
function nodeLabel(node) {
  if (isRawHtmlNode(node)) return "raw-html";

  const tag = node.tag || "?";
  const facts = classFactsForNode(node);
  if (facts) {
    const classes = [
      ...(facts.static || []),
      ...(facts.optional || []),
      ...(facts.exclusive || []).flatMap((group) =>
        (group || []).flatMap((option) => (option || []).filter((c) => !isDynamic(c)))
      ),
    ];
    const uniqueClasses = [...new Set(classes)];
    if (uniqueClasses.length === 0) return tag;
    return `${tag}.${uniqueClasses.join(".")}`;
  }

  return tag;
}

/**
 * Load graph version 2 heex-class-graph.json from a directory and build the
 * rendered context index. Legacy per-module analyzer JSON is not supported.
 *
 * Component refs are expanded as rendered children. They are not wrapper nodes,
 * so child and descendant selectors see the same shape Phoenix renders.
 */
function loadGraphAnalysis(analysisDir, opts = {}) {
  const graphPath = join(analysisDir, "heex-class-graph.json");

  if (!existsSync(graphPath)) {
    throw new Error(
      `Missing ${graphPath}. Run mix heex_class_analyzer to generate heex-class-graph.json.`
    );
  }

  const graph = JSON.parse(readFileSync(graphPath, "utf-8"));

  if (graph.version !== 2) {
    throw new Error("Expected HEEX class graph version 2");
  }

  const index = buildGraphIndex(graph, opts);

  index.cycles = deduplicateCycleDiagnostics([
    ...normalizeGraphCycles(graph.cycles || []),
    ...index.cycles,
  ]);
  index.unresolvedRefs = deduplicateDiagnostics([
    ...(graph.unresolved || []),
    ...index.unresolvedRefs,
  ]);
  index.stats.cycles = index.cycles.length;
  index.stats.unresolvedRefs = index.unresolvedRefs.length;

  return index;
}

/**
 * Build a rendered context index without cloning canonical graph nodes.
 */
function buildGraphIndex(graph, opts = {}) {
  const index = {
    graph,
    contexts: [],
    classToContexts: new Map(),
    allContextIds: [],
    ambientAncestorIds: [],
    rawHtmlContextIds: [],
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
      unresolvedRefs: 0,
    },
    maxContexts: opts.maxContexts || 250000,
  };

  for (const entry of graph.entries || []) {
    expandRefIntoContexts(index, entry.ref, {
      entry,
      definitionRef: entry.ref,
      parentId: null,
      previousSiblingId: null,
      callStack: [],
      callsite: null,
    });
  }

  index.stats.contexts = index.contexts.length;
  index.stats.classIndexKeys = index.classToContexts.size;
  index.stats.cycles = index.cycles.length;
  index.stats.unresolvedRefs = index.unresolvedRefs.length;

  return index;
}

function isComponentRefNode(node) {
  return node && Array.isArray(node.component_refs);
}

function isSlotPlaceholderNode(node) {
  return node && typeof node.slot_name === "string";
}

function isRawHtmlNode(node) {
  return node && node.raw_html === true;
}

function countCanonicalNodes(graph) {
  let count = 0;

  function visit(nodes) {
    for (const node of nodes || []) {
      if (isComponentRefNode(node)) continue;

      count++;
      visit(node.children || []);
    }
  }

  for (const tree of Object.values(graph.trees || {})) {
    visit(tree);
  }

  return count;
}

function expandRefIntoContexts(index, ref, context) {
  if (context.callStack.includes(ref)) {
    index.cycles.push(buildPathDiagnostic([...context.callStack, ref], context.callsite));
    return [];
  }

  const tree = index.graph.trees && index.graph.trees[ref];
  if (!Array.isArray(tree)) {
    index.unresolvedRefs.push(
      buildRefDiagnostic(ref, [...context.callStack, ref], context.callsite)
    );
    return [];
  }

  return expandNodeListIntoContexts(index, tree, {
    ...context,
    definitionRef: ref,
    callStack: [...context.callStack, ref],
  });
}

function expandNodeListIntoContexts(index, nodes, context) {
  const renderedIds = [];
  let previousSiblingId = context.previousSiblingId ?? null;

  for (const node of nodes || []) {
    let currentIds;

    if (isSlotPlaceholderNode(node)) {
      currentIds = expandNodeListIntoContexts(
        index,
        (context.slotChildrenByName && context.slotChildrenByName[node.slot_name]) || [],
        {
          ...context,
          previousSiblingId,
        }
      );

      if (currentIds.length > 0) {
        previousSiblingId = currentIds[currentIds.length - 1];
      }
    } else if (isComponentRefNode(node)) {
      currentIds = [];
      const rawSlotChildrenByName =
        node.slot_children_by_name || legacySlotChildrenByName(node.slot_children || []);
      const slotChildrenByName = bindSlotChildrenToCallerScope(
        rawSlotChildrenByName,
        context.slotChildrenByName || {}
      );
      const hasNamedSlots = Boolean(node.slot_children_by_name);

      for (const ref of node.component_refs || []) {
        const refIds = expandRefIntoContexts(index, ref, {
          ...context,
          previousSiblingId,
          slotChildrenByName,
          callsite: node.callsite || null,
        });

        currentIds.push(...refIds);

        if (!hasNamedSlots) for (const rootId of refIds) {
          expandSlotChildrenIntoContexts(index, node.slot_children || [], {
            ...context,
            parentId: rootId,
            callsite: node.callsite || null,
          });
        }

        if (refIds.length > 0) {
          previousSiblingId = refIds[refIds.length - 1];
        }
      }
    } else {
      const contextId = addContext(index, node, {
        ...context,
        previousSiblingId,
      });

      currentIds = [contextId];
      previousSiblingId = contextId;
    }

    renderedIds.push(...currentIds);
  }

  return renderedIds;
}

function legacySlotChildrenByName(slotChildren) {
  return slotChildren.length > 0 ? { inner_block: slotChildren } : {};
}

function bindSlotChildrenToCallerScope(slotChildrenByName, callerSlotChildrenByName) {
  const bound = {};

  for (const [slotName, children] of Object.entries(slotChildrenByName || {})) {
    bound[slotName] = bindSlotNodeListToCallerScope(children, callerSlotChildrenByName, new Set());
  }

  return bound;
}

function bindSlotNodeListToCallerScope(nodes, callerSlotChildrenByName, seenSlots) {
  const bound = [];

  for (const node of nodes || []) {
    if (isSlotPlaceholderNode(node)) {
      if (seenSlots.has(node.slot_name)) continue;

      const nextSeenSlots = new Set(seenSlots);
      nextSeenSlots.add(node.slot_name);

      bound.push(
        ...bindSlotNodeListToCallerScope(
          callerSlotChildrenByName[node.slot_name] || [],
          callerSlotChildrenByName,
          nextSeenSlots
        )
      );
    } else if (isComponentRefNode(node)) {
      bound.push(bindComponentSlotNodeToCallerScope(node, callerSlotChildrenByName, seenSlots));
    } else {
      bound.push({
        ...node,
        children: bindSlotNodeListToCallerScope(
          node.children || [],
          callerSlotChildrenByName,
          seenSlots
        ),
      });
    }
  }

  return bound;
}

function bindComponentSlotNodeToCallerScope(node, callerSlotChildrenByName, seenSlots) {
  const bound = { ...node };

  if (node.slot_children_by_name) {
    bound.slot_children_by_name = {};

    for (const [slotName, children] of Object.entries(node.slot_children_by_name)) {
      bound.slot_children_by_name[slotName] = bindSlotNodeListToCallerScope(
        children,
        callerSlotChildrenByName,
        seenSlots
      );
    }
  }

  if (node.slot_children) {
    bound.slot_children = bindSlotNodeListToCallerScope(
      node.slot_children,
      callerSlotChildrenByName,
      seenSlots
    );
  }

  return bound;
}

function expandChildrenIntoContexts(index, children, context) {
  return expandNodeListIntoContexts(index, children || [], {
    ...context,
    parentId: context.id,
    previousSiblingId: null,
  });
}

function expandSlotChildrenIntoContexts(index, children, context) {
  return expandNodeListIntoContexts(index, children || [], {
    ...context,
    previousSiblingId: null,
  });
}

function addContext(index, node, context) {
  if (index.contexts.length >= index.maxContexts) {
    throw new Error(
      `Context limit exceeded (${index.maxContexts}) while expanding ${context.definitionRef} from ${context.entry.ref}`
    );
  }

  const id = index.contexts.length;
  const renderedContext = {
    id,
    entryRef: context.entry.ref,
    entryModule: context.entry.module || "",
    entrySourceFile: context.entry.source_file || "",
    entryName: context.entry.name || context.entry.ref,
    definitionRef: context.definitionRef,
    node,
    parentId: context.parentId,
    previousSiblingId: context.previousSiblingId ?? null,
    callStack: [...(context.callStack || [])],
    slotChildrenByName: context.slotChildrenByName || {},
  };

  index.contexts.push(renderedContext);
  index.allContextIds.push(id);

  if (node.tag === "body") {
    index.ambientAncestorIds.push(id);
  }

  if (isRawHtmlNode(node)) {
    index.rawHtmlContextIds.push(id);
  }

  const allClasses = [...collectNodeClasses(node)].filter((cls) => !isDynamic(cls));
  index.stats.maxClassesPerNode = Math.max(index.stats.maxClassesPerNode, allClasses.length);
  index.stats.maxCallStackDepth = Math.max(
    index.stats.maxCallStackDepth,
    renderedContext.callStack.length
  );

  for (const cls of allClasses) {
    if (!index.classToContexts.has(cls)) index.classToContexts.set(cls, []);
    index.classToContexts.get(cls).push(renderedContext);
  }

  expandChildrenIntoContexts(index, node.children || [], {
    ...renderedContext,
    entry: context.entry,
  });

  return id;
}

function normalizeGraphCycles(cycles) {
  return cycles
    .map((cycle) => {
      if (Array.isArray(cycle)) return buildPathDiagnostic(cycle);
      if (cycle && Array.isArray(cycle.path)) return cycle;
      return null;
    })
    .filter(Boolean);
}

function buildPathDiagnostic(path, callsite = null) {
  const diagnostic = { path };
  if (callsite) diagnostic.callsite = callsite;
  return diagnostic;
}

function buildRefDiagnostic(ref, path, callsite = null) {
  const diagnostic = { ref, path };
  if (callsite) diagnostic.callsite = callsite;
  return diagnostic;
}

function deduplicateDiagnostics(diagnostics) {
  const seen = new Set();
  const deduped = [];

  for (const diagnostic of diagnostics) {
    const key = JSON.stringify(diagnostic);
    if (seen.has(key)) continue;
    seen.add(key);
    deduped.push(diagnostic);
  }

  return deduped;
}

function deduplicateCycleDiagnostics(diagnostics) {
  const byPath = new Map();
  const deduped = [];

  for (const diagnostic of diagnostics) {
    const key = JSON.stringify(diagnostic.path || []);
    const existing = byPath.get(key);

    if (existing) {
      mergeDiagnosticMetadata(existing, diagnostic);
      continue;
    }

    byPath.set(key, diagnostic);
    deduped.push(diagnostic);
  }

  return deduped;
}

function mergeDiagnosticMetadata(target, source) {
  for (const [key, value] of Object.entries(source)) {
    if (target[key] === undefined) target[key] = value;
  }
}

/**
 * Collect all unique class names from a node's class facts.
 */
function collectNodeClasses(node) {
  const classes = new Set();
  if (isRawHtmlNode(node)) return classes;

  const facts = classFactsForNode(node);

  if (facts) {
    for (const c of facts.static || []) {
      if (typeof c === "string") classes.add(c);
    }
    for (const c of facts.optional || []) {
      if (typeof c === "string") classes.add(c);
    }

    for (const group of facts.exclusive || []) {
      for (const option of group || []) {
        for (const c of option || []) {
          if (typeof c === "string") classes.add(c);
        }
      }
    }

    return classes;
  }

  return classes;
}

function nodeHasAlwaysClass(node, className) {
  const facts = classFactsForNode(node);

  if (facts) {
    return (facts.static || []).includes(className);
  }

  return false;
}

// ---------------------------------------------------------------------------
// PHASE 3: Match Selectors
// ---------------------------------------------------------------------------

/**
 * Check if a node's class facts can satisfy a segment's required classes.
 *
 * Returns:
 *   "static"  — matched by known class facts
 *   "dynamic" — not matched statically, but node has dynamic entries
 *   false     — not matched at all
 */
function nodeMatchesSegment(node, requiredClasses) {
  if (requiredClasses.length === 0) return "static";
  const facts = classFactsForNode(node);

  if (facts) {
    const concreteClasses = collectNodeClasses(node);
    const allKnown = requiredClasses.every((cls) => concreteClasses.has(cls));

    if (allKnown) {
      return violatesExclusiveGroup(requiredClasses, facts.exclusive || []) ? false : "static";
    }

    const concreteRequiredClasses = requiredClasses.filter((cls) => concreteClasses.has(cls));
    const hasPartialStatic = concreteRequiredClasses.length > 0;

    if (!hasPartialStatic) {
      return false;
    }

    if (violatesExclusiveGroup(concreteRequiredClasses, facts.exclusive || [])) {
      return false;
    }

    if ((facts.dynamic || []).some(isDynamic)) {
      return "dynamic";
    }

    if (exclusiveDynamicCanCoverMissing(concreteRequiredClasses, facts.exclusive || [])) {
      return "dynamic";
    }

    return false;
  }

  return false;
}

function violatesExclusiveGroup(requiredClasses, exclusiveGroups) {
  const required = new Set(requiredClasses);

  for (const group of exclusiveGroups) {
    const requiredInGroup = new Set();

    for (const option of group || []) {
      for (const cls of optionConcreteClasses(option)) {
        if (required.has(cls)) requiredInGroup.add(cls);
      }
    }

    if (requiredInGroup.size === 0) continue;

    const satisfiableByOneOption = (group || []).some((option) => {
      const optionClasses = new Set(optionConcreteClasses(option));
      return [...requiredInGroup].every((cls) => optionClasses.has(cls));
    });

    if (!satisfiableByOneOption) return true;
  }

  return false;
}

function exclusiveDynamicCanCoverMissing(concreteRequiredClasses, exclusiveGroups) {
  const required = new Set(concreteRequiredClasses);

  for (const group of exclusiveGroups) {
    for (const option of group || []) {
      if (!optionHasDynamic(option)) continue;
      if (dynamicOptionConflictsWithRequired(option, group || [], required)) continue;

      return true;
    }
  }

  return false;
}

function optionHasDynamic(option) {
  return (option || []).some(isDynamic);
}

function dynamicOptionConflictsWithRequired(dynamicOption, group, required) {
  const dynamicOptionClasses = new Set(optionConcreteClasses(dynamicOption));

  for (const option of group) {
    if (option === dynamicOption) continue;

    for (const cls of optionConcreteClasses(option)) {
      if (required.has(cls) && !dynamicOptionClasses.has(cls)) {
        return true;
      }
    }
  }

  return false;
}

function optionConcreteClasses(option) {
  return (option || []).filter((cls) => typeof cls === "string");
}

function nodeMatchesParsedSegment(node, segment) {
  if (isRawHtmlNode(node)) return "static";
  if (segment.wildcard) return "static";
  if (segment.tag && node.tag !== segment.tag) return false;
  if ((segment.notClasses || []).some((cls) => nodeHasAlwaysClass(node, cls))) {
    return false;
  }

  return nodeMatchesSegment(node, segment.classes);
}

/**
 * Given a candidate node and its ancestor chain, walk left through the
 * selector segments (from right-to-left) to check if the full selector
 * matches.
 *
 * Returns: { matched: boolean, dynamic: boolean, dynamicNode: object|null, unmatchedClasses: string[] }
 */
function matchSelectorLeftward(segments, candidateContext, graphIndex) {
  return matchSegmentAt(
    segments,
    segments.length - 1,
    candidateContext,
    graphIndex,
    false,
    null
  );
}

function matchSegmentAt(segments, segIdx, context, graphIndex, involvesDynamic, dynamicNode) {
  if (segIdx === 0) {
    return { matched: true, dynamic: involvesDynamic, dynamicNode, unmatchedClasses: [] };
  }

  const leftSeg = segments[segIdx - 1];
  const comb = segments[segIdx].combinator;

  const candidates = relatedCandidates(comb, context, graphIndex);
  let dynamicFailure = null;

  for (const candidate of candidates) {
    const matchResult = nodeMatchesParsedSegment(candidate.node, leftSeg);

    if (matchResult === "static" || matchResult === "dynamic") {
      const nextDynamic = involvesDynamic || matchResult === "dynamic";
      const nextDynamicNode =
        matchResult === "dynamic" ? dynamicNode || candidate.node : dynamicNode;

      const result = matchSegmentAt(
        segments,
        segIdx - 1,
        candidate,
        graphIndex,
        nextDynamic,
        nextDynamicNode
      );

      if (result.matched) return result;
      if (result.dynamic) dynamicFailure = result;
    }
  }

  if (dynamicFailure) return dynamicFailure;

  return {
    matched: false,
    dynamic: involvesDynamic,
    dynamicNode,
    unmatchedClasses: leftSeg.classes,
  };
}

function relatedCandidates(comb, context, index) {
  if (comb === ">") {
    return context.parentId == null ? [] : [index.contexts[context.parentId]];
  }

  if (comb === "+" || comb === "~") {
    return previousSiblingCandidates(comb, context, index);
  }

  return [...ancestorContexts(context, index), ...ambientAncestorContexts(index)];
}

function previousSiblingCandidates(comb, context, index) {
  const candidates = [];
  let siblingId = context.previousSiblingId;

  while (siblingId != null) {
    const sibling = index.contexts[siblingId];
    if (!sibling) break;

    candidates.push(sibling);
    if (comb === "+") break;

    siblingId = sibling.previousSiblingId;
  }

  return context.node.repeat ? [...candidates, context] : candidates;
}

function ancestorContexts(context, index) {
  const ancestors = [];
  let parentId = context.parentId;

  while (parentId != null) {
    const parent = index.contexts[parentId];
    if (!parent) break;
    ancestors.push(parent);
    parentId = parent.parentId;
  }

  return ancestors;
}

function ambientAncestorContexts(index) {
  return (index.ambientAncestorIds || [])
    .map((id) => index.contexts[id])
    .filter(Boolean);
}

/**
 * Build the provenance path for a match: array of "tag.class1.class2" strings
 * from root to the matched node.
 */
function buildPath(context, index) {
  return [...ancestorContexts(context, index).reverse(), context].map((ctx) =>
    nodeLabel(ctx.node)
  );
}

/**
 * Build the human-readable chain string:
 * "functionName -> tag.classes -> tag.classes -> ... -> tag.matched"
 */
function buildChain(context, index) {
  return [context.entryName, ...buildPath(context, index)].join(" \u2192 ");
}

/**
 * Match all parsed selectors against the rendered context index.
 *
 * Returns { matched, runtime_matched, possibly_dynamic, unmatched, skipped }
 */
function matchSelectors(parsedSelectors, graphIndex, runtimeEvidence = new Map()) {
  const matched = [];
  const runtimeMatched = [];
  const possiblyDynamic = [];
  const unmatched = [];
  const skipped = [];
  graphIndex.stats.selectorCount = parsedSelectors.length;

  // Deduplicate selectors — same selector text can appear in multiple rules,
  // but we group them by selectorText + line
  const seen = new Set();

  for (const sel of parsedSelectors) {
    if (sel.segments === null) {
      skipped.push({
        selector: sel.selectorText,
        file: sel.file,
        line: sel.line,
        reason: sel.skipReason || "no class selectors",
      });
      continue;
    }

    if (sel.segments.length === 0) {
      skipped.push({
        selector: sel.selectorText,
        file: sel.file,
        line: sel.line,
        reason: "no class selectors after parsing",
      });
      continue;
    }

    const dedupeKey = `${sel.selectorText}:${sel.file}:${sel.line}`;
    if (seen.has(dedupeKey)) continue;
    seen.add(dedupeKey);

    const result = matchOneSelector(sel, graphIndex);

    if (result.matches.length > 0) {
      if (result.allDynamic) {
        possiblyDynamic.push({
          selector: sel.selectorText,
          file: sel.file,
          line: sel.line,
          matches: result.matches,
        });
      } else {
        matched.push({
          selector: sel.selectorText,
          file: sel.file,
          line: sel.line,
          matches: result.matches,
        });
      }
    } else if (result.dynamicCandidates.length > 0) {
      possiblyDynamic.push({
        selector: sel.selectorText,
        file: sel.file,
        line: sel.line,
        matches: result.dynamicCandidates,
      });
    } else {
      const runtimeMatch = buildRuntimeSelectorMatch(sel, graphIndex, runtimeEvidence);

      if (
        runtimeMatch &&
        runtimeCanExplainSelector(sel, graphIndex, runtimeEvidence, runtimeMatch.classes, result)
      ) {
        runtimeMatched.push(runtimeMatch.entry);
        continue;
      }

      unmatched.push({
        selector: sel.selectorText,
        file: sel.file,
        line: sel.line,
        diagnostics: buildDiagnostics(sel, graphIndex),
      });
    }
  }

  return {
    matched,
    runtime_matched: runtimeMatched,
    possibly_dynamic: possiblyDynamic,
    unmatched,
    skipped,
  };
}

function buildRuntimeSelectorMatch(sel, graphIndex, runtimeEvidence) {
  if (!runtimeEvidence || runtimeEvidence.size === 0) return null;

  const classes = requiredClassNamesForRuntimeEvidence(sel.selectorText);
  const runtimeClasses = classes.filter((cls) => runtimeEvidence.has(cls));

  if (classes.length === 0 || runtimeClasses.length === 0) return null;

  return {
    classes,
    entry: {
      selector: sel.selectorText,
      file: sel.file,
      line: sel.line,
      runtime_classes: runtimeClasses,
      classes_found: classes.filter((cls) => graphIndex.classToContexts.has(cls)),
    },
  };
}

function requiredClassNamesForRuntimeEvidence(selectorText) {
  try {
    const parsed = selectorParser().astSync(selectorText);
    const classes = new Set();
    parsed.walkClasses((classNode) => classes.add(classNode.value));
    return [...classes].sort();
  } catch {
    return [];
  }
}

function runtimeCanExplainSelector(sel, graphIndex, runtimeEvidence, classes, matchResult) {
  const parsedClasses = new Set(sel.segments.flatMap((segment) => segment.classes));
  const hasRuntimeOnlyParsedClass = classes.some(
    (cls) => runtimeEvidence.has(cls) && !graphIndex.classToContexts.has(cls)
  );
  const hasRuntimePseudoClass = classes.some(
    (cls) => runtimeEvidence.has(cls) && !parsedClasses.has(cls)
  );

  if (matchResult.matches.length > 0 && !hasRuntimeOnlyParsedClass && !hasRuntimePseudoClass) {
    return false;
  }

  if (sel.segments.length > 1 && matchResult.matches.length === 0) {
    const usesSiblingCombinator = sel.segments.some(
      (segment) => segment.combinator === "+" || segment.combinator === "~"
    );
    if (usesSiblingCombinator) return false;

    const hasHeexClass = classes.some((cls) => graphIndex.classToContexts.has(cls));
    if (!hasHeexClass) return false;
  }

  return classes.every((cls) => graphIndex.classToContexts.has(cls) || runtimeEvidence.has(cls));
}

function buildAnalysisStats(index, parsedSelectors, results = null) {
  return {
    entries: index.stats.entries,
    tree_refs: index.stats.treeRefs,
    canonical_nodes: index.stats.canonicalNodes,
    contexts: index.stats.contexts,
    class_index_keys: index.stats.classIndexKeys,
    selector_count: parsedSelectors.length,
    max_classes_per_node: index.stats.maxClassesPerNode,
    max_call_stack_depth: index.stats.maxCallStackDepth,
    cycles: index.cycles.length,
    unresolved_refs: index.unresolvedRefs.length,
    runtime_matched_selector_count: results ? results.runtime_matched.length : 0,
  };
}

function printAnalysisStats(stats) {
  console.log("Analysis stats:");
  console.log(`  entries: ${stats.entries}`);
  console.log(`  tree refs: ${stats.tree_refs}`);
  console.log(`  canonical nodes: ${stats.canonical_nodes}`);
  console.log(`  contexts: ${stats.contexts}`);
  console.log(`  class index keys: ${stats.class_index_keys}`);
  console.log(`  selectors: ${stats.selector_count}`);
  console.log(`  max classes per node: ${stats.max_classes_per_node}`);
  console.log(`  max call stack depth: ${stats.max_call_stack_depth}`);
  console.log(`  cycles: ${stats.cycles}`);
  console.log(`  unresolved refs: ${stats.unresolved_refs}`);
  console.log(`  runtime matched selectors: ${stats.runtime_matched_selector_count}`);
}

/**
 * Build diagnostics for an unmatched selector: which classes exist
 * somewhere in the analysis and which don't, plus structural notes.
 */
function buildDiagnostics(sel, graphIndex) {
  const allSelectorClasses = sel.segments.flatMap((s) => s.classes);
  const unique = [...new Set(allSelectorClasses)];

  const classesFound = unique.filter((c) => graphIndex.classToContexts.has(c));
  const classesNotFound = unique.filter((c) => !graphIndex.classToContexts.has(c));

  const diagnostics = { classes_found: classesFound, classes_not_found: classesNotFound };

  if (classesNotFound.length > 0) {
    diagnostics.note = classesNotFound.length === unique.length
      ? "no classes from this selector exist in any template"
      : `${classesNotFound.join(", ")} not found in any template`;
  } else if (sel.segments.length > 1) {
    diagnostics.note = "all classes exist individually but not in the required structural relationship";
  } else if (sel.segments[0].classes.length > 1) {
    diagnostics.note = "all classes exist but not combined on a single element";
  }

  return diagnostics;
}

/**
 * Match a single selector against the index.
 *
 * Returns { matches, dynamicCandidates, allDynamic }
 */
function matchOneSelector(sel, graphIndex) {
  const segments = sel.segments;
  const matches = [];
  const dynamicCandidates = [];

  // Step 1: Find candidate nodes for the rightmost segment
  const rightmost = segments[segments.length - 1];
  const candidateEntries = findCandidatesForParsedSegment(rightmost, graphIndex);

  // Step 2: For each candidate, walk left through remaining segments
  let hasStaticMatch = false;

  for (const entry of candidateEntries) {
    const rightMatchResult = nodeMatchesParsedSegment(entry.node, rightmost);
    if (!rightMatchResult) continue;

    const rightIsDynamic = rightMatchResult === "dynamic";

    if (segments.length === 1) {
      // Only one segment — just check the rightmost
      const path = buildPath(entry, graphIndex);
      const chain = buildChain(entry, graphIndex);

      if (rightIsDynamic) {
        const missingClasses = rightmost.classes.filter((c) => {
          const nodeClasses = [...collectNodeClasses(entry.node)].filter(
            (nc) => !isDynamic(nc)
          );
          return !nodeClasses.includes(c);
        });
        const dynInfo = extractDynamicInfo(entry.node);
        dynamicCandidates.push({
          module: entry.entryModule,
          function: entry.entryName,
          entryRef: entry.entryRef,
          definitionRef: entry.definitionRef,
          callStack: entry.callStack,
          path,
          chain,
          dynamic: {
            ...dynInfo,
            unresolved_part: missingClasses.join(", "),
          },
        });
      } else {
        hasStaticMatch = true;
        matches.push({
          module: entry.entryModule,
          function: entry.entryName,
          entryRef: entry.entryRef,
          definitionRef: entry.definitionRef,
          callStack: entry.callStack,
          path,
          chain,
          dynamic: null,
        });
      }
      continue;
    }

    // Multiple segments — walk leftward
    const leftResult = matchSelectorLeftward(segments, entry, graphIndex);

    const path = buildPath(entry, graphIndex);
    const chain = buildChain(entry, graphIndex);

    if (leftResult.matched && !leftResult.dynamic && !rightIsDynamic) {
      hasStaticMatch = true;
      matches.push({
        module: entry.entryModule,
        function: entry.entryName,
        entryRef: entry.entryRef,
        definitionRef: entry.definitionRef,
        callStack: entry.callStack,
        path,
        chain,
        dynamic: null,
      });
    } else if (leftResult.matched && (leftResult.dynamic || rightIsDynamic)) {
      const dynNode = rightIsDynamic ? entry.node : leftResult.dynamicNode || entry.node;
      const dynInfo = extractDynamicInfo(dynNode);
      dynamicCandidates.push({
        module: entry.entryModule,
        function: entry.entryName,
        entryRef: entry.entryRef,
        definitionRef: entry.definitionRef,
        callStack: entry.callStack,
        path,
        chain,
        dynamic: {
          ...dynInfo,
          unresolved_part: leftResult.unmatchedClasses.join(", ") || "element classes",
        },
      });
    } else if (!leftResult.matched && leftResult.dynamic) {
      const dynNode = leftResult.dynamicNode || entry.node;
      const dynInfo = extractDynamicInfo(dynNode);
      dynamicCandidates.push({
        module: entry.entryModule,
        function: entry.entryName,
        entryRef: entry.entryRef,
        definitionRef: entry.definitionRef,
        callStack: entry.callStack,
        path,
        chain,
        dynamic: {
          ...dynInfo,
          unresolved_part: leftResult.unmatchedClasses.join(", "),
        },
      });
    }
    // If !leftResult.matched && !leftResult.dynamic, this candidate doesn't contribute
  }

  // Deduplicate matches by module+function
  const deduped = deduplicateMatches(matches);
  const dedupedDynamic = deduplicateMatches(dynamicCandidates);

  return {
    matches: deduped,
    dynamicCandidates: dedupedDynamic,
    allDynamic: deduped.length > 0 && deduped.every((m) => m.dynamic !== null),
  };
}

/**
 * Find all candidate index entries that could match a set of required classes.
 */
function findCandidatesForParsedSegment(segment, graphIndex) {
  const candidates = findCandidatesForSegment(segment.classes, graphIndex);

  if (!segment.tag) return candidates;

  return candidates.filter((entry) => entry.node.tag === segment.tag || isRawHtmlNode(entry.node));
}

function findCandidatesForSegment(requiredClasses, graphIndex) {
  // Use the first required class to narrow down candidates
  const candidates = new Set();

  if (requiredClasses.length === 0) {
    return graphIndex.allContextIds.map((id) => graphIndex.contexts[id]);
  }

  // Gather candidates from all required classes (union) so that nodes with
  // partial static + dynamic coverage are included
  for (const cls of requiredClasses) {
    const entries = graphIndex.classToContexts.get(cls);
    if (entries) {
      for (const e of entries) candidates.add(e);
    }
  }

  for (const id of graphIndex.rawHtmlContextIds || []) {
    const entry = graphIndex.contexts[id];
    if (entry) candidates.add(entry);
  }

  return [...candidates];
}

/**
 * Deduplicate matches: keep only the first match per module+function combination.
 */
function deduplicateMatches(matches) {
  const seen = new Set();
  const result = [];
  for (const m of matches) {
    const key = `${m.module}::${m.function}::${m.chain}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(m);
  }
  return result;
}

// ---------------------------------------------------------------------------
// Invalidation: prepend UNMATCHED_MARKER to unmatched selectors in the CSS source
// ---------------------------------------------------------------------------

/**
 * Modify the source CSS file, prepending UNMATCHED_MARKER to each unmatched
 * selector. For comma-separated rules, only the unmatched parts are prefixed.
 *
 * Works on the original source file (not the postcss-import resolved version)
 * by parsing with PostCSS, walking rules, and matching selectors against the
 * unmatched set.
 */
function invalidateUnmatchedSelectors(cssPath, unmatchedEntries, projectRoot) {
  const relCssPath = relative(projectRoot, cssPath);

  // Build a set of "selectorText:line" keys for fast lookup
  const unmatchedKeys = new Set();
  for (const entry of unmatchedEntries) {
    if (entry.file === relCssPath) {
      unmatchedKeys.add(`${entry.selector}:${entry.line}`);
    }
  }

  if (unmatchedKeys.size === 0) return 0;

  const cssContent = readFileSync(cssPath, "utf-8");
  const root = postcss.parse(cssContent, { from: cssPath });
  let count = 0;

  root.walkRules((rule) => {
    const line = rule.source && rule.source.start ? rule.source.start.line : null;

    try {
      const parsed = selectorParser().astSync(rule.selector);
      let modified = false;

      for (const sel of parsed.nodes) {
        const text = String(sel).trim();

        // Skip already-invalidated selectors
        if (text.includes(UNMATCHED_MARKER)) continue;

        const key = `${text}:${line}`;
        if (unmatchedKeys.has(key)) {
          // Prepend the marker as a descendant: UNMATCHED_MARKER .original-selector
          const markerNode = selectorParser.className({ value: UNMATCHED_PREFIX });
          const combNode = selectorParser.combinator({ value: " " });
          sel.prepend(combNode);
          sel.prepend(markerNode);
          modified = true;
          count++;
        }
      }

      if (modified) {
        rule.selector = parsed.toString();
      }
    } catch {
      // Can't parse this selector — leave it alone
    }
  });

  if (count > 0) {
    writeFileSync(cssPath, root.toString());
  }

  return count;
}

/**
 * Remove all UNMATCHED_MARKER markers from selectors in the CSS source.
 */
function restoreUnmatchedSelectors(cssPath) {
  const cssContent = readFileSync(cssPath, "utf-8");
  const replaced = cssContent.replaceAll(UNMATCHED_MARKER, "");
  const count = (cssContent.length - replaced.length) / UNMATCHED_MARKER.length;
  if (count > 0) writeFileSync(cssPath, replaced);
  return count;
}

/**
 * Rename @keyframes <name> to @keyframes UNMATCHED_PREFIX<name> for each unused keyframe.
 */
function invalidateUnmatchedKeyframes(cssPath, unusedKeyframes, projectRoot) {
  const names = new Set(unusedKeyframes.map((e) => e.name));
  if (names.size === 0) return 0;

  const cssContent = readFileSync(cssPath, "utf-8");
  const root = postcss.parse(cssContent, { from: cssPath });
  let count = 0;

  root.walkAtRules("keyframes", (atRule) => {
    if (names.has(atRule.params)) {
      atRule.params = `${UNMATCHED_PREFIX}${atRule.params}`;
      count++;
    }
  });

  if (count > 0) writeFileSync(cssPath, root.toString());
  return count;
}

/**
 * Restore invalidated @keyframes by removing the UNMATCHED_PREFIX prefix.
 */
function restoreUnmatchedKeyframes(cssPath) {
  const cssContent = readFileSync(cssPath, "utf-8");
  const replaced = cssContent.replaceAll(UNMATCHED_PREFIX, "");
  const count = (cssContent.length - replaced.length) / UNMATCHED_PREFIX.length;
  if (count > 0) writeFileSync(cssPath, replaced);
  return count;
}

/**
 * Remove unused @keyframes at-rules from the CSS source.
 */
function removeUnmatchedKeyframes(cssPath, unusedKeyframes, projectRoot) {
  const names = new Set(unusedKeyframes.map((e) => e.name));
  const cssContent = readFileSync(cssPath, "utf-8");
  const root = postcss.parse(cssContent, { from: cssPath });
  let count = 0;

  root.walkAtRules("keyframes", (atRule) => {
    if (names.has(atRule.params) || atRule.params.startsWith(UNMATCHED_PREFIX)) {
      atRule.remove();
      count++;
    }
  });

  if (count > 0) writeFileSync(cssPath, root.toString());
  return count;
}

/**
 * Collect selectors already invalidated (prefixed with UNMATCHED_MARKER) from the CSS source.
 * Returns array of {selector, file, line} with the original selector text (marker stripped).
 */
function collectInvalidatedSelectors(cssPath, projectRoot) {
  const relCssPath = relative(projectRoot, cssPath);
  const cssContent = readFileSync(cssPath, "utf-8");
  const root = postcss.parse(cssContent, { from: cssPath });
  const results = [];

  root.walkRules((rule) => {
    const line = rule.source && rule.source.start ? rule.source.start.line : null;
    try {
      const parsed = selectorParser().astSync(rule.selector);
      for (const sel of parsed.nodes) {
        const text = String(sel).trim();
        if (text.includes(UNMATCHED_MARKER)) {
          const original = text.replaceAll(UNMATCHED_MARKER, "").trim();
          results.push({ selector: original, file: relCssPath, line });
        }
      }
    } catch {
      // skip
    }
  });

  return results;
}

// ---------------------------------------------------------------------------
// Removal: delete unmatched and already-invalidated selectors from CSS source
// ---------------------------------------------------------------------------

/**
 * Remove unmatched selectors from the CSS source file. This handles:
 * 1. Selectors already invalidated (prefixed with UNMATCHED_MARKER) from prior runs
 * 2. Newly unmatched selectors identified by the current analysis
 *
 * For comma-separated rules, only the targeted parts are removed; the rest stay.
 * If all selectors in a rule are removed, the entire rule (including its block) is deleted.
 * Empty at-rules left behind (e.g. @media with no rules) are also cleaned up.
 */
function removeUnmatchedSelectors(cssPath, unmatchedEntries, projectRoot) {
  const relCssPath = relative(projectRoot, cssPath);

  const unmatchedKeys = new Set();
  for (const entry of unmatchedEntries) {
    if (entry.file === relCssPath) {
      unmatchedKeys.add(`${entry.selector}:${entry.line}`);
    }
  }

  const cssContent = readFileSync(cssPath, "utf-8");
  const root = postcss.parse(cssContent, { from: cssPath });
  let removedCount = 0;

  root.walkRules((rule) => {
    const line = rule.source && rule.source.start ? rule.source.start.line : null;

    try {
      const parsed = selectorParser().astSync(rule.selector);
      const keepSelectors = [];
      let removedFromRule = 0;

      for (const sel of parsed.nodes) {
        const text = String(sel).trim();

        if (text.includes(UNMATCHED_MARKER)) {
          removedFromRule++;
          continue;
        }

        const key = `${text}:${line}`;
        if (unmatchedKeys.has(key)) {
          removedFromRule++;
          continue;
        }

        keepSelectors.push(text);
      }

      if (removedFromRule > 0) {
        removedCount += removedFromRule;
        if (keepSelectors.length === 0) {
          rule.remove();
        } else {
          rule.selector = keepSelectors.join(",\n");
        }
      }
    } catch {
      // Can't parse — leave alone
    }
  });

  // Clean up empty at-rules (e.g. @media blocks with no rules left)
  let cleaned = true;
  while (cleaned) {
    cleaned = false;
    root.walkAtRules((atRule) => {
      if (atRule.nodes && atRule.nodes.length === 0) {
        atRule.remove();
        cleaned = true;
      }
    });
  }

  if (removedCount > 0) {
    writeFileSync(cssPath, root.toString());
  }

  return removedCount;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  const opts = parseArgs();
  const projectRoot = findProjectRoot();

  const cssPath = resolve(projectRoot, opts.css);
  const analysisDir = resolve(projectRoot, opts.analysis);
  const outputPath = resolve(projectRoot, opts.output);
  const defaultJsPath = resolve(projectRoot, "assets/js");
  const jsRoots =
    opts.jsPaths.length > 0
      ? opts.jsPaths.map((path) => resolve(projectRoot, path))
      : existsSync(defaultJsPath)
        ? [defaultJsPath]
        : [];

  // Validate inputs
  if (!existsSync(cssPath)) {
    console.error(`ERROR: CSS file not found: ${cssPath}`);
    process.exit(1);
  }

  // --restore-unmatched: remove markers and exit
  if (opts.restoreUnmatched) {
    const restored = restoreUnmatchedSelectors(cssPath);
    console.log(`Restored ${restored} selectors in ${relative(projectRoot, cssPath)}`);
    const restoredKf = restoreUnmatchedKeyframes(cssPath);
    console.log(`Restored ${restoredKf} keyframes in ${relative(projectRoot, cssPath)}`);
    return;
  }

  if (!existsSync(analysisDir)) {
    console.error(`ERROR: Analysis directory not found: ${analysisDir}`);
    process.exit(1);
  }

  // Phase 1: Parse CSS
  const nodeModulesCssEvidence = new Map();

  const parsedSelectors = await parseCss(cssPath, projectRoot, {
    includeNodeModulesCss: opts.includeNodeModulesCss,
    nodeModulesCssEvidence,
  });

  // Phase 2: Load analysis graph
  const graphIndex = loadGraphAnalysis(analysisDir, { maxContexts: opts.maxContexts });
  const runtimeEvidence = mergeRuntimeEvidence(
    buildPhoenixRuntimeClassEvidence(),
    buildRuntimeClassEvidence(discoverJavaScriptFiles(jsRoots), projectRoot),
    nodeModulesCssEvidence
  );

  // Phase 3: Match selectors
  const results = matchSelectors(parsedSelectors, graphIndex, runtimeEvidence);

  // Phase 3b: Analyze keyframes
  const keyframeAnalysis = analyzeKeyframes(cssPath, projectRoot);
  const unusedKeyframes = [];
  for (const [name, info] of keyframeAnalysis.declarations) {
    if (!keyframeAnalysis.references.has(name)) {
      unusedKeyframes.push({ name, file: info.file, line: info.line });
    }
  }

  // Build output
  const analysisStats = buildAnalysisStats(graphIndex, parsedSelectors, results);

  const output = {
    matched: results.matched,
    matched_selectors: results.matched.map((entry) => entry.selector),
    runtime_matched: results.runtime_matched,
    runtime_matched_selectors: results.runtime_matched.map((entry) => entry.selector),
    runtime_evidence: serializeRuntimeEvidence(runtimeEvidence),
    possibly_dynamic: results.possibly_dynamic,
    unmatched: results.unmatched,
    unmatched_selectors: results.unmatched.map((entry) => entry.selector),
    skipped: results.skipped,
    unused_keyframes: unusedKeyframes,
    cycles: graphIndex.cycles || [],
    unresolved_refs: graphIndex.unresolvedRefs || [],
    analysis_stats: analysisStats,
    summary: {
      matched: results.matched.length,
      runtime_matched: results.runtime_matched.length,
      unmatched: results.unmatched.length,
      possibly_dynamic: results.possibly_dynamic.length,
      skipped: results.skipped.length,
      keyframes_total: keyframeAnalysis.declarations.size,
      keyframes_unused: unusedKeyframes.length,
      cycles: graphIndex.cycles.length,
      unresolved_refs: graphIndex.unresolvedRefs.length,
    },
  };

  writeFileSync(outputPath, JSON.stringify(output, null, 2) + "\n");

  const s = output.summary;
  console.log(
    `CSS Coverage: ${s.matched} matched, ${s.runtime_matched} runtime-matched, ${s.unmatched} unmatched, ${s.possibly_dynamic} possibly dynamic, ${s.skipped} skipped`
  );
  if (keyframeAnalysis.declarations.size > 0) {
    console.log(
      `Keyframes: ${keyframeAnalysis.declarations.size} found, ${unusedKeyframes.length} unused`
    );
  }
  if (output.cycles.length > 0 || output.unresolved_refs.length > 0) {
    console.log(
      `Graph diagnostics: ${output.cycles.length} cycles, ${output.unresolved_refs.length} unresolved refs`
    );
  }
  if (opts.stats) {
    printAnalysisStats(output.analysis_stats);
  }

  // List all unmatched selectors (newly unmatched + already invalidated)
  if (opts.listUnmatched) {
    const invalidated = collectInvalidatedSelectors(cssPath, projectRoot);
    const all = [
      ...results.unmatched.map((e) => ({ selector: e.selector, file: e.file, line: e.line, status: "unmatched" })),
      ...invalidated.map((e) => ({ ...e, status: "invalidated" })),
    ];
    all.sort((a, b) => (a.file || "").localeCompare(b.file || "") || (a.line || 0) - (b.line || 0));
    console.log(`\n--- Unmatched selectors (${all.length}) ---`);
    for (const e of all) {
      const loc = e.line ? `${e.file}:${e.line}` : e.file;
      const tag = e.status === "invalidated" ? " [invalidated]" : "";
      console.log(`  ${loc}  ${e.selector}${tag}`);
    }
    console.log();

    const allUnusedKeyframes = [
      ...unusedKeyframes.map((e) => ({ ...e, status: "unmatched" })),
      ...keyframeAnalysis.invalidated.map((e) => ({ ...e, status: "invalidated" })),
    ];
    if (allUnusedKeyframes.length > 0) {
      console.log(`--- Unused keyframes (${allUnusedKeyframes.length}) ---`);
      for (const e of allUnusedKeyframes) {
        const loc = e.line ? `${e.file}:${e.line}` : e.file;
        const tag = e.status === "invalidated" ? " [invalidated]" : "";
        console.log(`  ${loc}  @keyframes ${e.name}${tag}`);
      }
      console.log();
    }

  }

  if (opts.listRuntime) {
    console.log(`\n--- Runtime-matched selectors (${results.runtime_matched.length}) ---`);
    for (const e of results.runtime_matched) {
      const loc = e.line ? `${e.file}:${e.line}` : e.file;
      console.log(`  ${loc}  ${e.selector}`);
    }
    console.log();
  }

  // Phase 4 (optional): Invalidate unmatched selectors in source CSS
  if (opts.invalidateUnmatched && results.unmatched.length > 0) {
    const invalidated = invalidateUnmatchedSelectors(cssPath, results.unmatched, projectRoot);
    console.log(`Invalidated ${invalidated} selectors in ${relative(projectRoot, cssPath)}`);
  }
  if (opts.invalidateUnmatched && unusedKeyframes.length > 0) {
    const count = invalidateUnmatchedKeyframes(cssPath, unusedKeyframes, projectRoot);
    console.log(`Invalidated ${count} keyframes in ${relative(projectRoot, cssPath)}`);
  }

  // Phase 4 alt (optional): Remove unmatched + already-invalidated selectors
  if (opts.removeUnmatched) {
    const removed = removeUnmatchedSelectors(cssPath, results.unmatched, projectRoot);
    console.log(`Removed ${removed} unused selectors from ${relative(projectRoot, cssPath)}`);
    const removedKf = removeUnmatchedKeyframes(cssPath, unusedKeyframes, projectRoot);
    console.log(`Removed ${removedKf} unused keyframes from ${relative(projectRoot, cssPath)}`);
  }
}

main().catch((err) => {
  console.error("FATAL:", err.message);
  console.error(err.stack);
  process.exit(1);
});
