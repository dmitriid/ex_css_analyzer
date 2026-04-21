defmodule Mix.Tasks.HeexClassAnalyzer.Output do
  @moduledoc """
  Serializes resolved module data to JSON files for external consumption.

  The Output module is the final stage of the analyzer pipeline. It takes the
  fully-resolved module data produced by the Resolver and writes one `.json`
  file per module into the output directory (defaults to `./analysis/`).

  ## Public API

      # Write all resolved modules to JSON files in the output directory
      Output.write_all(resolved_modules, "./analysis")
      #=> :ok

  ## Parameters

  - `resolved_modules` - A list of `{module_info, resolved_functions}` tuples where:
    - `module_info` is a `Discovery.module_info()` map with `:module` and `:source_file`
    - `resolved_functions` is a list of `{label, [Node.t()]}` tuples from the Resolver
  - `output_dir` - Path to the directory where JSON files will be written. Created
    if it does not exist.

  ## Output File Format

  Each JSON file contains:

      {
        "module": "MyAppWeb.Components.Button",  // or null for standalone .heex files
        "source_file": "lib/my_app_web/components/button.ex",
        "functions": [
          {
            "name": "render/1",
            "tree": [
              {
                "tag": "button",
                "static": ["px-4", "py-2", "rounded"],
                "variants": [
                  {"type": "toggle", "value": "bg-blue-500"},
                  {"type": "either", "values": [["text-white"], ["text-gray-800"]]}
                ],
                "permutations": [["px-4", "py-2", "rounded", "bg-blue-500", "text-white"], ...],
                "children": [...]
              }
            ]
          }
        ]
      }

  ## File Naming

  - For modules: the file is named after the module, e.g. `Elixir.MyAppWeb.PageLive.json`
  - For standalone `.heex` files (no associated module): the file is named after
    the source file basename, e.g. `index.html.heex.json`

  ## Variant Serialization

  Node variants are serialized as typed JSON objects:
  - `{:toggle, "class"}` becomes `{"type": "toggle", "value": "class"}`
  - `{:either, [["opt-a"], ["opt-b"]]}` becomes `{"type": "either", "values": [["opt-a"], ["opt-b"]]}`
  - `{:fn_call, _}` (unresolved leftovers) becomes `{"type": "fn_call", "value": "<unresolved>"}`

  ## Interaction with Other Modules

  - `Node` - The input data structure whose trees are recursively serialized
  - `Resolver` - Produces the `resolved_functions` data that this module serializes
  - `Discovery` - Provides the `module_info` maps used for file naming and metadata
  - Uses `Jason` for JSON encoding with pretty-printing enabled
  """

  alias Mix.Tasks.HeexClassAnalyzer.Node

  @spec write_all(
          [{Mix.Tasks.HeexClassAnalyzer.Discovery.module_info(), [{String.t(), [Node.t()]}]}],
          String.t()
        ) :: :ok
  def write_all(resolved_modules, output_dir) do
    File.mkdir_p!(output_dir)

    Enum.each(resolved_modules, fn {module_info, resolved_functions} ->
      filename = build_filename(module_info)
      file_path = Path.join(output_dir, filename)

      serialized_functions = Enum.map(resolved_functions, &serialize_function/1)

      json =
        %{
          module: format_module_name(module_info.module),
          source_file: module_info.source_file,
          dynamic: collect_all_dynamics(resolved_functions),
          functions: serialized_functions
        }
        |> Jason.encode!(pretty: true)

      File.write!(file_path, json)
    end)

    :ok
  end

  defp build_filename(%{module: nil, source_file: source_file}) do
    Path.basename(source_file) <> ".json"
  end

  defp build_filename(%{module: module}) do
    "#{inspect(module)}.json"
  end

  defp format_module_name(nil), do: nil
  defp format_module_name(module), do: inspect(module)

  defp serialize_function({name, tree}) do
    %{
      name: name,
      tree: Enum.map(tree, &serialize_node/1)
    }
  end

  defp collect_all_dynamics(resolved_functions) do
    Enum.flat_map(resolved_functions, fn {func_name, tree} ->
      Enum.flat_map(tree, &collect_node_dynamics(&1, func_name, []))
    end)
  end

  defp collect_node_dynamics(%Node{} = node, func_name, path_acc) do
    current_path = path_acc ++ [node.tag || "?"]

    static_dynamics =
      node.static
      |> Enum.filter(&match?({:dynamic, _}, &1))
      |> Enum.map(fn {:dynamic, info} ->
        {path, path_parts} = build_path(func_name, current_path)

        %{
          path: path,
          path_parts: path_parts,
          location: "static",
          reason: info.reason,
          expr: info.expr,
          chain: info.chain
        }
      end)

    variant_dynamics =
      Enum.flat_map(node.variants, fn
        {:either, options} ->
          options
          |> Enum.filter(&match?({:dynamic, _}, &1))
          |> Enum.map(fn {:dynamic, info} ->
            {path, path_parts} = build_path(func_name, current_path)

            %{
              path: path,
              path_parts: path_parts,
              location: "variant:either",
              reason: info.reason,
              expr: info.expr,
              chain: info.chain
            }
          end)

        {:toggle, {:dynamic, info}} ->
          {path, path_parts} = build_path(func_name, current_path)

          [
            %{
              path: path,
              path_parts: path_parts,
              location: "variant:toggle",
              reason: info.reason,
              expr: info.expr,
              chain: info.chain
            }
          ]

        _ ->
          []
      end)

    children_dynamics =
      Enum.flat_map(node.children, &collect_node_dynamics(&1, func_name, current_path))

    static_dynamics ++ variant_dynamics ++ children_dynamics
  end

  defp build_path(func_name, tag_path) do
    parts = [func_name | tag_path]
    {Enum.join(parts, " > "), parts}
  end

  defp serialize_node(%Node{} = node) do
    %{
      tag: node.tag,
      static: Enum.map(node.static, &serialize_class/1),
      variants: Enum.map(node.variants, &serialize_variant/1),
      permutations: Enum.map(node.permutations, fn p -> Enum.map(p, &serialize_class/1) end),
      children: Enum.map(node.children, &serialize_node/1)
    }
  end

  defp serialize_class(str) when is_binary(str), do: str

  defp serialize_class({:dynamic, info}) do
    %{dynamic: true, reason: info.reason, expr: info.expr, chain: info.chain}
  end

  defp serialize_class(list) when is_list(list), do: Enum.map(list, &serialize_class/1)

  defp serialize_variant({:toggle, value}) do
    %{type: "toggle", value: serialize_class(value)}
  end

  defp serialize_variant({:either, values}) do
    %{type: "either", values: Enum.map(values, &serialize_class/1)}
  end

  defp serialize_variant({:fn_call, _term}) do
    %{type: "fn_call", value: "<unresolved>"}
  end
end
