// Composable SDF primitives, built as TypeGPU functions.
//
// The point of the trial: in the pure-.wgsl library a combinator like
// `smoothUnion` can only be a scalar helper you call by hand inside a scene
// function you write yourself. Here a combinator takes two SDFs and *returns a
// new SDF*, so scenes are values you assemble:
//
//   const scene = smoothUnion(sphere(0.9), at(torus(0.7, 0.24), [1.4, 0, 0]), 0.4);
//
// WGSL still has no function pointers. Every combinator emits a new function
// with its operands inlined by name, so the composition happens at generation
// time and the GPU only ever sees ordinary monomorphic WGSL.

import tgpu from "typegpu";
import * as d from "typegpu/data";
import bridge from "./bridge.wgsl";

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

// The one that needs wgsl-std. `forgeNoise` is not a TypeGPU function — it is
// an identifier that resolution passes straight through, bound to the real one
// by `compile` below.
export const displace = (sdf: Sdf, amount: number, frequency: number) =>
  tgpu
    .fn([d.vec3f], d.f32)(`(p: vec3f) -> f32 {
      let n = forgeNoise(p * ${f(frequency)});
      // The displacement breaks the marcher's Lipschitz bound, so the marcher
      // below shortens every step.
      return inner(p) - n * ${f(amount)};
    }`)
    .$uses({ inner: sdf })
    .$name(uid("displace"));

// ── marching ────────────────────────────────────────────────────────────────

// This is the piece the pure-WGSL library documents as impossible: a marcher
// parameterised by a scene. It is not polymorphism — a new marcher is emitted
// per scene with the SDF inlined — but at the call site it reads as if it were.
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

const bridgeSource = typeof bridge === "string" ? bridge : bridge.wgsl;

// The resolver mangles names, so the real one has to be recovered rather than
// assumed. If this ever returns undefined the build has changed under us and
// the shader should fail loudly rather than silently lose its noise.
const resolvedNoise = /fn\s+(_vgsl_[0-9a-f]+__forgeNoise)\s*\(/.exec(bridgeSource)?.[1];
if (!resolvedNoise) {
  throw new Error("bridge.wgsl no longer exposes forgeNoise — did the resolver tree-shake it?");
}

/**
 * Resolves a set of TypeGPU functions into one WGSL module, joined to the
 * wgsl-std bridge and wrapped in the fragment entry point vgpu draws through.
 */
export function compile(items: unknown[], entry: string): string {
  // The keeper in bridge.wgsl exists only to survive tree-shaking, and it has
  // to go before the module is used: it leaves a second `@fragment` behind and
  // vgpu picked *it* as the entry point, so the first run of this rendered the
  // raw noise field. Dropping just the attribute is not enough either —
  // `@location` on a parameter is only legal on an entry point, so the module
  // stops compiling. The whole function has to come out.
  //
  // Its body has no nested braces, which is what makes the non-greedy match
  // safe. That is a fragile thing to rely on, so it fails loudly instead of
  // quietly leaving the keeper in.
  const keeper = /@fragment\s+fn\s+_keep[\s\S]*?\n\}/;
  if (!keeper.test(bridgeSource)) {
    throw new Error("bridge.wgsl keeper not found — the resolver's output format changed");
  }
  const bridged = bridgeSource.replace(keeper, "");
  const body = tgpu.resolve(items as never[]).replaceAll("forgeNoise(", `${resolvedNoise}(`);
  return `${bridged}\n\n${body}\n\n${entry}\n`;
}
