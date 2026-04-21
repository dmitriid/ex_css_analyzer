defmodule Mix.Tasks.HeexClassAnalyzer.Permutations do
  @moduledoc """
  Computes all non-empty subsets (power set minus the empty set) of CSS classes
  for a given HEEX element node.

  This module sits in the analyzer pipeline after the Resolver has determined
  which classes an element can have:

      Discovery -> HeexParser -> Expression -> Registry -> Resolver -> **Permutations** -> Output

  ## Purpose

  A CSS selector can match any subset of an element's classes. For example, if an
  element has classes `["a", "b", "c"]`, a selector `.a.b` would match it. To find
  all selectors that *could* apply, we need every non-empty combination (subset
  without repetition) of the element's classes.

  This module collects all unique individual class strings from both static classes
  and variant values, then generates the power set (excluding the empty set), sorted
  by subset size (ascending).

  ## Public API

      compute(static_classes, variants)

  ### Parameters

  - `static_classes` - A list of class strings (e.g. `["flex items-center", "gap-2"]`).
    Each string may contain whitespace-separated classes that will be split apart.
  - `variants` - A list of `Mix.Tasks.HeexClassAnalyzer.Node.variant()` tuples:
    - `{:toggle, class}` - A class that may or may not be present (conditional).
    - `{:either, options}` - A list of mutually exclusive class options.
    - `{:fn_call, _}` - An unresolved function call (ignored, contributes no classes).

  ### Return Value

  Returns a list of class lists (`[[String.t()]]`), where each inner list is one
  non-empty subset of the combined class pool. Results are sorted by length (shortest
  subsets first).

  ### Examples

      iex> Permutations.compute(["flex"], [{:toggle, "hidden"}])
      [["flex"], ["hidden"], ["flex", "hidden"]]

      iex> Permutations.compute(["text-sm font-bold"], [])
      [["text-sm"], ["font-bold"], ["text-sm", "font-bold"]]

      iex> Permutations.compute([], [{:either, ["bg-red", "bg-blue"]}])
      [["bg-red"], ["bg-blue"], ["bg-red", "bg-blue"]]

      iex> Permutations.compute([], [])
      [[]]

  ## Edge Cases

  - When both `static_classes` and `variants` are empty, returns `[[]]` (a single
    empty permutation), representing an element with no class attribute.
  - Multi-word class strings (e.g. `"flex items-center"`) are split on whitespace
    into individual classes before combination.
  - Duplicate classes across static and variant sources are deduplicated before
    generating combinations.
  - `{:fn_call, _}` variants contribute no classes (the function's return value
    cannot be statically determined).
  - Non-binary values in class lists are silently ignored.

  ## Algorithm

  The `combinations/1` function generates all non-empty subsets recursively:
  for each element, it produces subsets that include the element (paired with all
  subsets of the remaining elements) plus all subsets that exclude it. This yields
  2^n - 1 results for n unique classes.
  """

  @spec compute([String.t()], [Mix.Tasks.HeexClassAnalyzer.Node.variant()]) :: [[String.t()]]
  def compute([], []), do: [[]]

  def compute(static_classes, variants) do
    variant_classes =
      variants
      |> Enum.flat_map(fn
        {:toggle, class} -> to_class_list(class)
        {:either, options} -> Enum.flat_map(options, &to_class_list/1)
        {:fn_call, _} -> []
        _ -> []
      end)

    all_classes =
      (Enum.flat_map(static_classes, &to_class_list/1) ++ variant_classes)
      |> Enum.uniq()

    case all_classes do
      [] ->
        [[]]

      classes ->
        classes
        |> combinations()
        |> Enum.sort_by(&length/1)
    end
  end

  defp combinations([]), do: []

  defp combinations([head | tail]) do
    tail_combos = combinations(tail)
    [[head] | Enum.map(tail_combos, &[head | &1])] ++ tail_combos
  end

  defp to_class_list(classes) when is_list(classes) do
    Enum.flat_map(classes, fn
      s when is_binary(s) -> String.split(s, ~r/\s+/, trim: true)
      _ -> []
    end)
  end

  defp to_class_list(str) when is_binary(str) do
    String.split(str, ~r/\s+/, trim: true)
  end

  defp to_class_list({:dynamic, _} = d), do: [d]
  defp to_class_list(_), do: []
end
