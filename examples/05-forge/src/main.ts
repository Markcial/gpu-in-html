import { mount } from "@gpu-in-html/harness";
import tgpu from "typegpu";
import * as d from "typegpu/data";

import {
  at,
  box,
  compile,
  displace,
  marcher,
  normals,
  smoothUnion,
  sphere,
  subtract,
  torus,
} from "./forge";

// The whole reason for the trial. In the .wgsl library this scene would be a
// function you write by hand, calling helpers in the right order. Here it is a
// value, built by applying combinators — and every one of them emits a real
// WGSL function with its operands inlined.
const scene = displace(
  smoothUnion(
    subtract(sphere(1.0), at(box([0.62, 0.62, 1.5], 0.06), [0.62, 0.52, 0.0])),
    at(torus(0.68, 0.19), [1.62, 0.05, 0.0]),
    0.42,
  ),
  0.05,
  3.2,
);

const march = marcher(scene);
const normalAt = normals(scene);

const shade = tgpu
  .fn([d.vec2f, d.vec2f, d.f32], d.vec4f)(`(uv: vec2f, res: vec2f, time: f32) -> vec4f {
    var p = (uv - vec2f(0.5)) * 2.0;
    p.y = -p.y;
    p.x *= res.x / max(res.y, 1.0);

    let yaw = 0.55 + sin(time * 0.16) * 0.42;
    let ro = vec3f(sin(yaw) * 4.4, 1.25, cos(yaw) * 4.4);
    let fwd = normalize(vec3f(0.55, 0.1, 0.0) - ro);
    let right = normalize(cross(fwd, vec3f(0.0, 1.0, 0.0)));
    let up = cross(right, fwd);
    let rd = normalize(right * p.x + up * p.y + fwd * 1.7);

    let sky = mix(vec3f(0.055, 0.06, 0.075), vec3f(0.10, 0.105, 0.125), uv.y);
    var col = sky;

    let t = march(ro, rd);
    if (t > 0.0) {
      let hit = ro + rd * t;
      let n = normalAt(hit);
      let key = normalize(vec3f(-0.55, 0.78, 0.32));

      let diffuse = clamp(dot(n, key), 0.0, 1.0);
      let fresnel = pow(1.0 - clamp(dot(n, -rd), 0.0, 1.0), 3.0);
      let spec = pow(clamp(dot(reflect(-key, n), -rd), 0.0, 1.0), 42.0);

      let albedo = mix(vec3f(0.62, 0.24, 0.20), vec3f(0.80, 0.55, 0.40), n.y * 0.5 + 0.5);
      col = albedo * (0.10 + diffuse * 1.05);
      col += vec3f(0.30, 0.52, 0.85) * fresnel * 0.45;
      col += vec3f(1.0, 0.94, 0.86) * spec * 0.5;
      col = mix(col, sky, clamp((t - 4.0) * 0.14, 0.0, 1.0));
    }

    col = col / (col + vec3f(1.0));
    return vec4f(pow(col, vec3f(1.0 / 2.2)), 1.0);
  }`)
  .$uses({ march, normalAt })
  .$name("shade");

const source = compile(
  [shade],
  `struct Params {
  resolution: vec2f,
  time: f32,
}

@group(0) @binding(0) var<uniform> params: Params;

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  return shade(uv, params.resolution, params.time);
}`,
);

const canvas = document.querySelector<HTMLCanvasElement>("#stage");
const errorEl = document.querySelector<HTMLPreElement>("#error");
const sizeEl = document.querySelector<HTMLSpanElement>("#r-size");
const fnsEl = document.querySelector<HTMLSpanElement>("#r-fns");

if (!canvas || !errorEl) throw new Error("Missing #stage or #error");

if (sizeEl) sizeEl.textContent = `${source.length.toLocaleString()} chars`;
if (fnsEl) {
  fnsEl.textContent = String((source.match(/^\s*fn\s+/gm) ?? []).length);
}

try {
  const sketch = await mount(canvas, source, { dpr: 1 });
  import.meta.hot?.dispose(() => sketch.stop());
} catch (error) {
  errorEl.textContent = error instanceof Error ? (error.stack ?? error.message) : String(error);
  throw error;
}
