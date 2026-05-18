defmodule Mix.Tasks.HeexClassAnalyzer do
  @shortdoc "Extract CSS class hierarchies from HEEX templates"

  @moduledoc """
  Entry point Mix task that orchestrates the full HEEX class analysis pipeline.

  This task statically analyzes Phoenix HEEX templates to extract CSS class
  hierarchies, resolving dynamic expressions, component edges, and function
  calls to produce a graph of all CSS classes used in the application.

  ## Usage

      mix heex_class_analyzer [--output PATH]

  ## Options

  - `--output` - Directory to write `heex-class-graph.json`. Defaults to
    `"./analysis"`. The directory is cleaned of existing `.json` files before
    writing new output.

  ## Pipeline

  The task executes the following stages in order:

  1. **Discovery** - Scans all `.ex` and `.heex` files under `lib/*_web/` to
     find modules, their functions (with `~H` sigils), imports, aliases, uses,
     and embedded templates via `embed_templates/1`.

  2. **Registry** - Builds an index of all discovered functions keyed by
     module/function/arity (MFA) and by name, enabling cross-module function
     resolution including imports, aliases, and `use`-based imports.

  3. **Resolver** - Parses HEEX content, analyzes class attributes to extract
     static classes and dynamic variants, resolves `{:fn_call, ...}` references,
     resolves narrow assign facts captured before `~H`, emits component calls
     as graph edges, and computes compact class facts.

     Phoenix built-ins and runtime HTML are modeled conservatively:

     - `<.link>` is treated as an `a` tag so selectors like `.menu a:hover`
       can match without requiring a local component definition.
     - Slot placeholders from `render_slot(@inner_block)` and named slots such
       as `render_slot(@media)` are preserved in the graph so CSS coverage can
       place caller content under the component wrapper that renders it.
     - Standalone templates can resolve component tags like
       `Layouts.admin_content` by registry module suffix when alias metadata is
       unavailable.
     - Non-slot HEEX expressions that call a helper returning
       `Phoenix.HTML.raw/1` are serialized as raw HTML placeholders. CSS
       coverage treats those placeholders as matching one immediate child
       selector segment under the HEEX parent, e.g. `.markdown p`, but does not
       assume arbitrary deep descendants such as `.markdown p strong`.

  4. **Output** - Writes `analysis/heex-class-graph.json` by default,
     containing entries, canonical trees, cycles, and unresolved refs.

  5. **Summary** - Prints counts of entries, trees, and cycles.

  ## Error Handling

  The resolver builds the full graph in a single pass. If graph resolution
  fails (e.g., due to malformed HEEX or unexpected AST structures), the task
  logs a warning for the graph failure and reraises the exception.

  ## Output Structure

  The generated graph JSON file is graph version 2 and contains public entries,
  canonical node trees, component cycles, and unresolved refs. See
  `Mix.Tasks.HeexClassAnalyzer.Output` for the full JSON schema.

  ## Example

      $ mix heex_class_analyzer --output ./css_analysis
      Discovering modules...
      Building registry...
      Resolving 42 modules...
      Writing output...
      Analyzed 99 entries, 104 trees, 0 cycles. Output: ./css_analysis/heex-class-graph.json

  ## Interaction with Other Modules

  - `Discovery` - Provides `discover/1` to find and parse all source files
  - `Registry` - Provides `build/1` to create the function lookup index
  - `Resolver` - Provides `resolve_graph/2` to produce canonical graph trees
  - `Output` - Provides `write_graph!/2` to serialize graph results to JSON
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
