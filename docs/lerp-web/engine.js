// Lerping@Home Metal -> WebGL transpiler + shader metadata.
// Lives in the published site as lerp-web/engine.js; also used by node test scripts.

const GLSL_PRELUDE = `
#define PI 3.14159265358979323846
#define TWO_PI 6.28318530718

// Metal splats scalar args to mix() implicitly; GLSL does not, so every
// mix() call in shader bodies is renamed to lerpMix() and these overloads
// cover both spellings.
float lerpMix(float a, float b, float t) { return mix(a, b, t); }
vec2 lerpMix(vec2 a, vec2 b, float t) { return mix(a, b, t); }
vec3 lerpMix(vec3 a, vec3 b, float t) { return mix(a, b, t); }
vec4 lerpMix(vec4 a, vec4 b, float t) { return mix(a, b, t); }
vec2 lerpMix(vec2 a, float b, float t) { return mix(a, vec2(b), t); }
vec3 lerpMix(vec3 a, float b, float t) { return mix(a, vec3(b), t); }
vec4 lerpMix(vec4 a, float b, float t) { return mix(a, vec4(b), t); }
vec2 lerpMix(float a, vec2 b, float t) { return mix(vec2(a), b, t); }
vec3 lerpMix(float a, vec3 b, float t) { return mix(vec3(a), b, t); }
vec4 lerpMix(float a, vec4 b, float t) { return mix(vec4(a), b, t); }

// Centered, aspect-corrected UV: [-1, 1] on the short axis, y pointing up.
// (Port of LerpPrelude.lerpUV; pos is Metal-style top-left-origin pixels,
// which the main() wrapper reconstructs from gl_FragCoord.)
vec2 lerpUV(vec4 pos, vec2 res) {
    vec2 p = vec2(pos.x, res.y - pos.y);
    return (2.0 * p - res) / min(res.x, res.y);
}

// Plain 0..1 UV per axis, y pointing down (like CSS).
vec2 lerpScreenUV(vec4 pos, vec2 res) {
    return pos.xy / res;
}

// GLSL-style mod (floors, unlike fmod which truncates).
float glmod(float x, float y) { return x - y * floor(x / y); }
vec2 glmod2(vec2 x, float y) { return x - y * floor(x / y); }
vec3 glmod3(vec3 x, float y) { return x - y * floor(x / y); }

vec2 rotate(vec2 uv, float th) {
    float c = cos(th), s = sin(th);
    return mat2(vec2(c, s), vec2(-s, c)) * uv;
}

// Procedural hashes (from paper-design/shaders, Apache-2.0).
float hash11(float p) {
    p = fract(p * 0.3183099) + 0.1;
    p *= p + 19.19;
    return fract(p * p);
}
float hash21(vec2 p) {
    p = fract(p * vec2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}
vec2 hash22(vec2 p) {
    p = fract(p * vec2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p.yx + 19.19);
    return fract(vec2(p.x * p.y, p.x + p.y));
}

float valueNoise(vec2 st) {
    vec2 i = floor(st);
    vec2 f = fract(st);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

vec3 lerpGrainOverlay(vec3 color, vec2 grainUV, float amount) {
    float overlay = valueNoise(rotate(grainUV, 1.0) + 3.0);
    overlay = mix(overlay, valueNoise(rotate(grainUV, 2.0) - 1.0), 0.5);
    overlay = pow(overlay, 1.3);

    float value = overlay * 2.0 - 1.0;
    vec3 overlayColor = vec3(step(0.0, value));
    float strength = pow(amount * abs(value), 0.8);
    return mix(color, overlayColor, 0.35 * strength);
}

// 2D simplex noise (Ashima/paper-design port), returns roughly [-1, 1].
vec3 lerpPermute(vec3 x) { return glmod3(((x * 34.0) + 1.0) * x, 289.0); }
float snoise(vec2 v) {
    vec4 C = vec4(0.211324865405187, 0.366025403784439,
                  -0.577350269189626, 0.024390243902439);
    vec2 i = floor(v + dot(v, C.yy));
    vec2 x0 = v - i + dot(i, C.xx);
    vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = glmod2(i, 289.0);
    vec3 p = lerpPermute(lerpPermute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
    vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    vec3 x = 2.0 * fract(p * C.www) - 1.0;
    vec3 h = abs(x) - 0.5;
    vec3 ox = floor(x + 0.5);
    vec3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    vec3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// Breaks up gradient banding with a tiny screen-space dither
// (from paper-design/shaders, Apache-2.0).
vec3 lerpDither(vec3 color, vec4 pos) {
    return color + 1.0 / 256.0 *
        (fract(sin(dot(0.014 * pos.xy, vec2(12.9898, 78.233))) * 43758.5453123) - 0.5);
}
`;

