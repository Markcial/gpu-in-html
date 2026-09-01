# gpu-in-html

Reusable WGSL primitives for [vgpu](https://vgpu.sh), and a growing set of
examples built on top of them.

The library is **pure WGSL**. `@gpu-in-html/wgsl` ships `.wgsl` modules and
nothing else — no TypeScript, no runtime. vgpu resolves the import graph, drops
what an entry shader does not use, and emits compact WGSL at build time.

```
packages/wgsl/       @gpu-in-html/wgsl — the library
examples/_harness/   dev-only glue shared by the examples (not published)
examples/01-*/       one runnable example per idea
scripts/             shader validation
```

## Run it

```bash
pnpm install
pnpm dev        # examples/01-gradient on a local server
pnpm verify     # validate every shader, typecheck, build every example
```

WebGPU is required. If `init()` throws, the example prints the error on the
page instead of leaving a black canvas.

## Render headless

The same entry shader renders without a browser, through Dawn:

```bash
pnpm render examples/01-gradient/src/gradient.wgsl -o out/01.png -w 3840 -h 2160 -t 2.5
```

`-t` is the `time` uniform in seconds, so any frame of an animation can be
pulled as a still at any resolution. Run `npx vgpu doctor` first on a new
machine — it acquires an adapter and renders a real frame, and prints the exact
fix as JSON when something is missing.

This is also the hook for snapshot tests: render a fixed `-t` and compare
against a committed PNG. Not wired into CI yet — the GitHub runner needs
`npx vgpu install-software-renderer` for deterministic output, which has not
been verified here.

## Using the primitives

Import them by package path from any entry shader:

```wgsl
import { centered, polar } from "@gpu-in-html/wgsl/space";
import { paletteDefault, tonemapAces, linearToSrgb } from "@gpu-in-html/wgsl/color";

struct Params {
  resolution: vec2f,
  time: f32,
}

@group(0) @binding(0) var<uniform> params: Params;

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let p = centered(uv, params.resolution);
  return vec4f(linearToSrgb(tonemapAces(paletteDefault(polar(p).y))), 1.0);
}
```

| module | what's in it |
| --- | --- |
| `@gpu-in-html/wgsl/space` | `centered`, `flipY`, `rot2`, `rotate`, `polar`, `tile`, `kaleidoscope` |
| `@gpu-in-html/wgsl/shaping` | `remap`, `aastep`, `sdFill`, `sdStroke`, `pulse`, `easeInOutCubic` |
| `@gpu-in-html/wgsl/shape2d` | `sdCircle`, `sdBox`, `sdRoundedBox`, `sdSegment`, `sdStar`, and `opUnion` / `opSubtract` / `opIntersect` in hard and smooth forms |
| `@gpu-in-html/wgsl/color` | `palette`, `paletteDefault`, Oklab/Oklch, `mixOklab` |

This package only holds what `@vgpu/wgsl-std` does not. Take hashing and noise
from `@vgpu/wgsl-std` (`hash`, `noise`, `noise/perlin`, `noise/simplex`),
transfer functions and tonemapping from `@vgpu/wgsl-std/color`
(`srgbToLinear3`, `linearToSrgb3`, `tonemapAces`), and scalar helpers from
`@vgpu/wgsl-std/math`. Check there before adding anything here.

## Examples

| | |
| --- | --- |
| `01-gradient` | A fullscreen fragment shader and nothing else — the smallest thing that renders. |
| `02-cloud-form` | A real HTML `<form>` with no background of its own, over a canvas that draws the cloud serving as its chrome. A `ResizeObserver` feeds the form's measured rect to the shader, so the silhouette tracks the DOM through any reflow, and `focusin`/`focusout` swell the cloud. |

Colours in a shader are authored in sRGB and converted with `srgbToLinear3`
before use. Using picker values as if they were linear makes a mid blue roughly
four times too bright, and everything washes out.

## Authoring rules

Three rules, and the first is enforced by vgpu itself:

1. **No `@group`/`@binding` in a module.** Imported modules are pure; declaring
   a resource fails resolution with `VGPU-RESOLVE-MODULE-BINDING`. Export the
   data shape as a `struct` and take it as a parameter. The entry shader owns
   its bindings.
2. **No implicit `time` or `resolution`.** Anything a function depends on
   arrives as an argument, so the same function works in an animation, a
   headless still, and a test.
3. **One concern per file, explicit names.** `sdBox`, not `box`. Every export
   gets a comment saying what it is for, and at least one example uses it.

`uv` is top-origin: `(0,0)` is the top-left and `v` grows downward, matching
WebGPU texture coordinates. Porting a y-up shader? Call `flipY` once at the
boundary and stay flip-free after that.

## Adding a primitive

1. Write it in the right module under `packages/wgsl/src/`, or add a new module
   and register it in that package's `exports` map.
2. Use it from an example. A primitive with no caller is not verified.
3. `pnpm verify`.
