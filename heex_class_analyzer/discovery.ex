defmodule Mix.Tasks.HeexClassAnalyzer.Discovery do
  @moduledoc """
  Scans a Phoenix project's web layer to discover all Elixir modules and HEEX
  templates, extracting metadata needed for downstream static analysis.

  This is the first stage of the analyzer pipeline:

      **Discovery** -> HeexParser -> Expression -> Registry -> Resolver -> Permutations -> Output

  ## Purpose

  The Discovery module builds a comprehensive inventory of the project's web code
  by scanning `lib/*_web/` for `.ex` and `.heex` files. For each `.ex` file it
  parses the source via `Code.string_to_quoted/2` and extracts:

  - Module name(s), including nested `defmodule` declarations
  - `import` directives (which modules are imported)
  - `alias` directives (short name to full module mappings, including multi-alias syntax)
  - `use` directives (which behaviours/extensions are applied)
  - Function definitions (`def`/`defp`) with their bodies, arity, and all clauses
  - Inline `~H` sigil content from function bodies
  - `embed_templates` resolution (locates and reads associated `.html.heex` files)

  For standalone `.heex` files not already associated with a module via
  `embed_templates`, it reads their content and wraps them in a module_info struct.

  ## Public API

      discover(base_path)

  ### Parameters

  - `base_path` - The project root path (e.g. `"/home/user/my_app"`). The function
    will glob `lib/*_web/**/*.ex` and `lib/*_web/**/*.heex` relative to this path.

  ### Return Value

  Returns a list of `module_info()` maps. Each map represents either a discovered
  Elixir module or a standalone HEEX template file.

  ### Example

      iex> Discovery.discover("/home/user/my_app")
      [
        %{
          module: MyAppWeb.PageHTML,
          source_file: "lib/my_app_web/controllers/page_html.ex",
          imports: [Phoenix.Component],
          aliases: %{Layouts: MyAppWeb.Layouts},
          uses: [Phoenix.Component],
          functions: [%{name: :home, arity: 1, body: ..., heex: "<div>...</div>", clauses: [...]}],
          heex_templates: [%{name: "home", content: "<div>...</div>"}]
        },
        ...
      ]

  ## Key Data Structures

  ### `module_info()` map

  | Field             | Type                          | Description                                                |
  |-------------------|-------------------------------|------------------------------------------------------------|
  | `module`          | `atom() \\| nil`              | Fully qualified module name, or `nil` for bare files       |
  | `source_file`     | `String.t()`                  | Path relative to `base_path`                               |
  | `imports`         | `[atom()]`                    | List of imported module atoms                              |
  | `aliases`         | `%{atom() => atom()}`         | Map of short alias atom to full module name                |
  | `uses`            | `[atom()]`                    | List of modules referenced in `use` declarations           |
  | `functions`       | `[function_info()]`           | All `def`/`defp` functions found in the module             |
  | `heex_templates`  | `[%{name: String.t(), content: String.t()}]` | Templates from `embed_templates` or standalone `.heex` files |

  ### `function_info()` map

  | Field     | Type                    | Description                                              |
  |-----------|-------------------------|----------------------------------------------------------|
  | `name`    | `atom()`                | Function name                                            |
  | `arity`   | `non_neg_integer()`     | Number of parameters                                     |
  | `body`    | `Macro.t()`             | AST of the first clause's body                           |
  | `heex`    | `String.t() \\| nil`    | Extracted `~H` sigil content (interpolations as `{...}`) |
  | `clauses` | `[Macro.t()]`           | AST bodies of all function clauses                       |

  ## Edge Cases and Special Behaviors

  - **Nested modules**: `defmodule` declarations nested inside other modules are
    discovered recursively. Each gets its own `module_info` entry.
  - **Bare files**: `.ex` files that don't contain a `defmodule` (e.g. config-like
    scripts) produce a single entry with `module: nil`.
  - **Multi-alias syntax**: `alias Foo.{Bar, Baz}` is correctly expanded into
    separate alias entries for `Bar` and `Baz`.
  - **HEEX deduplication**: Standalone `.heex` files are skipped if their basename
    matches a template already loaded via `embed_templates` in any discovered module.
  - **`~H` sigil interpolation**: Elixir expressions inside `~H` sigils are replaced
    with the placeholder string `{...}` since they cannot be statically evaluated.
  - **Guard clauses**: Function definitions with `when` guards are handled correctly;
    the guard is stripped and only the body is captured.
  - **One-liner functions**: `def foo(x), do: expr` with no explicit `do...end` block
    records the body as `nil`.
  - **Parse failures**: Files that fail to read or parse log a warning and are skipped.

  ## Interaction with Other Modules

  The output of `discover/1` is consumed directly by `Mix.Tasks.HeexClassAnalyzer.Registry`
  to build a lookup index for module/function resolution during expression evaluation.
  """

  require Logger

  @type function_info :: %{
          name: atom(),
          arity: non_neg_integer(),
          body: Macro.t(),
          heex: String.t() | nil,
          clauses: [Macro.t()]
        }

  @type module_info :: %{
          module: atom() | nil,
          source_file: String.t(),
          imports: [atom()],
          aliases: %{atom() => atom()},
          uses: [atom()],
          functions: [function_info()],
          heex_templates: [%{name: String.t(), content: String.t()}]
        }

  @spec discover(String.t()) :: [module_info()]
  def discover(base_path) do
    ex_files = Path.wildcard(Path.join(base_path, "lib/*_web/**/*.ex"))
    heex_files = Path.wildcard(Path.join(base_path, "lib/*_web/**/*.heex"))

    ex_results = Enum.flat_map(ex_files, &parse_ex_file(&1, base_path))
    heex_results = Enum.flat_map(heex_files, &parse_heex_file(&1, base_path, ex_results))

    ex_results ++ heex_results
  end

  # --- .ex file parsing ---

  defp parse_ex_file(file_path, base_path) do
    relative = Path.relative_to(file_path, base_path)

    case File.read(file_path) do
      {:ok, content} ->
        parse_ex_content(content, relative, base_path)

      {:error, reason} ->
        Logger.warning("Failed to read #{relative}: #{inspect(reason)}")
        []
    end
  end

  defp parse_ex_content(content, relative_path, base_path) do
    case Code.string_to_quoted(content, columns: true, file: relative_path) do
      {:ok, ast} ->
        modules = extract_modules(ast, relative_path, base_path)

        if modules == [] do
          [build_bare_module_info(ast, relative_path)]
        else
          modules
        end

      {:error, error} ->
        Logger.warning("Failed to parse #{relative_path}: #{inspect(error)}")
        []
    end
  end

  defp build_bare_module_info(ast, relative_path) do
    %{
      module: nil,
      source_file: relative_path,
      imports: extract_imports(ast),
      aliases: extract_aliases(ast),
      uses: extract_uses(ast),
      functions: extract_functions(ast),
      heex_templates: []
    }
  end

  defp extract_modules(ast, relative_path, base_path) do
    ast
    |> find_defmodules([])
    |> Enum.map(fn {module_name, body} ->
      embed_templates = find_embed_templates(body, relative_path, base_path)

      %{
        module: module_name,
        source_file: relative_path,
        imports: extract_imports(body),
        aliases: extract_aliases(body),
        uses: extract_uses(body),
        functions: extract_functions(body),
        heex_templates: embed_templates
      }
    end)
  end

  # Recursively finds all defmodule nodes in the AST, including nested ones.
  defp find_defmodules({:defmodule, _, [module_alias, [do: body]]}, acc) do
    module_name = resolve_module_name(module_alias)
    nested = find_defmodules(body, [])
    [{module_name, body} | nested] ++ acc
  end

  defp find_defmodules({:__block__, _, statements}, acc) when is_list(statements) do
    Enum.reduce(statements, acc, &find_defmodules/2)
  end

  defp find_defmodules(_ast, acc), do: acc

  # --- Module name resolution ---

  defp resolve_module_name({:__aliases__, _, parts}) do
    Module.concat(parts)
  end

  defp resolve_module_name(other) when is_atom(other), do: other
  defp resolve_module_name(_), do: nil

  # --- Import extraction ---

  defp extract_imports(ast) do
    ast
    |> collect_nodes(&import_node?/1)
    |> Enum.map(&extract_import_module/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp import_node?({:import, _, [{:__aliases__, _, _} | _]}), do: true
  defp import_node?({:import, _, [module | _]}) when is_atom(module), do: true
  defp import_node?(_), do: false

  defp extract_import_module({:import, _, [{:__aliases__, _, parts} | _]}) do
    Module.concat(parts)
  end

  defp extract_import_module({:import, _, [module | _]}) when is_atom(module) do
    module
  end

  defp extract_import_module(_), do: nil

  # --- Alias extraction ---

  defp extract_aliases(ast) do
    ast
    |> collect_nodes(&alias_node?/1)
    |> Enum.flat_map(&extract_alias_entries/1)
    |> Map.new()
  end

  defp alias_node?({:alias, _, [{:__aliases__, _, _} | _]}), do: true
  defp alias_node?({:alias, _, [{{:., _, _}, _, _} | _]}), do: true
  defp alias_node?(_), do: false

  defp extract_alias_entries({:alias, _, [{:__aliases__, _, parts}, opts]})
       when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, [short]} ->
        [{short, Module.concat(parts)}]

      _ ->
        short = List.last(parts)
        [{short, Module.concat(parts)}]
    end
  end

  defp extract_alias_entries({:alias, _, [{:__aliases__, _, parts}]}) do
    short = List.last(parts)
    [{short, Module.concat(parts)}]
  end

  # Multi-alias: alias Foo.{Bar, Baz}
  defp extract_alias_entries(
         {:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, suffixes}]}
       ) do
    Enum.map(suffixes, fn {:__aliases__, _, suffix_parts} ->
      full = Module.concat(prefix ++ suffix_parts)
      short = List.last(suffix_parts)
      {short, full}
    end)
  end

  defp extract_alias_entries(_), do: []

  # --- Use extraction ---

  defp extract_uses(ast) do
    ast
    |> collect_nodes(&use_node?/1)
    |> Enum.map(&extract_use_module/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp use_node?({:use, _, [{:__aliases__, _, _} | _]}), do: true
  defp use_node?({:use, _, [module | _]}) when is_atom(module), do: true
  defp use_node?(_), do: false

  defp extract_use_module({:use, _, [{:__aliases__, _, parts} | _]}) do
    Module.concat(parts)
  end

  defp extract_use_module({:use, _, [module | _]}) when is_atom(module) do
    module
  end

  defp extract_use_module(_), do: nil

  # --- Function extraction ---

  defp extract_functions(ast) do
    defs = collect_function_defs(ast)

    defs
    |> Enum.group_by(fn {name, arity, _body} -> {name, arity} end)
    |> Enum.map(fn {{name, arity}, clauses} ->
      bodies = Enum.map(clauses, fn {_name, _arity, body} -> body end)
      first_body = List.first(bodies)
      all_heex = bodies |> Enum.map(&find_heex_in_ast/1) |> Enum.reject(&is_nil/1)

      %{
        name: name,
        arity: arity,
        body: first_body,
        heex: List.first(all_heex),
        heex_clauses: all_heex,
        clauses: bodies
      }
    end)
  end

  defp collect_function_defs(ast) do
    ast
    |> collect_nodes(&function_def_node?/1)
    |> Enum.map(&extract_function_def/1)
    |> Enum.reject(&is_nil/1)
  end

  defp function_def_node?({kind, _, _}) when kind in [:def, :defp], do: true
  defp function_def_node?(_), do: false

  defp extract_function_def({kind, _, [{name, _, args}, [do: body]]})
       when kind in [:def, :defp] and is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {name, arity, body}
  end

  defp extract_function_def({kind, _, [{:when, _, [{name, _, args} | _]}, [do: body]]})
       when kind in [:def, :defp] and is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {name, arity, body}
  end

  # One-liner: def foo(x), do: expr
  defp extract_function_def({kind, _, [{name, _, args}]})
       when kind in [:def, :defp] and is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {name, arity, nil}
  end

  defp extract_function_def(_), do: nil

  # --- HEEX sigil extraction ---

  defp find_heex_in_ast(nil), do: nil

  defp find_heex_in_ast(ast) do
    case find_first_node(ast, &heex_sigil_node?/1) do
      {:sigil_H, _, [{:<<>>, _, parts}, _]} ->
        extract_heex_string(parts)

      _ ->
        nil
    end
  end

  defp heex_sigil_node?({:sigil_H, _, _}), do: true
  defp heex_sigil_node?(_), do: false

  defp extract_heex_string(parts) when is_list(parts) do
    Enum.map_join(parts, fn
      part when is_binary(part) -> part
      {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [_expr]}, {:binary, _, _}]} -> "{...}"
      _ -> "{...}"
    end)
  end

  defp extract_heex_string(other) when is_binary(other), do: other
  defp extract_heex_string(_), do: nil

  # --- embed_templates handling ---

  defp find_embed_templates(ast, source_file, base_path) do
    ast
    |> collect_nodes(&embed_templates_node?/1)
    |> Enum.flat_map(&resolve_embed_templates(&1, source_file, base_path))
  end

  defp embed_templates_node?({:embed_templates, _, [_path | _]}), do: true
  defp embed_templates_node?(_), do: false

  defp resolve_embed_templates({:embed_templates, _, [dir_pattern | _]}, source_file, base_path)
       when is_binary(dir_pattern) do
    source_dir = Path.dirname(source_file)

    # Phoenix embed_templates uses patterns like "layouts/*" where the directory
    # is "layouts" and "*" means all .html.heex files. Extract the directory part.
    # If the pattern contains a wildcard, take the directory portion.
    template_dir_name =
      if String.contains?(dir_pattern, "*") do
        Path.dirname(dir_pattern)
      else
        dir_pattern
      end

    template_dir = Path.join([base_path, source_dir, template_dir_name])

    # Find all .heex files in the resolved directory
    pattern = Path.join(template_dir, "*.html.heex")

    pattern
    |> Path.wildcard()
    |> Enum.flat_map(fn file_path ->
      case File.read(file_path) do
        {:ok, content} ->
          name = Path.basename(file_path, ".html.heex")
          [%{name: name, content: content}]

        _ ->
          []
      end
    end)
  end

  defp resolve_embed_templates(_, _, _), do: []

  # --- .heex file parsing ---

  defp parse_heex_file(file_path, base_path, ex_results) do
    relative = Path.relative_to(file_path, base_path)

    # Skip .heex files that are already associated with a module via embed_templates
    if heex_already_associated?(relative, ex_results) do
      []
    else
      case File.read(file_path) do
        {:ok, content} ->
          name = Path.basename(file_path, ".html.heex")

          [
            %{
              module: nil,
              source_file: relative,
              imports: [],
              aliases: %{},
              uses: [],
              functions: [],
              heex_templates: [%{name: name, content: content}]
            }
          ]

        {:error, reason} ->
          Logger.warning("Failed to read #{relative}: #{inspect(reason)}")
          []
      end
    end
  end

  defp heex_already_associated?(relative_heex_path, ex_results) do
    basename = Path.basename(relative_heex_path, ".html.heex")

    Enum.any?(ex_results, fn module_info ->
      Enum.any?(module_info.heex_templates, fn template ->
        template.name == basename
      end)
    end)
  end

  # --- AST traversal helpers ---

  # Collects all nodes in the AST matching a predicate (breadth-first).
  defp collect_nodes(ast, predicate) do
    collect_nodes_acc(ast, predicate, [])
    |> Enum.reverse()
  end

  defp collect_nodes_acc({_, _, _} = node, predicate, acc) do
    acc = if predicate.(node), do: [node | acc], else: acc

    case node do
      {_, _, children} when is_list(children) ->
        Enum.reduce(children, acc, &collect_nodes_acc(&1, predicate, &2))

      _ ->
        acc
    end
  end

  defp collect_nodes_acc(nodes, predicate, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &collect_nodes_acc(&1, predicate, &2))
  end

  defp collect_nodes_acc({left, right}, predicate, acc) do
    acc = collect_nodes_acc(left, predicate, acc)
    collect_nodes_acc(right, predicate, acc)
  end

  defp collect_nodes_acc([{:do, body} | rest], predicate, acc) do
    acc = collect_nodes_acc(body, predicate, acc)
    collect_nodes_acc(rest, predicate, acc)
  end

  defp collect_nodes_acc(_other, _predicate, acc), do: acc

  # Finds the first node in the AST matching a predicate (depth-first).
  defp find_first_node({_, _, _} = node, predicate) do
    if predicate.(node) do
      node
    else
      case node do
        {_, _, children} when is_list(children) ->
          find_first_in_list(children, predicate)

        _ ->
          nil
      end
    end
  end

  defp find_first_node(nodes, predicate) when is_list(nodes) do
    find_first_in_list(nodes, predicate)
  end

  defp find_first_node({left, right}, predicate) do
    find_first_node(left, predicate) || find_first_node(right, predicate)
  end

  defp find_first_node(_other, _predicate), do: nil

  defp find_first_in_list([], _predicate), do: nil

  defp find_first_in_list([head | tail], predicate) do
    case find_first_node(head, predicate) do
      nil -> find_first_in_list(tail, predicate)
      found -> found
    end
  end
end
