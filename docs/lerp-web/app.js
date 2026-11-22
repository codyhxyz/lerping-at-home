import { defaultParamValues, detectPreviewCapability, playShader, transpile } from "./engine.js";

const MAIN = document.querySelector("main");
const HOME = new URL("../", import.meta.url);
const PLATFORM = "https://lerping.app";
const hosted = location.origin === PLATFORM || document.documentElement.dataset.platform === "true";
const API = hosted ? location.origin : PLATFORM;
const ROUTE = /^\/p\/v1\/(piece|look|playlist)\/([0-9a-f]{64})$/;
const kinds = { piece: "Piece", look: "Look", playlist: "Playlist" };
const reduced = matchMedia("(prefers-reduced-motion: reduce)");
const artistPanel = document.querySelector("#artist-panel");
const reportPanel = document.querySelector("#report-panel");
const install = document.querySelector("#install");
const filters = { mood: "", motion: "", brightness: "", medium: "" };
let editorial, navigation, player, installTimer;

document.querySelector("#home").href = HOME.href;

function el(tag, text, className) {
  const node = document.createElement(tag);
  if (text != null) node.textContent = text;
  if (className) node.className = className;
  return node;
}
function link(text, href, className) {
  const node = el("a", text, className);
  node.href = href;
  return node;
}
function button(text, onClick, className) {
  const node = el("button", text, className);
  node.type = "button";
  node.addEventListener("click", onClick);
  return node;
}
function pathFor(kind, id) { return `/p/v1/${kind}/${id}`; }
function postcardLink(kind, id) { return hosted ? pathFor(kind, id) : `${HOME.href}#${pathFor(kind, id)}`; }
function artifactPath(kind, id) { return `/api/v1/artifacts/${kind}/${id}`; }
function kindOf(entry) { return entry.record.kind; }
function httpsURL(value) {
  try { const url = new URL(value); return url.protocol === "https:" ? url.href : null; }
  catch { return null; }
}
function assetURL(value, medium) {
  if (typeof value !== "string") return null;
  if (/^\/api\/v1\/blobs\/[0-9a-f]{64}$/.test(value)) return API + value;
  if (medium === "image" && /^data:image\/webp;base64,/.test(value)) return value;
  if (medium === "video" && /^data:video\/mp4;base64,/.test(value)) return value;
  return null;
}
function image(entry, eager = false) {
  const src = assetURL(entry.still, "image");
  if (!src) {
    const blank = el("div", "", "image");
    blank.setAttribute("aria-hidden", "true");
    return blank;
  }
  const img = el("img", null, "image");
  img.alt = `Still from ${entry.title}`;
  if (!eager) img.loading = "lazy";
  img.src = src;
  return img;
}
async function fetchJSON(url, signal) {
  const res = await fetch(url, { signal, cache: "no-store", headers: { Accept: "application/json" } });
  if (!res.ok) throw Object.assign(new Error("Couldn't load this postcard."), { status: res.status });
  return res.json();
}
function collection() {
  // The platform filters revoked records before returning a collection. Static
  // GitHub Pages builds are a snapshot; they don't serve community assets.
  return editorial ??= fetchJSON(hosted ? `${API}/api/v1/editorial` : new URL("editorial.json", import.meta.url))
    .catch((error) => { editorial = null; throw error; });
}
function stopPlayer(message) {
  if (!player) return;
  const old = player;
  player = null;
  old.abort.abort();
  old.dispose?.();
  old.stage.querySelector(".image")?.removeAttribute("aria-hidden");
  old.controls.hidden = true;
  old.play.textContent = "Play";
  old.status.textContent = message || "Preview paused. Showing the still.";
}
function closeOverlays() {
  clearTimeout(installTimer);
  artistPanel.close();
  reportPanel.close();
  install.hidePopover?.();
}
function artistButton(artist) {
  return button(artist.name, () => {
    const title = el("h2", artist.name);
    title.id = "artist-title";
    const close = button("Close", () => artistPanel.close(), "sheet-close");
    artistPanel.replaceChildren(close, el("p", "Artist profile", "label"), title);
    if (artist.bio) artistPanel.append(el("p", artist.bio));
    const url = httpsURL(artist.url);
    if (url) artistPanel.append(link("Visit artist’s website ↗", url));
    artistPanel.showModal();
  }, "quiet");
}
function reportButton(entry) {
  const path = pathFor(kindOf(entry), entry.id);
  if (!hosted) return link("Report", `${PLATFORM}${path}#report`);
  return button("Report", () => showReport(entry), "quiet");
}
function showReport(entry) {
  const title = el("h2", "Report this postcard");
  title.id = "report-title";
  const form = el("form");
  const input = el("textarea");
  input.name = "reason";
  input.required = true;
  input.maxLength = 1200;
  input.rows = 4;
  const label = el("label", "What should we look into?");
  label.append(input);
  const submit = el("button", "Send report");
  const status = el("p", "", "status");
  status.setAttribute("role", "status");
  reportPanel.replaceChildren(button("Close", () => reportPanel.close(), "sheet-close"), title, form);
  form.append(label, submit, status);
  form.onsubmit = async (event) => {
    event.preventDefault();
    submit.disabled = true;
    try {
      const res = await fetch(`${API}/api/v1/reports`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ target: `${kindOf(entry)}:sha256:${entry.id}`, reason: input.value }),
      });
      if (!res.ok) throw new Error();
      status.textContent = "Thank you. The report was sent to the editors.";
      input.disabled = true;
    } catch {
      status.textContent = "We couldn't send your report. Please try again later.";
      submit.disabled = false;
    }
  };
  if (!reportPanel.open) reportPanel.showModal();
}

