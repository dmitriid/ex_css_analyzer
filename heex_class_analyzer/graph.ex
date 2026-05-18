defmodule Mix.Tasks.HeexClassAnalyzer.Graph do
  @moduledoc """
  Shared graph helpers for HEEX class analyzer refs and component edges.
  """

  @type ref :: String.t()

  @type component_edge :: %{
          required(:component_refs) => [ref()],
          required(:callsite) => %{tag: String.t(), from: ref()},
          optional(:slot_children) => [map()]
        }

  @spec function_ref(module(), atom(), non_neg_integer(), non_neg_integer()) :: ref()
  def function_ref(module, name, arity, clause_index) do
    "fn:#{inspect(module)}:#{name}:#{arity}:#{clause_index}"
  end

  @spec template_ref(module() | nil | String.t(), String.t()) :: ref()
  def template_ref(module, name) when is_atom(module) do
    "tpl:#{inspect(module)}:#{name}.html.heex"
  end

  def template_ref(source, name) when is_binary(source) do
    "tpl:#{source}:#{name}.html.heex"
  end

  @spec component_edge([ref()], String.t(), ref()) :: component_edge()
  def component_edge(component_refs, tag, from_ref) do
    %{
      component_refs: component_refs,
      callsite: %{tag: tag, from: from_ref}
    }
  end
end
