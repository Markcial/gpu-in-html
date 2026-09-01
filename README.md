# gpu-in-html

Reusable WGSL primitives for [vgpu](https://vgpu.sh), and a growing set of
examples built on top of them.

The library is **pure WGSL**. `@gpu-in-html/wgsl` ships `.wgsl` modules and
nothing else — no TypeScript, no runtime. vgpu resolves the import graph, drops
what an entry shader does not use, and emits compact WGSL at build time.

```
index.html           the gallery
site/gallery.ts      builds the cards from examples/manifest.json
packages/wgsl/       @gpu-in-html/wgsl — the library
examples/manifest.json  one entry per example: blurb, tags, still settings
examples/_harness/   dev-only glue shared by the examples (not published)
examples/01-*/       one runnable example per idea
public/stills/       committed thumbnails, rendered by `pnpm stills`
scripts/             shader validation, headless rendering
```

## Run it

```bash
pnpm install
pnpm dev        # the gallery, with every example on the same server
pnpm verify     # validate every shader, typecheck, build the whole site
```

`pnpm dev` serves the gallery at `/` and each example at
`/examples/<slug>/` — one Vite app rooted at the repository, one port, and
`vgpu` shared across the pages instead of bundled once per example. Each
example is still its own workspace package resolving `@gpu-in-html/wgsl` by
package name, which is what keeps the library honestly consumable.

To add an example: create `examples/<slug>/` with an `index.html` and a `src/`,
then add an entry to `examples/manifest.json`. Vite picks up the page, the
gallery grows a card, and `pnpm stills` renders its thumbnail.

WebGPU is required. If `init()` throws, the example prints the error on the
page instead of leaving a black canvas.

## Render headless

The same entry shader renders without a browser, through Dawn:

```bash
pnpm render examples/01-gradient/src/gradient.wgsl -o out/01.png -w 3840 -h 2160 -t 2.5
pnpm stills   # re-render every gallery thumbnail from examples/manifest.json
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
| `@gpu-in-html/wgsl/sdf` | `opUnion` / `opSubtract` / `opIntersect` in hard and smooth forms, plus `opRound` and `opOnion`. Operate on distances, so they are shared by 2D and 3D |
| `@gpu-in-html/wgsl/shape2d` | `sdCircle`, `sdBox`, `sdRoundedBox`, `sdSegment`, `sdStar` |
| `@gpu-in-html/wgsl/shape3d` | `sdSphere`, `sdBox`, `sdRoundBox`, `sdTorus`, `sdCapsule`, `sdPlane`, `sdEllipsoid`, `opRepeat`, `opMirror`, `opTwist`, `rotX`, `rotY` |
| `@gpu-in-html/wgsl/camera` | `Ray`, `rayFromUv`, `lookAt`, `orbit` |
| `@gpu-in-html/wgsl/color` | `palette`, `paletteDefault`, Oklab/Oklch, `mixOklab` |
| `@gpu-in-html/wgsl/post` | `vignette`, `grain`, `applyGrain`, `contrast`, `halation` |

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
| `03-tetsuo` | A raymarched mass of flesh straining out of itself. Lobes and tendrils erupt from a core through smooth unions, fbm displaces the surface, and light bled through the thin parts gives it volume. A `<input type="range">` drives the mutation and the telemetry panel reads from the same number. |

Colours in a shader are authored in sRGB and converted with `srgbToLinear3`
before use. Using picker values as if they were linear makes a mid blue roughly
four times too bright, and everything washes out. The same conversion bites the
other way in dark scenes: sRGB `0.06` is linear `0.004`, which a vignette and a
contrast curve will finish off entirely. A dim-but-readable room wants to be
authored around sRGB `0.2`, not `0.05`.

## Raymarching

There is no `march()` or `normalAt()` in this package, and there cannot be:
both have to call *your* scene function, and WGSL has neither function pointers
nor generics. The march loop belongs in the entry shader. Everything around it
that does not depend on the scene — shapes, domain and combination operators,
camera rays, the grade — is here. `examples/03-tetsuo/src/scene.wgsl` is the
reference for how the two fit together.

Displacing an SDF with noise breaks the Lipschitz bound the marcher relies on,
so a full-length step will tunnel through thin features. Scaling the returned
distance down (`return d * 0.55`) is the standard fix.

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
