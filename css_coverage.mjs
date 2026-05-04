/*
 * ============================================================================
 * CSS Coverage Analyzer — Dead CSS Detection via HEEX Class Analysis
 * ============================================================================
 *
 * PURPOSE
 * -------
 * This script cross-references CSS selectors from the project's `app.css`
 * against the HEEX class analyzer output (JSON files in `analysis/`) to find
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
 *    This produces JSON files in the `analysis/` directory, one per Elixir
 *    module. Each file contains a tree representation of the HTML structure
 *    with static and dynamic class information for every element.
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
 *    --analysis <dir>    Directory containing analysis JSON files (default: analysis/)
 *    --output <path>     Path for the output JSON report (default: analysis/css-coverage.json)
 *    --remove-unmatched     Remove unmatched selectors (and already-invalidated ones) from CSS source
 *    --list-unmatched       List all unmatched selectors (including already-invalidated ones) to stdout
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
 *   - combinator: the combinator that connects this segment to the previous
 *     one (null for the first segment, " " for descendant, ">" for child,
 *     "+" for adjacent sibling, "~" for general sibling)
 *   - wildcard: true for classless structural segments that can match any
 *     analyzed node but still enforce their combinator
 *
 * Example decompositions:
 *   `.a.b > .c`  →  [{classes:["a","b"], combinator:null}, {classes:["c"], combinator:">"}]
 *   `.event-page .event-hero__title`  →  [{classes:["event-page"], combinator:null}, {classes:["event-hero__title"], combinator:" "}]
 *   `.x > :not(.a) .b` → [{classes:["x"], combinator:null}, {classes:[], combinator:">", wildcard:true}, {classes:["b"], combinator:" "}]
 *
 * Comma-separated selectors like `.input, .select, .textarea {}` are split
 * into independent selectors, each evaluated separately — if `.input` matches
 * but `.textarea` doesn't, they get different categories.
 *
 * Selectors with no class component (element-only like `html`, `body`;
 * attribute selectors like `[data-phx-session]`; `:root`) go into the
 * "skipped" category since we can't class-match them.
 *
 * Phase 2: Load Analysis Trees
 * ----------------------------
 * All *.json files in the analysis directory are read and parsed. Each file
 * has the structure:
 *
 *   {
 *     "module": "RsvpWeb.Components.Admin",
 *     "source_file": "lib/rsvp_web/components/admin.ex",
 *     "functions": [
 *       {
 *         "name": "admin_nav/1",
 *         "tree": [ { tag, static, variants, permutations, children }, ... ]
 *       }
 *     ]
 *   }
 *
 * Each node in the tree represents an HTML element and contains:
 *   - tag: the element tag (e.g. "div", "nav", ".link" for Phoenix components)
 *   - static: array of always-present class names
 *   - variants: array of conditional classes ({type:"toggle", value:...} or
 *     {type:"either", values:[...]})
 *   - permutations: array of arrays — each inner array is one possible
 *     combination of classes the element could have at runtime
 *   - repeat: whether the element comes from a HEEx :for and may render
 *     multiple sibling copies of itself
 *   - children: nested child nodes with the same structure
 *
 * DYNAMIC ENTRIES: Objects with {dynamic: true, reason, expr, chain} can
 * appear in permutation arrays wherever a class name would normally be.
 * These represent classes computed at runtime (e.g. from an assign like
 * @btn_class) that could be any value. Nodes containing dynamic entries
 * are flagged so that CSS selectors that partially match are categorized
 * as "possibly_dynamic" (with the original reason/expr metadata) rather
 * than "unmatched".
 *
 * An index is built: classToNodes maps each class name to a list of entries
 * containing the module, source file, function name, node reference, ancestor
 * chain, and sibling nodes. A separate allEntries list is kept for selectors
 * whose rightmost segment is classless (for example `.stack > * + *`).
 *
 * Phase 3: Match Selectors (Right-to-Left)
 * -----------------------------------------
 * CSS selectors are matched right-to-left, mirroring how browser engines
 * evaluate selectors. For each parsed selector:
 *
 * 1. Start from the RIGHTMOST segment (the "key selector"). If that segment is
 *    classless/wildcard, all analyzed nodes are potential candidates.
 *
 * 2. Find all tree nodes where at least one permutation contains ALL classes
 *    required by that segment. A permutation is a list of class strings;
 *    we check if any single permutation is a superset of the required classes.
 *    If a permutation entry is "<dynamic>", the node COULD match any class.
 *    Wildcard segments match any analyzed node.
 *
 * 3. For each candidate node from step 2, recursively walk LEFT through the
 *    remaining selector segments, checking combinator constraints against the
 *    node's ancestor chain and siblings. Recursion lets wildcard/descendant
 *    segments try every valid ancestor position instead of greedily accepting
 *    the nearest one:
 *
 *    - Descendant combinator (" "): ANY ancestor in the chain must have a
 *      permutation satisfying the segment's classes.
 *    - Child combinator (">"): the IMMEDIATE parent must satisfy the segment.
 *    - Adjacent sibling combinator ("+"): a sibling node (another child of
 *      the same parent), or another rendered copy of the same repeatable
 *      node, must satisfy the segment.
 *    - General sibling combinator ("~"): same as "+", any sibling works.
 *
 *    "Satisfies a segment" means: does any permutation of that node contain
 *    ALL classes in the segment? Wildcard segments satisfy any analyzed node.
 *
 * 4. Results are categorized:
 *    - matched: all segments satisfied statically, with full provenance.
 *    - possibly_dynamic: couldn't match statically, but a candidate path
 *      involves nodes with dynamic ("<dynamic>") entries.
 *    - unmatched: no match found and no dynamic entries involved.
 *    - skipped: selectors with no class components.
 *
 * OUTPUT FORMAT
 * -------------
 * The script writes JSON to analysis/css-coverage.json (configurable) with
 * four arrays (matched, possibly_dynamic, unmatched, skipped) and a summary
 * object with counts. It also prints a one-line summary to stdout.
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
 * ============================================================================
 */

