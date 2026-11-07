# Integration tests for the HEEX class analyzer. The tests parse Elixir
# source and resolve the class graph with the analyzer modules.
#
# Run the tests from the repository root:
#
#     elixir test/heex_class_analyzer_test.exs
#
# The analyzer compiles its test helpers only in the `:test` environment of
# Mix. The script starts Mix in that environment and compiles the analyzer
# modules before the tests.

Mix.start()
Mix.env(:test)

{:ok, _modules, _diagnostics} =
  __DIR__
  |> Path.join("../heex_class_analyzer/*.ex")
  |> Path.wildcard()
  |> Kernel.ParallelCompiler.compile(return_diagnostics: true)

ExUnit.start()

defmodule Mix.Tasks.HeexClassAnalyzer.AssignNewTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.HeexClassAnalyzer.{Discovery, Registry, Resolver}

  defp resolve(source) do
    module_infos = Discovery.parse_ex_content_for_test(source, "lib/sample_web/button.ex")
    registry = Registry.build(module_infos)
    Resolver.resolve_graph(module_infos, registry)
  end

  defp option_classes(exclusive), do: exclusive |> List.flatten() |> Enum.sort()

  test "resolves an assign_new class list with a map lookup" do
    graph =
      resolve(~S"""
      defmodule SampleWeb.Button do
        use Phoenix.Component

        def button(assigns) do
          variants = %{"primary" => "btn-primary", "destructive" => "btn-destructive", nil => "btn-outline"}

          assigns =
            assign_new(assigns, :class, fn ->
              ["btn", Map.fetch!(variants, assigns[:variant]), assigns[:size] == "compact" && "btn-compact"]
            end)

          ~H|<button class={@class}>{render_slot(@inner_block)}</button>|
        end
      end
      """)

    [button] = graph.trees["fn:SampleWeb.Button:button:1:0"]

    assert button.classes.static == ["btn"]
    assert button.classes.optional == ["btn-compact"]

    assert option_classes(button.classes.exclusive) == [
             "btn-destructive",
             "btn-outline",
             "btn-primary"
           ]

    assert button.classes.dynamic == []
  end

  test "resolves a piped assign_new with Map.get, a default, and Access" do
    graph =
      resolve(~S"""
      defmodule SampleWeb.Badge do
        use Phoenix.Component

        def badge(assigns) do
          tones = %{info: "badge-info", danger: "badge-danger"}
          sizes = %{small: "badge-sm"}

          assigns =
            assigns
            |> assign_new(:tone_class, fn -> Map.get(tones, assigns[:tone], "badge-neutral") end)
            |> assign_new(:size_class, fn -> sizes[assigns[:size]] end)

          ~H|<span class={["badge", @tone_class, @size_class]}></span>|
        end
      end
      """)

    [span] = graph.trees["fn:SampleWeb.Badge:badge:1:0"]

    assert "badge" in span.classes.static

    other_classes = span.classes.static -- ["badge"]
    resolved = option_classes(span.classes.exclusive) ++ span.classes.optional ++ other_classes

    assert Enum.sort(resolved) == ["badge-danger", "badge-info", "badge-neutral", "badge-sm"]
  end

  test "ignores a map update in a local variable" do
    graph =
      resolve(~S"""
      defmodule SampleWeb.Row do
        use Phoenix.Component

        def row(assigns) do
          state = %{assigns.state | error: nil}
          assigns = assign(assigns, :state, state)

          ~H|<div class="row"></div>|
        end
      end
      """)

    [div] = graph.trees["fn:SampleWeb.Row:row:1:0"]

    assert div.classes.static == ["row"]
  end

  test "keeps an assign_new value from a variable dynamic" do
    graph =
      resolve(~S"""
      defmodule SampleWeb.Box do
        use Phoenix.Component

        def box(assigns) do
          assigns = assign_new(assigns, :class, fn -> assigns.extra end)

          ~H|<div class={@class}></div>|
        end
      end
      """)

    [div] = graph.trees["fn:SampleWeb.Box:box:1:0"]

    assert div.classes.static == []
    assert [%{dynamic: true}] = div.classes.dynamic
  end

  test "serializes an assign value with a branch that the analyzer cannot resolve" do
    graph =
      resolve(~S"""
      defmodule SampleWeb.Card do
        use Phoenix.Component

        def card(assigns) do
          assigns = assign(assigns, :class, if(assigns.cover, do: cover_class(), else: @link_class))

          ~H|<a class={@class}></a>|
        end

        defp cover_class, do: "card-cover"
      end
      """)

    [link] = graph.trees["fn:SampleWeb.Card:card:1:0"]

    # The JSON output reads the `:chain` key of each dynamic class.
    assert [{:dynamic, %{chain: chain}}] = for({:dynamic, _info} = item <- link.static, do: item)
    assert is_binary(chain)
  end
end
