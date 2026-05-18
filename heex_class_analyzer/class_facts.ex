defmodule Mix.Tasks.HeexClassAnalyzer.ClassFacts do
  @moduledoc """
  Converts analyzed HEEX class data into compact facts for selector matching.
  """

  @type dynamic_fact :: %{
          dynamic: true,
          reason: String.t() | nil,
          expr: String.t() | nil,
          chain: String.t() | nil
        }

  @type exclusive_option :: [String.t() | dynamic_fact()]

  @type t :: %{
          static: [String.t()],
          optional: [String.t()],
          exclusive: [[exclusive_option()]],
          dynamic: [dynamic_fact()]
        }

  @spec from_static_and_variants([term()], [term()]) :: t()
  def from_static_and_variants(static_classes, variants) do
    {static, static_dynamic} = split_classes(static_classes)

    {optional, exclusive, variant_dynamic} =
      Enum.reduce(variants, {[], [], []}, fn
        {:toggle, class}, {optional, exclusive, dynamic} ->
          {classes, dynamics} = split_classes([class])
          {optional ++ classes, exclusive, dynamic ++ dynamics}

        {:either, options}, {optional, exclusive, dynamic} ->
          {group, dynamics} = split_exclusive_group(options)
          exclusive = if group == [], do: exclusive, else: exclusive ++ [group]
          {optional, exclusive, dynamic ++ dynamics}

        {:fn_call, _}, acc ->
          acc

        other, {optional, exclusive, dynamic} ->
          {optional, exclusive, dynamic ++ [dynamic_fact("unknown_variant", inspect(other), nil)]}
      end)

    %{
      static: Enum.uniq(static),
      optional: Enum.uniq(optional),
      exclusive: Enum.map(exclusive, &Enum.uniq/1),
      dynamic: static_dynamic ++ variant_dynamic
    }
  end

  defp split_exclusive_group(options) do
    Enum.reduce(options, {[], []}, fn option, {group, dynamics} ->
      {classes, option_dynamics} = split_classes(List.wrap(option))
      option_facts = Enum.uniq(classes) ++ option_dynamics
      group = if option_facts == [], do: group, else: group ++ [option_facts]
      {group, dynamics ++ option_dynamics}
    end)
  end

  defp split_classes(values) do
    Enum.reduce(values, {[], []}, fn
      value, {classes, dynamics} when is_binary(value) ->
        {classes ++ String.split(value, ~r/\s+/, trim: true), dynamics}

      {:dynamic, info}, {classes, dynamics} ->
        {classes, dynamics ++ [dynamic_fact(info.reason, info.expr, Map.get(info, :chain))]}

      value, {classes, dynamics} when is_list(value) ->
        {nested_classes, nested_dynamics} = split_classes(value)
        {classes ++ nested_classes, dynamics ++ nested_dynamics}

      nil, acc ->
        acc

      other, {classes, dynamics} ->
        {classes, dynamics ++ [dynamic_fact("non_string_class", inspect(other), nil)]}
    end)
  end

  defp dynamic_fact(reason, expr, chain) do
    %{dynamic: true, reason: reason, expr: expr, chain: chain}
  end
end
