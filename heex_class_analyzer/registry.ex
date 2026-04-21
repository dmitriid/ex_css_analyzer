defmodule Mix.Tasks.HeexClassAnalyzer.Registry do
  @moduledoc """
  Indexes all discovered modules and functions for fast lookup during expression
  resolution. Supports exact MFA (module/function/arity) lookup, local function
  resolution with import/use chain traversal, and remote function resolution with
  alias expansion.

  This module sits in the middle of the analyzer pipeline:

      Discovery -> HeexParser -> Expression -> **Registry** -> Resolver -> Permutations -> Output

  ## Purpose

  After Discovery has extracted all module metadata, the Registry builds a
  searchable index so the Resolver can quickly find function definitions when it
  encounters function calls in class expressions. This is essential because HEEX
  templates use both local calls (e.g. `classes(assigns)`) and remote calls
  (e.g. `Components.button_classes()`) that need to be traced back to their
  definitions for static analysis.

  ## Public API

  ### `build(module_infos)`

  Constructs a registry from a list of `Discovery.module_info()` maps.

      iex> registry = Registry.build(Discovery.discover("/path/to/project"))
      %{by_mfa: %{...}, by_name: %{...}, modules: %{...}}

  ### `lookup(registry, module, func_name, arity)`

  Exact MFA lookup. Returns the function entry map or `nil`.

      iex> Registry.lookup(registry, MyAppWeb.Components, :button_class, 1)
      %{function: %{name: :button_class, arity: 1, ...}, module: MyAppWeb.Components, module_info: %{...}}

  ### `resolve_local(registry, calling_module, func_name)`

  Resolves a local (unqualified) function call from the perspective of
  `calling_module`. Searches in this order:

  1. Functions defined in `calling_module` itself
  2. Functions in modules imported by `calling_module`
  3. Functions in modules brought in via `use` (including implied imports like
     `Phoenix.Component` from `use Phoenix.LiveView`)
  4. Global fallback: any module in the registry that defines a function with
     that name

  Returns `{module, entry}` or `nil`.

      iex> Registry.resolve_local(registry, MyAppWeb.PageLive, :class_list)
      {MyAppWeb.Helpers, %{function: ..., module: MyAppWeb.Helpers, ...}}

  ### `resolve_remote(registry, calling_module, target_module, func_name)`

  Resolves a remote (qualified) function call like `Components.card_class(...)`.
  Expands `target_module` using the alias map of `calling_module` before lookup.

  Returns `{module, entry}` or `nil`.

      iex> Registry.resolve_remote(registry, MyAppWeb.PageLive, :Components, :card_class)
      {MyAppWeb.Components, %{function: ..., ...}}

  ### `get_module(registry, module)`

  Returns the full `Discovery.module_info()` for a module, or `nil`.

      iex> Registry.get_module(registry, MyAppWeb.PageLive)
      %{module: MyAppWeb.PageLive, imports: [...], aliases: %{...}, ...}

  ## Key Data Structures

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

  ## Resolution Strategy Details

  ### Local Resolution Order

  The four-step resolution mimics how Elixir resolves function calls at compile time:

  1. **Own module** - direct definitions take highest priority.
  2. **Imports** - explicitly imported modules are checked next.
  3. **Use'd modules** - modules brought in via `use` may imply additional imports.
     The registry knows that `use Phoenix.LiveView` implies `import Phoenix.Component`,
     and that `use MyAppWeb, :html` implies `import Phoenix.Component`.
  4. **Global fallback** - if all else fails, search any registered module. This
     handles cases where the import chain is incomplete in static analysis.

  ### Arity Preference

  When multiple arities exist for a function, arity 1 is preferred. This matches
  the Phoenix component convention where components accept a single `assigns` argument.

  ### Alias Expansion

  Remote calls use the short alias form (e.g. `Components.foo()`). The registry
  expands these using the calling module's alias map before lookup. If no alias
  matches, the atom is used as-is (assumed to be a fully qualified module).

  ## Edge Cases

  - Modules with `module: nil` (bare files without `defmodule`) are not indexed
    in the `modules` map but their functions are still registered in `by_mfa` and
    `by_name` with a `nil` module key.
  - If `resolve_local/3` finds no match anywhere, it returns `nil` rather than
    raising, allowing the Resolver to handle unresolved calls gracefully.
  - The global fallback in `resolve_local/3` returns the first registered entry
    for a given name, which may be arbitrary if multiple modules define the same
    function name.

  ## Interaction with Other Modules

  - **Input**: Consumes the output of `Mix.Tasks.HeexClassAnalyzer.Discovery.discover/1`.
  - **Consumer**: Used by the Resolver module to trace function calls back to their
    definitions, enabling extraction of class values from function bodies.
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
      nil -> nil
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
        # 3. Functions in modules brought in via `use` (e.g., Phoenix.Component)
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

  defp resolve_alias(registry, calling_module, target_module) do
    module_info = get_module(registry, calling_module)

    if module_info do
      # target_module might be a short alias atom like :Components
      # We need to check if it matches any alias key
      Map.get(module_info.aliases, target_module, target_module)
    else
      target_module
    end
  end
end