export { GLSL_PRELUDE };

// Parses a color default: #rgb, #rrggbb, #rrggbbaa, or (r, g, b[, a]).
export function parseColor(def) {
  const d = def.trim();
  if (d.startsWith("#")) {
    let h = d.slice(1);
    if (h.length === 3) h = h.split("").map((c) => c + c).join("");
    const r = parseInt(h.slice(0, 2), 16) / 255;
    const g = parseInt(h.slice(2, 4), 16) / 255;
    const b = parseInt(h.slice(4, 6), 16) / 255;
    const a = h.length >= 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1;
    return [r, g, b, a];
  }
  const m = d.match(/^\(\s*([^)]+)\)$/);
  if (!m) throw new Error("bad color default: " + def);
  const parts = m[1].split(",").map((x) => parseFloat(x.trim()));
  if (parts.some(isNaN) || parts.length < 3) throw new Error("bad color default: " + def);
  return [parts[0], parts[1], parts[2], parts.length > 3 ? parts[3] : 1];
}

// Reads // lerp-param:, // lerp-data: and the leading description comment.
export function parseShader(src) {
  const params = [];
  let dataProvider = null;
  for (const line of src.split("\n")) {
    let m = line.match(/^\s*\/\/\s*lerp-data:\s*(\w+)\s*$/);
    if (m) { dataProvider = m[1]; continue; }
    m = line.match(/^\s*\/\/\s*lerp-param:\s*([A-Za-z_]\w*)\s+(color|float|int|bool)\s+(.*?)\s*=\s*(.+?)\s+"([^"]*)"\s*$/);
    if (!m) continue;
    const [, name, type, bounds, def, label] = m;
    const p = { name, type, def: def.trim(), label };
    if (type === "float" || type === "int") {
      const b = bounds.trim().split(/\s+/);
      p.min = parseFloat(b[0]);
      p.max = parseFloat(b[1]);
    }
    params.push(p);
  }
  // Description: first comment paragraph.
  const desc = [];
  for (const line of src.split("\n")) {
    const m = line.match(/^\s*\/\/\s?(.*)$/);
    if (!m) break;
    const text = m[1].trim();
    if (/^lerp-(param|preset|data)/.test(text)) continue;
    if (text === "") { if (desc.length) break; else continue; }
    desc.push(text);
  }
  return { params, dataProvider, description: desc.join(" ") };
}

