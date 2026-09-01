// Composable SDF primitives, built as TypeGPU functions.
//
// In the pure-.wgsl library a combinator like `smoothUnion` can only be a
// scalar helper you call by hand inside a scene function you write yourself.
// Here a combinator takes distance functions and *returns a new one*, so a
// scene is a value you assemble:
//
//   const scene = smoothUnion(sphere(0.9), at(torus(0.7, 0.24), [1.4, 0, 0]), 0.4);
//
// WGSL still has no function pointers. Every combinator emits a new function
// with its operands inlined by name, so composition happens at generation time
// and the GPU only ever sees ordinary monomorphic WGSL.
//
// Nothing here runs in the browser. `scripts/forge-gen.ts` calls `emitModule`
// at build time and writes a .wgsl file, which then goes through vgpu's
// resolver like any other module — so `pnpm check` validates it, wgsl-std
// imports work natively, and the runtime never sees TypeGPU at all.

import tgpu from "typegpu";
import * as d from "typegpu/data";

/** A distance function from a point to a surface. */
export type Sdf = ReturnType<typeof sphere>;

// Names have to be unique across a resolve, and a scene may hold several
// spheres.
let counter = 0;
const uid = (base: string) => `${base}_${(counter++).toString(36)}`;

// WGSL has no implicit int-to-float conversion, so every number interpolated
// into a body has to carry a decimal point.
const f = (n: number) => n.toFixed(5);
const v3 = ([x, y, z]: readonly [number, number, number]) =>
  `vec3f(${f(x)}, ${f(y)}, ${f(z)})`;

// ── shapes ──────────────────────────────────────────────────────────────────

export const sphere = (radius: number) =>
  tgpu
    .fn([d.vec3f], d.f32)(`(p: vec3f) -> f32 {
      return length(p) - ${f(radius)};
    }`)
    .$name(uid("sphere"));

export const box = (half: readonly [number, number, number], round = 0) =>
  tgpu
    .fn([d.vec3f], d.f32)(`(p: vec3f) -> f32 {
      let q = abs(p) - ${v3(half)} + ${f(round)};
      return length(max(q, vec3f(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0) - ${f(round)};
    }`)
    .$name(uid("box"));

export const torus = (major: number, minor: number) =>
  tgpu
    .fn([d.vec3f], d.f32)(`(p: vec3f) -> f32 {
      let q = vec2f(length(p.xz) - ${f(major)}, p.y);
      return length(q) - ${f(minor)};
    }`)
    .$name(uid("torus"));

// ── combinators ─────────────────────────────────────────────────────────────

export const union = (a: Sdf, b: Sdf) =>
  tgpu
    .fn([d.vec3f], d.f32)(`(p: vec3f) -> f32 {
      return min(lhs(p), rhs(p));
    }`)
    .$uses({ lhs: a, rhs: b })
    .$name(uid("union"));

export const smoothUnion = (a: Sdf, b: Sdf, k: number) =>
  tgpu
    .fn([d.vec3f], d.f32)(`(p: vec3f) -> f32 {
      let da = lhs(p);
      let db = rhs(p);
      let h = clamp(0.5 + 0.5 * (db - da) / ${f(k)}, 0.0, 1.0);
      return mix(db, da, h) - ${f(k)} * h * (1.0 - h);
    }`)
    .$uses({ lhs: a, rhs: b })
    .$name(uid("smoothUnion"));

export const subtract = (a: Sdf, b: Sdf) =>
  tgpu
    .fn([d.vec3f], d.f32)(`(p: vec3f) -> f32 {
      return max(lhs(p), -rhs(p));
    }`)
    .$uses({ lhs: a, rhs: b })
    .$name(uid("subtract"));

// ── domain ──────────────────────────────────────────────────────────────────

export const at = (sdf: Sdf, offset: readonly [number, number, number]) =>
  tgpu
    .fn([d.vec3f], d.f32)(`(p: vec3f) -> f32 {
      return inner(p - ${v3(offset)});
    }`)
    .$uses({ inner: sdf })
    .$name(uid("at"));

