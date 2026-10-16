<!-- Godot Director · framework-owned: replaced on upgrade. -->
# UI design

The human designs screens by drawing over screenshots of the running game; you capture the screens, look at them and report what you find. This procedure covers listing and capturing them.

Requests:
- `list`: the screens in the catalog.
- `capture [screen|all]` (default `all`).
- No argument: `list`, then ask which screen to capture.

## The catalog
`tools/ui_screens.gd` (project-owned, extends `tools/ui_catalog.gd`) lists every screen: an `id`, a `title`, its `scene`, and how to put it on screen in a representative state (`setup`, or named `states` such as `default` and `empty`). The entry format and the helpers (`reset()`, `open_view()`, `wait_frames()`, `focus_default()`) are documented at the top of `tools/ui_catalog.gd`. A state builds its data through the game's public APIs, fixtures and debug hooks, never player data. If the screen you're asked about has no entry, add one first (`rules.md` › Architecture defaults › UI). Sizes, the seed, the lint thresholds and screens never captured are in `tools/ui_capture.cfg`.

`tools/ui_capture.sh` finds Godot as the check does: `$GODOT_BIN`, else the first line of `tools/godot_bin.local`, else `godot`. If none is found, run `bash tools/setup-clone.sh --skip-hook`.

## list
1. Run `bash tools/ui_capture.sh --list`. It needs no display. Each line has a screen's id, title, states, the scene it opens, and whether a drawing (`director/ui/<id>.excalidraw`) and a spec (`design/ui/<id>.md`) exist.
2. Show it as a short table. A `FAIL` line is a catalog entry with a problem (an unknown key, a duplicate id, a missing scene): fix the entry.

## capture
1. Run `bash tools/ui_capture.sh <screen>`, or `--all`. `--state <name>` narrows it; `--size <W>x<H>` captures one size, listed in `tools/ui_capture.cfg` or not. Godot needs a display, since it renders nothing headless, and opens a small window for a few seconds. The screens themselves are rendered offscreen at each size with the project's stretch settings, so every size captures whatever the monitor; a size the GPU can't render is skipped with a note.
   - Exit 3: say capture couldn't run and why (no Godot, Godot older than 4.3, no display, or Godot couldn't open a window or start its renderer; on Linux it needs a display or `xvfb-run`), and stop. Where the reason is the display, `--no-images` still writes the element maps and lint; say they come from a headless run, whose text measurement can differ slightly.
   - Exit 1: something failed, and the run went on with everything else. The causes, each named in a `FAIL` line:
     - a screen's setup printed a script error, or didn't finish within `[capture] setup_timeout` seconds: the error is at the top of that screen's `.lint.txt`;
     - a catalog entry has a problem (an unknown key, a duplicate id, a missing scene, no title, a setup or state that isn't a Callable), or `tools/ui_screens.gd` doesn't compile or doesn't extend `tools/ui_catalog.gd`;
     - the screen or state named doesn't exist, an option is unknown, or `tools/ui_capture.cfg` has a size that isn't `WxH`;
     - a capture file couldn't be written, or Godot ran past `CAPTURE_TIMEOUT` (600 seconds by default).

     Fix what's in the catalog or the settings; report the rest.
2. The outputs are in `design/ui/captures/` (gitignored), per screen, state and size, named `<id>[.<state>]@<W>x<H>` (no state for `default`):
   - `.png`: the screenshot, as a player sees the window at that size.
   - `.elements.json`: the element map. Each mapped element has a number `n`, its `id` (the unique node name when `stable` is true), `path`, `kind`, visible text, `rect` in pixels and `rect_pct` in percent of the capture, `focusable` and `focus_order` (its place in Tab and arrow traversal from the default focus, `null` when unreachable), `overflow`, `min_size`, and Godot extras under `native`. Clickable 3D objects are in `pickables_3d`.
   - `.map.png`: the screenshot with every element outlined and numbered, so you and the human can say "element 4".
   - `.lint.txt`: one finding per line, `<rule> element <n> <path>: <message>`; empty when clean.
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

A capture shows the screen as the catalog opens it, in its own viewport: anything an autoload draws (a HUD on a `CanvasLayer`, say) isn't in it. A capture never touches player data: `user://` points at a temporary folder that is deleted afterwards, and `Engine.has_meta("godot_director_check")` and `("godot_director_capture")` are true, so autoloads skip saves and settings. Two captures of the same state and size on the same machine give the same element map and image. A capture changes no source file and commits nothing.
