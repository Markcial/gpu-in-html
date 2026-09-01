// Entry shader: the wall of an organ, looked at.
//
// Two things carry this one. The lamp rides the camera, so there is no sun and
// no room and the light falls off with distance. And the camera does not move:
// the only motion in the frame is the tissue itself, slowly. A moving camera
// over a wall reads as a shot; a still one reads as something being looked at.

import { rayFromUv } from "@gpu-in-html/wgsl/camera";
import { sdRoundedBox } from "@gpu-in-html/wgsl/shape2d";
import { cylindricalUv } from "@gpu-in-html/wgsl/shape3d";
import { applyGrain, contrast, fog, halation, vignette } from "@gpu-in-html/wgsl/post";
import { linearToSrgb3, srgbToLinear3, tonemapAces } from "@vgpu/wgsl-std/color";
import { fbmSimplex3d, simplex3d } from "@vgpu/wgsl-std/noise/simplex";
import { saturate } from "@vgpu/wgsl-std/math";
import {
  BEAT_RATE,
  heartbeat,
  lumenSdf,
  skin,
  tubeCenter,
  venousNetwork,
  vessels,
} from "./organ.wgsl";

struct Params {
  resolution: vec2f,
  // The form's measured rectangle, in uv space. The tissue under it is drawn
  // differently, so the sheet is not a panel over the wall — it is a patch of
  // the wall.
  panelCenter: vec2f,
  panelHalf: vec2f,
  time: f32,
  tone: f32,
  // Distance travelled along the wall, in world units. The page's scroll
  // position feeds this, so scrolling the form moves the camera rather than
  // just moving the document over a static backdrop.
  scroll: f32,
  fieldCount: u32,
}

@group(0) @binding(0) var<uniform> params: Params;

// Every form control on screen, two vec4f each:
//
//   [i*2 + 0]  (centreX, centreY, halfX, halfY)  rectangle, in uv space
//   [i*2 + 1]  (kind, cornerRadius, focused, _)  0 = recessed, 1 = raised
//
// A storage buffer rather than a uniform array: the count varies with the page
// and with scrolling, and vgpu's structured uniforms carry scalars, vectors and
// matrices but not WGSL arrays.
@group(0) @binding(1) var<storage, read> fields: array<vec4f>;

const MAX_STEPS: i32 = 90;
const MAX_DIST: f32 = 14.0;
const SURFACE: f32 = 0.0016;

// A fixed viewpoint: where around the axis the camera sits, at what height,
// and how far back from the wall as a fraction of the lumen radius. Close
// enough that the surface fills the frame, far enough that there is real
// perspective across it.
// Venous lattice density. VEINS_AROUND is the tiling period, so it has to stay
// a whole number — a fractional count cannot close around the tube.
const VEINS_AROUND: f32 = 12.0;
const VEINS_ALONG: f32 = 2.3;

const VIEW_ANGLE: f32 = 0.65;
const VIEW_Y: f32 = 0.0;
const STANDOFF: f32 = 0.55;

fn normalAt(p: vec3f, time: f32, tone: f32) -> vec3f {
  let e = vec2f(0.0020, 0.0);
  return normalize(vec3f(
    lumenSdf(p + e.xyy, time, tone) - lumenSdf(p - e.xyy, time, tone),
    lumenSdf(p + e.yxy, time, tone) - lumenSdf(p - e.yxy, time, tone),
    lumenSdf(p + e.yyx, time, tone) - lumenSdf(p - e.yyx, time, tone),
  ));
}

