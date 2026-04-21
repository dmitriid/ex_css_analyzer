# What

LLMs tend top produce *a lot* of CSS, and rarely clean it up. This is a mix task and a script to analyze your css and remove some of it.

See below for how to use this, and a description of what it does.

## Caveat

This is AI-slop. I looked at a total of may be 10 lines of code of this. This is also why I don't release it as an installable library:
there's already too much AI-generated code as it is.

However, I use this myself, and at *works on my machine*. YMMV :)

I will gladly accept PRs, see Contributing section at the end.

**Note**: this README is human-generated

# Install

- Download ZIP of this directory
- Extract to `<your project>/lib/mix/tasks`
  ```
  lib/mix
    └── tasks
        ├── css_coverage.mjs
        ├── heex_class_analyzer
        │   ├── discovery.ex
        │   ├── expression.ex
        │   ├── heex_parser.ex
        │   ├── node.ex
        │   ├── output.ex
        │   ├── permutations.ex
        │   ├── registry.ex
        │   └── resolver.ex
        └── heex_class_analyzer.ex

  ```
- Install ` postcss`, `postcss-import`, `postcss-selector-parser`
  
  I did it globally:
  ```
  npm install -g postcss postcss-import postcss-selector-parser
  ```
- Add `analyse/` to `.gitignore`: this directory will contain results of css analysis

# Usage

There are two parts: 

1. A `mix` task to analyze `heex` templates and `~H` macros, recursively, resolving all function calls and components, and build a list of possible css
2. A Node script to list, mark, or remove dead code

## 1. `mix heex_class_analyzer`

Run `mix heex_class_analyzer`.

This will output analysis result to `<propject dir>/analysis`

See also `mix help heex_class_analyzer`

## 2. run `node lib/mix/tasks/css_coverage.mjs`

- To output analysis only to `analysis/css-coverage.json`, run
  ```
  node lib/mix/tasks/css_coverage.mjs
  ```

- To list dead selectors and animations, run
  ```
  node lib/mix/tasks/css_coverage.mjs --list-unmatched
  ```

- To invalidate dead selectors and animations, run
  ```
  node lib/mix/tasks/css_coverage.mjs --invalidate-unmatched
  ```
  This will prepend `____unmatched___` to all dead selectors and animations. Use this to check that CSS isn't broken

- To restore dead selectors and animations after invalidation, run
  ```
  node lib/mix/tasks/css_coverage.mjs --restore-unmatched
  ```
  This will remove the `____unmatched___` prefix

- To remove dead selectors and animations, run
  ```
  node lib/mix/tasks/css_coverage.mjs --remove-unmatched
  ```
  This will remove all dead selectors and update `app.css`:
  - If there are multiple selectors, will remove only dead ones
  - If it's a single selector, remove it's associated style declarations
  - If after removal `@media` or similar query becomes empty, remove it, too

See also `node lib/mix/tasks/css_coverage.mjs --help`

# Slightly more details

Every module is extensiveley documented... by AI.

## `mix heex_class_analyzer`

This task looks into `<project-dir>/lib/*_web` directory, recursively, and parses all `.heex` templates, and all `~H` macros inside all `.ex` files, as follows (simplified):

- extracts string `class=""` atrtributes, and splits class names from the string
  
  E.g. `<div class="hero hero_image"></div>` becomes `static: ["hero", "hero_image]`

- extracts strings from class lists
  
  E.g. `<div class={["hero", "hero_image"]}></div>` becomes `static: ["hero", "hero_image]`

- extracts conditionals
  
  E.g. `<div class={["hero", @image && "hero_image"]}></div>` becomes `static: ["hero"], variants: ["hero_image"]`
  
  It handles `&&`, `||`, `if`, `cond` etc.

- extracts values from helper functions

  E.g. this:

  ```
    <div class={"hero #{color_variant(@theme)}"}></div>



    def color_variant("dark"): "blue"
    def color_variant("light"): "white"
  ```

  becomes
  ```
  {
    tag: "div",
    static: ["hero"],
    variants: ["blue", "white"]
  }
  ```
  Basicallym, it tries to see what strings are returned by the function, and uses that.

- recurses into components.

  E.g. `<div class="hero"><MyApp.Components.Hero.render_image class="hidden" /></div>` becomes

  ```
  {
    tag: "div",
    static: ["hero"],
    children: [
        {
            node: MyApp.Components.Hero.render_image,
            static: ["hidden"]
        }
    ]
  }
  ```
  This handles:
  - "external" components, e.g. `<Myapp.Component />`
  - function components, e.g. `<.element>x</.element>`

