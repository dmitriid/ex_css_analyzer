defmodule Mix.Tasks.HeexClassAnalyzer do
  @shortdoc "Extract CSS class hierarchies from HEEX templates"

  @moduledoc """
  Reads the HEEX templates of the project and writes their CSS class
  hierarchies as a JSON graph. The graph includes dynamic class expressions
  and the edges between components.

  ## Usage

      mix heex_class_analyzer [--output PATH]

  ## Options

  - `--output`. The directory for `heex-class-graph.json`. The default is
    `"./analysis"`. Before the task writes the file, it deletes all `.json`
    files in this directory.

  ## Stages

  The task runs these stages in this order:

  1. Discovery. Reads the `.ex` and `.heex` files under `lib/*_web/`.
     Finds modules, functions with `~H` sigils, imports, aliases, `use`
     calls, and templates from `embed_templates/1`.

  2. Registry. Makes a function index by module, function name, and arity,
     and a second index by function name. Finds functions in other modules
     through imports, aliases, and the imports that `use` adds.

  3. Resolver. Parses the HEEX content into static classes and dynamic
     variants. Finds the values of `{:fn_call, ...}` references and of the
     assigns that the function sets before `~H`. Adds an edge for each
     component call and computes compact class facts.

     The resolver uses these models for Phoenix components:
     - `<.link>` is an `a` tag. A selector such as `.menu a:hover` matches
       it without a local definition.
     - `render_slot(@inner_block)` and named slots stay in the graph for
       the CSS coverage check.
     - Standalone templates find tags such as `Layouts.admin_content` by
       the last part of the module name.
     - A `Phoenix.HTML.raw/1` call becomes a placeholder for raw HTML. The
       CSS coverage check matches one tag selector directly below the HEEX
       parent, for example `.markdown p`. Deeper selectors, for example
       `.markdown p strong`, do not match.

  4. Output. Writes `analysis/heex-class-graph.json` with the entries,
     canonical trees, cycles, and unresolved references.

  5. Summary. Prints the number of entries, trees, and cycles.

  ## Errors

  The resolver builds the graph in one pass. A malformed HEEX file or an
  unknown AST form can make the resolver fail on a template. In that case,
  the task logs a warning and raises the exception again.

  ## Output

  The graph is version 2. It contains the public entries, canonical node
  trees, component cycles, and unresolved references.
  `Mix.Tasks.HeexClassAnalyzer.Output` describes the JSON schema.

  ## Example

      $ mix heex_class_analyzer --output ./css_analysis
      Discovering modules...
      Building registry...
      Resolving 42 modules...
      Writing output...
      Analyzed 99 entries, 104 trees, 0 cycles. Output: ./css_analysis/heex-class-graph.json

  ## Submodules

  - `Discovery`. `discover/1` finds and parses the source files.
  - `Registry`. `build/1` makes the function index.
  - `Resolver`. `resolve_graph/2` makes the canonical graph trees.
  - `Output`. `write_graph!/2` writes the graph as JSON.
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