// Micro-relief. At this range the distance field's own detail is far too
// smooth, and a smooth normal plus any specular at all reads as polished —
// however matte the colour underneath is. Tilting the normal with a fine noise
// gradient breaks the shading up for four noise samples on hit pixels only.
// Putting the same detail in the SDF would cost an evaluation on every step of
// every ray, and would force the marcher to take shorter steps as well.
fn microNormal(p: vec3f, n: vec3f, scale: f32, strength: f32) -> vec3f {
  let e = 0.12;
  let base = simplex3d(p * scale);
  let gradient = vec3f(
    simplex3d(p * scale + vec3f(e, 0.0, 0.0)) - base,
    simplex3d(p * scale + vec3f(0.0, e, 0.0)) - base,
    simplex3d(p * scale + vec3f(0.0, 0.0, e)) - base,
  );
  // Only the part tangential to the surface should tilt it.
  let tangential = gradient - n * dot(gradient, n);
  return normalize(n + tangential * strength);
}

fn march(origin: vec3f, direction: vec3f, time: f32, tone: f32) -> f32 {
  var t = 0.02;
  for (var i = 0; i < MAX_STEPS; i++) {
    let d = lumenSdf(origin + direction * t, time, tone);
    if (d < SURFACE * t) {
      return t;
    }
    t += d;
    if (t > MAX_DIST) {
      break;
    }
  }
  return -1.0;
}

// Cavity occlusion: how enclosed a point is. Sampling the field a short way
// along the normal is the cheapest useful ambient term, and against a folded
// wall it does most of the work — the creases are exactly what should go dark.
fn occlusion(p: vec3f, n: vec3f, time: f32, tone: f32) -> f32 {
  var acc = 0.0;
  var weight = 1.0;
  for (var i = 1; i <= 4; i++) {
    let step = f32(i) * 0.085;
    acc += weight * (step - lumenSdf(p + n * step, time, tone));
    weight *= 0.65;
  }
  // A light touch. Driven hard, this is what digs the creases to black and
  // splits the image into pale ridges and dark pits — the tissue should read
  // as one material at one value, shaped by light rather than by contrast.
  return saturate(1.0 - acc * 2.6);
}

