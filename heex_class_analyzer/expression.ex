defmodule Mix.Tasks.HeexClassAnalyzer.Expression do
  @moduledoc """
  Parses the Elixir AST of class attribute values. Sorts the CSS classes into
  static classes, toggle variants, either variants, and function calls.

  Expression is the third analyzer stage. It finds the CSS classes that an
  element can have at runtime from the Elixir expression in its `class`
  attribute.

  ## Stage order

      Discovery -> HeexParser -> **Expression** -> Registry -> Resolver -> ClassFacts -> Output

  The `Resolver` calls `analyze/1` on the class attribute value of each node.
  The value is a plain string, an `{:expr, code}` tuple, or `nil`. The
  result is a `{static_classes, variants}` tuple. The `Resolver` puts this
  tuple into the `:static` and `:variants` fields of the node.

  The `Resolver` also uses `extract_returns/1` to find the class values that
  a function body can return. With these values, the `Resolver` follows
  dynamic class expressions into other functions.

  ## Public API

  ### `analyze/1`

  Returns the `{static_classes, variants}` tuple for a class attribute value.

      @spec analyze(String.t() | {:expr, String.t()} | nil) :: {[String.t()], [variant()]}

  #### Examples

      # Static string - split into individual classes
      iex> Expression.analyze("flex items-center gap-2")
      {["flex", "items-center", "gap-2"], []}

      # nil or empty - no classes
      iex> Expression.analyze(nil)
      {[], []}

      # Dynamic expression with && (toggle)
      iex> Expression.analyze({:expr, ~S(@active && "btn-active")})
      {[], [{:toggle, "btn-active"}]}

      # Dynamic expression with if/else (either)
      iex> Expression.analyze({:expr, ~S(if @ok, do: "text-green", else: "text-red")})
      {[], [{:either, ["text-green", "text-red"]}]}

      # Dynamic expression with if, no else (toggle)
      iex> Expression.analyze({:expr, ~S(if @active, do: "font-bold")})
      {[], [{:toggle, "font-bold"}]}

      # List of mixed expressions
      iex> Expression.analyze({:expr, ~S(["static-class", @flag && "conditional"])})
      {["static-class"], [{:toggle, "conditional"}]}

      # Function call
      iex> Expression.analyze({:expr, ~S(button_classes(@variant))})
      {[], [{:fn_call, {:button_classes, [{:@, [line: 1], [{:variant, [line: 1], nil}]}]}}]}

      # Unparseable expression
      iex> Expression.analyze({:expr, "invalid %%% code"})
      {["<dynamic>"], []}

  ### `extract_returns/1`

  Finds all possible return values of a function body. The `Resolver`
  uses the result to find the classes that a helper function can return.

      @spec extract_returns(Macro.t()) :: {:ok, [term()]} | :unresolved

  The result is `{:ok, list_of_possible_returns}`. Each return value is one
  of these items:
  - A list of class strings, for example `["flex", "gap-2"]`
  - `["<dynamic>"]` for a value that static analysis cannot find
  - `{:fn_call, {module, func, args}}` or `{:fn_call, {func, args}}` for a
    nested function call that the `Resolver` must analyze next

  If the analyzer cannot read the function body, the result is
  `:unresolved`.
  #### Examples

      iex> {:ok, ast} = Code.string_to_quoted(~S("flex gap-2"))
      iex> Expression.extract_returns(ast)
      {:ok, [["flex", "gap-2"]]}

      iex> {:ok, ast} = Code.string_to_quoted(~S(if x, do: "a", else: "b"))
      iex> Expression.extract_returns(ast)
      {:ok, [["a"], ["b"]]}

      iex> {:ok, ast} = Code.string_to_quoted(~S(case x do; :a -> "red"; :b -> "blue"; end))
      iex> Expression.extract_returns(ast)
      {:ok, [["red"], ["blue"]]}

  ## Variant types

  The `variant()` type is a dynamic class expression:

  - `{:toggle, class_string}`. A class that is present or absent at
    runtime. `&&` expressions and `if` without `else` give this variant.
    The string can contain several classes with spaces between them.

  - `{:either, [option1, option2, ...]}`. Class options that exclude each
    other. At runtime, exactly one option applies. `if/else`, `case`,
    `cond`, and `||` expressions give this variant. Each option is a class
    string with one or more classes. The value `"<dynamic>"` is an option
    that static analysis cannot find.

  - `{:fn_call, {func_name, args}}`. A local function call. The return
    value of the call sets the classes. The `Resolver` finds the function
    in the `Registry` and analyzes its body with `extract_returns/1`.

  - `{:fn_call, {module, func_name, args}}`. A remote function call, for
    example `MyModule.class_helper(arg)`. The `Resolver` handles it as a
    local call.

  - `{:assign_ref, assign_name}`. A HEEX assign reference such as
    `@tie_class`. If the function clause sets this assign before the `~H`
    sigil, the `Resolver` replaces the reference with the assign facts.

  ## Expression rules

  The analyzer reads the Elixir AST and sorts each expression into one of
  these classifications:

  | Expression Pattern            | Classification                        |
  |-------------------------------|---------------------------------------|
  | `"literal string"`            | Static classes (split on whitespace)  |
  | `["a", expr, "b"]`           | Each item analyzed independently      |
  | `cond && "classes"`           | `{:toggle, "classes"}`                |
  | `"a" \\|\\| "b"`             | `{:either, ["a", "b"]}`              |
  | `if c, do: "a", else: "b"`   | `{:either, ["a", "b"]}`              |
  | `if c, do: "a"` (no else)    | `{:toggle, "a"}`                      |
  | `case x do ... end`          | `{:either, [branch_values...]}`       |
  | `cond do ... end`            | `{:either, [branch_values...]}`       |
  | `func(args)`                 | `{:fn_call, {func, args}}`            |
  | `Mod.func(args)`             | `{:fn_call, {Mod, func, args}}`       |
  | `@assign`                    | `{:assign_ref, assign}` variant       |
  | variable                     | Static `["<dynamic>"]`                |
  | Unparseable                  | Static `["<dynamic>"]`                |

  ## Special cases

  - `"<dynamic>"`. If the analyzer cannot find the class value, for
    example for a variable or a module attribute, it uses the string
    `"<dynamic>"`. This string goes into the output and shows the elements
    with unknown classes.

  - String concatenation in `extract_returns/1`. The analyzer joins
    expressions such as `"prefix-" <> "suffix"` into one string. If an
    operand is not a string, the result is `:unresolved`.

  - Block expressions. In a block of several expressions (`__block__`),
    only the last expression is the return value. Elixir uses the same rule.

  - `nil` branches. An `if` without `else` returns `nil` for the missing
    branch. `extract_returns/1` changes this `nil` to an empty class list.

  - Lists in `extract_returns/1`. The function returns list literals
    without changes. Each item that is not a string becomes `"<dynamic>"`.

  - Nested conditionals. `analyze/1` and `extract_returns/1` collect the
    branch values of nested `if`, `case`, and `cond` expressions.

  ## Related modules

  - `Resolver`. Calls `analyze/1` on the class value of each node. Calls
    `extract_returns/1` on the function bodies from the `Registry`.
  - `ClassFacts`. `ClassFacts.from_static_and_variants/2` makes compact
    selector facts from the `{static_classes, variants}` tuples.
  - `Code`. `Code.string_to_quoted/1` parses the expression strings into
    AST.
  """

  @type variant ::
          {:toggle, String.t()}
          | {:either, [String.t()]}
          | {:assign_ref, atom()}
          | {:fn_call, {atom(), list()} | {module(), atom(), list()}}

  @spec analyze(String.t() | {:expr, String.t()} | nil) :: {[String.t()], [variant()]}
  def analyze(nil), do: {[], []}
  def analyze(""), do: {[], []}

  def analyze(class_value) when is_binary(class_value) do
    classes = split_classes(class_value)
    {classes, []}
  end

  def analyze({:expr, expr_string}) when is_binary(expr_string) do
    case Code.string_to_quoted(expr_string, emit_warnings: false) do
      {:ok, ast} ->
        analyze_ast(ast)

      {:error, _} ->
        {[make_dynamic("parse_error", expr_string)], []}
    end
  end

  def analyze(_), do: {[], []}

  @spec extract_returns(Macro.t()) :: {:ok, [term()]} | :unresolved
  def extract_returns(ast) do
    case do_extract_returns(ast) do
      :unresolved -> :unresolved
      results when is_list(results) -> {:ok, results}
    end
  end

  # --- Private: analyze_ast ---

  defp analyze_ast(ast) do
    {statics, variants} = walk_expr(ast)
    {statics, variants}
  end

  defp walk_expr(str) when is_binary(str), do: walk_string(str)
  defp walk_expr(items) when is_list(items), do: walk_list(items)
  defp walk_expr({:&&, _, [left, right]}), do: walk_and(left, right)
  defp walk_expr({:||, _, [left, right]}), do: walk_or(left, right)
  defp walk_expr({:if, _, [_condition, branches]}), do: walk_if(branches)
  defp walk_expr({:case, _, [_subject, [do: clauses]]}), do: walk_clauses(clauses)
  defp walk_expr({:cond, _, [[do: clauses]]}), do: walk_clauses(clauses)
  defp walk_expr({:@, _, [{name, _, _}]}) when is_atom(name), do: {[], [{:assign_ref, name}]}

  defp walk_expr({{:., _, [{:__aliases__, _, mod_parts}, func_name]}, _, args})
       when is_atom(func_name) and is_list(args) do
    walk_remote_call(mod_parts, func_name, args)
  end

  defp walk_expr({func_name, _, args})
       when is_atom(func_name) and is_list(args) and func_name not in [:@, :^] do
    walk_local_call(func_name, args)
  end

  defp walk_expr({:@, _, _} = ast), do: {[make_dynamic("assign", Macro.to_string(ast))], []}

  defp walk_expr({name, _, context} = ast) when is_atom(name) and is_atom(context),
    do: {[make_dynamic("variable", Macro.to_string(ast))], []}

  defp walk_expr(ast), do: {[make_dynamic("unknown_expression", Macro.to_string(ast))], []}

  # Plain string literal
  defp walk_string(str), do: {split_classes(str), []}

  # List of expressions: ["a", cond && "b", func()]
  defp walk_list(items) do
    Enum.reduce(items, {[], []}, fn item, {s_acc, v_acc} ->
      {s, v} = walk_expr(item)
      {s_acc ++ s, v_acc ++ v}
    end)
  end

  # && operator: cond && "class" or "class" && cond
  defp walk_and(left, right) do
    case {extract_string(right), extract_string(left)} do
      {nil, nil} ->
        case {collect_class_values(right), collect_class_values(left)} do
          {[], []} ->
            expr = Macro.to_string({:&&, [], [left, right]})
            {[make_dynamic("complex_expression", expr)], []}

          {right_values, _} when right_values != [] ->
            {[], Enum.map(right_values, &{:toggle, &1})}

          {[], left_values} ->
            {[], Enum.map(left_values, &{:toggle, &1})}
        end

      {right_str, _} when right_str != nil ->
        {[], [{:toggle, right_str}]}

      {nil, left_str} ->
        {[], [{:toggle, left_str}]}
    end
  end

  # || operator
  defp walk_or(left, right) do
    left_str = extract_string(left)
    right_str = extract_string(right)

    cond do
      left_str != nil && right_str != nil ->
        {[], [{:either, [left_str, right_str]}]}

      right_str != nil ->
        {[], [{:either, [make_dynamic("unknown_expression", Macro.to_string(left)), right_str]}]}

      left_str != nil ->
        {[], [{:either, [left_str, make_dynamic("unknown_expression", Macro.to_string(right))]}]}

      true ->
        expr = Macro.to_string({:||, [], [left, right]})
        {[make_dynamic("complex_expression", expr)], []}
    end
  end

  # if/else
  defp walk_if(branches) do
    do_branch = Keyword.get(branches, :do)
    else_branch = Keyword.get(branches, :else)

    case {extract_string(do_branch), else_branch} do
      {nil, _} -> walk_if_dynamic_do(do_branch, else_branch)
      {do_str, nil} -> {[], [{:toggle, do_str}]}
      {do_str, else_ast} -> walk_if_with_else(do_str, else_ast)
    end
  end

  defp walk_if_dynamic_do(do_branch, else_branch) do
    do_values = collect_branch_strings(do_branch)
    else_values = collect_branch_strings(else_branch)
    all = (do_values ++ else_values) |> Enum.uniq()

    if all == [] do
      {[make_dynamic("unknown_expression", Macro.to_string(do_branch))], []}
    else
      {[], [{:either, all}]}
    end
  end

  defp walk_if_with_else(do_str, else_ast) do
    case extract_string(else_ast) do
      nil ->
        else_values = collect_branch_strings(else_ast)

        if else_values == [],
          do:
            {[],
             [{:either, [do_str, make_dynamic("unknown_expression", Macro.to_string(else_ast))]}]},
          else: {[], [{:either, [do_str | else_values]}]}

      else_str ->
        {[], [{:either, [do_str, else_str]}]}
    end
  end

  # case/cond clauses
  defp walk_clauses(clauses) do
    values = collect_clause_strings(clauses)

    if values == [] do
      {[make_dynamic("unknown_expression", "case/cond with non-string clauses")], []}
    else
      {[], [{:either, Enum.uniq(values)}]}
    end
  end

  # Remote function call: Module.func(args)
  defp walk_remote_call(mod_parts, func_name, args) do
    module = Module.concat(mod_parts)
    {[], [{:fn_call, {module, func_name, args}}]}
  end

  # Local function call: func(args)
  defp walk_local_call(func_name, args), do: {[], [{:fn_call, {func_name, args}}]}

  # --- Private: extract_returns ---

  defp do_extract_returns(str) when is_binary(str), do: extract_string_return(str)
  defp do_extract_returns({:<>, _, _} = ast), do: extract_concat_return(ast)
  defp do_extract_returns(items) when is_list(items), do: extract_list_return(items)
  defp do_extract_returns({:if, _, [_cond, branches]}), do: extract_if_return(branches)

  defp do_extract_returns({:case, _, [_subject, [do: clauses]]}),
    do: extract_from_clauses(clauses)

  defp do_extract_returns({:cond, _, [[do: clauses]]}), do: extract_from_clauses(clauses)

  defp do_extract_returns({:__block__, _, exprs}) when is_list(exprs) and exprs != [] do
    extract_block_return(exprs)
  end

  defp do_extract_returns({{:., _, [{:__aliases__, _, mod_parts}, func_name]}, _, args})
       when is_atom(func_name) and is_list(args) do
    extract_remote_call_return(mod_parts, func_name, args)
  end

  defp do_extract_returns({func_name, _, args})
       when is_atom(func_name) and is_list(args) and func_name not in [:@, :^, :__block__] do
    extract_local_call_return(func_name, args)
  end

  defp do_extract_returns({:@, _, _} = ast), do: [[make_dynamic("assign", Macro.to_string(ast))]]

  defp do_extract_returns({name, _, context} = ast) when is_atom(name) and is_atom(context),
    do: [[make_dynamic("variable", Macro.to_string(ast))]]

  defp do_extract_returns(nil), do: [[]]
  defp do_extract_returns(_), do: :unresolved

  # String literal
  defp extract_string_return(str), do: [split_classes(str)]

  # String concatenation: "a" <> " " <> "b"
  defp extract_concat_return(ast) do
    case eval_concat(ast) do
      {:ok, result} -> [split_classes(result)]
      :error -> :unresolved
    end
  end

  # List literal
  defp extract_list_return(items) do
    resolved =
      Enum.map(items, fn
        s when is_binary(s) -> s
        other -> make_dynamic("non_string_in_list", Macro.to_string(other))
      end)

    [resolved]
  end

  # if/else
  defp extract_if_return(branches) do
    do_branch = Keyword.get(branches, :do)
    else_branch = Keyword.get(branches, :else)

    do_results = do_extract_returns(do_branch)
    else_results = if else_branch, do: do_extract_returns(else_branch), else: [[]]

    case {do_results, else_results} do
      {:unresolved, _} -> :unresolved
      {_, :unresolved} -> :unresolved
      {d, e} -> d ++ e
    end
  end

  # Block - return value is the last expression
  defp extract_block_return(exprs) do
    last = List.last(exprs)
    do_extract_returns(last)
  end

  # Remote function call
  defp extract_remote_call_return(mod_parts, func_name, args) do
    module = Module.concat(mod_parts)
    [{:fn_call, {module, func_name, args}}]
  end

  # Local function call
  defp extract_local_call_return(func_name, args), do: [{:fn_call, {func_name, args}}]

  defp extract_from_clauses(clauses) when is_list(clauses) do
    Enum.reduce_while(clauses, [], fn {:->, _, [_pattern, body]}, acc ->
      case do_extract_returns(body) do
        :unresolved -> {:halt, :unresolved}
        values -> {:cont, acc ++ values}
      end
    end)
  end

  defp extract_from_clauses(_), do: :unresolved

  # --- Helpers ---

  defp split_classes(str) when is_binary(str) do
    str
    |> String.split(~r/\s+/, trim: true)
  end

  defp split_classes(_), do: []

  defp extract_string(str) when is_binary(str), do: str
  defp extract_string(nil), do: nil
  defp extract_string(_), do: nil

  defp collect_branch_strings(nil), do: []

  defp collect_branch_strings(str) when is_binary(str), do: [str]

  defp collect_branch_strings({:__block__, _, exprs}),
    do: exprs |> List.last() |> collect_branch_strings()

  defp collect_branch_strings(_), do: []

  defp collect_class_values(str) when is_binary(str), do: [str]

  defp collect_class_values({:||, _, [left, right]}) do
    collect_class_values(left) ++ collect_class_values(right)
  end

  defp collect_class_values({:if, _, [_condition, branches]}) do
    collect_branch_strings(Keyword.get(branches, :do)) ++
      collect_branch_strings(Keyword.get(branches, :else))
  end

  defp collect_class_values({:case, _, [_subject, [do: clauses]]}) do
    collect_clause_strings(clauses)
  end

  defp collect_class_values({:cond, _, [[do: clauses]]}) do
    collect_clause_strings(clauses)
  end

  defp collect_class_values({:__block__, _, exprs}) do
    exprs |> List.last() |> collect_class_values()
  end

  defp collect_class_values({:@, _, _} = ast) do
    [make_dynamic("assign", Macro.to_string(ast))]
  end

  defp collect_class_values({name, _, context} = ast) when is_atom(name) and is_atom(context) do
    [make_dynamic("variable", Macro.to_string(ast))]
  end

  defp collect_class_values(_), do: []

  defp collect_clause_strings(clauses) when is_list(clauses) do
    Enum.flat_map(clauses, fn
      {:->, _, [_pattern, body]} ->
        collect_branch_strings(body)

      _ ->
        []
    end)
  end

  defp collect_clause_strings(_), do: []

  defp eval_concat({:<>, _, [left, right]}) do
    with {:ok, l} <- eval_concat(left),
         {:ok, r} <- eval_concat(right) do
      {:ok, l <> r}
    end
  end

  defp eval_concat(str) when is_binary(str), do: {:ok, str}
  defp eval_concat(_), do: :error

  defp make_dynamic(reason, expr), do: {:dynamic, %{reason: reason, expr: expr}}
end