export function transpile(src) {
  const { params, dataProvider } = parseShader(src);
  let s = src.replace(/\r/g, "");

  // Drop preprocessor / namespace lines (prelude supplies PI etc.).
  s = s.replace(/^#include.*$/gm, "");
  s = s.replace(/^#define.*$/gm, "");
  s = s.replace(/^using namespace metal;.*$/gm, "");

  // lerpMain signature -> plain GLSL function. Handles multi-line signatures.
  s = s.replace(/fragment\s+half4\s+lerpMain\s*\([\s\S]*?\)\s*\{/, "vec4 lerpMain(vec4 pos){");

  // u.field -> u_field
  s = s.replace(/\bu\.([A-Za-z_]\w*)/g, "u_$1");

  // mix() -> lerpMix() (scalar-splat-tolerant overloads live in the prelude)
  s = s.replace(/\bmix\s*\(/g, "lerpMix(");

  // Metal builtins that GLSL ES spells differently.
  s = s.replace(/\batan2\s*\(/g, "atan(");
  s = s.replace(/\bdfdx\s*\(/g, "dFdx(");
  s = s.replace(/\bdfdy\s*\(/g, "dFdy(");
  s = s.replace(/\brsqrt\s*\(/g, "inversesqrt(");
  s = rewriteSelect(s);

  // Types, longest names first.
  const types = [
    ["float2x2", "mat2"],
    ["half4", "vec4"], ["half3", "vec3"], ["half2", "vec2"],
    ["float4", "vec4"], ["float3", "vec3"], ["float2", "vec2"],
    ["int4", "ivec4"], ["int3", "ivec3"], ["int2", "ivec2"],
    ["uint4", "uvec4"], ["uint3", "uvec3"], ["uint2", "uvec2"],
  ];
  for (const [m, g] of types) s = s.replace(new RegExp("\\b" + m + "\\b", "g"), g);
  s = s.replace(/\bhalf\b/g, "float");

  // half literals: 1.0h -> 1.0
  s = s.replace(/(\d(?:\.\d+)?)h\b/g, "$1");

  // Qualifiers Metal has and GLSL ES doesn't (in these positions).
  s = s.replace(/\bconstant\b/g, "const");
  s = s.replace(/\bstatic\b/g, "");
  s = s.replace(/\binline\b/g, "");

  // Stray [[attributes]].
  s = s.replace(/\[\[[^\]]*\]\]/g, "");

  // Helper functions that take the uniforms struct (e.g. color-panels'):
  // in GLSL the uniforms are globals, so drop the parameter from
  // definitions and the trailing `u` argument from call sites.
  s = stripUniformsParam(s);

  // Array initializers: `vec3 N[S] = { ... };` -> `vec3 N[S] = vec3[S](...);`
  // (GLSL ES 3.00 needs the constructor form, and no trailing comma.)
  s = arrayInitTransform(s);

  const uniforms = [
    "uniform vec2 u_resolution;",
    "uniform float u_time;",
    "uniform float u_seed;",
    ...params.map((p) => (p.type === "color" ? `uniform vec4 u_${p.name};`
      : p.type === "int" ? `uniform int u_${p.name};`
      : `uniform float u_${p.name};`)),
  ];

  const glsl = `#version 300 es
precision highp float;
precision highp int;
${uniforms.join("\n")}
${GLSL_PRELUDE}
${s}
out vec4 fragColor;
void main() {
    // Match Metal's top-left pixel origin: flip gl_FragCoord's y.
    vec4 pos = vec4(gl_FragCoord.x, u_resolution.y - gl_FragCoord.y, gl_FragCoord.z, gl_FragCoord.w);
    fragColor = lerpMain(pos);
}
`;
  return { glsl, params, dataProvider };
}

// Metal's select(a, b, cond) returns b when cond is true, a otherwise —
// i.e. `cond ? b : a`. GLSL has no equivalent, so rewrite the call.
function rewriteSelect(s) {
  const needle = "select(";
  let out = "";
  let i = 0;
  for (;;) {
    const j = s.indexOf(needle, i);
    if (j === -1) { out += s.slice(i); break; }
    if (j > 0 && /[A-Za-z0-9_]/.test(s[j - 1])) { out += s.slice(i, j + 1); i = j + 1; continue; }
    let depth = 0, k = j + needle.length, start = k;
    const args = [];
    for (; k < s.length; k++) {
      const c = s[k];
      if (c === "(") depth++;
      else if (c === ")") {
        if (depth === 0) { args.push(s.slice(start, k)); break; }
        depth--;
      } else if (c === "," && depth === 0) { args.push(s.slice(start, k)); start = k + 1; }
    }
    if (args.length !== 3 || k >= s.length) { out += s.slice(i, j + 1); i = j + 1; continue; }
    out += s.slice(i, j) + `((${args[2]}) ? (${args[1]}) : (${args[0]}))`;
    i = k + 1;
  }
  return out;
}

// Rewrites Metal brace array initializers into GLSL constructor form.
// Handles both multi-line initializers (brace opens and closes on their
// own lines) and single-line ones (`vec4 c[N] = { a, b };`).
function arrayInitTransform(s) {
  // Join C-style line continuations first (affects initializers like heatmap's).
  s = s.replace(/\\\r?\n/g, "");
  // Single-line: `vec4 c[N] = { a, b, c };` -> `vec4 c[N] = vec4[N](a, b, c);`
  // ([ \t]* instead of \s* so this never spans lines; multiline is below.)
  s = s.replace(
    /^(\s*(?:const\s+)?)(vec[234]|int|float|ivec[234])\s+(\w+)\s*\[\s*(\w+)\s*\]\s*=\s*\{[ \t]*(.+?)[ \t]*\}[ \t]*;/gm,
    (m, ind, type, name, size, elems) =>
      `${ind}${type} ${name}[${size}] = ${type}[${size}](${elems.replace(/,[ \t]*$/, "")});`
  );

  const lines = s.split("\n");
  // Multiline: brace may open at end of line or mid-line (`= { a, b,`).
  const openRe = /^(\s*(?:const\s+)?)(vec[234]|int|float|ivec[234])\s+(\w+)\s*\[\s*(\w+)\s*\]\s*=\s*\{\s*(.*)$/;
  const out = [];
  let pendingClose = -1; // index in `out` of the line holding the opening
  for (const line of lines) {
    if (pendingClose === -1) {
      const m = line.match(openRe);
      if (m) {
        out.push(`${m[1]}${m[2]} ${m[3]}[${m[4]}] = ${m[2]}[${m[4]}](${m[5]}`);
        pendingClose = out.length - 1;
      } else {
        out.push(line);
      }
    } else {
      const closeIdx = line.indexOf("};");
      if (closeIdx !== -1) {
        const content = line.slice(0, closeIdx).trim();
        const after = line.slice(closeIdx + 2).trim();
        if (content) out.push(content);
        // Strip a trailing comma from the last initializer element. The
        // comma may hide behind a trailing `// comment`, so only strip a
        // comma that is followed by nothing but whitespace/comment to EOL.
        for (let k = out.length - 1; k > pendingClose; k--) {
          if (out[k].trim() !== "") {
            out[k] = out[k].replace(/,(?=\s*(\/\/.*)?$)/, "");
            break;
          }
        }
        out.push(");" + (after ? " " + after : ""));
        pendingClose = -1;
      } else {
        out.push(line);
      }
    }
  }
  return out.join("\n");
}

// Drops the `, const LerpUniforms& u` parameter from helper-function
// definitions and the matching trailing `, u` argument from their call
// sites. In GLSL the uniforms are globals, so the parameter is vestigial.
function stripUniformsParam(s) {
  // Collect helper names from definitions (param lists here never nest).
  const helpers = new Set();
  for (const m of s.matchAll(/\b([A-Za-z_]\w*)\s*\(([^()]*)\)\s*\{/g)) {
    if (/(^|,)\s*const\s+LerpUniforms\s*&\s*u\s*$/.test(m[2])) helpers.add(m[1]);
  }
  s = s.replace(/,\s*const\s+LerpUniforms\s*&\s*u\s*\)/g, ")");
  s = s.replace(/\(\s*const\s+LerpUniforms\s*&\s*u\s*\)/g, "()");
  for (const name of helpers) s = stripTrailingArg(s, name, "u");
  return s;
}

// Removes a trailing `, ARG` argument from every call of `name(...)`,
// balancing parentheses so nested calls don't confuse it.
function stripTrailingArg(s, name, arg) {
  const needle = name + "(";
  let out = "";
  let i = 0;
  const argRe = new RegExp(",\\s*" + arg + "\\s*$");
  for (;;) {
    const j = s.indexOf(needle, i);
    if (j === -1) { out += s.slice(i); break; }
    if (j > 0 && /[A-Za-z0-9_]/.test(s[j - 1])) { out += s.slice(i, j + 1); i = j + 1; continue; }
    let depth = 0, k = j + needle.length - 1;
    for (; k < s.length; k++) {
      if (s[k] === "(") depth++;
      else if (s[k] === ")") { if (--depth === 0) break; }
    }
    if (k >= s.length) { out += s.slice(i); break; }
    const args = s.slice(j + needle.length, k).replace(argRe, "");
    out += s.slice(i, j) + needle + args + ")";
    i = k + 1;
  }
  return out;
}

// All 31 built-in shaders. `macOnly` ones need a native data provider
// (CPU simulation) that has no web equivalent yet.
export const SHADER_IDS = [
  "aurora", "color-panels", "dithering", "dot-grid", "dot-orbit",
  "fluted-glass", "game-of-life", "gem-smoke", "god-rays", "grain-gradient",
  "halftone-cmyk", "halftone-dots", "heatmap", "liquid-metal", "mesh-gradient",
  "metaballs", "neuro-noise", "paper-texture", "perlin-noise", "pipes",
  "pulsing-border", "simplex-noise", "smoke-ring", "spiral",
  "static-mesh-gradient", "static-radial-gradient", "swirl", "voronoi",
  "warp", "water", "waves",
];

export const MAC_ONLY = new Set(["game-of-life", "heatmap", "pipes"]);

const ACRONYMS = new Set(["cmyk"]);
export function titleize(id) {
  return id.split("-").map((w) => ACRONYMS.has(w) ? w.toUpperCase() : w[0].toUpperCase() + w.slice(1)).join(" ");
}

// Deterministic per-shader seed in [0, 1) so thumbnails are stable.
export function seedFor(id) {
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) { h ^= id.charCodeAt(i); h = Math.imul(h, 16777619); }
  return ((h >>> 0) % 1000000) / 1000000;
}

export function defaultParamValues(params) {
  const v = {};
  for (const p of params) v[p.name] = p.type === "color" ? parseColor(p.def) : parseFloat(p.def);
  return v;
}
