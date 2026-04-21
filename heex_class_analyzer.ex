defmodule Mix.Tasks.HeexClassAnalyzer do
  @moduledoc """
  Entry point Mix task that orchestrates the full HEEX class analysis pipeline.

  This task statically analyzes Phoenix HEEX templates to extract CSS class
  hierarchies, resolving dynamic expressions, component trees, and function
  calls to produce a complete picture of all CSS classes used in the application.

  ## Usage

      mix heex_class_analyzer [--output PATH]

  ## Options

  - `--output` - Directory to write JSON output files. Defaults to `"./analysis"`.
    The directory is cleaned of existing `.json` files before writing new output.

  ## Pipeline

  The task executes the following stages in order:

  1. **Discovery** - Scans all `.ex` and `.heex` files under `lib/*_web/` to
     find modules, their functions (with `~H` sigils), imports, aliases, uses,
     and embedded templates via `embed_templates/1`.

  2. **Registry** - Builds an index of all discovered functions keyed by
     module/function/arity (MFA) and by name, enabling cross-module function
     resolution including imports, aliases, and `use`-based imports.

  3. **Resolver** - For each discovered module, parses HEEX content, analyzes
     class attributes to extract static classes and dynamic variants, resolves
     `{:fn_call, ...}` references by following function definitions (up to
     depth 10 with cycle detection), inlines component trees, and computes
     all class permutations.

  4. **Output** - Writes one JSON file per module to the output directory,
     containing the fully resolved node trees with tags, static classes,
     variants, permutations, and children.

  5. **Summary** - Prints counts of analyzed modules, functions, and templates.

  ## Error Handling

  If resolution fails for a particular module (e.g., due to malformed HEEX or
  unexpected AST structures), the error is logged as a warning and that module
  is skipped. The task continues processing remaining modules.

  ## Output Structure

  Each generated JSON file in the output directory represents one module and
  contains its source file path, module name, and a list of functions/templates
  with their resolved class trees. See `Mix.Tasks.HeexClassAnalyzer.Output` for
  the full JSON schema.

  ## Example

      $ mix heex_class_analyzer --output ./css_analysis
      Discovering modules...
      Building registry...
      Resolving 42 modules...
      Writing output...
      Analyzed 42 modules, 87 functions, 12 templates. Output: ./css_analysis/

  ## Interaction with Other Modules

  - `Discovery` - Provides `discover/1` to find and parse all source files
  - `Registry` - Provides `build/1` to create the function lookup index
  - `Resolver` - Provides `resolve_module/2` to produce fully-resolved node trees
  - `Output` - Provides `write_all/2` to serialize results to JSON
  """

  use Mix.Task

  alias Mix.Tasks.HeexClassAnalyzer.Discovery
  alias Mix.Tasks.HeexClassAnalyzer.Output
  alias Mix.Tasks.HeexClassAnalyzer.Registry
  alias Mix.Tasks.HeexClassAnalyzer.Resolver

  require Logger

  @shortdoc "Extract CSS class hierarchies from HEEX templates"

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

    resolved =
      module_infos
      |> Enum.map(fn module_info ->
        try do
          {module_info, Resolver.resolve_module(module_info, registry)}
        rescue
          e ->
            name = module_info.module || module_info.source_file
            Logger.warning("Failed to resolve #{inspect(name)}: #{Exception.message(e)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    Mix.shell().info("Writing output...")
    clean_output_dir(output_dir)
    Output.write_all(resolved, output_dir)

    {function_count, template_count} = count_outputs(resolved)

    Mix.shell().info(
      "Analyzed #{length(resolved)} modules, " <>
        "#{function_count} functions, " <>
        "#{template_count} templates. " <>
        "Output: #{output_dir}/"
    )
  end

  defp clean_output_dir(output_dir) do
    File.mkdir_p!(output_dir)

    output_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end

  defp count_outputs(resolved) do
    Enum.reduce(resolved, {0, 0}, fn {module_info, functions}, {fn_acc, tpl_acc} ->
      fn_count = length(functions)
      tpl_count = length(module_info.heex_templates)
      {fn_acc + fn_count, tpl_acc + tpl_count}
    end)
  end
end
