import { reference } from "./records.js";

const freshHeaders = {
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
};
export function headers({ privateLink = false, cors = false } = {}) {
  const h = new Headers(freshHeaders);
  if (privateLink) h.set("X-Robots-Tag", "noindex, nofollow");
  if (cors) h.set("Access-Control-Allow-Origin", "*");
  return h;
}
export function json(value, status = 200, options) {
  const h = headers(options);
  h.set("Content-Type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(value), { status, headers: h });
}

async function site(env, path) {
  // Static asset binding requests do not re-enter the Worker router.
  if (!env.SITE) return null;
  const res = await env.SITE.fetch(new Request(`https://lerping.app${path}`));
  return res.ok ? res : null;
}
export async function getEdition(env) {
  const res = await site(env, "/lerp-web/editorial.json");
  return res ? res.json() : { edition: "01", entries: [], shelves: [] };
}
async function stockBlocked(db, entry) {
  return Boolean(await db.prepare("SELECT 1 FROM revocations WHERE target IN (?, ?) LIMIT 1")
    .bind(`${entry.record.kind}:sha256:${entry.id}`, entry.record.source || "").first());
}
export async function visibleEdition(ctx) {
  const data = await getEdition(ctx.env);
  const blocked = await ctx.db.prepare(`SELECT target FROM revocations UNION
    SELECT kind || ':sha256:' || a.id AS target FROM artifacts a WHERE a.id NOT IN (SELECT id FROM public_artifacts)`).all();
  const keys = new Set(blocked.results.map((row) => row.target));
  const entries = data.entries.filter((entry) => !keys.has(`${entry.record.kind}:sha256:${entry.id}`) && !keys.has(entry.record.source));
  return { ...data, entries: entries.map(({ video, ...entry }) => entry) };
}

export async function lookup(ctx, target, { allowStock = true } = {}) {
  // Resolve public state, existence, and withdrawal in the same primary query.
  const row = await ctx.db.prepare(`SELECT a.*, r.canonical_json, s.name, s.bio, s.url,
    p.id IS NOT NULL AS public, w.id IS NOT NULL OR EXISTS(SELECT 1 FROM revocations WHERE target = ?) AS withdrawn
    FROM (SELECT 1) AS anchor
    LEFT JOIN artifacts a ON a.id = ? AND a.kind = ?
    LEFT JOIN revisions r ON r.id = a.id LEFT JOIN artists s ON s.id = a.artist_id
    LEFT JOIN public_artifacts p ON p.id = a.id LEFT JOIN withdrawn_artifacts w ON w.id = a.id`)
    .bind(target.value, target.id, target.kind).first();
  if (row.withdrawn) return { status: 410 };
  if (row.id) return row.public && row.canonical_json ? { status: 200, row } : { status: 404 };
  if (allowStock && ctx.env.SITE) {
    const data = await getEdition(ctx.env);
    const stock = data.entries.find((entry) => entry.id === target.id && entry.record.kind === target.kind);
    if (stock) return await stockBlocked(ctx.db, stock) ? { status: 410 } : { status: 200, stock };
  }
  return { status: 404 };
}

const artist = (row) => ({ name: row.name, bio: row.bio, url: row.url });
const credit = (row) => ({ kind: row.kind, id: row.id, title: row.title, artist: artist(row) });
export async function postcard(ctx, record, result) {
  if (result.stock) return result.stock;
  const { row } = result;
  const { results: credits } = await ctx.db.prepare(`WITH RECURSIVE trail(id, hop) AS (
    SELECT target_id, 1 FROM lineage WHERE artifact_id = ? AND relation = 'remix_of'
    UNION ALL SELECT e.target_id, t.hop + 1 FROM trail t JOIN lineage e ON e.artifact_id = t.id
    WHERE e.relation = 'remix_of' AND t.hop < 16
  ) SELECT a.kind, a.id, a.title, r.canonical_json, s.name, s.bio, s.url FROM trail t
    JOIN public_artifacts a ON a.id = t.id JOIN artists s ON s.id = a.artist_id JOIN revisions r ON r.id = a.id ORDER BY t.hop`)
    .bind(row.id).all();
  const media = await ctx.db.prepare(`WITH RECURSIVE artwork(id, branch, hop) AS (
    SELECT ?, '', 0
    UNION ALL SELECT e.target_id, artwork.branch || '/' || printf('%03d', e.position), hop + 1
    FROM artwork JOIN lineage e ON e.artifact_id = artwork.id WHERE hop < 16 AND
      (e.relation = 'remix_of' OR NOT EXISTS (SELECT 1 FROM lineage r WHERE r.artifact_id = artwork.id AND r.relation = 'remix_of'))
  ) SELECT s.sha256 AS still, v.sha256 AS video, v.content_type AS video_type, a.tags
    FROM artwork JOIN public_artifacts a ON a.id = artwork.id
    JOIN revision_blobs s ON s.artifact_id = artwork.id AND s.role = 'still'
    LEFT JOIN revision_blobs v ON v.artifact_id = artwork.id AND v.role = 'video'
    ORDER BY branch LIMIT 1`).bind(row.id).first();
  let members;
  if (record.kind === "playlist") {
    const ordered = await ctx.db.prepare(`SELECT a.kind, a.id, a.title, s.name, s.bio, s.url FROM lineage l
      JOIN public_artifacts a ON a.id = l.target_id JOIN artists s ON s.id = a.artist_id
      WHERE l.artifact_id = ? AND l.relation = 'contains' ORDER BY l.position`).bind(row.id).all();
    members = ordered.results.map(credit);
  }
  return {
    ...credit(row), record, description: row.description,
    tags: { ...JSON.parse(media?.tags || "{}"), ...JSON.parse(row.tags) }, lineage: credits.map(credit), members,
    license: record.license || credits.map((c) => JSON.parse(c.canonical_json).license).find(Boolean),
    still: media?.still ? `/api/v1/blobs/${media.still}` : null,
    video: media?.video ? { url: `/api/v1/blobs/${media.video}`, type: media.video_type } : null,
  };
}

export const escapeHTML = (text) => String(text ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const e = escapeHTML;
const route = (record) => `/p/v1/${record.kind}/${record.id}`;
function placard(entry) {
  const { record, title, description, artist: author, lineage = [], tags = {}, license } = entry;
  const preview = /^\/api\/v1\/blobs\/[0-9a-f]{64}$|^data:image\/webp;base64,[A-Za-z0-9+/=]+$/.test(entry.still ?? "")
    ? `<img class="image" src="${e(entry.still)}" alt="Still from ${e(title)}">` : "";
  const credits = lineage.map((p) => `<p class="muted">Remixed from ${p.id ? `<a href="${e(route(p))}">${e(p.title)}</a>` : e(p.title)} by ${e(p.artist.name)}</p>`).join("");
  const members = entry.members?.map((p) => `<li><a href="${e(route(p))}">${e(p.title)}</a></li>`).join("");
  return `<nav class="breadcrumb" aria-label="Collection"><a href="/">← All postcards</a></nav>
    <article class="postcard"><div class="stage">${preview}</div><div class="placard">
    <p class="label">${e(record.kind)} / Postcard</p><h1>${e(title)}</h1><p>By ${e(author.name)}</p>
    ${description ? `<p>${e(description)}</p>` : ""}${credits}${members ? `<ol>${members}</ol>` : ""}
    ${license ? `<p class="muted">License: ${e(license)}</p>` : ""}
    <ul class="tags" aria-label="Postcard tags">${Object.values(tags).map((tag) => `<li>${e(tag)}</li>`).join("")}</ul>
    <div class="actions"><a class="button primary" href="lerp://open/v1/${record.kind}/${entry.id}">Open in Lerping</a></div>
    <p class="secondary"><a href="https://github.com/codyhxyz/lerping-at-home/releases/latest">Download for Mac</a></p>
    </div></article>`;
}
export async function page(env, { entry, status = 200, privateLink = false } = {}) {
  const h = headers({ privateLink });
  h.set("Content-Type", "text/html; charset=utf-8");
  h.set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; media-src 'self' data:; " +
    "connect-src 'self' https://raw.githubusercontent.com; style-src 'unsafe-inline'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'");
  const title = entry ? `${entry.title} — Lerping@Home` : status !== 200 ? "Postcard unavailable — Lerping@Home" : "Lerping@Home — Works for idle screens";
  const main = entry ? placard(entry) : status !== 200
    ? `<p><a href="/">← All postcards</a></p><h1>Postcard unavailable</h1><p>${status === 410 ? "This work has been withdrawn." : "There’s no postcard at this address."}</p>` : null;
  const template = await site(env, "/index.html");
  const robots = privateLink ? '<meta name="robots" content="noindex, nofollow">' : "";
  let html;
  if (!template) html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${e(title)}</title>${robots}</head><body><main>${main ?? ""}</main></body></html>`;
  else {
    html = (await template.text()).replace('<html lang="en">', '<html lang="en" data-platform="true">')
      .replace(/<title>[^<]*<\/title>/, () => `<title>${e(title)}</title>${robots}<base href="/">`);
    if (main) html = html.replace(/<!-- main:start -->[\s\S]*?<!-- main:end -->/, () => main);
  }
  return new Response(html, { headers: h, status });
}

export function artifactResponse(record, canonical, privateLink) {
  const h = headers({ privateLink, cors: true });
  h.set("Content-Type", "application/json; charset=utf-8");
  return new Response(canonical ?? JSON.stringify(record), { headers: h });
}

export function stockTarget(kind, id) { return reference(`${kind}:sha256:${id}`); }
