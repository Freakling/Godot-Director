<!-- Godot Director · framework-owned: replaced on upgrade. -->
# UI design

The human designs screens by drawing over screenshots of the running game; you capture the screens, read the drawings through a reader, record each screen's layout once in a screen spec, and report what you find. This procedure covers listing and capturing the screens, processing a drawing, and verifying a built screen against its spec. The human decides; you propose. Every step has a text path, for an assistant that can't view images: it is named in the step, and gathered under "If you can't view images" at the end.

Requests:
- `list`: the screens in the catalog.
- `capture [screen|all]` (default `all`).
- `process <screen>`: read the human's drawing of a screen and record it.
- `verify <screen>`: check the built screen against its spec, and write the compare images.
- No argument: `list`, then ask which screen.

## The catalog
`tools/ui_screens.gd` (project-owned, extends `tools/ui_catalog.gd`) lists every screen: an `id`, a `title`, its `scene` (keep it when `setup` builds the screen in code, so the screen can be found from its scene), and how to put it on screen in a representative state (`setup`, or named `states` such as `default` and `empty`). The `overlays` of an entry name what the screen shows that it doesn't draw itself, such as a HUD or a toast layer an autoload owns: `"overlays": ["/root/Hud"]` (an autoload's node path, moved into the screen's viewport for the shot and put back afterwards) or a scene (`"res://scenes/toast.tscn"`, instanced there). Name them whenever a player sees them over the screen. The entry format and the helpers (`reset()`, `open_view()`, `wait_frames()`, `focus_default()`) are documented at the top of `tools/ui_catalog.gd`. A state builds its data through the game's public APIs, fixtures and debug hooks, never player data. If the screen you're asked about has no entry, add one first (`rules.md` › Architecture defaults › UI). Sizes, the seed, the lint thresholds and screens never captured are in `tools/ui_capture.cfg`.

`tools/ui_capture.sh` finds Godot as the check does: `$GODOT_BIN`, else the first line of `tools/godot_bin.local`, else `godot`. If none is found, run `bash tools/setup-clone.sh --skip-hook`.

## list
1. Run `bash tools/ui_capture.sh --list`. It needs no display. Each line has a screen's id, title, states, the scene it opens, and whether a drawing (`director/ui/<id>.excalidraw`) and a spec (`design/ui/<id>.md`) exist.
2. Run `bash tools/ui_capture.sh --missing`. It lists the scenes whose root script is in a screen folder (`tools/check.cfg` › `[screens] dirs`) that no catalog entry opens and that `[capture] skip` doesn't name, as `missing:` lines. It only lists: it never fails. Add an entry for each, or add its scene path to `skip` when it isn't a screen. With no screen folders set it says so and lists nothing.
3. Show it as a short table. A `FAIL` line is a catalog entry with a problem (an unknown key, a duplicate id, a missing scene or overlay scene): fix the entry.

