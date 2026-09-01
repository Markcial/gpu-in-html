// The bridge to @vgpu/wgsl-std.
//
// TypeGPU ships the WGSL builtins and nothing else — no noise, no hash — while
// this repository leans on wgsl-std for exactly those. Neither side can import
// the other, so the join is textual: Vite's wgsl loader resolves this file at
// build time, forge.ts finds the resolved name by regex, and rewrites the call
// sites in the TypeGPU output to match.
//
// Two details make it work, and both are the resolver's doing. It tree-shakes
// anything no entry point reaches, hence `_keep` below. And it mangles every
// name to `_vgsl_<hash>__<original>`, which is why the name has to be found
// rather than assumed.

import { fbmSimplex3d } from "@vgpu/wgsl-std/noise/simplex";

fn forgeNoise(p: vec3f) -> f32 {
  return fbmSimplex3d(p, 4, 2.0, 0.5);
}

// Exists only to hold forgeNoise against the tree-shaker. vgpu draws through
// `fs_main`, so a second fragment entry point is inert.
@fragment
fn _keep(@location(0) uv: vec2f) -> @location(0) vec4f {
  return vec4f(forgeNoise(vec3f(uv, 0.0)));
}
