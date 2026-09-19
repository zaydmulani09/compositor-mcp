# compositor-mcp

[![CI](https://github.com/zaydmulani09/compositor-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/zaydmulani09/compositor-mcp/actions/workflows/ci.yml)

An [MCP](https://modelcontextprotocol.io) server that lets an agent build and edit
[Compositor](https://github.com/robbietilton/Compositor) image projects.

Compositor is a free, open-source image editor for macOS by
[Robbie Tilton](https://github.com/robbietilton). This server drives its document
model headlessly: it opens and writes real `.comp` projects, composites them with
Compositor's own renderer, and exports PNG and JPEG. What the agent builds, the app
opens.

The app does not need to be running. The server never automates the UI.

## What it does

Claude can lay out a composition, adjust it, look at the result, and save a project
you then open and finish by hand.

```
You:    Build me a 1200x800 poster from photo.png, put badge.png on top
        at 130%, rotate it slightly, and warm the whole thing up.

Claude: [create_document] [import_image] [transform_layer]
        [add_adjustment_layer Gradient Map] [render_preview]
        -> shows you the rendered image
        [save_document ~/Desktop/poster.comp]
```

`render_preview` returns the composite as an image, so the agent sees its own work
and can correct it before saving.

## Coverage

It works on the document — structure, placement, non-destructive adjustments and
output — and now paints real pixels too: brush, eraser, clone stamp, spot healing,
smudge, liquify, selections, crop, destructive filters, merge and flatten.

**Covered**

| Area | Tools |
| --- | --- |
| Documents | `create_document`, `open_document`, `save_document`, `close_document`, `list_documents`, `describe_document` |
| Layers | `import_image`, `set_layer`, `delete_layer`, `duplicate_layer`, `reorder_layer`, `group_layers` |
| Transform | `transform_layer` (move, scale, rotate, flip, sampling) |
| Compositing | opacity and all 13 blend modes, folders, `set_clipping_mask` |
| Painting | `paint_stroke` (brush, eraser, smudge, liquify), `clone_stamp_stroke`, `heal_stroke` |
| Selection & crop | `apply_selection` (rect, ellipse, lasso; replace/add/subtract), `crop_canvas` |
| Filters | `apply_filter` (Gaussian Blur, Motion Blur, Add Noise, Lens Correction) |
| Combine | `merge_layers`, `flatten_document` |
| Adjustments | `add_adjustment_layer`, `describe_adjustment` (Levels, Curves, Hue/Saturation, Exposure, Gradient Map, Grain) |
| Canvas | `resize_canvas`, `resize_image` |
| Output | `render_preview`, `export_image` |
| Generation | `generate_layer`, `vary_layer`, `fuse_layers`, `restyle_composition`, `remove_layer_background`, `upscale_layer`, `list_generations`, `import_generation` |

### Interactive tools (painting)

Every interactive tool in Compositor reduces to the same shape: `begin(at:)` →
`continue(at:)` × N → `finish()`, driven by AppKit mouse events in the app. These
handlers drive the exact same `EditorSession` methods (`beginBrush`, `continueBrush`,
`finishBrushImmediately`, `setCloneSource`, `applySelection`, `beginFilter`/`commitFilter`,
`commitCrop`, `mergeLayers`) with a synthesised path of points instead of live NSEvents,
then read the result back through `projectSnapshot()`. No new pixel engine — the app's
own tile-based brush, `HealPixels.c`, `SmudgeLiquify`, `PixelFilter` and compositor do the
work. Painting is committed to the same document draft the other tools edit and validated
by the same store.

```
You:    paint a soft red brush stroke from (100,100) to (300,150) at 40% opacity
        on layer 2, then spot-heal the blemish near (150,120)

Claude: [paint_stroke  brush  path=[{100,100},…,{300,150}]  red=1 opacity=0.4 hardness=0.2]
        [heal_stroke   path=[{150,120},{151,120}]  diameter=16]
        [render_preview]
```

Three deliberate differences from a naive spec, each forced by Compositor's own source:

- **Coordinates are canvas pixels, not layer-local.** `BrushStroke` maps a canvas point
  onto the layer through the layer transform itself, so canvas coordinates are what every
  entry point takes. Passing layer-local points would mean re-deriving that mapping and
  getting it wrong.
- **`pressure` is accepted but ignored.** Compositor's `BrushSettings` has diameter,
  hardness, colour, opacity and erase/heal flags — no per-point pressure input. Rather than
  fake dynamics by splitting a stroke into sub-strokes (which would break the one-stroke =
  one-undo model), pressure is recorded and passed through untouched, ready for the day the
  engine gains it.
- **No `intersect` selection mode.** Compositor's `SelectionMode` is replace / add /
  subtract only, and `apply_selection` exposes exactly those. `feather` is accepted but
  ignored for the same honesty reason: the selection stores no feather radius (edges are
  antialiased only).

### Image generation (optional)

The generation tools call [ContentMaschine](https://contentmaschine.ai). They are
inert without an API key, and every other tool works without one.

```
You:    generate a misty forest backdrop, drop the logo layer on it,
        and cut the logo out of its background

Claude: [generate_layer  "misty forest, low sun" 16:9 2048]
        [remove_layer_background  logo]
        [transform_layer] [render_preview]
```

A generated image arrives as an ordinary layer, so masks, blend modes and
adjustments apply to it afterwards. Three details worth knowing:

- `remove_layer_background` normalises to about one megapixel in 64-pixel steps.
  A square layer maps back exactly, so only its alpha is carried onto the
  original pixels and no resolution is lost. A shape the service cannot hit
  comes back slightly cropped, so the cutout's own pixels are used and the layer
  is reshaped around its centre rather than stretching a mismatched alpha. Send a
  square layer when you want full resolution.
- `restyle_composition` renders the whole document and sends that composite to be
  restyled. The original layers stay below the result, untouched.
- `list_generations` and `import_generation` re-use past work. Importing costs no
  credits and returns the original file, so check there before generating again.

Put the key in `~/.config/contentmaschine/credentials`:

```
CONTENTMASCHINE_API_KEY=...
CONTENTMASCHINE_BASE_URL=https://contentmaschine.ai/api/v1
```

`CONTENTMASCHINE_API_KEY` and `CONTENTMASCHINE_BASE_URL` in the environment
override the file. The key is never logged.

**Not covered yet.** The gradient and shape tools, magic-wand selection,
content-aware fill, painting layer masks by hand, and Remove Background as a
destructive filter (it exists as the ContentMaschine cutout instead). Text layers
are absent because Compositor itself has no text. Per-point pressure/velocity
dynamics are not wired, because the brush engine has no input for them.

Those remaining tools live on the same `EditorSession`; the ones shipped here prove
the headless-driver approach, and the rest follow the same pattern. See
[ROADMAP](#roadmap).

> **Build status.** Built and tested on macOS in
> [CI](https://github.com/zaydmulani09/compositor-mcp/actions/workflows/ci.yml) on
> every push: `scripts/setup.sh`, `swift build`, `swift test`. The 10 pixel tests
> render through Compositor's own exporter and assert the raster actually changed
> where each tool ran — the brush test drives `MetalBrushCoverage` headlessly and
> the filter/crop tests exercise the `async` commits, so those paths are confirmed
> to work without a UI. The `demo` step also runs a real edit over the MCP protocol on a
> photo: it finds a plane in a clear sky from the pixels, heals it away, and confirms the
> region became clean sky — uploading before/after frames plus the JSON-RPC calls.

## Requirements

- macOS 26 or newer
- Xcode 26 or newer (for the Swift 6.2 toolchain)

## Install

```bash
git clone --recursive https://github.com/marcushorndt/compositor-mcp.git
cd compositor-mcp
./scripts/setup.sh
swift build -c release
```

`setup.sh` checks out the pinned Compositor commit, applies the two build fixes it
needs on Xcode 26.1, and links the sources this server compiles.

The binary lands at `.build/release/compositor-mcp`.

## Use it with Claude Code

```bash
claude mcp add compositor -- /absolute/path/to/compositor-mcp/.build/release/compositor-mcp
```

Or add it to `.mcp.json` by hand:

```json
{
  "mcpServers": {
    "compositor": {
      "command": "/absolute/path/to/compositor-mcp/.build/release/compositor-mcp"
    }
  }
}
```

The server speaks MCP over stdio, so any MCP client can run it.

## How it works

Compositor already separates its document from its interface. `ProjectSnapshot` is
an immutable value holding the manifest and the decoded images, and
`ImageExporter.render` turns one into a finished composite: folders, folder masks,
clipping masks, adjustment layers, blend modes and opacity. None of that needs a
window.

So this server compiles 54 of Compositor's own source files and drives them
directly:

```
MCP client  ->  compositor-mcp  ->  ProjectSnapshot  ->  ImageExporter.render
                                          |
                                    ProjectStore  ->  .comp on disk
```

A tool call loads the document once, edits it in memory as a mutable draft, and
validates the layer tree before accepting the change. Nothing is written until you
call `save_document` or `export_image`.

Because the rendering, the validation and the file format are Compositor's own, a
project this server writes is the same thing the app writes.

## Relationship to Compositor

Compositor is a git submodule, pinned to a commit. No upstream source is copied
here. Everything in `Sources/compositor-mcp/Upstream/` is a symbolic link into the
submodule. See [NOTICE.md](NOTICE.md).

To move to a newer Compositor:

```bash
git -C vendor/Compositor fetch origin && git -C vendor/Compositor checkout <commit>
./scripts/setup.sh && swift build -c release
```

## Roadmap

Done in this release: painting (brush, eraser, smudge, liquify), clone stamp, spot
healing, selections, crop, destructive filters (Gaussian/Motion Blur, Add Noise, Lens
Correction), merge and flatten.

Still open:

- Painting and importing layer masks (paint on the mask channel, not just pixels)
- Gradient and shape tools, magic-wand selection, content-aware fill
- Per-point pressure/velocity, once Compositor's brush engine accepts it
- Text layers, which Compositor does not have yet

## License

This project is MIT, Copyright (c) 2026 Marcus Horndt. See [LICENSE](LICENSE).

Compositor is MIT, Copyright (c) 2026 Wonder Assembly LLC. Its notice is kept
verbatim at [`licenses/Compositor-LICENSE.txt`](licenses/Compositor-LICENSE.txt).
No Compositor source is copied into this repository, and a binary you build from
it should ship both notices. [NOTICE.md](NOTICE.md) explains the attribution and
why the terms permit this.

Not affiliated with or endorsed by Robbie Tilton or Wonder Assembly LLC.
