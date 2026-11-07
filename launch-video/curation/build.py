"""Builds curation/index.html: an editor for the launch video's picks.

    python3 curation/build.py

Two views over the same state. Montage: a viewer, the look library, and a
timeline of 16 fixed bars from the drop (two 8-bar phrases), where each bar is
one shot or two half-bar shots. Opening grid: the 6x6 wall behind the title.
State lives in localStorage; "Copy picks.json" exports the `montage` / `grid`
the Remotion project reads from remotion/src/picks.json.
"""
import json
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
looks = sorted(p.stem for p in (root / "footage/tiles").glob("*.mp4"))
current = json.loads((root / "remotion/src/picks.json").read_text())

html = r"""<!doctype html>
<meta charset="utf-8">
<title>Lerping@Home: launch edit</title>
<style>
  @font-face { font-family: Geist; src: url(../remotion/public/fonts/Geist-VariableFont_wght.ttf); font-weight: 100 900; }
  @font-face { font-family: Geist Mono; src: url(../remotion/public/fonts/geist-mono-latin-500.woff2); }
  :root {
    --bg: #0a0b0d; --panel: #111215; --raised: #17191d; --line: #1e2025; --line2: #2a2d33;
    --ink: #ececee; --dim: #8a8e97; --faint: #5b5f68; --acc: #5aa9ff; --fill: #d9a54a;
  }
  * { box-sizing: border-box; }
  [hidden] { display: none !important; }
  html, body { height: 100%; margin: 0; }
  body { background: var(--bg); color: var(--ink); font: 13px/1.35 Geist, system-ui; -webkit-font-smoothing: antialiased;
         display: grid; grid-template-rows: 52px minmax(0, 1fr) auto; grid-template-columns: minmax(0, 1fr); overflow: hidden; user-select: none; }
  header, main, footer { min-width: 0; }
  button { font: 500 12.5px Geist; color: var(--ink); background: var(--raised); border: 1px solid var(--line2);
           border-radius: 7px; height: 30px; padding: 0 12px; cursor: pointer; white-space: nowrap; }
  button:hover { border-color: #3a3e46; background: #1c1f24; }
  button.primary { background: var(--ink); color: #000; border-color: var(--ink); }
  button.primary:hover { background: #fff; }
  button:disabled { opacity: .4; cursor: default; }
  .mono { font-family: "Geist Mono"; font-size: 11.5px; }

  /* Header */
  header { display: flex; align-items: center; gap: 12px; padding: 0 16px; border-bottom: 1px solid var(--line); }
  @media (max-width: 1100px) { .brand { display: none; } .kbd { display: none; } }
  .brand { font-weight: 650; letter-spacing: -.015em; font-size: 14px; }
  .tabs { display: flex; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 2px; }
  .tabs button { border: 0; background: transparent; height: 26px; color: var(--dim); }
  .tabs button.on { background: var(--raised); color: var(--ink); box-shadow: 0 0 0 1px var(--line2); }
  .grow { flex: 1; }
  #status { color: var(--dim); font-size: 12px; }
  #status.bad { color: var(--fill); }

  /* Workspace */
  main { display: grid; grid-template-columns: minmax(0, 1fr) clamp(280px, 34%, 560px); min-height: 0; }
  .stagewrap { display: flex; flex-direction: column; min-height: 0; padding: 14px 16px 12px; gap: 10px; }
  .stagebox { flex: 1; min-height: 0; display: grid; place-items: center; }
  .frame { position: relative; aspect-ratio: 16 / 9; height: 100%; max-width: 100%; border-radius: 10px; overflow: hidden;
           background: #000; box-shadow: 0 0 0 1px var(--line); }
  @supports (width: 1cqw) { .stagebox { container-type: size; } .frame { width: min(100cqw, 100cqh * 16 / 9); height: auto; } }
  .frame video { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
  .frame .hint { position: absolute; inset: 0; display: grid; place-items: center; color: var(--faint); }
  #stage video { opacity: 0; } #stage video.on { opacity: 1; }
  .badge-over { position: absolute; left: 12px; top: 10px; font: 500 11px Geist; background: rgba(0,0,0,.55);
                backdrop-filter: blur(8px); padding: 4px 8px; border-radius: 6px; color: #fff; }
  .info { display: flex; align-items: center; gap: 10px; min-height: 30px; }
  .info .title { font-weight: 600; font-size: 14px; letter-spacing: -.01em; }
  .info .meta { color: var(--dim); font-size: 12px; }
  .board { display: grid; grid-template-columns: repeat(6, 1fr); grid-template-rows: repeat(6, 1fr); gap: 3px; padding: 3px;
           position: absolute; inset: 0; background: #050608; }

  /* Library */
  aside { border-left: 1px solid var(--line); display: flex; flex-direction: column; min-height: 0; background: #0c0d10; }
  .libhead { padding: 12px 14px 10px; display: flex; flex-direction: column; gap: 8px; border-bottom: 1px solid var(--line); }
  .libhead .row { display: flex; align-items: baseline; justify-content: space-between; }
  .libhead h3 { margin: 0; font-size: 13px; font-weight: 600; }
  .libhead .sub { color: var(--faint); font-size: 11.5px; }
  #filter { font: 13px Geist; background: var(--panel); color: var(--ink); border: 1px solid var(--line2); border-radius: 7px;
            height: 30px; padding: 0 10px; outline: none; }
  #filter:focus { border-color: var(--acc); }
  #library { overflow-y: auto; padding: 4px 14px 24px; }
  .group h4 { margin: 14px 0 7px; font-size: 11.5px; font-weight: 500; color: var(--dim); display: flex; gap: 6px; }
  .group h4 span { color: var(--faint); }
  .looks { display: grid; grid-template-columns: repeat(auto-fill, minmax(104px, 1fr)); gap: 10px 8px; }
  .look { cursor: pointer; }
  .look .thumb { position: relative; aspect-ratio: 16 / 9; border-radius: 6px; overflow: hidden; background: #000;
                 box-shadow: 0 0 0 1px var(--line); transition: box-shadow .12s; }
  .look:hover .thumb { box-shadow: 0 0 0 2px var(--acc); }
  .look img, .clip img, .tile img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; pointer-events: none; }
  .look .cap { margin-top: 5px; font-size: 11.5px; color: var(--ink); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .look .used { position: absolute; right: 4px; top: 4px; display: flex; gap: 3px; }
  .look .used span { font: 600 9.5px Geist; background: var(--acc); color: #000; border-radius: 4px; padding: 1px 4px; }
  .look .used span.g { background: #b9a6ff; }

  /* Timeline */
  footer { border-top: 1px solid var(--line); background: #0c0d10; padding: 10px 16px 14px; }
  .tl-top { display: flex; align-items: center; gap: 12px; margin-bottom: 8px; }
  .tl-top .label { font-weight: 600; font-size: 12.5px; }
  .tl-top .meta { color: var(--faint); font-size: 11.5px; }
  .tlscroll { overflow-x: auto; }
  .tl { position: relative; min-width: 720px; }
  .ruler, .track { display: grid; grid-template-columns: repeat(16, minmax(0, 1fr)); gap: 4px; }
  .ruler { margin-bottom: 5px; }
  .phrases { display: grid; grid-template-columns: 1fr 1fr; gap: 4px; margin-bottom: 4px; }
  .phrases div { font: 500 11px Geist; color: var(--dim); border-top: 1px solid var(--line2); padding-top: 3px; }
  .tick { font: 11px "Geist Mono"; color: var(--faint); display: flex; gap: 6px; align-items: center; padding-left: 2px;
          border-left: 1px solid var(--line2); height: 16px; white-space: nowrap; overflow: hidden; }
  .tick.phrase { color: var(--ink); border-left-color: var(--dim); }
  .tick .ph { font: 500 11px Geist; color: var(--dim); }
  .tick .fl { width: 5px; height: 5px; border-radius: 50%; background: var(--fill); }
  .bar { display: flex; gap: 2px; }
  .clip { position: relative; flex: 1; height: 62px; border-radius: 6px; overflow: hidden; background: var(--panel); cursor: pointer;
          box-shadow: 0 0 0 1px var(--line); }
  .bar.fill .clip { box-shadow: 0 0 0 1px #3b3222; }
  .clip.empty { background: repeating-linear-gradient(135deg, #111215 0 6px, #14161a 6px 12px); }
  .clip.empty::after { content: "+"; position: absolute; inset: 0; display: grid; place-items: center; color: var(--faint); font-size: 16px; }
  .clip .n { position: absolute; left: 4px; top: 4px; font: 600 10px Geist; background: rgba(0,0,0,.6); padding: 1px 5px; border-radius: 4px; }
  .clip.sel, .tile.sel { box-shadow: 0 0 0 2px var(--acc) !important; }
  .clip.over, .tile.over { box-shadow: 0 0 0 2px #fff !important; }
  .playhead { position: absolute; top: 0; bottom: 0; width: 2px; background: #fff; box-shadow: 0 0 8px #fff8; pointer-events: none; display: none; }
  .tile { position: relative; border-radius: 3px; overflow: hidden; background: var(--panel); cursor: pointer; }
  .tile.empty { background: repeating-linear-gradient(135deg, #111215 0 6px, #14161a 6px 12px); }
  .tile .n { position: absolute; left: 3px; top: 2px; font: 600 9px Geist; background: rgba(0,0,0,.55); padding: 0 4px; border-radius: 3px; }

  dialog { background: var(--panel); color: var(--ink); border: 1px solid var(--line2); border-radius: 12px; width: min(640px, 90vw); padding: 18px; }
  dialog::backdrop { background: rgba(0,0,0,.6); }
  textarea { width: 100%; height: 300px; background: #000; color: #cfe3ff; font: 11.5px "Geist Mono"; border: 1px solid var(--line); border-radius: 8px; padding: 10px; }
  .kbd { font: 11px "Geist Mono"; color: var(--faint); }
</style>

<header>
  <span class="brand">Lerping@Home: launch edit</span>
  <div class="tabs"><button id="tab-m" class="on">Montage</button><button id="tab-g">Opening grid</button></div>
  <span class="grow"></span>
  <span id="status"></span>
  <button id="reset">Reset</button>
  <button id="export" class="primary">Copy picks.json</button>
</header>

<main>
  <div class="stagewrap">
    <div class="info">
      <span class="title" id="info-title"></span>
      <span class="meta" id="info-meta"></span>
      <span class="grow"></span>
      <button id="split"></button>
      <button id="remove">Remove</button>
    </div>
    <div class="stagebox">
      <div class="frame" id="frame">
        <video id="viewer" muted loop autoplay playsinline></video>
        <div id="stage"></div>
        <div class="board" id="board" hidden></div>
        <div class="hint" id="hint" hidden>Empty. Pick a look from the library →</div>
        <span class="badge-over" id="peek" hidden></span>
      </div>
    </div>
  </div>
  <aside>
    <div class="libhead">
      <div class="row"><h3>Looks</h3><span class="sub" id="libsub"></span></div>
      <input id="filter" placeholder="Search looks">
    </div>
    <div id="library"></div>
  </aside>
</main>

<footer id="footer">
  <div class="tl-top">
    <button id="play" class="primary">▶ Play with music</button>
    <span class="label">Montage</span>
    <span class="meta">16 bars from the drop · cuts land on downbeats · gold dot = drum fill</span>
    <span class="grow"></span>
    <span class="kbd">← → select · ⌫ remove · space play</span>
  </div>
  <div class="tlscroll"><div class="tl" id="tl">
    <div class="phrases"><div>Phrase 1 · 0:07.2</div><div>Phrase 2 · 0:21.7</div></div>
    <div class="ruler" id="ruler"></div>
    <div class="track" id="track"></div>
    <div class="playhead" id="playhead"></div>
  </div></div>
</footer>

<dialog id="dlg"><p id="dlg-msg" style="margin-top:0"></p><textarea id="out" readonly></textarea>
  <div style="text-align:right;margin-top:10px"><button onclick="dlg.close()">Done</button></div></dialog>
<audio id="audio" src="../audio/parallel-jalebi.flac" preload="auto"></audio>

<script>
const LOOKS = __LOOKS__;
const CURRENT = __CURRENT__;
const SPB = 60 / 133, SONG_START = 0.024 + 92 * 4 * SPB, DROP_BEAT = 16;
const $ = id => document.getElementById(id);
const shaderOf = s => s.split('--')[0];
const presetOf = s => (s.split('--')[1] || 'Default').replace(/_/g, ' ');
const pretty = s => s ? `${shaderOf(s)} · ${presetOf(s)}` : 'Empty';
const still = s => `../footage/stills/${s}.jpg`;
const tile = s => `../footage/tiles/${s}.mp4`;
const master = s => `../footage/1080p/${s}.mp4`;
const fmt = t => `${Math.floor(t / 60)}:${(t % 60).toFixed(1).padStart(4, '0')}`;

// ── State
function fromPicks(p) {
  const bars = [];
  for (let i = 0; i < p.montage.length; i++) {
    const s = p.montage[i];
    if (s.beats === 2 && p.montage[i + 1]?.beats === 2) { bars.push([s.look, p.montage[i + 1].look]); i++; }
    else bars.push([s.look]);
  }
  while (bars.length < 16) bars.push([null]);
  const grid = p.grid.slice(0, 36); while (grid.length < 36) grid.push(null);
  return {bars: bars.slice(0, 16), grid};
}
let state = JSON.parse(localStorage.getItem('lerp-edit-v3') || 'null') || fromPicks(CURRENT);
let view = 'm', selM = {kind: 'm', bar: 0, shot: 0}, selG = {kind: 'g', i: 0}, peekLook = null, playing = false;
const sel = () => view === 'm' ? selM : selG;
const setSel = a => { if (a.kind === 'm') selM = a; else selG = a; };
const get = a => a.kind === 'm' ? state.bars[a.bar][a.shot] : state.grid[a.i];
const put = (a, v) => { if (a.kind === 'm') state.bars[a.bar][a.shot] = v; else state.grid[a.i] = v; };
const same = (a, b) => a.kind === b.kind && (a.kind === 'm' ? a.bar === b.bar && a.shot === b.shot : a.i === b.i);
const slots = kind => kind === 'm'
  ? state.bars.flatMap((b, bar) => b.map((_, shot) => ({kind: 'm', bar, shot})))
  : state.grid.map((_, i) => ({kind: 'g', i}));
const indexOf = a => slots(a.kind).findIndex(s => same(s, a));
function timing(a) {
  let beat = 0;
  for (let b = 0; b < a.bar; b++) beat += 4;
  const half = state.bars[a.bar].length === 2;
  beat += half ? a.shot * 2 : 0;
  return {start: (DROP_BEAT + beat) * SPB, beats: half ? 2 : 4};
}

// ── Drag and drop: payload is {look} from the library or {from: slot}.
function droppable(el, a) {
  el.ondragover = e => { e.preventDefault(); el.classList.add('over'); };
  el.ondragleave = () => el.classList.remove('over');
  el.ondrop = e => {
    e.preventDefault(); el.classList.remove('over');
    const d = JSON.parse(e.dataTransfer.getData('text/plain') || '{}');
    if (d.look) put(a, d.look);
    else if (d.from && !same(d.from, a)) { const t = get(a); put(a, get(d.from)); put(d.from, t); }
    setSel(a); render();
  };
  if (get(a)) { el.draggable = true; el.ondragstart = e => e.dataTransfer.setData('text/plain', JSON.stringify({from: a})); }
}

// ── Render
function render() {
  localStorage.setItem('lerp-edit-v3', JSON.stringify(state));
  $('tab-m').classList.toggle('on', view === 'm');
  $('tab-g').classList.toggle('on', view === 'g');
  $('footer').style.display = view === 'm' ? '' : 'none';
  $('board').hidden = view !== 'g';
  renderTimeline(); renderBoard(); renderViewer(); renderBadges(); renderStatus();
}

function renderTimeline() {
  const ruler = $('ruler'), track = $('track');
  ruler.innerHTML = ''; track.innerHTML = '';
  let n = 0;
  state.bars.forEach((bar, b) => {
    const tick = document.createElement('div');
    tick.className = 'tick' + (b % 8 === 0 ? ' phrase' : '');
    tick.innerHTML = `${b + 1}` + (b % 8 === 7 ? '<span class="fl" title="drum fill"></span>' : '');
    ruler.appendChild(tick);
    const cell = document.createElement('div');
    cell.className = 'bar' + (b % 8 === 7 ? ' fill' : '');
    bar.forEach((look, shot) => {
      const a = {kind: 'm', bar: b, shot};
      const el = document.createElement('div');
      el.className = 'clip' + (look ? '' : ' empty') + (same(a, selM) ? ' sel' : '');
      el.title = pretty(look);
      el.innerHTML = (look ? `<img src="${still(look)}">` : '') + `<span class="n">${++n}</span>`;
      el.onclick = () => { selM = a; peekLook = null; render(); };
      droppable(el, a);
      cell.appendChild(el);
    });
    track.appendChild(cell);
  });
}

function renderBoard() {
  const board = $('board'); board.innerHTML = '';
  state.grid.forEach((look, i) => {
    const a = {kind: 'g', i};
    const el = document.createElement('div');
    el.className = 'tile' + (look ? '' : ' empty') + (same(a, selG) ? ' sel' : '');
    el.title = pretty(look);
    el.innerHTML = (look ? `<img src="${still(look)}">` : '') + `<span class="n">${i + 1}</span>`;
    el.onclick = () => { selG = a; render(); };
    droppable(el, a);
    board.appendChild(el);
  });
}

function renderViewer() {
  const a = sel(), look = get(a), v = $('viewer');
  const shown = view === 'm' ? (peekLook || look) : null;
  const want = shown ? (peekLook ? tile(shown) : master(shown)) : '';
  if (!playing) {
    if (v.dataset.src !== want) { v.dataset.src = want; if (want) { v.src = want; v.play(); } else v.removeAttribute('src'); }
    v.style.display = shown ? '' : 'none';
  }
  $('hint').hidden = playing || view !== 'm' || !!shown;
  $('peek').hidden = !peekLook || playing;
  $('peek').textContent = peekLook ? `Preview · click to put in shot ${indexOf(selM) + 1}` : '';

  if (view === 'm') {
    const t = timing(a);
    $('info-title').textContent = `Shot ${indexOf(a) + 1} · ${pretty(look)}`;
    $('info-meta').textContent = `bar ${a.bar + 1}${a.bar % 8 === 7 ? ' (fill)' : ''} · ${fmt(t.start)} · ${t.beats === 4 ? '1 bar' : '½ bar'}`;
    const split = state.bars[a.bar].length === 2;
    $('split').hidden = false;
    $('split').textContent = split ? 'Merge into one shot' : 'Split into two ½-bar shots';
  } else {
    $('info-title').textContent = `Tile ${a.i + 1} · ${pretty(look)}`;
    $('info-meta').textContent = `row ${Math.floor(a.i / 6) + 1}, column ${a.i % 6 + 1} of the opening wall`;
    $('split').hidden = true;
  }
  $('remove').disabled = !look;
}

function renderBadges() {
  const where = {};
  slots('m').forEach((s, i) => { const v = get(s); if (v) (where[v] ||= []).push(`<span>M${i + 1}</span>`); });
  slots('g').forEach((s, i) => { const v = get(s); if (v) (where[v] ||= []).push(`<span class="g">G${i + 1}</span>`); });
  for (const el of document.querySelectorAll('.look')) el.querySelector('.used').innerHTML = (where[el.dataset.look] || []).join('');
}

function renderStatus() {
  const em = slots('m').filter(s => !get(s)).length, eg = slots('g').filter(s => !get(s)).length;
  $('status').className = em || eg ? 'bad' : '';
  $('status').textContent = em || eg ? `${em + eg} empty slot${em + eg > 1 ? 's' : ''}` : 'All slots filled';
}

// ── Library, grouped by shader
function buildLibrary() {
  const lib = $('library'); lib.innerHTML = '';
  const groups = {};
  LOOKS.forEach(l => (groups[shaderOf(l)] ||= []).push(l));
  $('libsub').textContent = `${LOOKS.length} looks · ${Object.keys(groups).length} shaders`;
  for (const [shader, list] of Object.entries(groups)) {
    const g = document.createElement('div'); g.className = 'group'; g.dataset.shader = shader;
    g.innerHTML = `<h4>${shader}<span>${list.length}</span></h4><div class="looks"></div>`;
    for (const look of list) {
      const el = document.createElement('div');
      el.className = 'look'; el.dataset.look = look; el.draggable = true; el.title = pretty(look);
      el.innerHTML = `<div class="thumb"><img src="${still(look)}" loading="lazy"><span class="used"></span></div><div class="cap">${presetOf(look)}</div>`;
      el.ondragstart = e => e.dataTransfer.setData('text/plain', JSON.stringify({look}));
      el.onclick = () => place(look);
      el.onmouseenter = () => { if (view === 'm' && !playing) { peekLook = look; renderViewer(); } };
      el.onmouseleave = () => { if (peekLook === look) { peekLook = null; renderViewer(); } };
      g.querySelector('.looks').appendChild(el);
    }
    lib.appendChild(g);
  }
  lib.ondragover = e => e.preventDefault();
  lib.ondrop = e => { const d = JSON.parse(e.dataTransfer.getData('text/plain') || '{}'); if (d.from) { put(d.from, null); render(); } };
}
function place(look) {
  const a = sel(); put(a, look); peekLook = null;
  const list = slots(a.kind), at = list.findIndex(s => same(s, a));
  const next = [...list.slice(at + 1), ...list.slice(0, at)].find(s => !get(s));
  if (next) setSel(next);
  render();
}
$('filter').oninput = e => {
  const q = e.target.value.toLowerCase().replace(/\s+/g, '');
  for (const g of document.querySelectorAll('.group')) {
    let any = false;
    for (const el of g.querySelectorAll('.look')) {
      const hit = el.dataset.look.toLowerCase().replace(/[_-]/g, '').includes(q.replace(/[_-]/g, ''));
      el.style.display = hit ? '' : 'none'; any ||= hit;
    }
    g.style.display = any ? '' : 'none';
  }
};

// ── Commands
$('tab-m').onclick = () => { stop(); view = 'm'; render(); };
$('tab-g').onclick = () => { stop(); view = 'g'; render(); };
$('remove').onclick = () => { put(sel(), null); render(); };
$('split').onclick = () => {
  const b = selM.bar, bar = state.bars[b];
  state.bars[b] = bar.length === 2 ? [bar[0] ?? bar[1]] : [bar[0], null];
  selM = {kind: 'm', bar: b, shot: bar.length === 2 ? 0 : 1}; render();
};
$('reset').onclick = () => { stop(); state = fromPicks(CURRENT); selM = {kind: 'm', bar: 0, shot: 0}; selG = {kind: 'g', i: 0}; render(); };
function picks() {
  return {...CURRENT, grid: state.grid,
    montage: state.bars.flatMap(b => b.length === 1 ? [{look: b[0], beats: 4}] : b.map(look => ({look, beats: 2})))};
}
$('export').onclick = () => {
  const p = picks(), empty = p.montage.filter(s => !s.look).length + p.grid.filter(g => !g).length;
  const text = JSON.stringify(p, null, 2);
  navigator.clipboard?.writeText(text).catch(() => {});
  $('dlg-msg').textContent = empty ? `Copied, but ${empty} slot${empty > 1 ? 's are' : ' is'} still empty. Fill them before rendering.`
                                   : 'Copied to the clipboard. Paste it to Claude to render.';
  $('out').value = text; dlg.showModal();
};
document.addEventListener('keydown', e => {
  if (e.target.tagName === 'INPUT' || dlg.open) return;
  const list = slots(view), at = indexOf(sel());
  if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
    e.preventDefault(); setSel(list[(at + (e.key === 'ArrowRight' ? 1 : -1) + list.length) % list.length]); render();
  } else if (e.key === 'Backspace' || e.key === 'Delete') { put(sel(), null); render(); }
  else if (e.key === ' ' && view === 'm') { e.preventDefault(); playing ? stop() : play(); }
  else if (e.key === 'Escape') stop();
});

// ── Play: the montage in the viewer, cut on the real beats, playhead on the timeline.
const audio = $('audio');
let schedule = [], raf = 0;
function play() {
  playing = true; peekLook = null;
  $('play').textContent = '■ Stop';
  $('viewer').style.display = 'none';
  const stage = $('stage'); stage.innerHTML = '';
  schedule = []; let beat = 0;
  state.bars.forEach((b, bar) => b.forEach((look, shot) => {
    const beats = b.length === 1 ? 4 : 2;
    const v = document.createElement('video');
    Object.assign(v, {muted: true, playsInline: true, preload: 'auto'});
    if (look) v.src = tile(look);
    stage.appendChild(v);
    schedule.push({a: {kind: 'm', bar, shot}, start: beat, end: beat + beats, v});
    beat += beats;
  }));
  audio.currentTime = SONG_START + (DROP_BEAT - 2) * SPB;
  audio.play();
  $('playhead').style.display = 'block';
  let cur = -1;
  const tick = () => {
    const b = (audio.currentTime - SONG_START) / SPB - DROP_BEAT;
    $('playhead').style.left = `${Math.max(0, Math.min(1, b / 64)) * 100}%`;
    const i = schedule.findIndex(s => b >= s.start && b < s.end);
    if (i !== cur && i >= 0) {
      schedule.forEach(s => s.v.classList.remove('on'));
      const s = schedule[i];
      s.v.currentTime = 0; s.v.playbackRate = 1.5; s.v.play(); s.v.classList.add('on');
      selM = s.a; renderTimeline(); renderViewer();
      cur = i;
    }
    if (b > 66) return stop();
    raf = requestAnimationFrame(tick);
  };
  raf = requestAnimationFrame(tick);
}
function stop() {
  if (!playing) return;
  playing = false; cancelAnimationFrame(raf); audio.pause();
  $('play').textContent = '▶ Play with music';
  $('stage').innerHTML = ''; $('playhead').style.display = 'none';
  $('viewer').dataset.src = ''; render();
}
$('play').onclick = () => playing ? stop() : play();

if (location.hash === '#grid') view = 'g';
buildLibrary();
render();
</script>
"""
html = html.replace("__LOOKS__", json.dumps(looks)).replace("__CURRENT__", json.dumps(current))
(root / "curation/index.html").write_text(html)
print(f"wrote curation/index.html: {len(looks)} looks")
