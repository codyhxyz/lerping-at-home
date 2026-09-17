import { transpile, parseShader, titleize, seedFor, defaultParamValues, MAC_ONLY, SHADER_IDS } from "./engine.js";

const RAW = "https://raw.githubusercontent.com/codyhxyz/lerping-at-home/main/Sources/Shaders/";
const VERTEX = `#version 300 es
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;

let shaders = [];        // {id, title, description, macOnly, params, glsl, thumbValues, thumbProgram, values, heroProgram}
let activeId = null;
let raf = 0;
let t0 = performance.now();

function getGL(canvas) {
  const gl = canvas.getContext("webgl2", { antialias: false, alpha: false });
  if (!gl) {
    document.getElementById("nogl").style.display = "flex";
    document.getElementById("hero").style.display = "none";
    return null;
  }
  return gl;
}

function compileProgram(gl, fsSrc) {
  const compile = (type, src) => {
    const sh = gl.createShader(type);
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(sh);
      gl.deleteShader(sh);
      throw new Error("shader compile failed: " + log);
    }
    return sh;
  };
  const vs = compile(gl.VERTEX_SHADER, VERTEX);
  const fs = compile(gl.FRAGMENT_SHADER, fsSrc);
  const prog = gl.createProgram();
  gl.attachShader(prog, vs);
  gl.attachShader(prog, fs);
  gl.linkProgram(prog);
  gl.deleteShader(vs);
  gl.deleteShader(fs);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
    const log = gl.getProgramInfoLog(prog);
    gl.deleteProgram(prog);
    throw new Error("program link failed: " + log);
  }
  return prog;
}

function drawScene(gl, prog, rec, values, w, h, time, seed) {
  gl.viewport(0, 0, w, h);
  gl.useProgram(prog);
  gl.uniform2f(gl.getUniformLocation(prog, "u_resolution"), w, h);
  gl.uniform1f(gl.getUniformLocation(prog, "u_time"), time);
  gl.uniform1f(gl.getUniformLocation(prog, "u_seed"), seed);
  for (const p of rec.params) {
    const loc = gl.getUniformLocation(prog, "u_" + p.name);
    const v = values[p.name];
    if (p.type === "color") gl.uniform4fv(loc, v);
    else if (p.type === "int" || p.type === "bool") gl.uniform1i(loc, Math.round(v));
    else gl.uniform1f(loc, v);
  }
  gl.drawArrays(gl.TRIANGLES, 0, 3);
}

async function boot() {
  const grid = document.getElementById("grid");

  // Load + transpile in parallel. Check HTTP status before trusting the body.
  const loaded = await Promise.all(SHADER_IDS.map(async (id) => {
    const res = await fetch(RAW + id + ".metal");
    if (!res.ok) throw new Error(`${id}: HTTP ${res.status}`);
    const src = await res.text();
    const { glsl, params, dataProvider } = transpile(src);
    const { description } = parseShader(src);
    return { id, title: titleize(id), description, macOnly: MAC_ONLY.has(id) || !!dataProvider,
             params, glsl, values: defaultParamValues(params), thumbValues: null,
             heroProgram: null, seed: seedFor(id) };
  }));

  // Deterministic order: web shaders first (alphabetical), then Mac-only.
  const web = loaded.filter((s) => !s.macOnly).sort((a, b) => a.id.localeCompare(b.id));
  const mac = loaded.filter((s) => s.macOnly).sort((a, b) => a.id.localeCompare(b.id));
  shaders = [...web, ...mac];
  for (const s of web) s.thumbValues = { ...s.values };

  // Drop skeletons, build cards in final order.
  grid.innerHTML = "";
  for (const s of shaders) {
    const card = document.createElement("button");
    card.className = "card" + (s.macOnly ? " mac-only" : "");
    card.id = "card-" + s.id;
    if (s.macOnly) {
      card.innerHTML = `<div class="mac-chip">Mac app only</div>
        <div class="mac-body"><div class="mac-title">${s.title}</div>
        <div class="mac-desc">${s.description || "Needs the native engine."}</div></div>`;
    } else {
      card.innerHTML = `<canvas width="320" height="200"></canvas>
        <div class="card-label"><span class="card-title">${s.title}</span></div>`;
      card.addEventListener("click", () => selectShader(s.id));
    }
    grid.appendChild(card);
  }

  // Render thumbnails lazily as cards scroll into view.
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      const id = e.target.id.replace("card-", "");
      const rec = shaders.find((s) => s.id === id);
      io.unobserve(e.target);
      if (rec && !rec.macOnly) renderThumb(rec);
    }
  }, { rootMargin: "200px" });
  document.querySelectorAll(".card:not(.mac-only)").forEach((c) => io.observe(c));

  selectShader(web[0].id);
}

// Thumbnails share one offscreen WebGL2 context: programs are cached per
// shader, pixels are read back synchronously and painted into each card's
// plain 2D canvas. This never hits the browser's per-page GL context limit
// and never races context loss against presentation.
let thumbGL = null;
const thumbProgs = new Map();
function renderThumb(rec) {
  const dest = document.querySelector(`#card-${rec.id} canvas`);
  if (!dest) return;
  if (!thumbGL) {
    const off = document.createElement("canvas");
    off.width = 320; off.height = 200;
    thumbGL = getGL(off);
    if (!thumbGL) return;
  }
  const gl = thumbGL;
  try {
    if (!thumbProgs.has(rec.id)) thumbProgs.set(rec.id, compileProgram(gl, rec.glsl));
  } catch (e) {
    console.warn(rec.id, e.message);
    return;
  }
  const w = 320, h = 200;
  // Freeze a flattering moment: t=8s catches most animations mid-flow.
  drawScene(gl, thumbProgs.get(rec.id), rec, rec.thumbValues, w, h, 8, rec.seed);
  // readPixels forces GPU completion, so the capture can't race anything.
  const pixels = new Uint8Array(w * h * 4);
  gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
  const ctx = dest.getContext("2d");
  const img = ctx.createImageData(w, h);
  for (let y = 0; y < h; y++) {
    img.data.set(pixels.subarray((h - 1 - y) * w * 4, (h - y) * w * 4), y * w * 4);
  }
  ctx.putImageData(img, 0, 0);
}