export const repeat = (sdf: Sdf, period: readonly [number, number, number]) =>
  tgpu
    .fn([d.vec3f], d.f32)(`(p: vec3f) -> f32 {
      let c = ${v3(period)};
      return inner(p - c * round(p / c));
    }`)
    .$uses({ inner: sdf })
    .$name(uid("repeat"));

// `fbmSimplex3d` is not a TypeGPU function — resolution passes the identifier
// straight through, and `emitModule` puts a real wgsl-std import at the top of
// the generated module so vgpu's resolver binds it. No bridging, no name
// rewriting: it is an ordinary WGSL import because the output is an ordinary
// WGSL module.
export const displace = (sdf: Sdf, amount: number, frequency: number) =>
  tgpu
    .fn([d.vec3f], d.f32)(`(p: vec3f) -> f32 {
      let n = fbmSimplex3d(p * ${f(frequency)}, 4, 2.0, 0.5);
      // The displacement breaks the marcher's Lipschitz bound, so the marcher
      // below shortens every step.
      return inner(p) - n * ${f(amount)};
    }`)
    .$uses({ inner: sdf })
    .$name(uid("displace"));

// ── marching ────────────────────────────────────────────────────────────────

// The piece the pure-WGSL library documents as impossible: a marcher
// parameterised by a scene. Not polymorphism — a new marcher is emitted per
// scene with the SDF inlined — but at the call site it reads as if it were.
export const marcher = (scene: Sdf, stepScale = 0.55) =>
  tgpu
    .fn([d.vec3f, d.vec3f], d.f32)(`(ro: vec3f, rd: vec3f) -> f32 {
      var t = 0.0;
      for (var i = 0; i < 96; i++) {
        let dist = scene(ro + rd * t) * ${f(stepScale)};
        if (dist < 0.0008) { return t; }
        t += dist;
        if (t > 14.0) { break; }
      }
      return -1.0;
    }`)
    .$uses({ scene })
    .$name(uid("march"));

export const normals = (scene: Sdf) =>
  tgpu
    .fn([d.vec3f], d.vec3f)(`(p: vec3f) -> vec3f {
      let e = vec2f(0.0012, 0.0);
      return normalize(vec3f(
        scene(p + e.xyy) - scene(p - e.xyy),
        scene(p + e.yxy) - scene(p - e.yxy),
        scene(p + e.yyx) - scene(p - e.yyx),
      ));
    }`)
    .$uses({ scene })
    .$name(uid("normalAt"));

// ── emitting ────────────────────────────────────────────────────────────────

export interface EmitOptions {
  /** WGSL import lines to place at the top of the module. */
  readonly imports?: readonly string[];
  /** The functions to resolve. */
  readonly items: readonly unknown[];
  /**
   * Names to mark `export` so an entry shader can import them. Give those
   * functions a stable name with `.$name()` — the uid suffix the combinators
   * add is there to avoid collisions between anonymous intermediates, and a
   * module's public surface should not carry it.
   */
  readonly exports: readonly string[];
}

/**
 * Resolves TypeGPU functions into the text of a vgpu WGSL module.
 *
 * The output is an ordinary module: it declares no bindings, it imports what it
 * needs, and everything downstream — the resolver, tree-shaking, `vgpu check`,
 * the headless renderer — treats it exactly like a hand-written one.
 */
export function emitModule(options: EmitOptions): string {
  let text = tgpu.resolve(options.items as never[]);

  for (const name of options.exports) {
    const declaration = new RegExp(`(^|\\n)fn\\s+${escapeRe(name)}\\s*\\(`);
    if (!declaration.test(text)) {
      throw new Error(`emitModule: no function named '${name}' in the resolved output`);
    }
    text = text.replace(declaration, `$1export fn ${name}(`);
  }

  const header = [
    "// Generated by scripts/forge-gen.ts — do not edit.",
    "//",
    "// The scene is composed in TypeScript with TypeGPU; this file is what that",
    "// composition resolves to. Regenerate with `pnpm generate`.",
    "",
    ...(options.imports ?? []),
  ].join("\n");

  return `${header}\n\n${text}\n`;
}

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