import { readFileSync, writeFileSync, readdirSync, existsSync } from "node:fs";
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
  };

  const HELP = `Usage: node css_coverage.mjs [options]
  --css <path>              CSS file (default: assets/css/app.css)
  --analysis <dir>          Analysis JSON dir (default: analysis/)
  --output <path>           Output file (default: analysis/css-coverage.json)
  --invalidate-unmatched    Prepend ${UNMATCHED_MARKER} to unmatched selectors in the CSS source
  --restore-unmatched       Remove ${UNMATCHED_MARKER} markers from all selectors in the CSS source
  --remove-unmatched           Remove unmatched selectors (and already-invalidated ones) from CSS source
  --list-unmatched             List all unmatched selectors (including already-invalidated ones) to stdout
  --help                    Show this message`;

  const FLAGS_WITH_VALUE = new Set(["--css", "--analysis", "--output"]);
  const FLAGS_BOOLEAN = new Set(["--invalidate-unmatched", "--restore-unmatched", "--help"]);

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
    } else if (arg === "--invalidate-unmatched") {
      opts.invalidateUnmatched = true;
    } else if (arg === "--restore-unmatched") {
      opts.restoreUnmatched = true;
    } else if (arg === "--remove-unmatched") {
      opts.removeUnmatched = true;
    } else if (arg === "--list-unmatched") {
      opts.listUnmatched = true;
    } else {
      console.error(`Unknown option: ${arg}\n`);
      console.error(HELP);
      process.exit(1);
    }
  }
  return opts;
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

/**
 * Parse a CSS file and return an array of parsed selector descriptors.
 *
 * Each descriptor:
 *   { selectorText, file, line, segments: [{classes:[], combinator:null|string}] }
 *
 * Comma-separated selectors produce separate descriptors.
 */
