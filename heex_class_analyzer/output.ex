defmodule Mix.Tasks.HeexClassAnalyzer.Output do
  @moduledoc """
  Serializes analyzer graph data to JSON for external consumption.

  The Output module is the final stage of the analyzer pipeline. It takes the
  graph data produced by the Resolver and writes only
  `analysis/heex-class-graph.json` by default.

  ## Public API

      # Write the resolved graph to JSON in the output directory
      Output.write_graph!(graph, "./analysis")
      #=> :ok

  ## Parameters

  - `graph` - A resolved graph map containing `:version`, `:entries`,
    `:trees`, `:cycles`, and `:unresolved`
  - `output_dir` - Path to the directory where `heex-class-graph.json` will be
    written. Created if it does not exist.

  ## Output File Format

  The graph JSON file uses graph version 2 and contains:

      {
        "version": 2,
        "entries": [...],
        "trees": {"fn:MyAppWeb.PageLive:render:1:0": [...]},
        "cycles": [...],
        "unresolved": [...]
      }

  ## Variant Serialization

  Node variants are serialized as typed JSON objects:
  - `{:toggle, "class"}` becomes `{"type": "toggle", "value": "class"}`
  - `{:either, [["opt-a"], ["opt-b"]]}` becomes `{"type": "either", "values": [["opt-a"], ["opt-b"]]}`
  - `{:fn_call, _}` (unresolved leftovers) becomes `{"type": "fn_call", "value": "<unresolved>"}`

  Nodes also serialize compact class facts under `"classes"`.

  ## Repeat Metadata

  Nodes with HEEx `:for` are serialized with `"repeat": true`; all other nodes
  use `"repeat": false`. Consumers such as CSS coverage use this to recognize
  that one template node may render as multiple adjacent sibling elements.

  ## Interaction with Other Modules

  - `Node` - The input data structure whose trees are recursively serialized
  - `Resolver` - Produces the graph data that this module serializes
  - Uses `Jason` for JSON encoding with pretty-printing enabled
  """

  alias Mix.Tasks.HeexClassAnalyzer.Node

  @graph_filename "heex-class-graph.json"

  @spec write_graph!(map(), String.t()) :: :ok
  def write_graph!(graph, output_dir) do
    File.mkdir_p!(output_dir)
    clean_json_files!(output_dir)

    output =
      graph
      |> serialize_graph()
      |> Jason.encode!(pretty: true)

    output_dir
    |> Path.join(@graph_filename)
    |> File.write!(output)
  end

  defp clean_json_files!(output_dir) do
    output_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end

  defp serialize_graph(graph) do
    %{
      version: graph.version,
      entries: graph.entries,
      trees: Map.new(graph.trees, fn {ref, tree} -> {ref, Enum.map(tree, &serialize_child/1)} end),
      cycles: graph.cycles,
      unresolved: graph.unresolved
    }
  end

  defp serialize_node(%Node{} = node) do
    %{
      tag: node.tag,
      static: Enum.map(node.static, &serialize_class/1),
      variants: Enum.map(node.variants, &serialize_variant/1),
      classes: serialize_class_facts(node.classes),
      repeat: node.repeat,
      children: Enum.map(node.children, &serialize_child/1)
    }
  end

  defp serialize_child(%Node{} = node), do: serialize_node(node)

  defp serialize_child(%{slot_name: slot_name}), do: %{slot_name: slot_name}

  defp serialize_child(%{raw_html: true, expr: expr}), do: %{raw_html: true, expr: expr}

  defp serialize_child(%{component_refs: refs, callsite: callsite} = edge) do
    serialized = %{component_refs: refs, callsite: callsite}

    serialized =
      case Map.get(edge, :slot_children, []) do
        [] ->
          serialized

        slot_children ->
          Map.put(serialized, :slot_children, Enum.map(slot_children, &serialize_child/1))
      end

    case Map.get(edge, :slot_children_by_name, %{}) do
      slots when slots == %{} ->
        serialized

      slots ->
        Map.put(
          serialized,
          :slot_children_by_name,
          Map.new(slots, fn {name, children} -> {name, Enum.map(children, &serialize_child/1)} end)
        )
    end
  end

  defp serialize_class(str) when is_binary(str), do: str

  defp serialize_class({:dynamic, info}) do
    %{dynamic: true, reason: info.reason, expr: info.expr, chain: info.chain}
  end

  defp serialize_class(%{dynamic: true} = info) do
    %{
      dynamic: true,
      reason: Map.get(info, :reason),
      expr: Map.get(info, :expr),
      chain: Map.get(info, :chain)
    }
  end

  defp serialize_class(list) when is_list(list), do: Enum.map(list, &serialize_class/1)

  defp serialize_class_facts(classes) do
    %{
      static: Enum.map(classes.static, &serialize_class/1),
      optional: Enum.map(classes.optional, &serialize_class/1),
      exclusive:
        Enum.map(classes.exclusive, fn group ->
          Enum.map(group, fn option -> Enum.map(option, &serialize_class/1) end)
        end),
      dynamic: Enum.map(classes.dynamic, &serialize_class/1)
    }
  end

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
