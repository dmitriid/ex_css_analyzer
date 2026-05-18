defmodule Mix.Tasks.HeexClassAnalyzer.Node do
  @moduledoc """
  The core data structure for the HEEX class analyzer pipeline.

  A `Node` represents a single HTML or Phoenix component element in a parsed
  HEEX template tree. Each node carries the element's tag name, its CSS class
  information (split into static classes and dynamic variants), compact class
  facts for selector matching, and a list of child nodes forming the tree
  structure.

  ## Pipeline Role

  `Node` is the universal data structure flowing through the entire analyzer
  pipeline:

      Discovery -> HeexParser -> Expression -> Registry -> Resolver -> Output

  - **HeexParser** produces `Node` trees with `tag` and `static` populated
    (where `static` may be a raw string, an `{:expr, code}` tuple, or a list).
  - **Resolver** enriches nodes by running `Expression.analyze/1` on the
    `static` field to populate `static` (as a list of class strings) and
    `variants`.
  - **Resolver** also fills in the `classes` field with compact class facts
    derived from static classes and variants.
  - **Output** traverses the tree to render the final class hierarchy.

  ## Fields

  - `:tag` - The element tag name. For HTML elements this is the tag (e.g.,
    `"div"`, `"span"`). For Phoenix function components it is the dotted name
    (e.g., `".button"`, `"CoreComponents.icon"`). For slots it is prefixed
    with a colon (e.g., `":inner_block"`). `nil` if unknown.

  - `:static` - A list of CSS class strings that are always applied to this
    element. During parsing, this field temporarily holds the raw class
    attribute value (a string or `{:expr, code}` tuple) before the Resolver
    stage processes it into a proper list.

  - `:variants` - A list of dynamic class variants. Each variant is one of:
    - `{:toggle, classes}` - A class string conditionally applied (from `&&`
      expressions or `if` without `else`). The classes may or may not be
      present.
    - `{:either, [option1, option2, ...]}` - Mutually exclusive class strings
      (from `if/else`, `case`, `cond`, or `||` expressions). Exactly one of
      the options will be applied at runtime.

  - `:classes` - Compact class facts describing always-present static classes,
    optional classes, mutually exclusive branch options, and dynamic class
    sources.

  - `:children` - A list of child `Node` structs or component edge refs
    forming the tree hierarchy. Corresponds to elements nested within this
    element in the HEEX template.

  - `:repeat` - Whether the element has a HEEx `:for` attribute and may render
    multiple sibling copies of itself.

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
          repeat: boolean()
        }

  defstruct tag: nil,
            static: [],
            variants: [],
            classes: %{static: [], optional: [], exclusive: [], dynamic: []},
            children: [],
            repeat: false
end
