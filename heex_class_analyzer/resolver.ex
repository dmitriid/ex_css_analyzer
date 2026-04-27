defmodule Mix.Tasks.HeexClassAnalyzer.Resolver do
  @moduledoc """
  The core orchestrator of the HEEX class analyzer pipeline.

  The Resolver sits between the Registry (which indexes all discovered modules
  and functions) and the Output stage. For each module, it:

  1. Parses HEEX content via `HeexParser` to produce a raw node tree
  2. Analyzes class attributes on each node via `Expression.analyze/1` to
     separate static classes from dynamic variants (toggles, either/or, fn_calls)
  3. Resolves `{:fn_call, ...}` variants by following function definitions
     through the Registry, extracting return values up to a maximum depth of 10
     with cycle detection to avoid infinite loops
  4. Inlines component trees for `.func` (local) and `Module.func` (remote)
     component calls by recursively parsing their HEEX content
  5. Computes all class permutations via `Permutations.compute/2`

  ## Public API

      # Resolve a single module's functions and templates into fully-resolved node trees
      Resolver.resolve_module(module_info, registry)
      #=> [{"render/1", [%Node{...}]}, {"index.html.heex", [%Node{...}]}]

  ## Parameters

  - `module_info` - A `Discovery.module_info()` map containing `:module`, `:functions`,
    and `:heex_templates` fields
  - `registry` - A `Registry.t()` built from all discovered modules, used to look up
    function definitions across module boundaries

  ## Return Value

  Returns a list of `{label, tree}` tuples where:
  - `label` is either `"function_name/arity"` for inline `~H` sigil functions, or
    `"template_name.html.heex"` for embedded templates
  - `tree` is a list of `Node.t()` structs with fully resolved `:static`, `:variants`,
    `:permutations`, and `:children` fields

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

  ## Component Inlining

  Tags like `.my_component` or `SharedComponents.button` trigger component
  inlining:

  - The component's HEEX is parsed and resolved recursively
  - The resulting nodes are appended as children of the calling node
  - A visited-components set (using `MapSet`) prevents infinite recursion
    from mutually-recursive components
  - Max depth of 10 applies to component nesting as well

  ## Interaction with Other Modules

  - `HeexParser` - Parses raw HEEX strings into initial `Node.t()` trees
  - `Expression` - Classifies class attribute values into statics and variants,
    and extracts return values from function ASTs
  - `Registry` - Provides `resolve_local/3` and `resolve_remote/4` to find
    function definitions across module boundaries (handling imports, aliases, uses)
  - `Permutations` - Computes all possible class combinations from statics + variants
  - `Node` - The output data structure holding resolved class information
  """

  alias Mix.Tasks.HeexClassAnalyzer.{Expression, HeexParser, Node, Permutations, Registry}

  @max_depth 10

  @spec resolve_module(map(), Registry.t()) :: [{String.t(), [Node.t()]}]
  def resolve_module(module_info, registry) do
    calling_module = module_info.module

    function_results =
      module_info.functions
      |> Enum.flat_map(fn func_info ->
        heex_list = Map.get(func_info, :heex_clauses, []) |> Enum.reject(&is_nil/1)

        heex_list =
          if heex_list == [] && func_info.heex != nil,
            do: [func_info.heex],
            else: heex_list

        resolve_heex_clauses(heex_list, func_info, calling_module, registry)
      end)

    template_results =
      Enum.map(module_info.heex_templates, fn %{name: name, content: content} ->
        label = "#{name}.html.heex"
        tree = parse_and_resolve(content, calling_module, registry)
        {label, tree}
      end)

    function_results ++ template_results
  end

  defp resolve_heex_clauses(heex_list, func_info, calling_module, registry) do
    heex_list
    |> Enum.with_index()
    |> Enum.map(fn {heex, idx} ->
      label =
        if length(heex_list) > 1,
          do: "#{func_info.name}/#{func_info.arity}##{idx + 1}",
          else: "#{func_info.name}/#{func_info.arity}"

      tree = parse_and_resolve(heex, calling_module, registry)
      {label, tree}
    end)
  end

  # --- Core pipeline ---

  defp parse_and_resolve(heex_string, calling_module, registry) do
    heex_string
    |> HeexParser.parse()
    |> Enum.map(&resolve_node(&1, calling_module, registry, MapSet.new(), 0))
  end

  defp resolve_node(node, calling_module, registry, visited_components, depth) do
    # Step 1: Analyze the class attribute
    {static, variants} = Expression.analyze(node.static)

    # Step 1.5: Stamp chains on direct dynamics (not from fn_call resolution)
    static = stamp_direct_dynamics(static)
    variants = stamp_direct_variant_dynamics(variants)

    # Step 2: Resolve fn_call variants
    {resolved_variants, extra_statics} =
      resolve_fn_call_variants(variants, calling_module, registry, MapSet.new(), 0)

    all_statics = static ++ extra_statics

    # Step 3: Resolve component children (for tags like .func or Module.func)
    component_children =
      resolve_component(node.tag, calling_module, registry, visited_components, depth)

    # Step 4: Recursively resolve existing children
    resolved_children =
      Enum.map(node.children, fn child ->
        resolve_node(child, calling_module, registry, visited_components, depth)
      end)

    all_children = resolved_children ++ component_children

    # Step 5: Compute permutations
    permutations = Permutations.compute(all_statics, resolved_variants)

    %Node{
      tag: node.tag,
      static: all_statics,
      variants: resolved_variants,
      permutations: permutations,
      repeat: node.repeat,
      children: all_children
    }
  end

  # --- Function call variant resolution ---

  defp resolve_fn_call_variants(variants, calling_module, registry, visited_fns, depth) do
    Enum.reduce(variants, {[], []}, fn variant, {var_acc, static_acc} ->
      case variant do
        {:fn_call, fn_ref} ->
          fn_ref
          |> resolve_fn_call(calling_module, registry, visited_fns, depth, [])
          |> merge_resolved({var_acc, static_acc})

        other ->
          {var_acc ++ [other], static_acc}
      end
    end)
  end

  defp merge_resolved({:variants, new_variants}, {var_acc, static_acc}),
    do: {var_acc ++ new_variants, static_acc}

  defp merge_resolved({:statics, new_statics}, {var_acc, static_acc}),
    do: {var_acc, static_acc ++ new_statics}

  defp resolve_fn_call(_fn_ref, _calling_module, _registry, _visited, depth, chain)
       when depth >= @max_depth do
    chain_str = build_chain(chain, "<max depth>")

    {:statics,
     [
       {:dynamic,
        %{reason: "unresolved:max_depth", expr: "max depth #{@max_depth}", chain: chain_str}}
     ]}
  end

  defp resolve_fn_call({func_name, _args}, calling_module, registry, visited, depth, chain)
       when is_atom(func_name) do
    resolve_fn_lookup(
      Registry.resolve_local(registry, calling_module, func_name),
      func_name,
      registry,
      visited,
      depth,
      chain
    )
  end

  defp resolve_fn_call(
         {module, func_name, _args},
         calling_module,
         registry,
         visited,
         depth,
         chain
       )
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

    {:statics,
     [{:dynamic, %{reason: "unresolved:unknown_fn", expr: "#{func_name}", chain: chain_str}}]}
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
    all_returns =
      func_info.clauses
      |> Enum.flat_map(fn clause_body ->
        case Expression.extract_returns(clause_body) do
          {:ok, returns} -> returns
          :unresolved -> [[make_dynamic("unresolved:extract_failed", "unresolved function body")]]
        end
      end)

    {string_values, nested_fn_calls} = partition_returns(all_returns)

    nested_strings =
      Enum.flat_map(nested_fn_calls, fn fn_ref ->
        case resolve_fn_call(fn_ref, resolved_module, registry, visited, depth, chain) do
          {:variants, variants} ->
            collect_strings_from_variants(variants)

          {:statics, statics} ->
            statics
        end
      end)

    all_values = string_values ++ nested_strings

    normalized =
      Enum.map(all_values, fn
        classes when is_list(classes) -> classes
        str when is_binary(str) -> String.split(str, ~r/\s+/, trim: true)
        {:dynamic, _} = d -> [d]
        _ -> [make_dynamic("unknown_expression", "unknown")]
      end)
      |> Enum.reject(&(&1 == []))

    stamped = stamp_chains(normalized, chain)

    case stamped do
      [] ->
        chain_str = build_chain(chain, "<no returns>")

        {:statics,
         [
           {:dynamic,
            %{reason: "unresolved:no_returns", expr: "no extractable returns", chain: chain_str}}
         ]}

      [single] ->
        {:statics, single}

      multiple ->
        {:variants, [{:either, Enum.uniq(multiple)}]}
    end
  end

  defp partition_returns(returns) do
    Enum.reduce(returns, {[], []}, fn item, {strings, fn_calls} ->
      case item do
        {:fn_call, fn_ref} ->
          {strings, [fn_ref | fn_calls]}

        classes when is_list(classes) ->
          partition_class_list(classes, strings, fn_calls)

        str when is_binary(str) ->
          partition_string(str, strings, fn_calls)

        _ ->
          {strings, fn_calls}
      end
    end)
  end

  defp partition_class_list(classes, strings, fn_calls) do
    flat =
      Enum.flat_map(classes, fn
        s when is_binary(s) -> String.split(s, ~r/\s+/, trim: true)
        {:dynamic, _} = d -> [d]
        other -> [make_dynamic("non_string_in_list", inspect(other))]
      end)

    if flat == [] do
      {strings, fn_calls}
    else
      {[flat | strings], fn_calls}
    end
  end

  defp partition_string("", strings, fn_calls), do: {strings, fn_calls}
  defp partition_string(str, strings, fn_calls), do: {[str | strings], fn_calls}

  defp collect_strings_from_variants(variants) do
    Enum.flat_map(variants, fn
      {:either, options} -> options
      {:toggle, class} -> [class]
      _ -> []
    end)
  end

  # --- Component resolution ---

  defp resolve_component(tag, calling_module, registry, visited_components, depth)
       when is_binary(tag) do
    cond do
      # Local component: .func_name
      String.starts_with?(tag, ".") ->
        func_name = tag |> String.trim_leading(".") |> String.to_atom()
        resolve_component_call(calling_module, func_name, registry, visited_components, depth)

      # Remote component: Module.func or Module.Sub.func
      String.contains?(tag, ".") && starts_with_uppercase?(tag) ->
        resolve_remote_component(tag, calling_module, registry, visited_components, depth)

      true ->
        []
    end
  end

  defp resolve_component(_tag, _calling_module, _registry, _visited_components, _depth), do: []

  defp resolve_component_call(calling_module, func_name, registry, visited, depth) do
    if depth >= @max_depth do
      []
    else
      resolve_component_lookup(
        Registry.resolve_local(registry, calling_module, func_name),
        func_name,
        registry,
        visited,
        depth
      )
    end
  end

  defp resolve_remote_component(tag, calling_module, registry, visited, depth) do
    if depth >= @max_depth do
      []
    else
      parts = String.split(tag, ".")
      func_name_str = List.last(parts)
      module_parts = Enum.slice(parts, 0..-2//1)

      func_name = String.to_atom(func_name_str)

      module_atom =
        module_parts
        |> Enum.map(&String.to_atom/1)
        |> Module.concat()

      resolve_component_lookup(
        Registry.resolve_remote(registry, calling_module, module_atom, func_name),
        func_name,
        registry,
        visited,
        depth
      )
    end
  end

  defp resolve_component_lookup(nil, _func_name, _registry, _visited, _depth), do: []

  defp resolve_component_lookup({resolved_module, entry}, func_name, registry, visited, depth) do
    component_key = {resolved_module, func_name}

    if MapSet.member?(visited, component_key) do
      []
    else
      visited = MapSet.put(visited, component_key)
      inline_component(entry.function, resolved_module, registry, visited, depth + 1)
    end
  end

  defp inline_component(func_info, resolved_module, registry, visited, depth) do
    case func_info.heex do
      nil ->
        []

      heex_content ->
        heex_content
        |> HeexParser.parse()
        |> Enum.map(&resolve_node(&1, resolved_module, registry, visited, depth))
    end
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