function renderCollection({ entries, shelves, edition, feature }) {
  document.title = "Lerping@Home — Works for idle screens";
  const items = new Map(entries.map((entry) => [entry.slug, entry]));
  const front = el("section", null, "feature");
  const intro = el("div");
  intro.append(el("p", `Postcard collection / ${edition}`, "label"), el("h1", "Works for idle screens."),
    el("p", "A small exhibition of light, texture, and places. Look first; play when you’re ready.", "intro"));
  front.append(intro);
  if (items.has(feature)) front.append(card(items.get(feature), true));
  const controls = el("div", null, "filters");
  controls.setAttribute("role", "group");
  controls.setAttribute("aria-label", "Filter the collection");
  const options = {
    mood: [...new Set(entries.map((entry) => entry.tags.mood))].sort(),
    motion: ["still", "slow", "moderate", "brisk"], brightness: ["dim", "balanced", "bright"],
    medium: ["procedural", "simulation", "splat"],
  };
  const gallery = el("div");
  const count = el("p", "", "status");
  count.setAttribute("role", "status");
  for (const key of Object.keys(filters)) {
    const select = el("select");
    for (const value of ["", ...options[key]]) {
      const option = el("option", value ? value[0].toUpperCase() + value.slice(1) : "All");
      option.value = value;
      select.append(option);
    }
    select.value = filters[key];
    select.addEventListener("change", () => { filters[key] = select.value; renderShelves(); });
    const label = el("label");
    label.append(el("span", key, "label"), select);
    controls.append(label);
  }
  function renderShelves() {
    const shown = new Set();
    gallery.replaceChildren();
    for (const shelf of shelves) {
      const visible = shelf.entries.map((slug) => items.get(slug)).filter((entry) => entry &&
        Object.entries(filters).every(([key, value]) => !value || value === entry.tags[key]));
      if (!visible.length) continue;
      const section = el("section", null, "shelf");
      const header = el("div", null, "shelf-header");
      header.append(el("h2", shelf.name), el("p", shelf.note, "muted"));
      if (shelf.artist) header.append(artistButton(shelf.artist));
      const cards = el("div", null, "cards");
      for (const entry of visible) { cards.append(card(entry)); shown.add(entry.id); }
      section.append(header, cards);
      gallery.append(section);
    }
    count.textContent = shown.size ? `${shown.size} ${shown.size === 1 ? "work" : "works"} on view` : "No works match these filters.";
  }
  MAIN.replaceChildren(front, controls, count, gallery);
  renderShelves();
}
function card(entry, feature = false) {
  const figure = el("figure");
  const caption = el("figcaption");
  caption.append(el("strong", entry.title), el("span", feature ? "Featured postcard ↗" : entry.tags.medium));
  figure.append(image(entry, feature), caption);
  const node = link(null, postcardLink(kindOf(entry), entry.id), "card");
  node.append(figure);
  return node;
}