function selectShader(id) {
  const rec = shaders.find((s) => s.id === id);
  if (!rec || rec.macOnly) return;
  activeId = id;
  document.querySelectorAll(".card").forEach((c) => c.classList.remove("active"));
  document.getElementById("card-" + id)?.classList.add("active");

  document.getElementById("heroTitle").textContent = rec.title;
  document.getElementById("heroDesc").textContent = rec.description || "";
  document.getElementById("shaderFile").textContent = `Sources/Shaders/${id}.metal`;
  document.getElementById("shaderFile").href = `https://github.com/codyhxyz/lerping-at-home/blob/main/Sources/Shaders/${id}.metal`;
  const i = shaders.filter((s) => !s.macOnly).indexOf(rec);
  const n = shaders.filter((s) => !s.macOnly).length;
  document.getElementById("heroCount").textContent = `${i + 1} / ${n}`;

  buildSliders(rec);

  const canvas = document.getElementById("hero");
  const gl = getGL(canvas);
  if (!gl) return;
  try {
    if (rec.heroProgram) gl.deleteProgram(rec.heroProgram);
    rec.heroProgram = compileProgram(gl, rec.glsl);
  } catch (e) {
    document.getElementById("heroError").textContent = "Couldn't compile this shader on your GPU: " + e.message;
    document.getElementById("heroError").style.display = "block";
    return;
  }
  document.getElementById("heroError").style.display = "none";

  cancelAnimationFrame(raf);
  t0 = performance.now();
  const frame = () => {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.floor(canvas.clientWidth * dpr), h = Math.floor(canvas.clientHeight * dpr);
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    drawScene(gl, rec.heroProgram, rec, rec.values, canvas.width, canvas.height,
              (performance.now() - t0) / 1000, rec.seed);
    raf = requestAnimationFrame(frame);
  };
  frame();
}