After classes are extracted we create all possible combinations of these classes and variants. E.g. (permutations is the wrong name, itr should be combinations, but oh well): 
```
            {
              "tag": "label",
              "static": [
                "label",
                "mb-2",
                "font-medium"
              ],
              "children": [],
              "variants": [],
              "permutations": [
                [
                  "label"
                ],
                [
                  "mb-2"
                ],
                [
                  "font-medium"
                ],
                [
                  "label",
                  "mb-2"
                ],
                [
                  "label",
                  "font-medium"
                ],
                [
                  "mb-2",
                  "font-medium"
                ],
                [
                  "label",
                  "mb-2",
                  "font-medium"
                ]
              ]
            }

```

We do this to make sure that we know that CSS selector `class1.class2` catches `class1 class2 class3`.

We do this for every module, and save analysis of every module in `analysis/<ModuleName>.json`. Take a look, there's more info than just in this simplified description. Example:

```
{
  "functions": [
    {
      "name": "admin_text_body/1",
      "tree": [
        {
          "tag": "div",
          "static": [
            "section-text-content__body",
            "editable-area"
          ],
          "children": [],
          "variants": [
            {
              "type": "either",
              "values": [
                [
                  "section-text-content__body--align-right"
                ],
                [
                  "section-text-content__body--align-center"
                ],
                [
                  "section-text-content__body--align-left"
                ]
              ]
            }
          ],
          "permutations": [
            [
              "section-text-content__body"
            ],
            [
              "editable-area"
            ],
            [
              "section-text-content__body--align-right"
            ],
...
  "dynamic": [
    {
      "reason": "assign",
      "path": "render_section_content/1#1 > div > div > Shared.segmented_control > :button > .icon > span",
      "expr": "@name",
      "location": "static",
      "chain": "@name",
      "path_parts": [
        "render_section_content/1#1",
        "div",
        "div",
        "Shared.segmented_control",
        ":button",
        ".icon",
        "span"
      ]
    },
    {
      "reason": "assign",
      "path": "render_section_content/1#1 > div > div > Shared.segmented_control > :button > .icon > span",
      "expr": "@class",
      "location": "static",
      "chain": "@class",
      "path_parts": [
        "render_section_content/1#1",
        "div",
        "div",
        "Shared.segmented_control",
        ":button",
        ".icon",
        "span"
      ]
    },
```

## node lib/mix/tasks/css_coverage.mjs

This script parses `app.css` with PostCSS, loads analysis made by the mix task and basically tries to match existing CSS selectors to selector combinations found by the mix task.

The result is output to `analysis/css-coverage.json`.

It will contain which selectors have been matched, skipped or unmatched, and why.

Examples:

```
  "matched": [
    {
      "selector": ".btn",
      "file": "assets/css/app.css",
      "line": 20,
      "matches": [
        {
          "module": "Web.Admin.EventEditorLive",
          "function": "render/1",
          "path": [
            "Layouts.event",
            "Admin.admin_toolbar",
            ":left",
            "div.admin-toolbar__actions",
            "button.btn.btn-primary"
          ],
          "chain": "render/1 → Layouts.event → Admin.admin_toolbar → :left → div.admin-toolbar__actions → button.btn.btn-primary",
          "dynamic": null
        },

....

 "unmatched": [
    {
      "selector": ".btn-soft",
      "file": "assets/css/app.css",
      "line": 120,
      "diagnostics": {
        "classes_found": [],
        "classes_not_found": [
          "btn-soft"
        ],
        "note": "no classes from this selector exist in any template"
      }
    },
    {
      "selector": "-.admin-page .card",
      "file": "assets/css/app.css",
      "line": 142,
      "diagnostics": {
        "classes_found": [
          "admin-page"
        ],
        "classes_not_found": [
          "card"
        ],
        "note": "card not found in any template"
      }
    }
....
```

## Removing dead CSS

When you run `node lib/mix/tasks/css_coverage.mjs --remove-unmatched`:

- if there's multiple selectors to a style, remove only dead ones:
  
  ```
  .class1 .class2, /* this one is dead */
  .class3,
  .class4  {
    ...
  }
  ```

  becomes

  ```
  .class3,
  .class4  {
    ...
  }
  ```