async function runPreview(entry, view) {
  if (player) { stopPlayer(); return; }
  if (document.hidden || reduced.matches) return;
  const session = { ...view, abort: new AbortController() };
  const signal = session.abort.signal;
  player = session;
  session.play.textContent = "Pause";
  session.status.textContent = "Preparing preview…";
  let canvas, video;
  try {
    // Recheck visibility before Play so a postcard open during a withdrawal
    // cannot start a fresh preview. Blob requests check the same state.
    if (hosted || !entry.slug) await fetchJSON(`${API}${artifactPath(kindOf(entry), entry.id)}`, signal);
    let shader;
    if (entry.webShader) {
      try {
        const url = new URL(entry.webShader.url);
        const hash = entry.record.source.split(":").at(-1);
        if (url.origin !== "https://raw.githubusercontent.com") throw new Error();
        const res = await fetch(url, { signal });
        if (!res.ok) throw new Error();
        const bytes = await res.arrayBuffer();
        const digest = await crypto.subtle.digest("SHA-256", bytes);
        if (Array.from(new Uint8Array(digest), (value) => value.toString(16).padStart(2, "0")).join("") !== hash) throw new Error();
        const converted = transpile(new TextDecoder().decode(bytes));
        if (!converted.dataProvider) shader = converted;
      } catch (error) { if (signal.aborted) throw error; }
    }
    if (signal.aborted) return;
    const videoSrc = assetURL(entry.video?.url, "video");
    if (videoSrc) {
      video = el("video", null, "surface");
      video.muted = true;
      video.playsInline = true;
      video.loop = true;
      video.setAttribute("aria-label", `Preview of ${entry.title}`);
    }
    if (shader) {
      canvas = el("canvas", null, "surface");
      canvas.setAttribute("aria-label", `Live preview of ${entry.title}`);
    }
    let cap = detectPreviewCapability({ canvas, shader, video, videoType: entry.video?.type, motionAllowed: true });
    if (cap.mode === "webgl2") {
      try {
        const values = defaultParamValues(shader.params);
        session.stage.append(canvas);
        session.dispose = playShader(canvas, cap.gl, shader, values, entry.webShader,
          () => stopPlayer("Live preview ended. Showing the still."));
        buildParameters(session.controls, shader.params, values);
        session.controls.hidden = !shader.params.length;
        session.stage.querySelector(".image")?.setAttribute("aria-hidden", "true");
        session.status.textContent = "Live WebGL2 preview · 30 fps max";
        return;
      } catch {
        // playShader has released the context. Try a clip if one exists.
        session.dispose?.();
        session.dispose = undefined;
        cap = detectPreviewCapability({ video, videoType: entry.video?.type, motionAllowed: true });
      }
    }
    if (cap.mode === "video") {
      session.dispose = () => { video.pause(); video.removeAttribute("src"); video.load(); video.remove(); };
      video.addEventListener("error", () => { if (player === session) stopPlayer("Video unavailable. Showing the still."); });
      video.addEventListener("loadedmetadata", () => {
        if (player === session && video.videoWidth * video.videoHeight > 1_000_000) {
          stopPlayer("The preview is too large. Showing the still.");
        }
      });
      video.src = videoSrc;
      session.stage.append(video);
      await video.play();
      if (!signal.aborted) {
        session.stage.querySelector(".image")?.setAttribute("aria-hidden", "true");
        session.status.textContent = "Recorded preview";
      }
      return;
    }
    stopPlayer("No moving preview is available on this device. Showing the still.");
  } catch (error) {
    if (signal.aborted) return;
    stopPlayer("Preview unavailable. Showing the still.");
    if (error.status === 404 || error.status === 410) renderUnavailable(error.status);
  }
}

