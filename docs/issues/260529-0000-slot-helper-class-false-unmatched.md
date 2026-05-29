# Slot Helper Classes Reported As Unmatched

## Summary

CSS coverage currently reports classes as unmatched when they are emitted inside a slot passed to a function component and the class expression is nested in the caller-provided slot content.

This produced a false positive in the RSVP app for the admin dark/light background swatches. The rendered HTML contains the classes and the UI depends on them, but `css_coverage.mjs --list-unmatched` reports the CSS selectors as unused.

## Observed Output

Running:

```bash
mix heex_class_analyzer
node lib/mix/tasks/css_coverage.mjs --list-unmatched
```

reported:

```text
--- Unmatched selectors (4) ---
  assets/css/app.css:999  .admin-bg-swatch
  assets/css/app.css:1007  .admin-bg-swatch--colored
  assets/css/app.css:1012  .admin-bg-swatch--none
  assets/css/app.css:1017  .admin-bg-swatch--active
```

## Rendered HTML

The actual rendered HTML contains the classes:

```html
<div class="admin-section-option-bar">
  <div class="segmented-control--bare">
    <button
      type="button"
      phx-click="section_edit:set_text_bg"
      phx-value-field="8b97a6b9-1e2b-4ed0-86d3-51c946aee213"
      phx-value-setting="colored"
      class="segmented-control__bare-btn"
    >
      <span class="admin-bg-swatch admin-bg-swatch--colored"></span>
    </button>

    <button
      type="button"
      phx-click="section_edit:set_text_bg"
      phx-value-field="8b97a6b9-1e2b-4ed0-86d3-51c946aee213"
      phx-value-setting="none"
      class="segmented-control__bare-btn"
    >
      <span class="admin-bg-swatch admin-bg-swatch--none admin-bg-swatch--active"></span>
    </button>
  </div>
</div>
```

## HEEx Reproduction

Caller:

```elixir
defp bg_control(assigns) do
  ~H"""
  <Shared.segmented_control
    current={@current}
    event="section_edit:set_text_bg"
    field={@section_id}
    bare
  >
    <:button :let={%{active?: active?}} value="colored">
      <span class={[
        "admin-bg-swatch admin-bg-swatch--colored",
        active? && "admin-bg-swatch--active"
      ]} />
    </:button>

    <:button :let={%{active?: active?}} value="none">
      <span class={[
        "admin-bg-swatch admin-bg-swatch--none",
        active? && "admin-bg-swatch--active"
      ]} />
    </:button>
  </Shared.segmented_control>
  """
end
```

Component:

```elixir
slot :button do
  attr :value, :string, required: true
end

def segmented_control(assigns) do
  ~H"""
  <div class={[
    !@bare && "segmented-control",
    @bare && "segmented-control--bare"
  ]}>
    <button
      :for={btn <- @button}
      type="button"
      phx-click={@event}
      phx-value-field={@field}
      phx-value-setting={btn.value}
      class={[
        !@bare && "segmented-btn",
        @bare && "segmented-control__bare-btn"
      ]}
    >
      {render_slot(btn, %{active?: btn.value == @current})}
    </button>
  </div>
  """
end
```

CSS:

```css
.admin-bg-swatch {
  display: block;
  width: 1.5rem;
  height: 1.5rem;
  border-radius: 9999px;
}

.admin-bg-swatch--colored {
  background: var(--c-primary);
}

.admin-bg-swatch--none {
  background: var(--c-bg);
}

.admin-bg-swatch--active {
  box-shadow:
    0 0 0 2px var(--c-bg),
    0 0 0 4px var(--c-text);
}
```

## Expected Behavior

The analyzer should preserve classes from slot content when the component renders the slot with `render_slot/2`.

Expected classification:

- `.admin-bg-swatch` -> `matched`
- `.admin-bg-swatch--colored` -> `matched`
- `.admin-bg-swatch--none` -> `matched`
- `.admin-bg-swatch--active` -> `matched` or `possibly_dynamic`

`admin-bg-swatch--active` is controlled by a slot binding:

```elixir
render_slot(btn, %{active?: btn.value == @current})
```

If the analyzer cannot prove the slot binding value, it should still know that the class is possible, not unused.

## Why The Current Workaround Is Wrong

Changing CSS to target implementation-specific component attributes makes coverage pass but makes the stylesheet worse:

```css
.segmented-control--bare .segmented-control__bare-btn[phx-value-setting="colored"] { ... }
```

That couples visual styling to Phoenix event metadata and component internals. The correct CSS is the explicit semantic class selector:

```css
.admin-bg-swatch--colored { ... }
```

The analyzer should not force application CSS into attribute-selector workarounds.

## Fix Direction

Investigate slot materialization for caller slot content with `:let` bindings:

1. Ensure slot child nodes are indexed under the component render site.
2. Preserve static class strings inside slot content.
3. Treat classes depending on slot binding values as optional or dynamic.
4. Add a fixture that proves the four selectors above are not reported as unmatched.