function buildSliders(rec) {
  const wrap = document.getElementById("sliders");
  wrap.innerHTML = "";
  for (const p of rec.params) {
    const row = document.createElement("div");
    row.className = "slider-row";
    const lab = document.createElement("label");
    lab.innerHTML = `<span>${p.label}</span><span class="val" id="val-${p.name}"></span>`;
    row.appendChild(lab);
    const showVal = () => {
      const v = rec.values[p.name];
      document.getElementById("val-" + p.name).textContent =
        p.type === "color" ? rgbaToHex(v) : p.type === "int" || p.type === "bool" ? String(Math.round(v))
        : Number(v).toFixed(3).replace(/\.?0+$/, "");
    };

    if (p.type === "color") {
      const cur = rec.values[p.name];
      const picker = document.createElement("input");
      picker.type = "color";
      picker.value = rgbaToHex(cur);
      const alpha = document.createElement("input");
      alpha.type = "range"; alpha.min = 0; alpha.max = 1; alpha.step = 0.01; alpha.value = cur[3];
      alpha.title = "Alpha";
      picker.addEventListener("input", () => { const c = hexToRgba(picker.value); c[3] = parseFloat(alpha.value); rec.values[p.name] = c; showVal(); });
      alpha.addEventListener("input", () => { rec.values[p.name][3] = parseFloat(alpha.value); showVal(); });
      const ctl = document.createElement("div");
      ctl.className = "color-ctl";
      ctl.appendChild(picker); ctl.appendChild(alpha);
      row.appendChild(ctl);
    } else if (p.type === "bool") {
      const box = document.createElement("input");
      box.type = "checkbox";
      box.checked = !!Math.round(rec.values[p.name]);
      box.addEventListener("change", () => { rec.values[p.name] = box.checked ? 1 : 0; showVal(); });
      row.appendChild(box);
    } else {
      const input = document.createElement("input");
      input.type = "range";
      input.min = p.min; input.max = p.max;
      input.step = p.type === "int" ? 1 : (p.max - p.min) / 200;
      input.value = rec.values[p.name];
      input.addEventListener("input", () => { rec.values[p.name] = parseFloat(input.value); showVal(); });
      row.appendChild(input);
    }
    showVal();
    wrap.appendChild(row);
  }
  if (!rec.params.length) wrap.innerHTML = `<p class="muted">No adjustable parameters.</p>`;
}

function rgbaToHex([r, g, b]) {
  const h = (x) => Math.round(x * 255).toString(16).padStart(2, "0");
  return "#" + h(r) + h(g) + h(b);
}
function hexToRgba(hex) {
  return [parseInt(hex.slice(1, 3), 16) / 255, parseInt(hex.slice(3, 5), 16) / 255,
          parseInt(hex.slice(5, 7), 16) / 255, 1];
}

function stepShader(dir) {
  const web = shaders.filter((s) => !s.macOnly);
  const i = web.findIndex((s) => s.id === activeId);
  selectShader(web[(i + dir + web.length) % web.length].id);
}

document.getElementById("prevBtn").addEventListener("click", () => stepShader(-1));
document.getElementById("nextBtn").addEventListener("click", () => stepShader(1));
document.getElementById("shuffleBtn").addEventListener("click", () => {
  const rec = shaders.find((s) => s.id === activeId);
  if (rec) { rec.seed = Math.random(); }
});
document.getElementById("resetBtn").addEventListener("click", () => {
  const rec = shaders.find((s) => s.id === activeId);
  if (rec) { rec.values = defaultParamValues(rec.params); buildSliders(rec); }
});
document.addEventListener("keydown", (e) => {
  if (/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName)) return;
  if (e.key === "ArrowRight") stepShader(1);
  else if (e.key === "ArrowLeft") stepShader(-1);
  else if (e.key === " ") { e.preventDefault(); document.getElementById("shuffleBtn").click(); }
});

boot().catch((e) => {
  document.getElementById("grid").innerHTML =
    `<p class="muted">Couldn't load the shaders (${e.message}). Check your connection and reload.</p>`;
});