function buildParameters(wrapper, params, values) {
  wrapper.replaceChildren(el("summary", "Preview settings"));
  const fields = el("div");
  const reset = button("Reset settings", () => {
    Object.assign(values, defaultParamValues(params));
    buildParameters(wrapper, params, values);
    wrapper.querySelector("button").focus();
  });
  wrapper.append(fields, reset);
  for (const p of params) {
    const field = el("div", null, "parameter");
    fields.append(field);
    const control = (text, type, value, onInput) => {
      const label = el("label", text);
      const input = el("input");
      input.type = type;
      if (type === "checkbox") input.checked = Boolean(value);
      else if (type !== "range") input.value = value;
      input.addEventListener("input", () => onInput(input));
      label.append(input);
      field.append(label);
      return input;
    };
    if (p.type === "bool") control(p.label, "checkbox", values[p.name], (x) => { values[p.name] = Number(x.checked); });
    else if (p.type === "color") {
      const rgb = values[p.name].slice(0, 3).map((x) => Math.round(Math.max(0, Math.min(1, x)) * 255).toString(16).padStart(2, "0"));
      control(p.label, "color", `#${rgb.join("")}`, (x) => {
        for (let i = 0; i < 3; i++) values[p.name][i] = parseInt(x.value.slice(1 + i * 2, 3 + i * 2), 16) / 255;
      });
      const alpha = control(`${p.label} opacity`, "range", null, (x) => { values[p.name][3] = x.valueAsNumber; });
      Object.assign(alpha, { min: 0, max: 1, step: 0.01, value: values[p.name][3] });
    } else {
      const value = el("output", String(values[p.name]));
      const slider = control(p.label, "range", null, (x) => {
        values[p.name] = x.valueAsNumber;
        value.textContent = String(Number(x.valueAsNumber.toFixed(3)));
      });
      Object.assign(slider, { min: p.min, max: p.max, step: p.type === "int" ? 1 : ((p.max - p.min) / 200 || "any"), value: values[p.name] });
      field.append(value);
    }
  }
}