- if there's a single selectors to a style, remove both the selector and the style:
  
  ```
  .class1 .class2, /* this one is dead */{
    ...
  }

  .some-other-style {}
  ```

  becomes

  ```
  .some-other-style {}
  ```

- if an `@`-rule becomes empty after removal, remove the rule:
  
  ```
  @media (min-width: 1024px) {
    .dead-class {
        grid-template-columns: 7fr 5fr;
        min-height: 70vh;
    }
  }

  .other-class {}

  ```

  becomes

  ```
  .other-class {}
  ```

- unused `@keyframe` animations are removed

  ```
  @keyframes dead-anim {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.85; }
  }
  @keyframes other {}
  ```

  becomes

  ```
  @keyframes other {}
  ```

  **Caveat:** does not parse/look at Tailwind's `anim-[<animation name>]` classes

## Unresolved classes

Sometimes the mix task cannot resolve the class name because it's a runtime value. Example:

```
attr :class, :string

def button(assigns), do: ~H"<button class={@class}>Button</button>"
```

In this case a class is marked as "dynamic". It will also participate in all permutations etc., but it will not be matched or removed.

Check out the "dynamic" data that the task outputs as a result of its run. Example:

```
  "dynamic": [
    {
      "reason": "assign",
      "path": "admin_nav/1 > nav > button > .icon > span",
      "expr": "@name",
      "location": "static",
      "chain": "@name",
      "path_parts": [
        "admin_nav/1",
        "nav",
        "button",
        ".icon",
        "span"
      ]
    },
    {
      "reason": "assign",
      "path": "admin_nav/1 > nav > button > .icon > span",
      "expr": "@class",
      "location": "static",
      "chain": "@class",
      "path_parts": [
        "admin_nav/1",
        "nav",
        "button",
        ".icon",
        "span"
      ]
    },

```


# Contributing

If you find this useful, and find issues and edge cases, please send PRs. If you send an AI-generated PR, please provide the prompt used to generate it, or a short explanation (e.g. of an actual bug). See examples below.

## Prompts

Some prompts I recovered from working on this (using [superpowers](https://github.com/obra/superpowers)):

```
/brainstorming

I need two scripts:

- script one goes through each file in `lib/*_web`, finds HEEX templates (heex files, or ~H macros), parses them, and extracts class names from them. This has to be recursive, and parsing function elements, and function calls.

  Example ~H"""<div class="a"><Module.x /><.element>aaa</.element><span class={helper("x")}></div> should all be parsed in place, recursively, all classes extracted. Variants extracted too, e.g. <div class={["class1", x && "class2"]}> should extract both

classes should be stored hierarchichally based on child elements, with all combinations of variants being on the same hierarchy level. E.g.

   - class-1
   -- child-element-class-2
   --- grandchild-class-1
   --- grandchild-variant
   --- grand-child-class-1 grandchild-variant

these have to be saved in a .gitignored directory for example ./analysys, per module. E.g. Module1 will contain all the hierarchy starting from Module1 etc.

```

```
/brainstorming

we have a `mix heex_class_analyzer` that analyses all potential css combinations. See moduledocs for modules in @lib/mix/tasks/heex_class_analyzer/ and output in analysis. Now we want another script that can be written in any language, not necessarily elixir:

- extract all style combinations from app.css
  examples: 
      .class1, .class2{<styles>} is [class1, class2]
      .class1 .class2, .class 3 {} is [[class1, class2], class3]
- for each of these extracted combination, and for each combination inside, try to match it to a combination/permutation in the output of the mix task
example:

app.css:
   .class1 > .class2 {}
mix task:
   ....permutations: [...[class1, class2], ]
result: match


example:

app.css
    .class3 .class4 {}
mix task: 
    <no such permutation>
result: no match


output all matching and non-matching combinations. matching combinations should point to where they were found
```


## Bug prompts

```
problems: a list of class strings shouldn't be compacted into a single class string (e.g. in resolver). for purposes of further analysis these are permutations as well (to be combined witrh variant permutations). because "class-1 class-2 class-3" can easily be targeted by css containing ".class1.class3"
```

```
not all permutations are calculated. I was wrong, I need not permutations of all classes, but combinations of all classes, without repitition.
```


```
one issue. selectors like `.class1 .class2` can match any depth of the child with .class2
```