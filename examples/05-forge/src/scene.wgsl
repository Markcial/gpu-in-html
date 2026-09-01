// Entry shader. Ordinary hand-written WGSL — the scene it marches came out of
// scene.generated.wgsl, which TypeGPU produced at build time, but nothing here
// knows or cares about that.

import { march, normalAt } from "./scene.generated.wgsl";

struct Params {
  resolution: vec2f,
  time: f32,
}

@group(0) @binding(0) var<uniform> params: Params;

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  var p = (uv - vec2f(0.5)) * 2.0;
  p.y = -p.y;
  p.x *= params.resolution.x / max(params.resolution.y, 1.0);

  let yaw = 0.55 + sin(params.time * 0.16) * 0.42;
  let ro = vec3f(sin(yaw) * 4.4, 1.25, cos(yaw) * 4.4);
  let forward = normalize(vec3f(0.55, 0.1, 0.0) - ro);
  let right = normalize(cross(forward, vec3f(0.0, 1.0, 0.0)));
  let up = cross(right, forward);
  let rd = normalize(right * p.x + up * p.y + forward * 1.7);

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
}
