defmodule Mix.Tasks.HeexClassAnalyzer do
  @shortdoc "Extract CSS class hierarchies from HEEX templates"

  @moduledoc """
  Static analysis of HEEX templates. Extracts CSS class hierarchies, resolves dynamic expressions
  and component edges, and writes the result as a JSON graph.

  ## Usage

      mix heex_class_analyzer [--output PATH]

  ## Options

  - `--output` - Directory for `heex-class-graph.json`. Default: `"./analysis"`.
    The task deletes existing `.json` files in the directory before it writes.

  ## Pipeline

  The task runs these stages in order:

  1. **Discovery** - Scans `.ex` and `.heex` files under `lib/*_web/`.
     Finds modules, functions with `~H` sigils, imports, aliases, uses,
     and templates registered through `embed_templates/1`.

  2. **Registry** - Builds a function index keyed by module/function/arity and by name.
     Resolves cross-module references through imports, aliases, and `use`-based imports.

  3. **Resolver** - Parses HEEX content. Extracts static classes and dynamic variants.
     Resolves `{:fn_call, ...}` references and assign facts captured before `~H`.
     Emits component calls as graph edges. Computes compact class facts.

     Conservative models for Phoenix built-ins:
     - `<.link>` is an `a` tag (selectors like `.menu a:hover` match without a local definition).
     - `render_slot(@inner_block)` and named slots are kept in the graph for CSS coverage.
     - Standalone templates resolve tags like `Layouts.admin_content` by module suffix.
     - `Phoenix.HTML.raw/1` calls become raw-HTML placeholders. CSS coverage matches one
       immediate tag-only selector under the HEEX parent (e.g. `.markdown p`),
       not deep descendants (e.g. `.markdown p strong`).

  4. **Output** - Writes `analysis/heex-class-graph.json`: entries, canonical trees,
     cycles, and unresolved refs.

  5. **Summary** - Prints counts of entries, trees, and cycles.

  ## Error handling

  The resolver builds the graph in a single pass. If resolution fails (malformed HEEX,
  unexpected AST), the task logs a warning and re-raises the exception.

  ## Output structure

  Graph version 2. Contains public entries, canonical node trees, component cycles,
  and unresolved refs. See `Mix.Tasks.HeexClassAnalyzer.Output` for the JSON schema.

  ## Example

      $ mix heex_class_analyzer --output ./css_analysis
      Discovering modules...
      Building registry...
      Resolving 42 modules...
      Writing output...
      Analyzed 99 entries, 104 trees, 0 cycles. Output: ./css_analysis/heex-class-graph.json

  ## Submodules

  - `Discovery` - `discover/1`: finds and parses source files.
  - `Registry` - `build/1`: creates the function lookup index.
  - `Resolver` - `resolve_graph/2`: produces canonical graph trees.
  - `Output` - `write_graph!/2`: serializes graph results to JSON.
  """

  use Mix.Task

  alias Mix.Tasks.HeexClassAnalyzer.Discovery
  alias Mix.Tasks.HeexClassAnalyzer.Output
  alias Mix.Tasks.HeexClassAnalyzer.Registry
  alias Mix.Tasks.HeexClassAnalyzer.Resolver

  require Logger

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [output: :string])
    output_dir = opts[:output] || "./analysis"

    base_path = File.cwd!()

    Mix.shell().info("Discovering modules...")
    module_infos = Discovery.discover(base_path)

    Mix.shell().info("Building registry...")
    registry = Registry.build(module_infos)

    module_count = length(module_infos)
    Mix.shell().info("Resolving #{module_count} modules...")

    graph =
      try do
        Resolver.resolve_graph(module_infos, registry)
      rescue
        e ->
          Logger.warning("Failed to resolve graph: #{Exception.message(e)}")
          reraise e, __STACKTRACE__
      end

    Mix.shell().info("Writing output...")
    Output.write_graph!(graph, output_dir)

    Mix.shell().info(
      "Analyzed #{length(graph.entries)} entries, " <>
        "#{map_size(graph.trees)} trees, " <>
        "#{length(graph.cycles)} cycles. " <>
        "Output: #{Path.join(output_dir, "heex-class-graph.json")}"
    )
  end
end