@fragment
fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let time = params.time;
  let tone = clamp(params.tone, 0.0, 1.0);

  // The form's rectangle, as a rounded box in screen space. Aspect-corrected
  // so the corners stay round whatever the canvas is.
  let aspect = params.resolution.x / max(params.resolution.y, 1e-4);
  let panelD = sdRoundedBox(
    (uv - params.panelCenter) * vec2f(aspect, 1.0),
    params.panelHalf * vec2f(aspect, 1.0),
    0.016 * aspect,
  );
  // With no form on the page the half-extent arrives as zero, and a rounded
  // box of zero size is still a disc of its corner radius — which would blanch
  // a stray dot in the middle of the frame. Headless renders hit exactly that.
  let panelActive = step(1e-5, params.panelHalf.x * params.panelHalf.y);
  let underPanel = smoothstep(0.0016, -0.0016, panelD) * panelActive;
  // The band just outside the edge, where displaced blood collects.
  let panelRim = smoothstep(0.016, 0.0, panelD) * (1.0 - underPanel) * panelActive;

  // The controls, in the same screen space. Fields become depressions in the
  // wall and the button a raised welt; the DOM elements themselves draw no
  // background at all.
  var fieldInset = 0.0;
  var fieldRaised = 0.0;
  var fieldLip = 0.0;
  var fieldFocus = 0.0;
  var fieldBevel = vec2f(0.0);

  for (var i = 0u; i < params.fieldCount; i++) {
    let rect = fields[i * 2u];
    // Not `meta`: that is a reserved word in WGSL, like `target`.
    let info = fields[i * 2u + 1u];

    let q = (uv - rect.xy) * vec2f(aspect, 1.0);
    let d = sdRoundedBox(q, rect.zw * vec2f(aspect, 1.0), info.y * aspect);

    let inside = smoothstep(0.0012, -0.0012, d);
    let edge = smoothstep(0.0055, 0.0, abs(d));

    if (info.x < 0.5) {
      fieldInset = max(fieldInset, inside);
    } else {
      fieldRaised = max(fieldRaised, inside);
    }
    fieldLip = max(fieldLip, edge);
    fieldFocus = max(fieldFocus, edge * info.z);

    // Outward direction along the edge, accumulated so the normal can be
    // tilted there. The epsilon keeps normalize defined at the centre.
    fieldBevel += normalize(q + vec2f(1e-5)) * edge;
  }

  // The camera moves only with the page. Scrolling slides it along the wall
  // and turns it slightly, so the traverse curves rather than running dead
  // straight — and because the tube's own axis wanders, the wall keeps
  // presenting a different face.
  let viewY = VIEW_Y + params.scroll;
  let viewAngle = VIEW_ANGLE + params.scroll * 0.10;

  let axis = tubeCenter(viewY);
  let radial = vec3f(cos(viewAngle), 0.0, sin(viewAngle));
  let onAxis = vec3f(axis.x, viewY, axis.y);
  let ray = rayFromUv(uv, params.resolution, onAxis + radial * STANDOFF, onAxis + radial * 3.0, 1.02);

  // Not black. Out of the lamp's reach there is still tissue glowing dimly,
  // and a pure black hole reads as a missing object rather than as depth.
  let voidColor = srgbToLinear3(vec3f(0.170, 0.028, 0.034));
  var col = voidColor;

  let t = march(ray.origin, ray.direction, time, tone);

  if (t > 0.0) {
    let p = ray.origin + ray.direction * t;
    let view = -ray.direction;

    // The geometric normal is kept as well as the perturbed one: occlusion is
    // a property of the shape, and feeding it a bumped normal would make the
    // micro-relief cast shadows it has no geometry for.
    let geometric = normalAt(p, time, tone);

    // Everything that decorates the surface is sampled in skin space, so the
    // pattern stays stuck to the tissue while the wall breathes underneath it.
    let s = skin(p);

    // Two scales of micro-relief: pores, then the grain between them. Gentle —
    // enough to stop the specular reading as polished, not enough to make the
    // membrane look rough. The bumps in the distance field carry the relief.
    var n = microNormal(s, geometric, 9.0, 0.45);
    n = microNormal(s, n, 34.0, 0.22);
    // Flattened under the sheet: something pressing on a membrane smooths it.
    n = normalize(mix(n, geometric, underPanel * 0.92));

    // Bevel the field edges. The accumulated direction is in screen space, so
    // it goes through the camera basis to reach the world normal — colour
    // alone gives painted rectangles, while a tilted normal gives a rim the
    // lamp actually catches and reads as cut into the tissue.
    let camRight = normalize(cross(radial, vec3f(0.0, 1.0, 0.0)));
    let camUp = cross(camRight, radial);
    n = normalize(n + (camRight * fieldBevel.x - camUp * fieldBevel.y) * 0.85);

    // The lamp rides the camera, so the light direction is the view direction.
    // True inverse-square is too aggressive: it leaves a lit ring at the very
    // edge of frame and nothing else.
    let attenuation = 1.0 / (1.0 + t * t * 0.16);
    let facing = dot(n, view);

    // Wrap lighting. Tissue is translucent, so light does not stop at the
    // terminator — a hard lambert falloff is one of the things that makes
    // organic surfaces read as painted plastic.
    let wrap = 0.42;
    let diffuse = saturate((facing + wrap) / (1.0 + wrap)) * attenuation;
    let ao = occlusion(p, geometric, time, tone);

    // Mucosa colour, continuous rather than patched. Real tissue does not come
    // in discrete cells at this scale, so two low frequencies move the colour
    // inside a narrow hue range, and a fine one breaks it up close in.
    let deep = fbmSimplex3d(s * 0.85 + vec3f(0.0, 0.0, 3.7), 3, 2.0, 0.5);
    let thin = fbmSimplex3d(s * 2.30 + vec3f(5.1, 0.0, 0.0), 3, 2.0, 0.5);

    // A narrow range on purpose. Real mucosa is one colour with slight
    // variation, not a marbled pattern; widening these endpoints is what turned
    // the wall into a map of light and dark regions. The variation stays narrow
    // here — only the saturation has gone up.
    var albedo = mix(
      // Not pushed to the limit: with green and blue at zero the shading can
      // only move the red channel, which saturates almost immediately and
      // flattens the relief away. Leaving a little chroma headroom is what
      // keeps the nodules readable at this hue.
      srgbToLinear3(vec3f(0.58, 0.17, 0.15)),
      srgbToLinear3(vec3f(0.82, 0.34, 0.28)),
      saturate(deep * 0.95 + 0.5),
    );
    albedo = mix(
      albedo,
      srgbToLinear3(vec3f(0.82, 0.42, 0.34)),
      saturate(thin * 0.75 + 0.25) * 0.10,
    );

    // Blood floods the tissue on systole, so it flushes. Driving the colour
    // from the same waveform that moves the wall is what makes the beat read
    // as blood arriving rather than as the surface merely shifting.
    // Kept almost at full strength under the form: congested tissue holds
    // more blood, not less, so the patch should throb visibly against the
    // white type sitting on it.
    let pulse = heartbeat(time * BEAT_RATE);
    albedo = mix(
      albedo,
      srgbToLinear3(vec3f(0.74, 0.06, 0.07)),
      pulse * 0.26 * (1.0 - underPanel * 0.15),
    );
    albedo *= 0.95 + 0.08 * (simplex3d(s * 21.0) * 0.5 + 0.5);

    // Vessels at two scales: a few large veins, and a fine net over
    // everything. The net is what actually sells it — a single scale of
    // branching reads as cracks.
    // Veins proper: branching trees on a wrapped lattice, in blue.
    //
    // Two things keep them honest. They are trees, so no branch ever closes a
    // loop, and every tip tapers to nothing rather than ending square. And a
    // slow noise field sinks parts of the network below the mucosa, so a
    // vessel that leaves frame has dived rather than been cut off — the fade
    // is gradual enough that nothing pops into existence.
    // Straight segments read as arrows, not vessels, so the sample point is
    // warped before the lookup. A warp is a homeomorphism: it bends every
    // branch without being able to introduce a loop or break one, so the
    // topology the tree guarantees survives it intact.
    //
    // The warp is derived from the 3D point on the cylinder rather than from
    // the uv, because that is inherently periodic around the tube — warping
    // the uv directly would tear the seam where the field wraps.
    let veinWarp = vec2f(
      fbmSimplex3d(s * 0.85 + vec3f(11.0, 0.0, 0.0), 3, 2.0, 0.5),
      fbmSimplex3d(s * 0.85 + vec3f(0.0, 27.0, 0.0), 3, 2.0, 0.5),
    ) * 0.34;

    let venous = venousNetwork(
      cylindricalUv(s, VEINS_AROUND, VEINS_ALONG) + veinWarp,
      VEINS_AROUND,
    );
    let surfacing = 0.25 + 0.75 * smoothstep(
      -0.42,
      0.22,
      fbmSimplex3d(s * 0.65 + vec3f(2.3, 0.0, 1.1), 3, 2.0, 0.5),
    );

    let capillaries = vessels(s * 3.10 + vec3f(9.3, 2.1, 4.7), 0.16);
    // Vessels sit under the mucosa, so they show through rather than being
    // drawn on it — a much lighter mix than a surface marking would take.
    // Engorged rather than emptied, so they hold up better inside the patch —
    // but still damped, or the branching competes with the type.
    let vesselFade = 1.0 - underPanel * 0.55;
    albedo = mix(albedo, srgbToLinear3(vec3f(0.60, 0.11, 0.13)), capillaries * 0.16 * vesselFade);
    // Deoxygenated blood under a translucent membrane reads blue-violet, not
    // blue. Kept low: these should be noticed on the second look.
    albedo = mix(
      albedo,
      srgbToLinear3(vec3f(0.20, 0.24, 0.46)),
      venous * surfacing * 0.34 * vesselFade,
    );

    // The patch under the form is congested, not blanched: the rim is where
    // the tissue is actually pinched, and blood trapped inside it pools and
    // darkens toward venous red. That gives white type a ground dark enough to
    // sit on while the region stays unmistakably tissue.
    albedo = mix(albedo, srgbToLinear3(vec3f(0.195, 0.022, 0.030)), underPanel * 0.90);
    // The pinch line itself does blanch — that is the one place the pressure
    // actually drives blood out of.
    albedo = mix(albedo, srgbToLinear3(vec3f(0.88, 0.66, 0.61)), panelRim * 0.55);

    // Fields are depressions with a little fluid standing in them: darker than
    // the patch around them, which is what keeps white type readable inside.
    albedo = mix(albedo, srgbToLinear3(vec3f(0.085, 0.014, 0.022)), fieldInset * 0.84);
    // The button is a welt pushed up out of the wall and blanched by the
    // stretch, so it carries dark type instead.
    albedo = mix(albedo, srgbToLinear3(vec3f(0.93, 0.86, 0.82)), fieldRaised * 0.92);
    // Every control is pinched pale at its edge, and brighter where it has
    // keyboard focus — the focus ring is drawn by the tissue, not by CSS.
    albedo = mix(albedo, srgbToLinear3(vec3f(0.86, 0.62, 0.58)), fieldLip * 0.42);
    albedo = mix(albedo, srgbToLinear3(vec3f(1.00, 0.42, 0.28)), fieldFocus * 0.88);

    // The lamp gain is tuned for how far the wall actually is. Facing it at
    // roughly a radius' standoff, everything is near, so the value that lit a
    // receding tunnel blows this out completely.
    // A generous ambient term relative to the lamp. Lifting the floor is what
    // keeps the shadows off black and holds the whole wall inside one value
    // range instead of splitting it into lit and unlit halves.
    col = albedo * (diffuse * 1.75 * ao + 0.11 * ao);

    // Light scattering forward through the thin folds, warm and close.
    col += srgbToLinear3(vec3f(0.88, 0.24, 0.18))
      * pow(saturate(1.0 - abs(facing)), 2.4)
      * attenuation
      * (0.32 + tone * 0.22)
      * (1.0 - underPanel * 0.80);

    // Barely any specular, and broad rather than tight. Mucosa is damp, not
    // polished: a narrow bright lobe over a smooth surface is exactly what
    // makes this read as a mirror instead of tissue. The micro-relief above
    // scatters what little is left.
    let wetness = saturate(fbmSimplex3d(s * 3.1, 3, 2.0, 0.5) * 1.7 + 0.30);
    // Almost gone under the sheet: something resting on a wet membrane wipes
    // it, and a sheen there would read as glass over the tissue rather than as
    // the tissue itself.
    col += vec3f(1.0, 0.96, 0.93)
      * pow(saturate(facing), 14.0)
      * 0.045
      * wetness
      * attenuation
      * (1.0 - underPanel * 0.85)
      // Except in the fields: standing fluid is the one place the wall should
      // look wet.
      * (1.0 + fieldInset * 6.0);

    col = fog(col, voidColor, t, 0.14);
  }

  col = halation(col, srgbToLinear3(vec3f(1.0, 0.20, 0.12)), 0.70, 0.16);
  col = tonemapAces(col);
  // Below 1: flatten rather than crush. The grade should not be adding the
  // black-and-white separation the shading was just tuned to avoid.
  col = contrast(col, 1.0);
  col *= 1.0 - vignette(uv, 0.20, 0.62);
  // Grain is reseeded every frame, so it is a real contributor to how busy the
  // image feels even though nothing in the scene is moving because of it.
  col = applyGrain(col, uv, params.resolution, time, 0.032);

  return vec4f(linearToSrgb3(max(col, vec3f(0.0))), 1.0);
}
