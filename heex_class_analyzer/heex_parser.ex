defmodule Mix.Tasks.HeexClassAnalyzer.HeexParser do
  @moduledoc """
  Tokenizes and parses HEEX template strings into `Node` trees.

  This module is the second stage in the analyzer pipeline, taking raw HEEX
  template content (discovered by `Discovery`) and producing a tree of `Node`
  structs representing the element hierarchy with their class attributes
  extracted.

  ## Pipeline Role

      Discovery -> **HeexParser** -> Expression -> Registry -> Resolver -> Permutations -> Output

  The `HeexParser` receives a HEEX string and returns a list of root `Node`
  structs. At this stage, nodes have their `tag` and `static` fields populated.
  The `static` field contains the raw class attribute value -- either a plain
  string for static classes, an `{:expr, code}` tuple for dynamic expressions,
  or an empty list if no class attribute is present. Nodes with HEEx `:for`
  also get `repeat: true`, preserving the fact that one template node may
  render multiple sibling elements. Later pipeline stages (Resolver/Expression)
  analyze these values further.

  ## Public API

      HeexParser.parse(heex_string) :: [Node.t()]

  ### Examples

      iex> HeexParser.parse(~S(<div class="flex gap-2"><span class="text-sm">hi</span></div>))
      [%Node{tag: "div", static: "flex gap-2", children: [
        %Node{tag: "span", static: "text-sm", children: []}
      ]}]

      iex> HeexParser.parse(~S(<.button class={@btn_class} />))
      [%Node{tag: ".button", static: {:expr, "@btn_class"}, children: []}]

      iex> HeexParser.parse(~S(<img src="x.png" class="w-full" />))
      [%Node{tag: "img", static: "w-full", children: []}]

      iex> HeexParser.parse(~S(<p :for={line <- @lines} class="note">...</p>))
      [%Node{tag: "p", static: "note", repeat: true, children: []}]

  ## Parsing Details

  ### Tokenization

  The parser first tokenizes the input into a flat list of tokens:

  - `{:open, tag, attrs}` - An opening tag with its attributes map
  - `{:close, tag}` - A closing tag
  - `{:self_close, tag, attrs}` - A self-closing tag (explicit `/>` or void element)

  ### Tag Name Support

  The tokenizer recognizes several tag name formats:

  - **HTML tags**: `div`, `span`, `section`, etc.
  - **Phoenix function components**: `.func` (local) or `Module.func` (remote)
  - **Slots**: `:inner_block`, `:col`, etc. (prefixed with colon)

  ### Attribute Handling

  Attributes are parsed into a map. The class attribute value is extracted as:

  - A plain string for `class="static classes"`
  - An `{:expr, code}` tuple for `class={dynamic_expression}`
  - `repeat: true` metadata for elements with HEEx `:for`
  - `true` for boolean attributes (no value)
  - Only `class` and the presence of `:for` are preserved in the output nodes;
    other attributes are discarded.

  ### Void Elements

  HTML void elements (`area`, `base`, `br`, `col`, `embed`, `hr`, `img`,
  `input`, `link`, `meta`, `param`, `source`, `track`, `wbr`) are
  automatically treated as self-closing regardless of whether they have
  an explicit `/>`.

  ### Skipped Content

  The following are recognized and skipped (not included in the output tree):

  - HEEX comments: `<%!-- ... --%>`
  - HTML comments: `<!-- ... -->`
  - EEx expressions: `<%= ... %>` and `<% ... %>`
  - HEEX expressions at the text level: `{...}` (top-level curly brace blocks)
  - Plain text content between tags

  ### Tree Building

  After tokenization, the flat token list is assembled into a tree using a
  stack-based algorithm. The builder handles:

  - Properly nested elements (normal case)
  - Unclosed tags (treated as best-effort; popped from the stack as orphans)
  - Mismatched closing tags (unmatched close tags are skipped)
  - Nested string literals, heredocs, sigils, and charlists within `{...}`
    expressions (correctly balanced braces)

  ## Edge Cases

  - Malformed HTML is handled gracefully: unclosed tags are finalized when
    input is exhausted, and unmatched closing tags are silently skipped.
  - Deeply nested `{...}` expressions with internal braces, strings, and
    sigils are correctly parsed by tracking brace depth and recognizing
    string delimiters.
  - An invalid opening tag (e.g., `< `) causes the `<` character to be
    skipped and parsing continues.
  - Empty input returns an empty list.

  ## Interaction with Other Modules

  - **Input**: Raw HEEX strings from `Discovery` (extracted from `~H` sigils,
    `.heex` files, or `render/1` functions).
  - **Output**: `[Node.t()]` consumed by `Resolver`, which calls
    `Expression.analyze/1` on each node's `static` field and then
    `Permutations.compute/2` to fill in the remaining node fields.
  """

  alias Mix.Tasks.HeexClassAnalyzer.Node

  @void_elements ~w(area base br col embed hr img input link meta param source track wbr)

  @spec parse(String.t()) :: [Node.t()]
  def parse(heex_string) do
    heex_string
    |> tokenize()
    |> build_tree()
  end

  # --- Tokenizer ---

  # Produces a flat list of tokens:
  # {:open, tag, attrs} | {:close, tag} | {:self_close, tag, attrs}

  defp tokenize(input), do: tokenize(input, [])

  defp tokenize("", acc), do: Enum.reverse(acc)

  # HEEX comment: <%!-- ... --%>
  defp tokenize("<%!--" <> rest, acc) do
    case skip_heex_comment(rest) do
      nil -> Enum.reverse(acc)
      remaining -> tokenize(remaining, acc)
    end
  end

  # HTML comment: <!-- ... -->
  defp tokenize("<!--" <> rest, acc) do
    case skip_html_comment(rest) do
      nil -> Enum.reverse(acc)
      remaining -> tokenize(remaining, acc)
    end
  end

  # EEx expressions: <%= ... %> or <% ... %>
  defp tokenize("<%" <> rest, acc) do
    case skip_eex_expression(rest) do
      nil -> Enum.reverse(acc)
      remaining -> tokenize(remaining, acc)
    end
  end

  # Closing tag: </tag>
  defp tokenize("</" <> rest, acc) do
    case parse_closing_tag(rest) do
      {tag, remaining} -> tokenize(remaining, [{:close, tag} | acc])
      nil -> Enum.reverse(acc)
    end
  end

  # HEEX expression: {expr} — skip entire expression block
  defp tokenize("{" <> rest, acc) do
    {_expr, remaining} = read_brace_expression(rest, 1, "")
    tokenize(remaining, acc)
  end

  # Opening tag: <tag ...> or <tag ... />
  defp tokenize("<" <> rest, acc) do
    case parse_opening_tag(rest) do
      {tag, attrs, :self_close, remaining} ->
        tokenize(remaining, [{:self_close, tag, attrs} | acc])

      {tag, attrs, :open, remaining} ->
        if void_element?(tag) do
          tokenize(remaining, [{:self_close, tag, attrs} | acc])
        else
          tokenize(remaining, [{:open, tag, attrs} | acc])
        end

      nil ->
        # Not a valid tag, skip the '<' character
        tokenize(rest, acc)
    end
  end

  # Skip text content
  defp tokenize(<<_::utf8, rest::binary>>, acc) do
    tokenize(skip_text(rest), acc)
  end

  defp skip_text(""), do: ""
  defp skip_text("<" <> _ = rest), do: rest
  defp skip_text("{" <> _ = rest), do: rest
  defp skip_text(<<_::utf8, rest::binary>>), do: skip_text(rest)

  defp skip_heex_comment(""), do: nil
  defp skip_heex_comment("--%>" <> rest), do: rest
  defp skip_heex_comment(<<_::utf8, rest::binary>>), do: skip_heex_comment(rest)

  defp skip_html_comment(""), do: nil
  defp skip_html_comment("-->" <> rest), do: rest
  defp skip_html_comment(<<_::utf8, rest::binary>>), do: skip_html_comment(rest)

  defp skip_eex_expression(""), do: nil
  defp skip_eex_expression("%>" <> rest), do: rest
  defp skip_eex_expression(<<_::utf8, rest::binary>>), do: skip_eex_expression(rest)

  # --- Closing tag parser ---

  defp parse_closing_tag(input) do
    case parse_tag_name(input) do
      {"", _} -> nil
      {tag, rest} -> close_tag_end(String.trim_leading(rest), tag)
    end
  end

  defp close_tag_end(">" <> rest, tag), do: {tag, rest}
  defp close_tag_end(_, _tag), do: nil

  # --- Opening tag parser ---

  defp parse_opening_tag(input) do
    case parse_tag_name(input) do
      {"", _} -> nil
      {tag, rest} -> parse_tag_attrs(rest, tag, %{})
    end
  end

  # Parse tag name: supports HTML tags, Phoenix components (.func, Module.func),
  # and slots (:slot_name)
  defp parse_tag_name(input) do
    parse_tag_name(input, "")
  end

  defp parse_tag_name("", acc), do: {acc, ""}

  # First character can be a-z, A-Z, dot (component), or colon (slot)
  defp parse_tag_name(<<c, rest::binary>>, "") when c in ?a..?z or c in ?A..?Z do
    parse_tag_name(rest, <<c>>)
  end

  defp parse_tag_name(<<".", rest::binary>>, "") do
    parse_tag_name(rest, ".")
  end

  defp parse_tag_name(<<":", rest::binary>>, "") do
    parse_tag_name(rest, ":")
  end

  # Subsequent characters: letters, digits, dash, underscore, dot (for Module.Name.func)
  defp parse_tag_name(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?- or c == ?_ or c == ?. do
    parse_tag_name(rest, acc <> <<c>>)
  end

  defp parse_tag_name(rest, acc), do: {acc, rest}

  # --- Attribute parsing ---

  defp parse_tag_attrs(input, tag, attrs) do
    input = skip_whitespace(input)

    cond do
      # Self-closing />
      String.starts_with?(input, "/>") ->
        {tag, attrs, :self_close, String.slice(input, 2, String.length(input))}

      # End of tag >
      String.starts_with?(input, ">") ->
        {tag, attrs, :open, String.slice(input, 1, String.length(input))}

      # Empty input (malformed)
      input == "" ->
        nil

      # Attribute
      true ->
        case parse_one_attr(input) do
          {name, value, rest} ->
            attrs = Map.put(attrs, name, value)
            parse_tag_attrs(rest, tag, attrs)

          nil ->
            # Skip one character and try again (graceful handling)
            <<_::utf8, rest::binary>> = input
            parse_tag_attrs(rest, tag, attrs)
        end
    end
  end

  defp parse_one_attr(input) do
    case parse_attr_name(input) do
      {"", _} -> nil
      {name, rest} -> parse_attr_value(rest, name)
    end
  end

  defp parse_attr_name(input), do: parse_attr_name(input, "")

  defp parse_attr_name(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?- or c == ?_ or c == ?: or
              c == ?@ or c == ?. do
    parse_attr_name(rest, acc <> <<c>>)
  end

  defp parse_attr_name(rest, acc), do: {acc, rest}

  defp parse_attr_value("=" <> rest, name) do
    rest = skip_whitespace(rest)

    case rest do
      # Double-quoted value
      "\"" <> rest2 ->
        {value, remaining} = read_quoted_string(rest2, "\"")
        {name, value, remaining}

      # Single-quoted value
      "'" <> rest2 ->
        {value, remaining} = read_quoted_string(rest2, "'")
        {name, value, remaining}

      # Dynamic expression: {expr}
      "{" <> rest2 ->
        {expr, remaining} = read_brace_expression(rest2, 1, "")
        {name, {:expr, expr}, remaining}

      _ ->
        # Bare value (up to whitespace or > or />)
        {value, remaining} = read_bare_value(rest)
        {name, value, remaining}
    end
  end

  # Boolean attribute (no value)
  defp parse_attr_value(rest, name) do
    {name, true, rest}
  end

  defp read_quoted_string(input, quote_char), do: read_quoted_string(input, quote_char, "")

  defp read_quoted_string("", _quote, acc), do: {acc, ""}

  defp read_quoted_string(<<q, rest::binary>>, <<q>>, acc) do
    {acc, rest}
  end

  defp read_quoted_string(<<c::utf8, rest::binary>>, quote, acc) do
    read_quoted_string(rest, quote, acc <> <<c::utf8>>)
  end

  # Read a brace-delimited expression, handling nested braces, strings, and charlists
  defp read_brace_expression("", _depth, acc), do: {acc, ""}

  defp read_brace_expression("}" <> rest, 1, acc) do
    {acc, rest}
  end

  defp read_brace_expression("}" <> rest, depth, acc) do
    read_brace_expression(rest, depth - 1, acc <> "}")
  end

  defp read_brace_expression("{" <> rest, depth, acc) do
    read_brace_expression(rest, depth + 1, acc <> "{")
  end

  # Double-quoted string inside expression
  defp read_brace_expression("\"\"\"" <> rest, depth, acc) do
    {str_content, remaining} = read_heredoc_string(rest, "\"\"\"")
    read_brace_expression(remaining, depth, acc <> "\"\"\"" <> str_content <> "\"\"\"")
  end

  defp read_brace_expression("\"" <> rest, depth, acc) do
    {str_content, remaining} = read_string_in_expr(rest, ?")
    run_brace_expression(remaining, depth, acc <> "\"" <> str_content <> "\"")
  end

  # Single-quoted charlist inside expression
  defp read_brace_expression("'" <> rest, depth, acc) do
    {str_content, remaining} = read_string_in_expr(rest, ?')
    run_brace_expression(remaining, depth, acc <> "'" <> str_content <> "'")
  end

  # Sigil strings like ~s{...} or ~S{...}
  defp read_brace_expression(<<"~", sigil_type, "{", rest::binary>>, depth, acc)
       when sigil_type in ?a..?z or sigil_type in ?A..?Z do
    {sigil_content, remaining} = read_sigil_braces(rest, 1, "")

    run_brace_expression(
      remaining,
      depth,
      acc <> "~" <> <<sigil_type>> <> "{" <> sigil_content <> "}"
    )
  end

  defp read_brace_expression(<<c::utf8, rest::binary>>, depth, acc) do
    read_brace_expression(rest, depth, acc <> <<c::utf8>>)
  end

  # Helper to continue after reading a string literal
  defp run_brace_expression(remaining, depth, acc) do
    read_brace_expression(remaining, depth, acc)
  end

  # Read a string inside an expression (handles escape sequences)
  defp read_string_in_expr("", _quote), do: {"", ""}

  defp read_string_in_expr(<<q, rest::binary>>, q), do: {"", rest}

  defp read_string_in_expr("\\" <> <<c::utf8, rest::binary>>, quote) do
    {content, remaining} = read_string_in_expr(rest, quote)
    {"\\" <> <<c::utf8>> <> content, remaining}
  end

  defp read_string_in_expr(<<c::utf8, rest::binary>>, quote) do
    {content, remaining} = read_string_in_expr(rest, quote)
    {<<c::utf8>> <> content, remaining}
  end

  # Read heredoc (triple-quote) strings
  defp read_heredoc_string("", _terminator), do: {"", ""}

  defp read_heredoc_string("\"\"\"" <> rest, "\"\"\""), do: {"", rest}

  defp read_heredoc_string(<<c::utf8, rest::binary>>, terminator) do
    {content, remaining} = read_heredoc_string(rest, terminator)
    {<<c::utf8>> <> content, remaining}
  end

  # Read sigil content with brace delimiters (handles nested braces)
  defp read_sigil_braces("", _depth, acc), do: {acc, ""}
  defp read_sigil_braces("}" <> rest, 1, acc), do: {acc, rest}

  defp read_sigil_braces("}" <> rest, depth, acc) do
    read_sigil_braces(rest, depth - 1, acc <> "}")
  end

  defp read_sigil_braces("{" <> rest, depth, acc) do
    read_sigil_braces(rest, depth + 1, acc <> "{")
  end

  defp read_sigil_braces(<<c::utf8, rest::binary>>, depth, acc) do
    read_sigil_braces(rest, depth, acc <> <<c::utf8>>)
  end

  defp read_bare_value(input), do: read_bare_value(input, "")

  defp read_bare_value("", acc), do: {acc, ""}
  defp read_bare_value(">" <> _ = rest, acc), do: {acc, rest}
  defp read_bare_value("/>" <> _ = rest, acc), do: {acc, rest}

  defp read_bare_value(<<c, _::binary>> = rest, acc) when c in [?\s, ?\t, ?\n, ?\r] do
    {acc, rest}
  end

  defp read_bare_value(<<c::utf8, rest::binary>>, acc) do
    read_bare_value(rest, acc <> <<c::utf8>>)
  end

  # --- Utility ---

  defp skip_whitespace(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r] do
    skip_whitespace(rest)
  end

  defp skip_whitespace(rest), do: rest

  defp void_element?(tag), do: tag in @void_elements

  # --- Tree builder ---

  # Builds a tree from the flat token list using a stack.
  defp build_tree(tokens) do
    build_tree(tokens, [], [])
  end

  # tokens exhausted: finalize
  defp build_tree([], [], roots) do
    Enum.reverse(roots)
  end

  # If tokens exhausted but stack is non-empty, pop everything as best-effort
  defp build_tree([], stack, roots) do
    # Close all unclosed tags by popping them into roots
    finalize_stack(stack, roots)
  end

  # Self-closing tag
  defp build_tree([{:self_close, tag, attrs} | rest], stack, roots) do
    node = make_node(tag, attrs)

    case stack do
      [] ->
        build_tree(rest, stack, [node | roots])

      [{parent_tag, parent_attrs, siblings} | outer] ->
        build_tree(rest, [{parent_tag, parent_attrs, [node | siblings]} | outer], roots)
    end
  end

  # Opening tag
  defp build_tree([{:open, tag, attrs} | rest], stack, roots) do
    build_tree(rest, [{tag, attrs, []} | stack], roots)
  end

  # Closing tag
  defp build_tree([{:close, tag} | rest], stack, roots) do
    case pop_to_matching(tag, stack, []) do
      {matched_attrs, children, remaining_stack} ->
        node = make_node(tag, matched_attrs, Enum.reverse(children))

        case remaining_stack do
          [] ->
            build_tree(rest, [], [node | roots])

          [{parent_tag, parent_attrs, siblings} | outer] ->
            build_tree(rest, [{parent_tag, parent_attrs, [node | siblings]} | outer], roots)
        end

      :not_found ->
        # Closing tag without matching open: skip it
        build_tree(rest, stack, roots)
    end
  end

  # Pop the stack until we find a matching open tag.
  # Intermediate unclosed tags become children of the found tag.
  defp pop_to_matching(_tag, [], _orphans), do: :not_found

  defp pop_to_matching(tag, [{tag, attrs, children} | rest], orphans) do
    # The orphans (unclosed intermediate tags) become children of this element
    all_children = Enum.reverse(orphans) ++ children
    {attrs, all_children, rest}
  end

  defp pop_to_matching(tag, [{other_tag, other_attrs, other_children} | rest], orphans) do
    # This intermediate tag is unclosed; turn it into a node and add as orphan
    node = make_node(other_tag, other_attrs, Enum.reverse(other_children))
    pop_to_matching(tag, rest, [node | orphans])
  end

  defp finalize_stack([], roots), do: Enum.reverse(roots)

  defp finalize_stack([{tag, attrs, children} | rest], roots) do
    node = make_node(tag, attrs, Enum.reverse(children))
    finalize_stack(rest, [node | roots])
  end

  # --- Node construction ---

  defp make_node(tag, attrs, children \\ []) do
    class_value = extract_class(attrs)

    %Node{
      tag: tag,
      static: class_value,
      repeat: repeat?(attrs),
      children: children
    }
  end

  defp extract_class(attrs) do
    case Map.get(attrs, "class") do
      nil -> []
      {:expr, expr} -> {:expr, expr}
      value when is_binary(value) -> value
      _ -> []
    end
  end

  defp repeat?(attrs), do: Map.has_key?(attrs, ":for")
end
