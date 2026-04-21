defmodule Mix.Tasks.HeexClassAnalyzer.Expression do
  @moduledoc """
  Analyzes class attribute values by parsing Elixir AST to classify CSS classes
  as static, toggle variants, either variants, or function calls.

  This module is the third stage in the analyzer pipeline, responsible for
  understanding what CSS classes an element can have at runtime by examining
  the Elixir expression used in its `class` attribute.

  ## Pipeline Role

      Discovery -> HeexParser -> **Expression** -> Registry -> Resolver -> Permutations -> Output

  The `Expression` module is called by the `Resolver` on each node's class
  attribute value. It takes the raw class value (a plain string, an
  `{:expr, code}` tuple, or `nil`) and returns a tuple of
  `{static_classes, variants}` that the Resolver uses to populate the node's
  `:static` and `:variants` fields.

  Additionally, the `Resolver` uses `extract_returns/1` to analyze function
  bodies and determine what class values they might return, enabling
  cross-function resolution of dynamic class expressions.

  ## Public API

  ### `analyze/1`

  Analyzes a class attribute value and returns `{static_classes, variants}`.

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

  Analyzes an Elixir AST and extracts all possible return values from a
  function body. Used by the `Resolver` to determine what classes a helper
  function might return.

      @spec extract_returns(Macro.t()) :: {:ok, [term()]} | :unresolved

  Returns `{:ok, list_of_possible_returns}` where each return value is either:
  - A list of class strings (e.g., `["flex", "gap-2"]`)
  - `["<dynamic>"]` for values that cannot be statically determined
  - `{:fn_call, {module, func, args}}` or `{:fn_call, {func, args}}` for
    nested function calls that need further resolution

  Returns `:unresolved` if the function body cannot be analyzed.

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

  ## Variant Types

  The `variant()` type represents a dynamic class expression:

  - `{:toggle, class_string}` - A class that is conditionally present or
    absent. Produced by `&&` expressions and `if` without `else`. The string
    may contain multiple space-separated classes.

  - `{:either, [option1, option2, ...]}` - Mutually exclusive class options.
    Exactly one will be active at runtime. Produced by `if/else`, `case`,
    `cond`, and `||` expressions. Each option is a class string (possibly
    multi-word). The special value `"<dynamic>"` represents an option that
    cannot be statically determined.

  - `{:fn_call, {func_name, args}}` - A local function call whose return
    value determines the classes. The `Resolver` attempts to look up the
    function in the `Registry` and recursively analyze its body via
    `extract_returns/1`.

  - `{:fn_call, {module, func_name, args}}` - A remote function call
    (e.g., `MyModule.class_helper(arg)`). Handled similarly to local calls
    by the `Resolver`.

  ## Expression Classification Rules

  The analyzer walks the Elixir AST and classifies expressions as follows:

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
  | `@assign` / variable         | Static `["<dynamic>"]`                |
  | Unparseable                  | Static `["<dynamic>"]`                |

  ## Edge Cases and Special Behaviors

  - **`"<dynamic>"` sentinel**: When the analyzer cannot determine the actual
    class value (e.g., a bare variable or module attribute), it uses the
    string `"<dynamic>"` as a placeholder. This propagates through to the
    output so that users can see which elements have unresolvable classes.

  - **String concatenation in `extract_returns`**: Expressions like
    `"prefix-" <> "suffix"` are evaluated at analysis time to produce the
    concatenated result. Non-string operands cause the expression to be
    marked `:unresolved`.

  - **Block expressions**: For multi-expression blocks (`__block__`), only
    the last expression is considered as the return value (matching Elixir
    semantics).

  - **`nil` branches**: An `if` with no `else` clause returns `nil` for the
    else branch, which `extract_returns/1` maps to an empty class list `[]`.

  - **Lists in `extract_returns`**: List literals are returned as-is, with
    non-string elements replaced by `"<dynamic>"`.

  - **Nested conditionals**: Both `analyze/1` and `extract_returns/1` handle
    nested `if`/`case`/`cond` by recursively collecting branch values.

  ## Interaction with Other Modules

  - **Called by**: `Resolver` (calls `analyze/1` on each node's class value
    and `extract_returns/1` on function bodies found via the `Registry`).
  - **Produces**: `{static_classes, variants}` tuples consumed by
    `Permutations.compute/2` to generate all possible class combinations.
  - **Depends on**: Standard library `Code.string_to_quoted/1` for parsing
    expression strings into AST.
  """

  @type variant ::
          {:toggle, String.t()}
          | {:either, [String.t()]}
          | {:fn_call, {atom(), list()} | {module(), atom(), list()}}

  @spec analyze(String.t() | {:expr, String.t()} | nil) :: {[String.t()], [variant()]}
  def analyze(nil), do: {[], []}
  def analyze(""), do: {[], []}

  def analyze(class_value) when is_binary(class_value) do
    classes = split_classes(class_value)
    {classes, []}
  end

  def analyze({:expr, expr_string}) when is_binary(expr_string) do
    case Code.string_to_quoted(expr_string) do
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
        expr = Macro.to_string({:&&, [], [left, right]})
        {[make_dynamic("complex_expression", expr)], []}

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

  defp do_extract_returns({:@, _, _} = ast),
    do: [[make_dynamic("assign", Macro.to_string(ast))]]

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
    results =
      Enum.reduce_while(clauses, [], fn {:->, _, [_pattern, body]}, acc ->
        case do_extract_returns(body) do
          :unresolved -> {:halt, :unresolved}
          values -> {:cont, acc ++ values}
        end
      end)

    case results do
      :unresolved -> :unresolved
      list -> list
    end
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

  defp collect_branch_strings(ast) do
    case ast do
      str when is_binary(str) -> [str]
      {:__block__, _, exprs} -> exprs |> List.last() |> collect_branch_strings()
      _ -> []
    end
  end

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