async function parseCss(cssPath, projectRoot) {
  const cssContent = readFileSync(cssPath, "utf-8");
  const relCssPath = relative(projectRoot, cssPath);

  // Pre-filter: strip lines that postcss-import can't handle and that
  // aren't standard @import directives pointing to local files.
  // This avoids errors from non-file imports like @import "tailwindcss".
  const filteredCss = cssContent
    .split("\n")
    .map((line) => {
      const trimmed = line.trim();
      // Skip @import "tailwindcss" or any @import that doesn't look like a file path
      if (/^@import\s+["'](?!\.\/|\.\.\/|\/)/.test(trimmed)) {
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

/**
 * Extract segments from a postcss-selector-parser selector node.
 *
 * Returns an array of {classes:string[], combinator:string|null} or null
 * if the selector contains no class selectors at all.
 */
function extractSegments(selectorNode) {
  const segments = [];
  let currentClasses = [];
  let currentCombinator = null;
  let currentHasClasslessStructure = false;
  let hasAnyClass = false;

  function flushCurrentSegment() {
    if (currentClasses.length > 0) {
      segments.push({
        classes: currentClasses,
        combinator: currentCombinator,
        wildcard: false,
      });
    } else if (currentHasClasslessStructure && currentCombinator !== null) {
      segments.push({
        classes: [],
        combinator: currentCombinator,
        wildcard: true,
      });
    }

    currentClasses = [];
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
      case "id":
      case "attribute":
      case "universal":
        // We ignore these for matching, but they create segment boundaries
        // if followed by a combinator. We keep accumulating classes.
        currentHasClasslessStructure = true;
        break;

      case "pseudo":
        // Skip pseudo-classes and pseudo-elements entirely.
        // Don't descend into :not(), :where(), etc.
        currentHasClasslessStructure = true;
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
  return segments.filter((s) => s.wildcard || s.classes.length > 0);
}

// ---------------------------------------------------------------------------
// PHASE 2: Load Analysis Trees and Build Index
// ---------------------------------------------------------------------------

/**
 * Check whether a value is a dynamic entry.
 * Dynamic entries are objects with {dynamic: true, reason, expr, chain}.
 */
function isDynamic(value) {
  return typeof value === "object" && value !== null && value.dynamic === true;
}

/**
 * Check whether a node has any dynamic entries in its permutations.
 */
function nodeHasDynamic(node) {
  if (!node.permutations) return false;
  for (const perm of node.permutations) {
    if (perm.some(isDynamic)) return true;
  }
  return false;
}

/**
 * Extract dynamic entry metadata from a node's permutations.
 * Returns the first dynamic object found (with reason, expr, chain fields),
 * or a generic fallback.
 */
function extractDynamicInfo(node) {
  if (!node.permutations) return { reason: "dynamic", expr: "<unknown>", chain: null };
  for (const perm of node.permutations) {
    for (const entry of perm) {
      if (isDynamic(entry)) {
        return { reason: entry.reason, expr: entry.expr, chain: entry.chain };
      }
    }
  }
  return { reason: "dynamic", expr: "<unknown>", chain: null };
}

/**
 * Build a label for a node: "tag.class1.class2"
 * Uses the first permutation's non-dynamic classes for the label.
 */
function nodeLabel(node) {
  const tag = node.tag || "?";
  if (!node.permutations || node.permutations.length === 0) return tag;
  const longestPerm = node.permutations.reduce((a, b) => a.length >= b.length ? a : b, []);
  const classes = longestPerm.filter((c) => !isDynamic(c));
  if (classes.length === 0) return tag;
  return `${tag}.${classes.join(".")}`;
}

/**
 * Load all analysis JSON files from a directory and build the classToNodes index.
 *
 * classToNodes: Map<className, Array<{module, sourceFile, functionName, node, ancestors, siblings, hasDynamic}>>
 *
 * ancestors: array of parent node references from root down (not including the node itself)
 * siblings: array of sibling node references (other children of the same parent)
 */
function loadAnalysisTrees(analysisDir) {
  const classToNodes = new Map();
  const allEntries = [];
  const files = readdirSync(analysisDir).filter(
    (f) => f.endsWith(".json") && f !== "css-coverage.json"
  );

  for (const file of files) {
    const filePath = join(analysisDir, file);
    let data;
    try {
      data = JSON.parse(readFileSync(filePath, "utf-8"));
    } catch (err) {
      console.warn(`WARNING: Skipping malformed JSON file: ${file} (${err.message})`);
      continue;
    }

    const moduleName = data.module || file.replace(/\.json$/, "");
    const sourceFile = data.source_file || "";

    if (!data.functions || !Array.isArray(data.functions)) continue;

    for (const fn of data.functions) {
      if (!fn.tree || !Array.isArray(fn.tree)) continue;

      // Walk the tree, tracking ancestors
      walkTree(fn.tree, [], null, (node, ancestors, parentNode) => {
        const hasDynamic = nodeHasDynamic(node);

        // Collect all class names from this node
        const allClasses = collectNodeClasses(node);

        // Compute siblings: other children of the same parent
        let siblings = [];
        if (parentNode && parentNode.children) {
          siblings = parentNode.children.filter((c) => c !== node);
        }

        const entry = {
          module: moduleName,
          sourceFile,
          functionName: fn.name,
          node,
          ancestors: [...ancestors],
          siblings,
          hasDynamic,
        };

        allEntries.push(entry);

        for (const cls of allClasses) {
          if (isDynamic(cls)) continue;
          if (!classToNodes.has(cls)) classToNodes.set(cls, []);
          classToNodes.get(cls).push(entry);
        }
      });
    }
  }

  classToNodes.allEntries = allEntries;
  return classToNodes;
}

/**
 * Recursively walk a node tree, calling callback(node, ancestors, parentNode) for each node.
 */
function walkTree(nodes, ancestors, parentNode, callback) {
  for (const node of nodes) {
    callback(node, ancestors, parentNode);
    if (node.children && node.children.length > 0) {
      walkTree(node.children, [...ancestors, node], node, callback);
    }
  }
}

/**
 * Collect all unique class names from a node's permutations.
 */
function collectNodeClasses(node) {
  const classes = new Set();
  if (node.permutations) {
    for (const perm of node.permutations) {
      for (const c of perm) classes.add(c);
    }
  }
  return classes;
}

// ---------------------------------------------------------------------------
// PHASE 3: Match Selectors
// ---------------------------------------------------------------------------

/**
 * Check if a node satisfies a segment: does any permutation contain ALL
 * required classes?
 *
 * Returns:
 *   "static"  — matched by a concrete permutation
 *   "dynamic" — not matched statically, but node has dynamic entries
 *   false     — not matched at all
 */
function nodeMatchesSegment(node, requiredClasses) {
  if (requiredClasses.length === 0) return "static";
  if (!node.permutations) return false;

  let bestDynamic = false;

  for (const perm of node.permutations) {
    const concreteClasses = perm.filter((c) => !isDynamic(c));
    const hasDynamic = perm.some(isDynamic);

    if (requiredClasses.every((rc) => concreteClasses.includes(rc))) {
      return "static";
    }

    // Only consider dynamic if at least one required class matches statically
    // on this same node. This prevents heroicon @name etc. from matching everything.
    if (hasDynamic && requiredClasses.some((rc) => concreteClasses.includes(rc))) {
      bestDynamic = true;
    }
  }

  return bestDynamic ? "dynamic" : false;
}

function nodeMatchesParsedSegment(node, segment) {
  if (segment.wildcard) return "static";
  return nodeMatchesSegment(node, segment.classes);
}

/**
 * Given a candidate node and its ancestor chain, walk left through the
 * selector segments (from right-to-left) to check if the full selector
 * matches.
 *
 * Returns: { matched: boolean, dynamic: boolean, dynamicNode: object|null, unmatchedClasses: string[] }
 */
function matchSelectorLeftward(segments, candidateEntry) {
  return matchSegmentAt(
    segments,
    segments.length - 1,
    candidateEntry.node,
    candidateEntry.ancestors,
    false,
    null
  );
}

function matchSegmentAt(segments, segIdx, node, ancestors, involvesDynamic, dynamicNode) {
  if (segIdx === 0) {
    return { matched: true, dynamic: involvesDynamic, dynamicNode, unmatchedClasses: [] };
  }

  const leftSeg = segments[segIdx - 1];
  const comb = segments[segIdx].combinator;
  const candidates = relatedCandidates(comb, node, ancestors);
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
        candidate.node,
        candidate.ancestors,
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

function relatedCandidates(comb, node, ancestors) {
  if (comb === ">") {
    if (ancestors.length === 0) return [];
    const parentIdx = ancestors.length - 1;
    return [{ node: ancestors[parentIdx], ancestors: ancestors.slice(0, parentIdx) }];
  }

  if (comb === "+" || comb === "~") {
    const parent = ancestors[ancestors.length - 1];
    const siblings = parent && parent.children ? parent.children.filter((c) => c !== node) : [];
    const siblingNodes = node.repeat ? [...siblings, node] : siblings;

    return siblingNodes.map((sibling) => ({
      node: sibling,
      ancestors,
    }));
  }

  const candidates = [];
  for (let idx = ancestors.length - 1; idx >= 0; idx--) {
    candidates.push({ node: ancestors[idx], ancestors: ancestors.slice(0, idx) });
  }
  return candidates;
}

/**
 * Build the provenance path for a match: array of "tag.class1.class2" strings
 * from root to the matched node.
 */
function buildPath(ancestors, node) {
  const path = [];
  for (const anc of ancestors) {
    path.push(nodeLabel(anc));
  }
  path.push(nodeLabel(node));
  return path;
}

/**
 * Build the human-readable chain string:
 * "functionName -> tag.classes -> tag.classes -> ... -> tag.matched"
 */
function buildChain(functionName, ancestors, node) {
  const parts = [functionName];
  for (const anc of ancestors) {
    parts.push(nodeLabel(anc));
  }
  parts.push(nodeLabel(node));
  return parts.join(" \u2192 ");
}

/**
 * Match all parsed selectors against the classToNodes index.
 *
 * Returns { matched, possibly_dynamic, unmatched, skipped }
 */
function matchSelectors(parsedSelectors, classToNodes) {
  const matched = [];
  const possiblyDynamic = [];
  const unmatched = [];
  const skipped = [];

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

    const result = matchOneSelector(sel, classToNodes);

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
    } else if (
      sel.segments.length > 1 &&
      isDescendantOnly(sel.segments) &&
      crossTreeMatch(sel, classToNodes)
    ) {
      // All classes exist but across different component trees —
      // descendant selectors still match in the rendered DOM
      matched.push({
        selector: sel.selectorText,
        file: sel.file,
        line: sel.line,
        matches: [{
          module: "(cross-component)",
          function: "(descendant match across component boundaries)",
          path: sel.segments.map((s) => s.classes.join(".")),
          chain: sel.segments.map((s) => s.classes.join(".")).join(" → "),
          dynamic: null,
        }],
      });
    } else {
      unmatched.push({
        selector: sel.selectorText,
        file: sel.file,
        line: sel.line,
        diagnostics: buildDiagnostics(sel, classToNodes),
      });
    }
  }

  return { matched, possibly_dynamic: possiblyDynamic, unmatched, skipped };
}

/**
 * Build diagnostics for an unmatched selector: which classes exist
 * somewhere in the analysis and which don't, plus structural notes.
 */
function buildDiagnostics(sel, classToNodes) {
  const allSelectorClasses = sel.segments.flatMap((s) => s.classes);
  const unique = [...new Set(allSelectorClasses)];

  const classesFound = unique.filter((c) => classToNodes.has(c));
  const classesNotFound = unique.filter((c) => !classToNodes.has(c));

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
 * Check whether a selector uses only descendant combinators (spaces).
 * Selectors like `.a .b .c` can match across component/layout boundaries
 * because descendant relationships hold at any depth in the rendered DOM.
 */
function isDescendantOnly(segments) {
  for (let i = 1; i < segments.length; i++) {
    const comb = segments[i].combinator;
    if (comb && comb !== " ") return false;
  }
  return true;
}

/**
 * Cross-tree fallback for descendant-only selectors: check that every class
 * in every segment exists somewhere in the analysis. Since descendant selectors
 * match at any depth, classes split across layout/component boundaries still
 * match in the rendered HTML.
 */
function crossTreeMatch(sel, classToNodes) {
  for (const seg of sel.segments) {
    for (const cls of seg.classes) {
      if (!classToNodes.has(cls)) return false;
    }
  }
  return true;
}

/**
 * Match a single selector against the index.
 *
 * Returns { matches, dynamicCandidates, allDynamic }
 */
function matchOneSelector(sel, classToNodes) {
  const segments = sel.segments;
  const matches = [];
  const dynamicCandidates = [];

  // Step 1: Find candidate nodes for the rightmost segment
  const rightmost = segments[segments.length - 1];
  const candidateEntries = findCandidatesForSegment(
    rightmost.classes,
    classToNodes
  );

  // Step 2: For each candidate, walk left through remaining segments
  let hasStaticMatch = false;

  for (const entry of candidateEntries) {
    const rightMatchResult = nodeMatchesSegment(entry.node, rightmost.classes);
    if (!rightMatchResult) continue;

    const rightIsDynamic = rightMatchResult === "dynamic";

    if (segments.length === 1) {
      // Only one segment — just check the rightmost
      const path = buildPath(entry.ancestors, entry.node);
      const chain = buildChain(entry.functionName, entry.ancestors, entry.node);

      if (rightIsDynamic) {
        const missingClasses = rightmost.classes.filter((c) => {
          const nodeClasses = [...collectNodeClasses(entry.node)].filter(
            (nc) => !isDynamic(nc)
          );
          return !nodeClasses.includes(c);
        });
        const dynInfo = extractDynamicInfo(entry.node);
        dynamicCandidates.push({
          module: entry.module,
          function: entry.functionName,
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
          module: entry.module,
          function: entry.functionName,
          path,
          chain,
          dynamic: null,
        });
      }
      continue;
    }

    // Multiple segments — walk leftward
    const leftResult = matchSelectorLeftward(segments, entry);

    const path = buildPath(entry.ancestors, entry.node);
    const chain = buildChain(entry.functionName, entry.ancestors, entry.node);

    if (leftResult.matched && !leftResult.dynamic && !rightIsDynamic) {
      hasStaticMatch = true;
      matches.push({
        module: entry.module,
        function: entry.functionName,
        path,
        chain,
        dynamic: null,
      });
    } else if (leftResult.matched && (leftResult.dynamic || rightIsDynamic)) {
      const dynNode = rightIsDynamic ? entry.node : leftResult.dynamicNode || entry.node;
      const dynInfo = extractDynamicInfo(dynNode);
      dynamicCandidates.push({
        module: entry.module,
        function: entry.functionName,
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
        module: entry.module,
        function: entry.functionName,
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
function findCandidatesForSegment(requiredClasses, classToNodes) {
  // Use the first required class to narrow down candidates
  const candidates = new Set();

  if (requiredClasses.length === 0) return classToNodes.allEntries || [];

  // Gather candidates from all required classes (union) so that nodes with
  // partial static + dynamic coverage are included
  for (const cls of requiredClasses) {
    const entries = classToNodes.get(cls);
    if (entries) {
      for (const e of entries) candidates.add(e);
    }
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
  const parsedSelectors = await parseCss(cssPath, projectRoot);

  // Phase 2: Load analysis trees
  const classToNodes = loadAnalysisTrees(analysisDir);

  // Phase 3: Match selectors
  const results = matchSelectors(parsedSelectors, classToNodes);

  // Phase 3b: Analyze keyframes
  const keyframeAnalysis = analyzeKeyframes(cssPath, projectRoot);
  const unusedKeyframes = [];
  for (const [name, info] of keyframeAnalysis.declarations) {
    if (!keyframeAnalysis.references.has(name)) {
      unusedKeyframes.push({ name, file: info.file, line: info.line });
    }
  }

  // Build output
  const output = {
    matched: results.matched,
    possibly_dynamic: results.possibly_dynamic,
    unmatched: results.unmatched,
    skipped: results.skipped,
    unused_keyframes: unusedKeyframes,
    summary: {
      matched: results.matched.length,
      unmatched: results.unmatched.length,
      possibly_dynamic: results.possibly_dynamic.length,
      skipped: results.skipped.length,
      keyframes_total: keyframeAnalysis.declarations.size,
      keyframes_unused: unusedKeyframes.length,
    },
  };

  writeFileSync(outputPath, JSON.stringify(output, null, 2) + "\n");

  const s = output.summary;
  console.log(
    `CSS Coverage: ${s.matched} matched, ${s.unmatched} unmatched, ${s.possibly_dynamic} possibly dynamic, ${s.skipped} skipped`
  );
  if (keyframeAnalysis.declarations.size > 0) {
    console.log(
      `Keyframes: ${keyframeAnalysis.declarations.size} found, ${unusedKeyframes.length} unused`
    );
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
