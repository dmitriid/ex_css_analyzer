defmodule Mix.Tasks.HeexClassAnalyzer.Node do
  @moduledoc """
  The main data structure of the HEEX class analyzer.

  A `Node` is one HTML element or Phoenix component in a parsed HEEX
  template tree. It contains these items:

  - The tag name of the element
  - The CSS classes, as static classes and dynamic variants
  - Compact class facts for selector matches
  - The child nodes

  ## Use in the analyzer stages

  All analyzer stages use `Node`:

      Discovery -> HeexParser -> Expression -> Registry -> Resolver -> Output

  - HeexParser. Makes `Node` trees with data in `tag` and `static`. At this
    stage, `static` is a raw string, an `{:expr, code}` tuple, or a list.
  - Resolver. Calls `Expression.analyze/1` on the `static` field. Puts a
    list of class strings into `static` and the dynamic variants into
    `variants`. After that, computes the compact class facts in `classes`
    from the static classes and variants.
  - Output. Reads the tree and writes the final class hierarchy.

  ## Fields

  - `:tag`. The tag name of the element, or `nil` if it is unknown:
    - An HTML element has its tag, for example `"div"` or `"span"`.
    - A Phoenix function component has its dotted name, for example
      `".button"` or `"CoreComponents.icon"`.
    - A slot has a colon prefix, for example `":inner_block"`.

  - `:static`. The CSS class strings that always apply to this element.
    During parsing, this field contains the raw class attribute value, a
    string or an `{:expr, code}` tuple. The Resolver stage changes this
    value to a list.

  - `:variants`. The dynamic class variants. Each variant is one of these
    forms:
    - `{:toggle, classes}`. A class string that applies only on a
      condition. `&&` expressions and `if` without `else` give this form.
    - `{:either, [option1, option2, ...]}`. Class strings that exclude each
      other. `if/else`, `case`, `cond`, and `||` expressions give this
      form. At runtime, exactly one option applies.

  - `:classes`. Compact class facts with four groups: static classes,
    optional classes, branch options that exclude each other, and dynamic
    class sources.

  - `:children`. The child `Node` structs or component edge references. They
    are the elements in this element in the HEEX template.

  - `:repeat`. `true` if the element has a HEEx `:for` attribute. Such an
    element can render several sibling copies of itself.

  - `:slot_bindings`. Parser data from HEEx `:for` expressions such as
    `btn <- @button`. The resolver uses it to link `render_slot(btn, ...)`
    to the named slot `:button` before it writes the output.

  ## Examples

      # A simple div with static classes
      %Node{
        tag: "div",
        static: ["flex", "items-center", "gap-2"],
        variants: [],
        classes: %{static: ["flex", "items-center", "gap-2"], optional: [], exclusive: [], dynamic: []},
        children: []
      }

      # A button with a conditional "active" class
      %Node{
        tag: "button",
        static: ["btn"],
        variants: [{:toggle, "btn-active"}],
        classes: %{static: ["btn"], optional: ["btn-active"], exclusive: [], dynamic: []},
        children: []
      }

      # A span that is either "text-green-500" or "text-red-500"
      %Node{
        tag: "span",
        static: ["font-bold"],
        variants: [{:either, ["text-green-500", "text-red-500"]}],
        classes: %{static: ["font-bold"], optional: [], exclusive: [[["text-green-500"], ["text-red-500"]]], dynamic: []},
        children: []
      }
  """

  @type dynamic_info :: {:dynamic, %{reason: String.t(), expr: String.t(), chain: String.t()}}
  @type class_value :: String.t() | dynamic_info()
  @type variant :: {:toggle, class_value()} | {:either, [class_value() | [class_value()]]}
  @type child :: t() | Mix.Tasks.HeexClassAnalyzer.Graph.component_edge()
  @type class_facts :: Mix.Tasks.HeexClassAnalyzer.ClassFacts.t()

  @type t :: %__MODULE__{
          tag: String.t() | nil,
          static: [class_value()],
          variants: [variant()],
          classes: class_facts(),
          children: [child()],
          repeat: boolean(),
          slot_bindings: %{optional(String.t()) => String.t()}
        }

  defstruct tag: nil,
            static: [],
            variants: [],
            classes: %{static: [], optional: [], exclusive: [], dynamic: []},
            children: [],
            repeat: false,
            slot_bindings: %{}
end
