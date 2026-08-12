# Raw HTML Element Selector Design

## Problem

The CSS analyzer reports selectors such as `.event-page ul` as unmatched.
The application creates these elements from Markdown at run time.
The HEEX template uses an imported `Phoenix.HTML.raw/1` call for this output.
The analyzer does not add a raw HTML placeholder for this call.

## Selected design

The resolver will recognize `raw/1` when the calling module imports `Phoenix.HTML`.
The resolver will add the existing raw HTML placeholder to the graph.
The CSS matcher will use the placeholder for one tag-only selector segment.
This behavior will match `.event-page ul`, `.event-page ol`, and `.event-page li:last-child`.

The matcher will not use the placeholder for a class, an ID, or a deep raw HTML path.
This limit reduces false matches.

## Test design

An analyzer test will define a module that imports `Phoenix.HTML`.
The test module will render `raw(markdown_to_html(...))` below `.event-page`.
The generated graph must contain a raw HTML placeholder.

A CSS coverage test will use the generated graph.
The three example selectors must be in the `matched` list.
An unrelated deep selector must stay in the `unmatched` list.

