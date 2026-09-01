// Screen-space helpers: coordinate framing, rotation, and domain repetition.
//
// Pure module. Nothing here declares @group/@binding — vgpu rejects resource
// declarations inside imported modules (VGPU-RESOLVE-MODULE-BINDING). The
// entry shader owns its bindings and passes the values in as arguments.
//
// Convention: vgpu's injected `uv` is top-origin, so (0,0) is the top-left
// corner and v grows downward. Every function here takes uv in that space.
// Call flipY once at the boundary when porting a y-up shader.

export const TAU: f32 = 6.28318530717958647692;

// Flip to y-up. Use once at the boundary, then stay flip-free.
export fn flipY(uv: vec2f) -> vec2f {
  return vec2f(uv.x, 1.0 - uv.y);
}

// Centered, aspect-corrected coordinates: the shortest axis spans -1..1, so a
// circle stays a circle at any canvas size.
export fn centered(uv: vec2f, resolution: vec2f) -> vec2f {
  let p = (uv - vec2f(0.5)) * 2.0;
  return p * (resolution / min(resolution.x, resolution.y));
}

// Counter-clockwise rotation matrix, in radians. Columns, not rows — WGSL
// matrix constructors are column-major.
export fn rot2(angle: f32) -> mat2x2f {
  let s = sin(angle);
  let c = cos(angle);
  return mat2x2f(c, s, -s, c);
}

export fn rotate(p: vec2f, angle: f32) -> vec2f {
  return rot2(angle) * p;
}

// Cartesian to polar as (radius, turns). The angle is normalized to 0..1 so it
// feeds straight into palette() and anything else that wraps.
export fn polar(p: vec2f) -> vec2f {
  return vec2f(length(p), atan2(p.y, p.x) / TAU + 0.5);
}

// Repeat the plane into cells `1/n` across, returning cell-local coordinates
// centered on each cell.
export fn tile(p: vec2f, n: f32) -> vec2f {
  return fract(p * n) - vec2f(0.5);
}

// Mirror the plane into `segments` wedges around the origin.
export fn kaleidoscope(p: vec2f, segments: f32) -> vec2f {
  let wedge = TAU / segments;
  let a = atan2(p.y, p.x);
  let folded = abs(a - wedge * round(a / wedge));
  return vec2f(cos(folded), sin(folded)) * length(p);
}