## capture
1. Run `bash tools/ui_capture.sh <screen>`, or `--all`. `--state <name>` narrows it; `--size <W>x<H>` captures one size, listed in `tools/ui_capture.cfg` or not. Godot needs a display, since it renders nothing headless, and opens a small window for a few seconds. The screens themselves are rendered offscreen at each size with the project's stretch settings, so every size captures whatever the monitor; a size the GPU can't render is skipped with a note.
   - Exit 3: say capture couldn't run and why (no Godot, Godot older than 4.5, no display, or Godot couldn't open a window or start its renderer; on Linux it needs a display or `xvfb-run`), and stop. Where the reason is the display, `--no-images` still writes the element maps and lint; say they come from a headless run, whose text measurement can differ slightly.
   - Exit 1: something failed, and the run went on with everything else. The causes, each named in a `FAIL` line:
     - a screen's setup printed a script error, or didn't finish within `[capture] setup_timeout` seconds, or an overlay it names isn't in the scene tree: the error is at the top of that screen's `.lint.txt`;
     - a catalog entry has a problem (an unknown key, a duplicate id, a missing scene, no title, a setup or state that isn't a Callable), or `tools/ui_screens.gd` doesn't compile or doesn't extend `tools/ui_catalog.gd`;
     - the screen or state named doesn't exist, an option is unknown, or `tools/ui_capture.cfg` has a size that isn't `WxH`;
     - a capture file couldn't be written, or Godot ran past `CAPTURE_TIMEOUT` (600 seconds by default).

     Fix what's in the catalog or the settings; report the rest.
2. The outputs are in `design/ui/captures/` (gitignored), per screen, state and size, named `<id>[.<state>]@<W>x<H>` (no state for `default`):
   - `.png`: the screenshot, as a player sees the window at that size.
   - `.elements.json`: the element map. Each mapped element has a number `n`, its `id` (the unique node name when `stable` is true), `path`, `kind`, visible text, `rect` in pixels and `rect_pct` in percent of the capture, `focusable` and `focus_order` (its place in Tab and arrow traversal from the default focus, `null` when unreachable), `overflow`, `min_size`, and Godot extras under `native`. Clickable 3D objects are in `pickables_3d`.
   - `.map.png`: the screenshot with every element outlined and numbered, so you and the human can say "element 4".
   - `.lint.txt`: one finding per line, `<rule> element <n> <path>: <message>`; empty when clean.
   - `<id>.starter.excalidraw`: the drawing to draw over, written with the images for the default state at the default size (the first of `[sizes] list`).
3. Look at each `.png` and its `.lint.txt`; if you can't view images, use `.elements.json`. Report what you find in one line each. The lint rules:

   | Rule | Finding |
   |---|---|
   | `squeezed-text` | Wrapping text narrower than `min_label_chars` average characters, or text overflowing its box without clipping or an ellipsis |
   | `stretched-control` | A button in a Container taller than `max_button_height_ratio` times its minimum height |
   | `off-screen` | An element leaving the screen or its clipping parent (scrolled content is fine) |
   | `overlap` | Two focusable siblings overlapping where the upper one takes the clicks |
   | `unreachable` | An enabled focusable element that Tab, Shift+Tab and the arrows never reach from the default focus |
   | `no-default-focus` | A screen or dialog with focusable elements and nothing focused when it opens |
   | `hard-coded-position` | A pixel position saved on a Container's child, which the Container overrides (a warning) |

   Lint findings never change the exit code. A finding that is a real bug becomes a `B` item once the human agrees (at once inside a `/next-task` run).

4. Tell the human, in these words: "Nothing to install. Open excalidraw.com in Chrome, Edge or another browser: no account is needed, and Excalidraw+ isn't. Open `design/ui/captures/<id>.starter.excalidraw` from the menu's Open, or drag it onto the page, and draw over the screenshot. To save, use Save to… (Ctrl+S saves over the file you opened), and save it as `director/ui/<id>.excalidraw`: Chrome and Edge let you pick that folder; other browsers save to Downloads, so move the file there and rename it. Your drawing stays on this computer unless you use Live collaboration or a shareable link. Tell me when it's saved." Point at `design/ui/README.md` the first time. You never write in `director/`: if `director/ui/` doesn't exist, ask the human to create it, with an empty `director/.gdignore` beside it so the editor doesn't import their exported PNGs.

A capture shows the screen as the catalog opens it, in its own viewport, with the overlays the entry names drawn into it (a HUD an autoload owns is moved in for the shot and put back). What an entry doesn't name isn't in the shot, so a player sees more than the capture when an autoload draws something the entry leaves out. A capture never touches player data: `user://` points at a temporary folder that is deleted afterwards, and `Engine.has_meta("godot_director_check")` and `("godot_director_capture")` are true, so autoloads skip saves and settings. Two captures of the same state and size on the same machine give the same element map and image. A capture changes no source file and commits nothing.

## The lint in the check
`tools/ui_capture.cfg` › `[lint]` has two keys that put the layout lint into `bash tools/check.sh`:
- `check_in_check`: `true` runs the lint in the check, as one more headless Godot run after the check's own, at the default size. A missing key reads as `false`, and then the check is exactly what it was.
- `enforce`: the screen ids that fail the check on a lint finding (`["*"]` is every screen). A finding on any other screen isn't run at all. `hard-coded-position` is a warning and never fails.

A new project starts with `check_in_check=true` and `enforce=["*"]`. An upgrade writes the seed with `check_in_check=false` and `enforce=[]`, so a game adopts the lint one screen at a time: name a screen in `enforce` once its capture is lint-clean. A failing line reads `GDIR-FAIL: ui lint: <id>@<W>x<H>: <rule> element <n> <path>: <message>`; `bash tools/ui_capture.sh <id>` writes the capture and the map image that show it.

## process
`process <screen>` reads `director/ui/<screen>.excalidraw`. If the screen has no drawing, say so and point at its starter drawing (capture it first if it isn't there).
1. **Read.** Run the reader, with Godot found as `list` finds it (no display needed): `"$GODOT_BIN" --headless --path . --script tools/ui_drawing.gd -- director/ui/<id>.excalidraw design/ui/captures/<id>.drawing.json <id>`. Then read `<id>.drawing.json`. Never read the raw `.excalidraw`: it embeds the screenshot as base64. Exit 1 means it isn't valid JSON, isn't an Excalidraw file or has no frame: say which, and stop. To tell what a box overlaps, the reader uses the element map of the frame's state and size in `design/ui/captures/`, so capture the screen first when it's missing.
2. **Also read** the current spec if there is one, the screen's latest `.elements.json`, the GDD sections the screen implements and the related lines in `design/decisions.md`.
3. **Brief the human**, as `design.md` does: what the screen is for, what the drawing changes, element by element, such as:
   - `Gear list (new): a scrolling list on the right third, under the portrait; shows each slot and its item; clicking a row opens Change.`
   - `Belt row (moved): was beside the slots, now its own row above them.`
   - `Repair button (removed).`

   Include what the drawing leaves ambiguous, every `unparsed` entry, and anything it conflicts with: recorded rules, project rules (input support for every action), other screens' specs (Back in the same place).
4. **Confirm the reading** ("Is this what you drew?"). Then, for each open point, offer 2-4 options with a recommendation, as `design.md` › For each question does. Typical open points: what a box does at another aspect ratio, what happens when a list is empty or overflows, the keyboard and controller focus order, which element has default focus, the keys for new actions.
5. **Record in one change**, once the human has settled the points:
   - `design/ui/<id>.md` (the template below), replacing superseded content.
   - `design/decisions.md`: one line per real decision, in its format, with `from: drawing director/ui/<id>.excalidraw`.
   - The GDD only when the drawing changed what the screen does (a new action, a removed feature); layout lives in the spec. A point left undecided becomes an open question (`Q<n>`, bump `Next`), and the spec's Open section names it.
   - `TASKS.md`: one item per screen (split an `L`), with `UI: design/ui/<id>.md`, `Touches`, a tagged `Done when` and the `GDD:` line. The usual outcomes: every element in the spec exists under its unique name and the screen opens without errors `(test)` · the capture is lint-clean at every configured size and matches the spec within tolerance `(check)` · the screen reads as drawn and works by mouse, touch, keyboard and controller where the game supports them `(play)`.
6. **Commit** as `docs: ui <id>` once the human approves, then suggest a fresh session before the next screen (`design.md` › Finish).

## verify
`verify <screen>` checks the built screen against `design/ui/<id>.md`, and writes the compare images. It needs the spec; if there is none, say so and point at `process`.
1. Run `bash tools/ui_capture.sh <id> --verify`. It captures the screen (every state and size), then reads the spec, the element maps and the lint files and prints the result; no display is needed for the second part, so with `--no-images` it checks and writes no compare image. Exit 0: no deviations. Exit 1: deviations, or the capture failed. Exit 3: it couldn't run (as `capture`), or there is no spec or no capture to check.
2. Read the table it prints, one row per element of the spec's Layout table, against the capture at the size in the table's heading (`## Layout (at 1920x1080)`):

   | Check | Deviation when |
   |---|---|
   | Present | no visible element has that unique name |
   | Where | an edge of the element's `rect_pct` is more than `[verify] tolerance_pct` (default 4.0, percent of the screen) from the spec's Where |
   | Reachable | the element is focusable and its `focus_order` is `null` |
   | Lint-clean | a lint finding names the element (a `hard-coded-position` warning is listed, not a deviation) |

   It also lists the elements with a unique name that the spec does not, the lint findings in the screen's other states and sizes, and a drawn box whose element has since moved away from it (with both rectangles; this needs `<id>.drawing.json`).
3. Compare the focus order with the spec's Navigation section: the table shows that an element is reachable, and `.elements.json` gives each element's `focus_order`. Check it against the order the spec writes down.
4. With a drawing processed, `design/ui/captures/<id>[.<state>].compare@<W>x<H>.png` is written for every captured size: the screenshot the drawing was made over on the left, the new capture on the right with the drawing's boxes outlined, labelled `b1`, `b2` ... as in `<id>.drawing.json` and coloured by intent (green new, blue keep, red remove, orange unsure, dark default). Look at it if you can; the table says the same in text.
5. Report the deviations as a short table (element, expected, found, verdict). Fix the in-scope ones in the same item, and file the rest as `B` items once the human agrees (at once inside a `/next-task` run). A build item reports it as its `Screen:` line.

`tools/ui_overlay.gd -- compare design/ui/captures/<id>@<W>x<H>` redraws one compare image without a capture.

### Reading a drawing
The conventions the human follows are in `design/ui/README.md`. The reader (`tools/ui_drawing.gd`) turns them into `<id>.drawing.json` (`"schema": 1`), with one entry per frame:
- Frames are named `<id>`, `<id>.<state>` or `<id>@<W>x<H>`. `name` is the screen, `state` defaults to `default`, and `size` is the background image's size in pixels.
- `boxes`: one per rectangle, `id` being `b1`, `b2` ... in the file's order. The text bound to the rectangle is its `text`; its first line is the `label`, and `keys` holds the lines that start with `shows`, `does`, `click`, `key`, `size`, `stick`, `scroll`, `empty` or `hidden when`.
- `intent` comes from the stroke colour: `new` (green), `keep` (blue), `remove` (red), `unsure` (orange), else `default`.
- `rect_pct` is `[x, y, w, h]` in percent of the background image, to 0.1: the layout at the capture's size, the same wherever the image sits and however it is scaled.
- `parent` is the smallest box that fully contains it. `flows_to` lists the boxes an arrow leads to. `overlaps` lists the mapped elements it covers, when their intersection over union is above 0.2, as `{"n", "name", "iou"}`: how you tell a new box from one drawn over an existing element.
- `comments`: free text within 1.5 times its own height of a box, or joined to it by an arrow. Other text in the frame is a frame note, and text outside every frame is a note for every frame. `mode` is `patch` (what the human didn't touch stays) unless a note says `mode: replace`.
- `removed`: the mapped element a red X is over, as `{"n", "name", "by": "red-x"}`.
- `unparsed`: what the reader didn't understand, such as a freehand line, an ellipse or a red line that isn't part of an X. Ask about each; never guess.

### The screen spec
`design/ui/<id>.md` is the one place a screen's layout is recorded. The percentages guide the layout system and aren't positions: build with Containers and anchors. `Name` is the unique node name the build must create (`%GearList`), and the Layout table is what verifying the screen checks.

```markdown
# Hero room
**Opens:** res://scenes/shell/HeroRoomView.tscn · **Catalog:** hero_room (default, exhausted)
**Drawing:** director/ui/hero_room.excalidraw (sha1 3f2a..., processed 2026-10-16) · **GDD:** Heroes and Staff › Hero rooms

## Purpose
One or two lines: what the player does here.

## Layout (at 1920x1080)
| # | Element | Name | Where (x, y, w, h %) | Shows | Does | Size |
|---|---|---|---|---|---|---|
| 1 | Hero sheet | %HeroSheet | 1, 11, 20, 70 | stats, morale, backstory | - | fixed width, fills height |
| 2 | Gear list | %GearList | 62, 12, 34, 60 | each slot and its item | click: Change | fill, scrolls |

## Navigation
Default focus · focus order · Back · keys and pad buttons for each action.

## Other sizes
Ultrawide, 16:10, small or phone: what grows, what moves, what hides.

## States
Empty, loading, away, exhausted: what differs.

## Open
Undecided points, each with its `Q<n>` if it went to the open questions.
```

## If you can't view images
Each step has a text path; none needs a picture.

| Step | Read instead |
|---|---|
| `capture` | `<id>@<W>x<H>.elements.json` (every element's position, text, focus order and overflow) and `.lint.txt` |
| the starter drawing | nothing to read: it is for the human to draw over |
| `process` | `<id>.drawing.json`, the spec, and `.elements.json` for what the boxes cover |
| `verify` | the table `bash tools/ui_capture.sh <id> --verify` prints, and `.elements.json` for the focus order; the compare image repeats it |
| a `UI:` item's build, review and function check | the same table and lint output, in the builder's `Screen:` line |
