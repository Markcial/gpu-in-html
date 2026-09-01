// Scalar shaping: remapping, antialiased steps, bumps, and easing.
//
// Pure module — see space.wgsl for the authoring rules these all follow.

// Linear remap between two ranges. Unclamped on purpose; clamp at the call
// site when you actually want the ends held.
export fn remap(x: f32, inMin: f32, inMax: f32, outMin: f32, outMax: f32) -> f32 {
  return outMin + (x - inMin) * (outMax - outMin) / (inMax - inMin);
}

// Resolution-independent step: the transition is always about one pixel wide,
// whatever the canvas size or zoom.
//
// Fragment stage only. fwidth needs screen-space derivatives, so calling this
// from a vertex or compute entry point will not compile.
export fn aastep(threshold: f32, value: f32) -> f32 {
  let w = fwidth(value) * 0.70710678;
  return smoothstep(threshold - w, threshold + w, value);
}

// Antialiased fill of a signed distance field: 1 inside the shape, 0 outside.
export fn sdFill(d: f32) -> f32 {
  return 1.0 - aastep(0.0, d);
}

// Antialiased outline of a signed distance field, `width` units thick.
export fn sdStroke(d: f32, width: f32) -> f32 {
  return 1.0 - aastep(width * 0.5, abs(d));
}

// A smooth bump peaking at 1 on `center` and reaching 0 at `width` away.
export fn pulse(x: f32, center: f32, width: f32) -> f32 {
  return 1.0 - smoothstep(0.0, width, abs(x - center));
}

export fn easeInOutCubic(x: f32) -> f32 {
  let t = clamp(x, 0.0, 1.0);
  let rising = 4.0 * t * t * t;
  let falling = 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5;
  return select(falling, rising, t < 0.5);
}
