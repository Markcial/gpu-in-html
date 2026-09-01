// Camera rays for raymarched scenes.
//
// Pure module — see space.wgsl for the authoring rules these all follow.
//
// The look-at point is named `at`, not `target`: `target` is a reserved word
// in WGSL and using it fails resolution with VGPU-WGSL-RESERVED-IDENT.

export struct Ray {
  origin: vec3f,
  direction: vec3f,
}

// Right-handed look-at basis. Columns are (right, up, forward).
export fn lookAt(origin: vec3f, at: vec3f, roll: f32) -> mat3x3f {
  let forward = normalize(at - origin);
  let worldUp = vec3f(sin(roll), cos(roll), 0.0);
  let right = normalize(cross(forward, worldUp));
  let up = cross(right, forward);
  return mat3x3f(right, up, forward);
}

// Build a primary ray from vgpu's injected `uv`.
//
// `uv` is top-origin, so this flips y once here — the one place the flip
// belongs. `fov` is the vertical field of view in radians.
export fn rayFromUv(
  uv: vec2f,
  resolution: vec2f,
  origin: vec3f,
  at: vec3f,
  fov: f32,
) -> Ray {
  var p = (uv - vec2f(0.5)) * 2.0;
  p.y = -p.y;
  p.x *= resolution.x / max(resolution.y, 1e-4);

  let basis = lookAt(origin, at, 0.0);
  let focal = 1.0 / tan(fov * 0.5);
  let direction = normalize(basis * vec3f(p, focal));

  return Ray(origin, direction);
}

// Orbit a point: `yaw` and `pitch` in radians, pitch clamped off the poles.
export fn orbit(at: vec3f, distance: f32, yaw: f32, pitch: f32) -> vec3f {
  let p = clamp(pitch, -1.4, 1.4);
  return at + vec3f(
    distance * cos(p) * sin(yaw),
    distance * sin(p),
    distance * cos(p) * cos(yaw),
  );
}
