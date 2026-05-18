defmodule Mix.Tasks.HeexClassAnalyzer.Resolver do
  @moduledoc """
  The core orchestrator of the HEEX class analyzer pipeline.

  The Resolver sits between the Registry (which indexes all discovered modules
  and functions) and the Output stage. It resolves all discovered HEEX
  functions and templates into a graph:

  1. Parses HEEX content via `HeexParser` to produce a raw node tree
  2. Analyzes class attributes on each node via `Expression.analyze/1` to
     separate static classes from dynamic variants (toggles, either/or, fn_calls)
  3. Resolves `{:fn_call, ...}` variants by following function definitions
     through the Registry, extracting return values up to a maximum depth of 10
     with cycle detection to avoid infinite loops
  4. Emits component refs for `.func` (local) and `Module.func` (remote)
     component calls instead of duplicating component trees at each callsite
  5. Computes compact class facts for downstream selector matching

  ## Public API

      # Resolve all discovered functions and templates into graph version 2
      Resolver.resolve_graph(module_infos, registry)
      #=> %{version: 2, entries: [...], trees: %{...}, cycles: [...], unresolved: [...]}

  ## Parameters

  - `module_infos` - A list of `Discovery.module_info()` maps containing
    `:module`, `:functions`, and `:heex_templates` fields
  - `registry` - A `Registry.t()` built from all discovered modules, used to look up
    function definitions across module boundaries

  ## Return Value

  Returns a graph map where:
  - `:version` is `2`
  - `:entries` lists public analysis roots for functions and templates
  - `:trees` stores each canonical HEEX tree once, keyed by stable ref
  - `:cycles` lists component graph cycles found while resolving
  - `:unresolved` lists component refs that could not be resolved

  ## Function Call Resolution

  When `Expression.analyze/1` produces a `{:fn_call, {func_name, args}}` or
  `{:fn_call, {Module, func_name, args}}` variant, the Resolver attempts to
  follow the function definition:

  1. Looks up the function in the Registry (local, imported, or remote)
  2. Extracts return values from all clauses via `Expression.extract_returns/1`
  3. If a return value is itself a function call, recurses (up to depth 10)
  4. Converts results: a single return becomes static classes, multiple returns
     become an `{:either, [...]}` variant

  If resolution fails (unknown function, max depth reached, or cycle detected),
  the placeholder `"<unresolved>"` is used.

  ## Component Refs

  Tags like `.my_component` or `SharedComponents.button` produce graph edges:

  - The component's HEEX is resolved once into its own canonical tree ref
  - The caller stores `%{component_refs: [...], callsite: %{...}}` in children
  - Cycles are recorded in graph diagnostics instead of inlining recursively
  - CSS coverage later materializes refs as rendered DOM children

  Remote component resolution first uses normal alias metadata. When a
  standalone template has no alias metadata, the Registry can also resolve by
  module suffix if the target module defines the requested component. This lets
  template tags such as `Layouts.admin_content` resolve to
  `MuquiWeb.Layouts.admin_content/1` without hard-coding the web module.

  ## Slots and Raw HTML

  Slot placeholders from `render_slot(@name)` are preserved as graph nodes with
  `slot_name`. CSS coverage binds those placeholders to the caller's slot
  children when materializing component refs, including nested slot passthrough
  from one component into another.

  Non-slot HEEX expressions are normally ignored because they do not define
  class structure. If an expression calls a helper whose discovered return
  clauses call `Phoenix.HTML.raw/1`, the resolver emits a raw HTML placeholder
  instead. CSS coverage can use that placeholder for one immediate descendant
  selector segment under the HEEX parent, which covers Markdown output like
  `.answer p` without claiming arbitrary deep raw HTML selectors.

  ## Interaction with Other Modules

  - `HeexParser` - Parses raw HEEX strings into initial `Node.t()` trees
  - `Expression` - Classifies class attribute values into statics and variants,
    and extracts return values from function ASTs
  - `Registry` - Provides `resolve_local/3` and `resolve_remote/4` to find
    function definitions across module boundaries (handling imports, aliases, uses)
  - `ClassFacts` - Builds compact class facts from statics + variants
  - `Graph` - Builds stable refs and component edge nodes
  - `Node` - The output data structure holding resolved class information
  """

  alias Mix.Tasks.HeexClassAnalyzer.{ClassFacts, Expression, Graph, HeexParser, Node, Registry}

  @max_depth 10

  @spec resolve_graph([map()], Registry.t()) :: map()
  def resolve_graph(module_infos, registry) do
    entries = graph_entries(module_infos)
    state = %{trees: %{}, cycles: [], unresolved: []}

    state =
      Enum.reduce(entries, state, fn entry, acc ->
        {_tree, acc} = ensure_graph_tree(entry, registry, [entry.ref], acc)
        acc
      end)

    %{
      version: 2,
      entries: Enum.map(entries, &Map.drop(&1, [:heex, :calling_module, :assign_facts])),
      trees: state.trees,
      cycles: Enum.reverse(state.cycles) |> Enum.uniq(),
      unresolved: Enum.reverse(state.unresolved) |> Enum.uniq()
    }
  end

  # --- Graph pipeline ---

  defp graph_entries(module_infos) do
    Enum.flat_map(module_infos, fn module_info ->
      graph_function_entries(module_info) ++ graph_template_entries(module_info)
    end)
  end

  defp graph_function_entries(module_info) do
    module_info.functions
    |> Enum.flat_map(fn func_info ->
      func_info
      |> function_heex_clauses()
      |> Enum.with_index()
      |> Enum.map(fn {heex, idx} ->
        ref = Graph.function_ref(module_info.module, func_info.name, func_info.arity, idx)
        assign_facts = func_info |> Map.get(:heex_assign_facts, []) |> Enum.at(idx, %{})

        %{
          ref: ref,
          module: inspect(module_info.module),
          calling_module: module_info.module,
          source_file: module_info.source_file,
          name: "#{func_info.name}/#{func_info.arity}",
          assign_facts: assign_facts,
          heex: heex
        }
      end)
    end)
  end

  defp graph_template_entries(module_info) do
    Enum.map(module_info.heex_templates, fn %{name: name, content: content} ->
      ref = Graph.template_ref(module_info.module || module_info.source_file, name)

      %{
        ref: ref,
        module: inspect(module_info.module),
        calling_module: module_info.module,
        source_file: module_info.source_file,
        name: "#{name}.html.heex",
        assign_facts: %{},
        heex: content
      }
    end)
  end

  defp function_heex_clauses(func_info) do
    heex_list = Map.get(func_info, :heex_clauses, []) |> Enum.reject(&is_nil/1)

    if heex_list == [] && func_info.heex != nil,
      do: [func_info.heex],
      else: heex_list
  end

  defp ensure_graph_tree(%{ref: ref}, _registry, _stack, %{trees: trees} = state) when is_map_key(trees, ref) do
    {Map.fetch!(trees, ref), state}
  end

  defp ensure_graph_tree(
         %{ref: ref, heex: heex, calling_module: calling_module, assign_facts: assign_facts},
         registry,
         stack,
         state
       ) do
    {tree, state} =
      resolve_heex_tree(heex, assign_facts, calling_module, registry, ref, stack, state)

    state = put_in(state, [:trees, ref], tree)
    {tree, state}
  end

  defp ensure_graph_tree_for_function(resolved_module, func_info, clause_index, registry, stack, state) do
    heex =
      func_info
      |> function_heex_clauses()
      |> Enum.at(clause_index)

    ref = Graph.function_ref(resolved_module, func_info.name, func_info.arity, clause_index)
    assign_facts = func_info |> Map.get(:heex_assign_facts, []) |> Enum.at(clause_index, %{})

    ensure_graph_tree(
      %{
        ref: ref,
        module: inspect(resolved_module),
        calling_module: resolved_module,
        source_file: nil,
        name: "#{func_info.name}/#{func_info.arity}",
        assign_facts: assign_facts,
        heex: heex
      },
      registry,
      stack,
      state
    )
  end

  defp resolve_heex_tree(heex_string, assign_facts, calling_module, registry, current_ref, stack, state) do
    heex_string
    |> HeexParser.parse()
    |> resolve_graph_children(assign_facts, calling_module, registry, current_ref, stack, state)
  end

  defp resolve_graph_children(children, assign_facts, calling_module, registry, current_ref, stack, state) do
    Enum.reduce(children, {[], state}, fn child, {children_acc, acc} ->
      {resolved_child, acc} =
        resolve_graph_child(
          child,
          assign_facts,
          calling_module,
          registry,
          current_ref,
          stack,
          acc
        )

      children_acc =
        case resolved_child do
          nil ->
            children_acc

          resolved_children when is_list(resolved_children) ->
            Enum.reverse(resolved_children, children_acc)

          resolved_child ->
            [resolved_child | children_acc]
        end

      {children_acc, acc}
    end)
    |> then(fn {children_acc, acc} -> {Enum.reverse(children_acc), acc} end)
  end

  defp resolve_graph_child(
         %Node{tag: ":" <> _slot_name} = node,
         assign_facts,
         calling_module,
         registry,
         current_ref,
         stack,
         state
       ) do
    resolve_transparent_children(
      node,
      assign_facts,
      calling_module,
      registry,
      current_ref,
      stack,
      state
    )
  end

  defp resolve_graph_child(
         %Node{tag: "__slot__:" <> slot_name},
         _assign_facts,
         _calling_module,
         _registry,
         _current_ref,
         _stack,
         state
       ) do
    {%{slot_name: slot_name}, state}
  end

  defp resolve_graph_child(
         %Node{tag: "__expr__:" <> encoded_expr},
         _assign_facts,
         calling_module,
         registry,
         _current_ref,
         _stack,
         state
       ) do
    with {:ok, expr} <- Base.url_decode64(encoded_expr, padding: false),
         true <- raw_html_expression?(expr, calling_module, registry) do
      {%{raw_html: true, expr: expr}, state}
    else
      _ -> {nil, state}
    end
  end

  defp resolve_graph_child(%Node{tag: tag} = node, assign_facts, calling_module, registry, current_ref, stack, state)
       when is_binary(tag) do
    case phoenix_builtin_component_tag(tag) do
      nil ->
        resolve_graph_component_child(
          node,
          assign_facts,
          calling_module,
          registry,
          current_ref,
          stack,
          state
        )

      html_tag ->
        resolve_graph_node(
          %{node | tag: html_tag},
          assign_facts,
          calling_module,
          registry,
          current_ref,
          stack,
          state
        )
    end
  end

  defp resolve_graph_child(node, assign_facts, calling_module, registry, current_ref, stack, state) do
    resolve_graph_node(node, assign_facts, calling_module, registry, current_ref, stack, state)
  end

  defp resolve_graph_component_child(node, assign_facts, calling_module, registry, current_ref, stack, state) do
    case component_edge_for_tag(node.tag, calling_module, registry, current_ref, stack, state) do
      {nil, state} ->
        resolve_graph_node(
          node,
          assign_facts,
          calling_module,
          registry,
          current_ref,
          stack,
          state
        )

      {:unresolved, state} ->
        resolve_transparent_children(
          node,
          assign_facts,
          calling_module,
          registry,
          current_ref,
          stack,
          state
        )

      {edge, state} ->
        resolve_component_call_node(
          node,
          edge,
          assign_facts,
          calling_module,
          registry,
          current_ref,
          stack,
          state
        )
    end
  end

  defp phoenix_builtin_component_tag(".link"), do: "a"
  defp phoenix_builtin_component_tag(_tag), do: nil

  defp resolve_transparent_children(node, assign_facts, calling_module, registry, current_ref, stack, state) do
    resolve_graph_children(
      node.children,
      assign_facts,
      calling_module,
      registry,
      current_ref,
      stack,
      state
    )
  end

  defp resolve_component_call_node(node, edge, assign_facts, calling_module, registry, current_ref, stack, state) do
    {resolved_slots, state} =
      resolve_component_slot_children(
        node.children,
        assign_facts,
        calling_module,
        registry,
        current_ref,
        stack,
        state
      )

    slot_edge = maybe_put_slot_children(edge, resolved_slots)

    if class_source?(node.static) do
      {static, variants} = Expression.analyze(node.static)

      static = stamp_direct_dynamics(static)
      variants = stamp_direct_variant_dynamics(variants)

      {resolved_variants, extra_statics} =
        resolve_class_variants(variants, assign_facts, calling_module, registry, MapSet.new(), 0)

      all_statics = static ++ extra_statics
      classes = ClassFacts.from_static_and_variants(all_statics, resolved_variants)

      {%Node{
         tag: node.tag,
         static: all_statics,
         variants: resolved_variants,
         classes: classes,
         repeat: node.repeat,
         children: [slot_edge]
       }, state}
    else
      {slot_edge, state}
    end
  end

  defp resolve_component_slot_children(children, assign_facts, calling_module, registry, current_ref, stack, state) do
    {slots, state} =
      Enum.reduce(children, {%{}, state}, fn child, {slots_acc, acc} ->
        {slot_name, slot_nodes} = component_slot_node(child)

        {resolved_children, acc} =
          resolve_graph_children(
            slot_nodes,
            assign_facts,
            calling_module,
            registry,
            current_ref,
            stack,
            acc
          )

        slots_acc =
          Map.update(slots_acc, slot_name, resolved_children, &(&1 ++ resolved_children))

        {slots_acc, acc}
      end)

    {slots, state}
  end

  defp component_slot_node(%Node{tag: ":" <> slot_name, children: children}), do: {slot_name, children}

  defp component_slot_node(node), do: {"inner_block", [node]}

  defp maybe_put_slot_children(edge, slots) when map_size(slots) == 0, do: edge

  defp maybe_put_slot_children(edge, %{"inner_block" => slot_children} = slots) when map_size(slots) == 1 do
    edge
    |> Map.put(:slot_children, slot_children)
    |> Map.put(:slot_children_by_name, slots)
  end

  defp maybe_put_slot_children(edge, slots), do: Map.put(edge, :slot_children_by_name, slots)

  defp class_source?([]), do: false
  defp class_source?(nil), do: false
  defp class_source?(source) when is_binary(source), do: String.trim(source) != ""
  defp class_source?(_source), do: true

  defp raw_html_expression?(expr, calling_module, registry) do
    if raw_html_call_candidate?(expr) do
      case Code.string_to_quoted(expr, emit_warnings: false) do
        {:ok, ast} -> raw_html_ast?(ast, calling_module, registry)
        {:error, _error} -> false
      end
    else
      false
    end
  end

  defp raw_html_call_candidate?(expr) do
    String.match?(expr, ~r/^\s*(?:[A-Z]\w*(?:\.[A-Z]\w*)*\.)?[a-z_]\w*[!?]?\s*\(/)
  end

  defp raw_html_ast?({{:., _, [{:__aliases__, _, mod_parts}, func_name]}, _, args}, calling_module, registry)
       when is_atom(func_name) and is_list(args) do
    case Registry.resolve_remote(registry, calling_module, Module.concat(mod_parts), func_name) do
      {_module, entry} -> function_returns_phoenix_raw?(entry.function)
      nil -> false
    end
  end

  defp raw_html_ast?({func_name, _, args}, calling_module, registry)
       when is_atom(func_name) and is_list(args) and func_name not in [:@, :^] do
    case Registry.resolve_local(registry, calling_module, func_name) do
      {_module, entry} -> function_returns_phoenix_raw?(entry.function)
      nil -> false
    end
  end

  defp raw_html_ast?(_ast, _calling_module, _registry), do: false

  defp function_returns_phoenix_raw?(func_info) do
    Enum.any?(func_info.clauses || [], &contains_phoenix_raw_call?/1)
  end

  defp contains_phoenix_raw_call?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Phoenix, :HTML]}, :raw]}, _, _} = node, _acc ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp resolve_graph_node(node, assign_facts, calling_module, registry, current_ref, stack, state) do
    {static, variants} = Expression.analyze(node.static)

    static = stamp_direct_dynamics(static)
    variants = stamp_direct_variant_dynamics(variants)

    {resolved_variants, extra_statics} =
      resolve_class_variants(variants, assign_facts, calling_module, registry, MapSet.new(), 0)

    all_statics = static ++ extra_statics

    {resolved_children, state} =
      resolve_graph_children(
        node.children,
        assign_facts,
        calling_module,
        registry,
        current_ref,
        stack,
        state
      )

    classes = ClassFacts.from_static_and_variants(all_statics, resolved_variants)

    {%Node{
       tag: node.tag,
       static: all_statics,
       variants: resolved_variants,
       classes: classes,
       repeat: node.repeat,
       children: resolved_children
     }, state}
  end

  defp component_edge_for_tag("." <> func_name_str = tag, calling_module, registry, current_ref, stack, state) do
    func_name = String.to_atom(func_name_str)

    registry
    |> Registry.resolve_local(calling_module, func_name)
    |> component_edge_from_lookup(tag, current_ref, registry, stack, state)
  end

  defp component_edge_for_tag(tag, calling_module, registry, current_ref, stack, state) when is_binary(tag) do
    if String.contains?(tag, ".") && starts_with_uppercase?(tag) do
      parts = String.split(tag, ".")
      func_name = parts |> List.last() |> String.to_atom()

      modules = remote_component_modules(Enum.slice(parts, 0..-2//1))

      lookup =
        Enum.find_value(
          modules,
          &Registry.resolve_remote(registry, calling_module, &1, func_name)
        )

      component_edge_from_lookup(lookup, tag, current_ref, registry, stack, state)
    else
      {nil, state}
    end
  end

  defp component_edge_for_tag(_tag, _calling_module, _registry, _current_ref, _stack, state), do: {nil, state}

  defp remote_component_modules([short_name]) do
    short_atom = String.to_atom(short_name)
    [short_atom, Module.concat([short_atom])] |> Enum.uniq()
  end

  defp remote_component_modules(module_parts), do: [Module.concat(module_parts)]

  defp component_edge_from_lookup(nil, tag, current_ref, _registry, _stack, state) do
    unresolved = %{type: "component", tag: tag, from: current_ref, reason: "unresolved"}
    {:unresolved, update_in(state.unresolved, &[unresolved | &1])}
  end

  defp component_edge_from_lookup({resolved_module, entry}, tag, current_ref, registry, stack, state) do
    refs =
      entry.function
      |> function_heex_clauses()
      |> Enum.with_index()
      |> Enum.map(fn {_heex, idx} ->
        Graph.function_ref(resolved_module, entry.function.name, entry.function.arity, idx)
      end)

    state =
      refs
      |> Enum.with_index()
      |> Enum.reduce(state, fn {target_ref, clause_index}, acc ->
        if target_ref in stack do
          cycle = %{type: "component", path: Enum.reverse([target_ref | stack])}
          update_in(acc.cycles, &[cycle | &1])
        else
          {_tree, acc} =
            ensure_graph_tree_for_function(
              resolved_module,
              entry.function,
              clause_index,
              registry,
              [target_ref | stack],
              acc
            )

          acc
        end
      end)

    {Graph.component_edge(refs, tag, current_ref), state}
  end

  # --- Function call variant resolution ---

  defp resolve_class_variants(variants, assign_facts, calling_module, registry, visited_fns, depth) do
    Enum.reduce(variants, {[], []}, fn variant, {var_acc, static_acc} ->
      case variant do
        {:assign_ref, name} ->
          name
          |> resolve_assign_ref(assign_facts, calling_module, registry, visited_fns, depth)
          |> merge_resolved({var_acc, static_acc})

        {:fn_call, fn_ref} ->
          fn_ref
          |> resolve_fn_call(calling_module, registry, visited_fns, depth, [])
          |> merge_resolved({var_acc, static_acc})

        other ->
          {var_acc ++ [other], static_acc}
      end
    end)
  end

  defp resolve_assign_ref(name, assign_facts, calling_module, registry, visited_fns, depth) do
    case Map.fetch(assign_facts, name) do
      {:ok, expr_ast} ->
        assign_expr_to_resolution(expr_ast, calling_module, registry, visited_fns, depth)

      :error ->
        {:statics,
         [
           {:dynamic, %{reason: "unresolved:assign_ref", expr: "@#{name}", chain: "@#{name}"}}
         ]}
    end
  end

  defp assign_expr_to_resolution(str, _calling_module, _registry, _visited_fns, _depth) when is_binary(str) do
    {:statics, String.split(str, ~r/\s+/, trim: true)}
  end

  defp assign_expr_to_resolution(nil, _calling_module, _registry, _visited_fns, _depth), do: {:statics, []}

  defp assign_expr_to_resolution({func_name, _meta, args}, calling_module, registry, visited_fns, depth)
       when is_atom(func_name) and is_list(args) and func_name not in [:@, :^] do
    resolve_fn_call({func_name, args}, calling_module, registry, visited_fns, depth, [])
  end

  defp assign_expr_to_resolution(
         {{:., _, [{:__aliases__, _, mod_parts}, func_name]}, _meta, args},
         calling_module,
         registry,
         visited_fns,
         depth
       )
       when is_atom(func_name) and is_list(args) do
    resolve_fn_call(
      {Module.concat(mod_parts), func_name, args},
      calling_module,
      registry,
      visited_fns,
      depth,
      []
    )
  end

  defp assign_expr_to_resolution(ast, _calling_module, _registry, _visited_fns, _depth) do
    expr = Macro.to_string(ast)
    {:statics, [{:dynamic, %{reason: "unresolved:assign_expr", expr: expr, chain: expr}}]}
  end

  defp merge_resolved({:variants, new_variants}, {var_acc, static_acc}), do: {var_acc ++ new_variants, static_acc}

  defp merge_resolved({:statics, new_statics}, {var_acc, static_acc}), do: {var_acc, static_acc ++ new_statics}

  defp resolve_fn_call(_fn_ref, _calling_module, _registry, _visited, depth, chain) when depth >= @max_depth do
    chain_str = build_chain(chain, "<max depth>")

    {:statics,
     [
       {:dynamic, %{reason: "unresolved:max_depth", expr: "max depth #{@max_depth}", chain: chain_str}}
     ]}
  end

  defp resolve_fn_call({func_name, _args}, calling_module, registry, visited, depth, chain) when is_atom(func_name) do
    resolve_fn_lookup(
      Registry.resolve_local(registry, calling_module, func_name),
      func_name,
      registry,
      visited,
      depth,
      chain
    )
  end

  defp resolve_fn_call({module, func_name, _args}, calling_module, registry, visited, depth, chain)
       when is_atom(module) and is_atom(func_name) do
    resolve_fn_lookup(
      Registry.resolve_remote(registry, calling_module, module, func_name),
      func_name,
      registry,
      visited,
      depth,
      chain
    )
  end

  defp resolve_fn_call(other, _calling_module, _registry, _visited, _depth, chain) do
    expr = inspect(other)
    chain_str = build_chain(chain, expr)
    {:statics, [{:dynamic, %{reason: "unresolved:unknown_ref", expr: expr, chain: chain_str}}]}
  end

  defp resolve_fn_lookup(nil, func_name, _registry, _visited, _depth, chain) do
    chain_str = build_chain(chain, "#{func_name} (unknown)")

    {:statics, [{:dynamic, %{reason: "unresolved:unknown_fn", expr: "#{func_name}", chain: chain_str}}]}
  end

  defp resolve_fn_lookup({resolved_module, entry}, func_name, registry, visited, depth, chain) do
    mfa_key = {resolved_module, func_name, entry.function.arity}

    if MapSet.member?(visited, mfa_key) do
      chain_str = build_chain(chain, "#{func_name}/#{entry.function.arity} (cycle)")

      {:statics,
       [
         {:dynamic,
          %{
            reason: "unresolved:cycle",
            expr: "#{func_name}/#{entry.function.arity}",
            chain: chain_str
          }}
       ]}
    else
      visited = MapSet.put(visited, mfa_key)
      segment = "#{func_name}/#{entry.function.arity}"

      extract_fn_returns(
        entry.function,
        resolved_module,
        registry,
        visited,
        depth + 1,
        chain ++ [segment]
      )
    end
  end

  defp extract_fn_returns(func_info, resolved_module, registry, visited, depth, chain) do
    all_returns = extract_clause_returns(func_info.clauses)

    {string_values, nested_fn_calls, has_empty_return?} = partition_returns(all_returns)

    nested_strings =
      resolve_nested_fn_call_returns(
        nested_fn_calls,
        resolved_module,
        registry,
        visited,
        depth,
        chain
      )

    all_values = string_values ++ nested_strings

    {empty_values, non_empty_values} =
      all_values
      |> Enum.map(&normalize_return_value/1)
      |> Enum.split_with(&(&1 == []))

    has_empty_return? = has_empty_return? or empty_values != []
    stamped = stamp_chains(non_empty_values, chain)

    class_return_resolution(stamped, has_empty_return?, chain)
  end

  defp extract_clause_returns(clauses) do
    Enum.flat_map(clauses, fn clause_body ->
      case Expression.extract_returns(clause_body) do
        {:ok, returns} -> returns
        :unresolved -> [[make_dynamic("unresolved:extract_failed", "unresolved function body")]]
      end
    end)
  end

  defp resolve_nested_fn_call_returns(nested_fn_calls, resolved_module, registry, visited, depth, chain) do
    Enum.flat_map(nested_fn_calls, fn fn_ref ->
      case resolve_fn_call(fn_ref, resolved_module, registry, visited, depth, chain) do
        {:variants, variants} -> collect_strings_from_variants(variants)
        {:statics, statics} -> statics
      end
    end)
  end

  defp normalize_return_value(classes) when is_list(classes), do: classes
  defp normalize_return_value(str) when is_binary(str), do: String.split(str, ~r/\s+/, trim: true)
  defp normalize_return_value({:dynamic, _} = dynamic), do: [dynamic]
  defp normalize_return_value(_other), do: [make_dynamic("unknown_expression", "unknown")]

  defp class_return_resolution(stamped, has_empty_return?, chain) do
    case {stamped, has_empty_return?} do
      {[], true} ->
        {:statics, []}

      {[], false} ->
        chain_str = build_chain(chain, "<no returns>")

        {:statics,
         [
           {:dynamic, %{reason: "unresolved:no_returns", expr: "no extractable returns", chain: chain_str}}
         ]}

      {[single], true} ->
        {:variants, [{:toggle, class_list_to_class_value(single)}]}

      {[single], false} ->
        {:statics, single}

      {multiple, _has_empty_return?} ->
        {:variants, [{:either, Enum.uniq(multiple)}]}
    end
  end

  defp partition_returns(returns) do
    Enum.reduce(returns, {[], [], false}, fn item, {strings, fn_calls, has_empty_return?} ->
      case item do
        {:fn_call, fn_ref} ->
          {strings, fn_calls ++ [fn_ref], has_empty_return?}

        classes when is_list(classes) ->
          partition_class_list(classes, strings, fn_calls, has_empty_return?)

        str when is_binary(str) ->
          partition_string(str, strings, fn_calls, has_empty_return?)

        _ ->
          {strings, fn_calls, has_empty_return?}
      end
    end)
  end

  defp partition_class_list(classes, strings, fn_calls, has_empty_return?) do
    flat =
      Enum.flat_map(classes, fn
        s when is_binary(s) -> String.split(s, ~r/\s+/, trim: true)
        {:dynamic, _} = d -> [d]
        other -> [make_dynamic("non_string_in_list", inspect(other))]
      end)

    if flat == [] do
      {strings, fn_calls, true}
    else
      {strings ++ [flat], fn_calls, has_empty_return?}
    end
  end

  defp partition_string("", strings, fn_calls, _has_empty_return?), do: {strings, fn_calls, true}

  defp partition_string(str, strings, fn_calls, has_empty_return?), do: {strings ++ [str], fn_calls, has_empty_return?}

  defp class_list_to_class_value(classes) do
    if Enum.all?(classes, &is_binary/1) do
      Enum.join(classes, " ")
    else
      classes
    end
  end

  defp collect_strings_from_variants(variants) do
    Enum.flat_map(variants, fn
      {:either, options} -> options
      {:toggle, class} -> [class]
      _ -> []
    end)
  end

  # --- Dynamic chain helpers ---

  defp make_dynamic(reason, expr), do: {:dynamic, %{reason: reason, expr: expr}}

  defp build_chain(chain, final) do
    (chain ++ [final]) |> Enum.join(" → ")
  end

  defp stamp_chains(normalized, chain) do
    Enum.map(normalized, fn classes ->
      Enum.map(classes, fn
        {:dynamic, info} ->
          chain_str = build_chain(chain, info.expr)
          {:dynamic, Map.put(info, :chain, chain_str)}

        other ->
          other
      end)
    end)
  end

  defp stamp_direct_dynamics(items) do
    Enum.map(items, fn
      {:dynamic, info} -> {:dynamic, Map.put(info, :chain, info.expr)}
      other -> other
    end)
  end

  defp stamp_direct_variant_dynamics(variants) do
    Enum.map(variants, fn
      {:either, options} ->
        {:either,
         Enum.map(options, fn
           {:dynamic, info} -> {:dynamic, Map.put(info, :chain, info.expr)}
           other -> other
         end)}

      other ->
        other
    end)
  end

  # --- Helpers ---

  defp starts_with_uppercase?(<<c, _rest::binary>>) when c in ?A..?Z, do: true
  defp starts_with_uppercase?(_), do: false
end