function renderPostcard(entry) {
  const kind = kindOf(entry);
  document.title = `${entry.title} — Lerping@Home`;
  const back = el("nav", null, "breadcrumb");
  back.setAttribute("aria-label", "Collection");
  back.append(link("← All postcards", HOME.href));
  const postcard = el("article", null, "postcard");
  const preview = el("div");
  const stage = el("div", null, "stage");
  stage.append(image(entry, true));
  const status = el("p", "", "status");
  status.setAttribute("role", "status");
  preview.append(stage, status);
  const placard = el("div", null, "placard");
  const artistLine = el("p", "By ");
  artistLine.append(artistButton(entry.artist));
  placard.append(el("p", `${kinds[kind]} / Postcard`, "label"), el("h1", entry.title), artistLine);
  if (entry.description) placard.append(el("p", entry.description));
  for (const parent of entry.lineage ?? []) {
    const credit = el("p", "Remixed from ", "muted");
    credit.append(parent.kind && parent.id ? link(parent.title, postcardLink(parent.kind, parent.id)) : document.createTextNode(parent.title),
      document.createTextNode(" by "), artistButton(parent.artist));
    placard.append(credit);
  }
  if (entry.members?.length) {
    const list = el("ol");
    for (const member of entry.members) {
      const item = el("li");
      item.append(link(member.title, postcardLink(member.kind, member.id)));
      list.append(item);
    }
    placard.append(list);
  }
  if (entry.license) placard.append(el("p", `License: ${entry.license}`, "muted"));
  const tags = el("ul", null, "tags");
  tags.setAttribute("aria-label", "Postcard tags");
  for (const key of ["mood", "motion", "brightness", "medium"]) if (entry.tags?.[key]) tags.append(el("li", entry.tags[key]));
  placard.append(tags);
  const controls = el("details", null, "parameters");
  controls.hidden = true;
  const play = button("Play", () => runPreview(entry, { stage, play, status, controls }));
  const motionPossible = Boolean(entry.webShader || entry.video);
  const syncMotion = () => {
    if (reduced.matches && player) stopPlayer("Reduced motion is on. Showing the still.");
    play.disabled = reduced.matches || !motionPossible;
    if (play.disabled) status.textContent = reduced.matches ? "Reduced motion is on. Showing the still." : "Still preview · open in Lerping to view the work.";
    else if (!player) status.textContent = "Still preview";
  };
  reduced.addEventListener("change", syncMotion, { signal: navigation.signal });
  syncMotion();
  const open = link("Open in Lerping", `lerp://open/v1/${kind}/${entry.id}`, "button primary");
  const help = button("Need the Mac app?", () => install.showPopover(), "quiet");
  open.addEventListener("click", () => {
    clearTimeout(installTimer);
    installTimer = setTimeout(() => { if (!document.hidden && document.hasFocus()) install.showPopover?.(); }, 1300);
  });
  const actions = el("div", null, "actions");
  actions.append(play, open);
  const secondary = el("div", null, "secondary");
  secondary.append(install.showPopover ? help : link("Download for Mac", "https://github.com/codyhxyz/lerping-at-home/releases/latest"), reportButton(entry));
  placard.append(actions, secondary, controls);
  postcard.append(preview, placard);
  MAIN.replaceChildren(back, postcard);
  if (hosted && location.hash === "#report") showReport(entry);
}

function renderUnavailable(status) {
  document.title = "Postcard unavailable — Lerping@Home";
  MAIN.replaceChildren(link("← All postcards", HOME.href), el("h1", "Postcard unavailable"),
    el("p", status === 410 ? "This work has been withdrawn." : status === 404 ? "There’s no postcard at this address." : "The collection could not be reached. Please try again.", "muted"));
}
async function navigate(focus = false) {
  stopPlayer();
  closeOverlays();
  navigation?.abort();
  const nav = navigation = new AbortController();
  const route = location.hash.startsWith("#/p/") ? location.hash.slice(1) : location.pathname;
  const parsed = route.match(ROUTE);
  try {
    if (parsed) {
      const [, kind, id] = parsed;
      let entry = !hosted ? (await collection().catch(() => null))?.entries
        .find((x) => x.record.kind === kind && x.id === id) : null;
      entry ??= await fetchJSON(`${API}${artifactPath(kind, id)}?view=postcard`, nav.signal);
      if (!nav.signal.aborted) renderPostcard(entry);
    } else if (route.startsWith("/p/")) renderUnavailable(404);
    else {
      const data = hosted ? await fetchJSON(`${API}/api/v1/editorial`, nav.signal) : await collection();
      if (!nav.signal.aborted) renderCollection(data);
    }
  } catch (error) {
    if (!nav.signal.aborted) renderUnavailable(error.status);
  }
  if (focus && !nav.signal.aborted) { window.scrollTo(0, 0); MAIN.focus({ preventScroll: true }); }
}
window.addEventListener("hashchange", () => navigate(true));
window.addEventListener("pagehide", () => { stopPlayer(); closeOverlays(); });
document.addEventListener("visibilitychange", () => {
  if (document.hidden) { clearTimeout(installTimer); stopPlayer(); }
});
navigate();
