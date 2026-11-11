defmodule Mix.Tasks.HeexClassAnalyzer.Registry do
  @moduledoc """
  Makes an index of all discovered modules and functions for the expression
  resolution. The index supports these lookups:

  - Exact lookup by module, function, and arity (MFA)
  - Local calls, through the import and `use` chains
  - Remote calls, after alias expansion

  Registry is in the middle of the analyzer stages:

      Discovery -> HeexParser -> Expression -> **Registry** -> Resolver -> ClassFacts -> Output

  ## Purpose

  Discovery collects the module data. From this data, the Registry makes an
  index. With the index, the Resolver finds the definition of each function
  call in a class expression. HEEX templates contain local calls, for example
  `classes(assigns)`. They also contain remote calls, for example
  `Components.button_classes()`. Static analysis must find the definitions
  of both types of call.

  ## Public API

  ### `build(module_infos)`

  Makes a registry from a list of `Discovery.module_info()` maps.

      iex> registry = Registry.build(Discovery.discover("/path/to/project"))
      %{by_mfa: %{...}, by_name: %{...}, modules: %{...}}

  ### `lookup(registry, module, func_name, arity)`

  Finds a function by exact MFA. Returns the function entry map or `nil`.

      iex> Registry.lookup(registry, MyAppWeb.Components, :button_class, 1)
      %{function: %{name: :button_class, arity: 1, ...}, module: MyAppWeb.Components, module_info: %{...}}

  ### `resolve_local(registry, calling_module, func_name)`

  Finds the definition of a local call without a module name in
  `calling_module`. The search order:

  1. Functions in `calling_module`
  2. Functions in the modules that `calling_module` imports
  3. Functions in the modules from `use`, with the imports that `use` adds.
     For example, `use Phoenix.LiveView` adds `Phoenix.Component`.
  4. Global fallback: a module in the registry with a function of that name

  Returns `{module, entry}` or `nil`.

      iex> Registry.resolve_local(registry, MyAppWeb.PageLive, :class_list)
      {MyAppWeb.Helpers, %{function: ..., module: MyAppWeb.Helpers, ...}}

  ### `resolve_remote(registry, calling_module, target_module, func_name)`

  Finds the definition of a remote call, for example `Components.card_class(...)`.
  Before the lookup, expands `target_module` with the alias map of `calling_module`.

  Returns `{module, entry}` or `nil`.

      iex> Registry.resolve_remote(registry, MyAppWeb.PageLive, :Components, :card_class)
      {MyAppWeb.Components, %{function: ..., ...}}

  ### `get_module(registry, module)`

  Returns the full `Discovery.module_info()` for a module, or `nil`.

      iex> Registry.get_module(registry, MyAppWeb.PageLive)
      %{module: MyAppWeb.PageLive, imports: [...], aliases: %{...}, ...}

  ## Data structures

  ### Registry (`t()`)

  | Field      | Type                                              | Description                                          |
  |------------|---------------------------------------------------|------------------------------------------------------|
  | `by_mfa`   | `%{{atom(), atom(), non_neg_integer()} => map()}`| Index by exact `{module, function, arity}` tuple     |
  | `by_name`  | `%{atom() => [map()]}`                           | Index by function name (for global fallback search)  |
  | `modules`  | `%{atom() => Discovery.module_info()}`           | Full module metadata by module name                  |

  ### Function entry map (values in `by_mfa` and `by_name`)

  | Field         | Type                       | Description                                   |
  |---------------|----------------------------|-----------------------------------------------|
  | `function`    | `Discovery.function_info()`| The function's metadata (name, arity, body, heex, clauses) |
  | `module`      | `atom()`                   | The module that defines this function         |
  | `module_info` | `Discovery.module_info()`  | Full metadata of the defining module          |

  ## Resolution rules

  ### Order for local calls

  The four steps follow the order that Elixir uses at compile time:

  1. Own module. Definitions in the calling module come first.
  2. Imports. The registry looks in the imported modules next.
  3. Modules from `use`. A `use` call can add imports. The registry adds
     `import Phoenix.Component` for `use Phoenix.LiveView` and for
     `use MyAppWeb, :html`.
  4. Global fallback. If the first three steps find nothing, the registry
     looks in all modules. Static analysis does not always find the full
     import chain.

  ### Arity

  If a function has several arities, the registry selects arity 1. Phoenix
  components accept one `assigns` argument.

  ### Alias expansion

  Remote calls use the short alias name, for example `Components.foo()`.
  Before the lookup, the registry expands the name with the alias map of
  the calling module. If no alias matches, the registry uses the atom as a
  full module name.

  ## Special cases

  - Files without `defmodule`. The `modules` map does not contain these
    files. Their functions are in `by_mfa` and `by_name` with a `nil`
    module key.
  - No match. If `resolve_local/3` finds no function, it returns `nil` and
    does not raise. The Resolver handles the unresolved call.
  - Several modules with the same function name. The global fallback in
    `resolve_local/3` returns the first registered entry for that name.
    The order of the entries is not defined.

  ## Related modules

  - `Mix.Tasks.HeexClassAnalyzer.Discovery`. `discover/1` supplies the
    input of `build/1`.
  - Resolver. Uses the registry to find the definitions of function calls.
    After that, it reads the class values from the function bodies.
  """

  alias Mix.Tasks.HeexClassAnalyzer.Discovery

  @type t :: %{
          by_mfa: %{{atom(), atom(), non_neg_integer()} => map()},
          by_name: %{atom() => [map()]},
          modules: %{atom() => Discovery.module_info()}
        }

  @spec build([Discovery.module_info()]) :: t()
  def build(module_infos) do
    registry = %{by_mfa: %{}, by_name: %{}, modules: %{}}

    Enum.reduce(module_infos, registry, fn module_info, acc ->
      acc = register_module(acc, module_info)
      register_functions(acc, module_info)
    end)
  end

  @spec lookup(t(), atom(), atom(), non_neg_integer()) :: map() | nil
  def lookup(registry, module, func_name, arity) do
    Map.get(registry.by_mfa, {module, func_name, arity})
  end

  @spec resolve_local(t(), atom(), atom()) :: {atom(), map()} | nil
  def resolve_local(registry, calling_module, func_name) do
    # 1. Functions defined in the calling module itself
    case find_in_module(registry, calling_module, func_name) do
      {_mod, _info} = result -> result
      nil -> resolve_local_imported(registry, calling_module, func_name)
    end
  end

  @spec resolve_remote(t(), atom(), atom(), atom()) :: {atom(), map()} | nil
  def resolve_remote(registry, calling_module, target_module, func_name) do
    # Resolve aliases: if target_module is an alias in the calling module, expand it
    resolved_module = resolve_alias(registry, calling_module, target_module)

    # Look up the function in the resolved module (try any arity, prefer arity 1)
    case find_in_module(registry, resolved_module, func_name) do
      {_mod, _info} = result -> result
      nil -> find_in_module_by_suffix(registry, resolved_module, func_name)
    end
  end

  @spec get_module(t(), atom()) :: Discovery.module_info() | nil
  def get_module(registry, module) do
    Map.get(registry.modules, module)
  end

  # --- Private ---

  defp register_module(registry, %{module: nil}), do: registry

  defp register_module(registry, %{module: module} = module_info) do
    put_in(registry, [:modules, module], module_info)
  end

  defp register_functions(registry, %{module: module} = module_info) do
    Enum.reduce(module_info.functions, registry, fn func_info, acc ->
      entry = %{
        function: func_info,
        module: module,
        module_info: module_info
      }

      acc = put_mfa(acc, module, func_info.name, func_info.arity, entry)
      put_by_name(acc, func_info.name, entry)
    end)
  end

  defp put_mfa(registry, module, name, arity, entry) do
    put_in(registry, [:by_mfa, {module, name, arity}], entry)
  end

  defp put_by_name(registry, name, entry) do
    update_in(registry, [:by_name, name], fn
      nil -> [entry]
      existing -> [entry | existing]
    end)
  end

  defp find_in_module(registry, module, func_name) do
    # Search by_mfa for any arity matching the module and function name.
    # Prefer arity 1 (component convention: assigns argument).
    entries =
      registry.by_mfa
      |> Enum.filter(fn {{mod, name, _arity}, _entry} ->
        mod == module && name == func_name
      end)
      |> Enum.map(fn {_key, entry} -> entry end)

    case entries do
      [] ->
        nil

      entries ->
        # Prefer arity 1 (typical for Phoenix components)
        preferred =
          Enum.find(entries, List.first(entries), fn entry ->
            entry.function.arity == 1
          end)

        {preferred.module, preferred}
    end
  end

  defp resolve_local_imported(registry, calling_module, func_name) do
    # 2. Functions in modules imported by the calling module
    module_info = get_module(registry, calling_module)
    imports = if module_info, do: module_info.imports, else: []

    case find_in_imported_modules(registry, imports, func_name) do
      {_mod, _info} = result ->
        result

      nil ->
        # 3. Functions in modules brought in via `use` (for example, Phoenix.Component)
        uses = if module_info, do: module_info.uses, else: []

        case find_in_used_modules(registry, uses, func_name) do
          {_mod, _info} = result ->
            result

          nil ->
            # 4. Fall back to any module that defines this function
            find_by_name_fallback(registry, func_name)
        end
    end
  end

  defp find_in_imported_modules(_registry, [], _func_name), do: nil

  defp find_in_imported_modules(registry, [import_module | rest], func_name) do
    case find_in_module(registry, import_module, func_name) do
      {_mod, _info} = result -> result
      nil -> find_in_imported_modules(registry, rest, func_name)
    end
  end

  defp find_in_used_modules(_registry, [], _func_name), do: nil

  defp find_in_used_modules(registry, [used_module | rest], func_name) do
    # When a module uses Phoenix.Component, it effectively imports it.
    # Also check if the used module itself defines the function.
    case find_in_module(registry, used_module, func_name) do
      {_mod, _info} = result ->
        result

      nil ->
        # Phoenix.Component is commonly imported via use Phoenix.Component
        # or use RsvpWeb, :html / :live_view etc.
        implied_imports = implied_imports_for_use(used_module)

        case find_in_imported_modules(registry, implied_imports, func_name) do
          {_mod, _info} = result -> result
          nil -> find_in_used_modules(registry, rest, func_name)
        end
    end
  end

  defp implied_imports_for_use(Phoenix.Component), do: [Phoenix.Component]
  defp implied_imports_for_use(Phoenix.LiveView), do: [Phoenix.Component, Phoenix.LiveView]

  defp implied_imports_for_use(module) do
    module_str = to_string(module)

    # use RsvpWeb, :html or :live_view typically imports Phoenix.Component
    if String.ends_with?(module_str, "Web") do
      [Phoenix.Component]
    else
      []
    end
  end

  defp find_by_name_fallback(registry, func_name) do
    case Map.get(registry.by_name, func_name) do
      nil -> nil
      [] -> nil
      [entry | _] -> {entry.module, entry}
    end
  end

  defp find_in_module_by_suffix(registry, target_module, func_name) do
    target_suffix = module_suffix_parts(target_module)
    suffix_length = length(target_suffix)

    registry.modules
    |> Map.keys()
    |> Enum.filter(fn module ->
      Enum.take(Module.split(module), -suffix_length) == target_suffix
    end)
    |> Enum.find_value(&find_in_module(registry, &1, func_name))
  end

  defp module_suffix_parts(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
    |> String.split(".", trim: true)
  end

  defp resolve_alias(registry, calling_module, target_module) do
    module_info = get_module(registry, calling_module)

    if module_info do
      # target_module can be a short alias atom like :Components
      # We need to check if it matches any alias key
      Map.get(module_info.aliases, target_module, target_module)
    else
      target_module
    end
  end
end
