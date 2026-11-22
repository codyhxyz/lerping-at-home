import { canonicalJSON, sha256 } from "./canonical.js";
import { isAdmin, verifiedEmail } from "./auth.js";
import { HTTPError, check, object, prepareUpload, reference, requestJSON, text, validateParameters, validateRecord } from "./records.js";
import { artifactResponse, headers, json, lookup, page, postcard, stockTarget, visibleEdition } from "./postcards.js";

const POSTCARD = /^\/p\/v1\/(piece|look|playlist)\/([0-9a-f]{64})$/;
const ARTIFACT = /^\/api\/v1\/artifacts\/(piece|look|playlist)\/([0-9a-f]{64})$/;
const BLOB = /^\/api\/v1\/blobs\/([0-9a-f]{64})$/;
const RECEIPT = /^\/api\/v1\/receipts\/([0-9a-f]{64})$/;
const TAGS = { motion: ["still", "slow", "moderate", "brisk"], brightness: ["dim", "balanced", "bright"], medium: ["procedural", "simulation", "splat"] };
const PRIVATE = { privateLink: true };
const PUBLIC_ERROR = { privateLink: true, cors: true };

async function rate(binding, key) {
  if (binding) check((await binding.limit({ key })).success, "Please wait and try again", 429);
}

async function artistFor(db, email, data) {
  const existing = await db.prepare("SELECT id FROM artists WHERE verified_email = ?").bind(email).first();
  if (existing) return existing.id;
  check(object(data, ["name", "bio", "url"]) && text(data.name, 120), "First publication needs an artist name");
  check(data.bio === undefined || text(data.bio, 600), "Invalid artist bio");
  let url = null;
  if (data.url !== undefined) {
    try {
      check(text(data.url, 400), "Invalid artist URL");
      const parsed = new URL(data.url);
      check(parsed.protocol === "https:" && !parsed.username && !parsed.password, "Artist URL must be HTTPS");
      url = parsed.href;
    } catch { throw new HTTPError(400, "Invalid artist URL"); }
  }
  const artist = await db.prepare(`INSERT INTO artists (id, verified_email, name, bio, url)
    VALUES (?, ?, ?, ?, ?) ON CONFLICT(verified_email) DO UPDATE SET verified_email = excluded.verified_email RETURNING id`)
    .bind(crypto.randomUUID(), email, data.name, data.bio ?? null, url).first();
  return artist.id;
}

function validPostcard(meta) {
  check(object(meta, ["description", "tags", "still", "video"]), "Invalid postcard metadata");
  check(meta.description === undefined || text(meta.description, 1000), "Invalid description");
  const tags = meta.tags ?? {};
  check(object(tags, ["mood", ...Object.keys(TAGS)]), "Invalid tags");
  for (const [key, value] of Object.entries(tags)) {
    check(key === "mood" ? text(value, 50) : TAGS[key].includes(value), `Invalid ${key} tag`);
  }
  return tags;
}

async function publicDependency(ctx, ref) {
  const target = reference(ref);
  const result = await lookup(ctx, target, { allowStock: false });
  check(result.status === 200, "Referenced work must be approved and available", 422);
  return result.row;
}

async function draftEdges(ctx, record) {
  const edges = [];
  if (record.kind === "playlist") {
    // A single query also checks the exact kind and all author-specified
    // dependencies under one snapshot. Preserve authored order in the edges.
    const ids = record.looks.map((ref) => reference(ref).id);
    const { results } = await ctx.db.prepare(`SELECT id FROM public_artifacts WHERE kind = 'look' AND id IN (SELECT value FROM json_each(?))`)
      .bind(JSON.stringify(ids)).all();
    check(results.length === ids.length, "All playlist looks must be approved and available", 422);
    return ids.map((id, i) => [id, "contains", i]);
  }
  if (record.kind === "look") {
    const piece = await publicDependency(ctx, record.piece);
    check(piece.remix_enabled === 1, "This Piece does not allow remixes", 403);
    const source = reference(JSON.parse(piece.canonical_json).source, ["blob"]).id;
    const blob = await ctx.env.MEDIA.get(source);
    check(blob && blob.size <= 512 * 1024, "Piece source unavailable", 422);
    validateParameters(record, await blob.text());
    const remix = record.remixedFrom || record.piece;
    if (remix !== record.piece) {
      const parent = await publicDependency(ctx, remix);
      check(parent.kind === "look" && JSON.parse(parent.canonical_json).piece === record.piece, "Remix lineage must name the same Piece", 422);
      const chain = await ctx.db.prepare(`WITH RECURSIVE trail(id, hop) AS (
        SELECT ?, 1 UNION ALL SELECT l.target_id, t.hop + 1 FROM trail t JOIN lineage l ON l.artifact_id = t.id
        WHERE l.relation = 'remix_of' AND t.hop < 16) SELECT MAX(hop) AS hops FROM trail`).bind(parent.id).first();
      check(chain.hops < 16, "Remix lineage is too deep", 422);
      edges.push([piece.id, "contains", 0]);
    }
    edges.push([reference(remix).id, "remix_of", 0]);
  } else if (record.remixedFrom) {
    const parent = await publicDependency(ctx, record.remixedFrom);
    edges.push([parent.id, "remix_of", 0]);
  }
  return edges;
}

async function publish(ctx, email, request) {
  const input = await requestJSON(request);
  check(object(input, ["record", "artist", "postcard", "uploads"]), "Invalid publish request");
  const { record, postcard: meta = {}, uploads = {} } = input;
  validateRecord(record);
  const tags = validPostcard(meta);
  const canonical = canonicalJSON(record);
  const id = await sha256(canonical);
  const ref = `${record.kind}:sha256:${id}`;
  const existing = await lookup(ctx, reference(ref));
  check(existing.status !== 410, "This content was withdrawn", 410);
  const duplicate = existing.status === 200 || await ctx.db.prepare("SELECT 1 FROM artifacts WHERE id = ?").bind(id).first();
  check(!duplicate, "This revision has already been submitted", 409);
  const edges = await draftEdges(ctx, record);
  const files = await prepareUpload(record, meta, uploads);
  const bytesBlocked = await ctx.db.prepare("SELECT 1 FROM revocations WHERE target IN (SELECT value FROM json_each(?)) LIMIT 1")
    .bind(JSON.stringify(files.map((f) => `blob:sha256:${f.digest}`))).first();
  check(!bytesBlocked, "A referenced blob was withdrawn", 410);
  const artist = await artistFor(ctx.db, email, input.artist);
  const pending = record.kind === "piece";
  const receipt = pending ? await sha256(crypto.getRandomValues(new Uint8Array(32))) : null;
  // R2 has no cross-service transaction with D1. Bytes are written first and
  // remain inaccessible until the atomic D1 batch commits an approved owner.
  for (const file of new Map(files.map((f) => [f.digest, f])).values()) {
    await ctx.env.MEDIA.put(file.digest, file.bytes, { onlyIf: { etagDoesNotMatch: "*" } });
  }
  const batch = [
    ctx.db.prepare(`INSERT INTO artifacts (id, kind, artist_id, approval, listing, title, description, tags, receipt)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .bind(id, record.kind, artist, pending ? "pending" : "approved", pending ? "private" : "unlisted",
        record.title ?? "Untitled Piece", meta.description ?? null, JSON.stringify(tags), receipt),
    ctx.db.prepare("INSERT INTO revisions (id, canonical_json) VALUES (?, ?)").bind(id, canonical),
    ...edges.map(([target, relation, pos]) => ctx.db.prepare("INSERT INTO lineage (artifact_id, target_id, relation, position) VALUES (?, ?, ?, ?)")
      .bind(id, target, relation, pos)),
  ];
  for (const f of files) {
    batch.push(ctx.db.prepare("INSERT INTO blobs (sha256, size) VALUES (?, ?) ON CONFLICT(sha256) DO NOTHING")
      .bind(f.digest, f.bytes.length));
    batch.push(ctx.db.prepare("INSERT INTO revision_blobs (artifact_id, sha256, role, content_type) VALUES (?, ?, ?, ?)")
      .bind(id, f.digest, f.role, f.type));
  }
  try { await ctx.db.batch(batch); }
  catch (error) {
    if (await ctx.db.prepare("SELECT 1 FROM artifacts WHERE id = ?").bind(id).first()) throw new HTTPError(409, "This revision has already been submitted");
    throw error;
  }
  if (pending) return json({ state: "pending", receipt, href: `/api/v1/receipts/${receipt}` }, 202, PRIVATE);
  return json({ state: "unlisted", ref, href: `/p/v1/${record.kind}/${id}` }, 201, PRIVATE);
}

async function receipt(ctx, email, id) {
  const row = await ctx.db.prepare(`SELECT a.id, a.kind, a.approval, a.receipt FROM artifacts a JOIN artists s ON s.id = a.artist_id
    WHERE a.receipt = ? AND s.verified_email = ?`).bind(id, email).first();
  check(row, "Receipt not found", 404);
  const target = stockTarget(row.kind, row.id);
  const state = await lookup(ctx, target, { allowStock: false });
  return json({ receipt: id, state: state.status === 410 ? "withdrawn" : row.approval,
    ...(state.status === 200 && { ref: target.value, href: `/p/v1/${row.kind}/${row.id}` }) }, 200, PRIVATE);
}

function sliceRange(header, size) {
  if (!header) return undefined;
  const match = header.match(/^bytes=(\d*)-(\d*)$/);
  if (!match || (!match[1] && !match[2])) return null;
  const [, a, b] = match;
  if (!a) {
    const length = Math.min(Number(b), size);
    return length > 0 ? { offset: size - length, length } : null;
  }
  const offset = Number(a);
  const end = b ? Math.min(Number(b), size - 1) : size - 1;
  return offset <= end ? { offset, length: end - offset + 1 } : null;
}

async function blobResponse(ctx, request, digest) {
  const row = await ctx.db.prepare(`WITH authorized AS (
      SELECT s.content_type, a.listing FROM revision_blobs s JOIN public_artifacts a ON a.id = s.artifact_id WHERE s.sha256 = ?
    ) SELECT b.size,
      EXISTS (SELECT 1 FROM revocations WHERE target = ?) AS killed,
      EXISTS (SELECT 1 FROM revision_blobs s JOIN withdrawn_artifacts w ON w.id = s.artifact_id WHERE s.sha256 = ?) AS withdrawn,
      EXISTS (SELECT 1 FROM authorized WHERE listing = 'listed') AS listed,
      (SELECT CASE WHEN COUNT(DISTINCT content_type) > 1 THEN 'application/octet-stream' ELSE MIN(content_type) END FROM authorized) AS content_type
    FROM (SELECT 1) AS anchor LEFT JOIN blobs b ON b.sha256 = ?`)
    .bind(digest, `blob:sha256:${digest}`, digest, digest).first();
  if (row.killed || (!row.content_type && row.withdrawn)) return json({ error: "Blob withdrawn" }, 410, PUBLIC_ERROR);
  if (!row.content_type) return json({ error: "Blob not found" }, 404, PUBLIC_ERROR);
  const h = headers({ privateLink: !row.listed, cors: true });
  const range = sliceRange(request.headers.get("Range"), row.size);
  h.set("Accept-Ranges", "bytes");
  if (range === null) {
    h.set("Content-Range", `bytes */${row.size}`);
    return new Response(null, { status: 416, headers: h });
  }
  const file = request.method === "HEAD" ? await ctx.env.MEDIA.head(digest) : await ctx.env.MEDIA.get(digest, range && { range });
  if (!file || file.size !== row.size) return json({ error: "Blob not found" }, 404, PUBLIC_ERROR);
  h.set("Content-Type", row.content_type);
  h.set("Content-Length", String(range?.length ?? row.size));
  h.set("Cross-Origin-Resource-Policy", "cross-origin");
  if (!/^(image|video)\//.test(row.content_type)) h.set("Content-Disposition", "attachment");
  if (range) h.set("Content-Range", `bytes ${range.offset}-${range.offset + range.length - 1}/${row.size}`);
  return new Response(request.method === "HEAD" ? null : file.body, { status: range ? 206 : 200, headers: h });
}

async function handleReport(ctx, request) {
  await rate(ctx.env.REPORT_LIMIT, request.headers.get("CF-Connecting-IP") || "local");
  const data = await requestJSON(request, 4096);
  const target = reference(data?.target);
  check(object(data, ["target", "reason"]) && target && text(data.reason, 1200), "Invalid report");
  check((await lookup(ctx, target)).status === 200, "Postcard not found", 404);
  await ctx.db.prepare("INSERT INTO reports (id, target, reason) VALUES (?, ?, ?)")
    .bind(crypto.randomUUID(), target.value, data.reason).run();
  return json({ received: true }, 202, PRIVATE);
}

async function nominate(ctx, request, email) {
  const data = await requestJSON(request, 4096);
  const target = reference(data?.target);
  check(object(data, ["target", "note", "artist"]) && target && text(data.note, 1200), "Invalid nomination");
  check((await lookup(ctx, target)).status === 200, "Postcard not found", 404);
  const artist = await artistFor(ctx.db, email, data.artist);
  await ctx.db.prepare(`INSERT INTO nominations (artist_id, target, note) VALUES (?, ?, ?)
    ON CONFLICT(artist_id, target) DO NOTHING`).bind(artist, target.value, data.note).run();
  return json({ received: true }, 202, PRIVATE);
}

async function revoke(ctx, request) {
  check(await isAdmin(request, ctx.env), "Administrator required", 401);
  const data = await requestJSON(request, 4096);
  const target = reference(data?.target, ["piece", "look", "playlist", "blob"]);
  check(object(data, ["target", "reason"]) && target && text(data.reason, 1200), "Invalid revocation");
  await ctx.db.prepare("INSERT INTO revocations (target, reason) VALUES (?, ?) ON CONFLICT(target) DO NOTHING")
    .bind(target.value, data.reason).run();
  return json({ revoked: target.value }, 200, PRIVATE);
}

async function handle(request, env, fetcher) {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;
  const safe = method === "GET" || method === "HEAD";
  if (method === "POST") {
    const origin = request.headers.get("Origin");
    check(!origin || origin === url.origin, "Cross-origin write denied", 403);
  }
  const ctx = { db: env.DB.withSession?.("first-primary") ?? env.DB, env };
  const api = path.match(ARTIFACT);
  const post = path.match(POSTCARD);
  if (safe && (api || post)) {
    const [, kind, id] = api || post;
    const result = await lookup(ctx, stockTarget(kind, id));
    const privateLink = result.status !== 200 || (result.row && result.row.listing !== "listed");
    if (result.status !== 200) return api
      ? json({ error: result.status === 410 ? "Postcard withdrawn" : "Postcard not found" }, result.status, PUBLIC_ERROR)
      : page(env, { status: result.status, privateLink: true });
    const canonical = result.row?.canonical_json;
    const record = result.stock?.record ?? JSON.parse(canonical);
    if (api && url.searchParams.get("view") !== "postcard") return artifactResponse(record, canonical ?? canonicalJSON(record), privateLink);
    const entry = await postcard(ctx, record, result);
    return api ? json(entry, 200, { privateLink, cors: true }) : page(env, { entry, privateLink });
  }
  const blob = path.match(BLOB);
  if (safe && blob) return blobResponse(ctx, request, blob[1]);
  if (safe && (path === "/api/v1/editorial" || path === "/lerp-web/editorial.json")) return json(await visibleEdition(ctx), 200, { cors: true });
  if (method === "POST" && path === "/api/v1/reports") return handleReport(ctx, request);
  if (method === "POST" && path === "/api/v1/admin/revocations") return revoke(ctx, request);
  const getReceipt = safe && path.match(RECEIPT);
  if (getReceipt || (method === "POST" && ["/api/v1/publish", "/api/v1/nominations"].includes(path))) {
    const email = await verifiedEmail(request, env, fetcher);
    check(email, "Verified email required", 401);
    if (getReceipt) return receipt(ctx, email, getReceipt[1]);
    await rate(env.PUBLISH_LIMIT, email);
    return path.endsWith("/publish") ? publish(ctx, email, request) : nominate(ctx, request, email);
  }
  if (safe && ["/", "/index.html"].includes(path)) return page(env);
  if (path.startsWith("/p/")) return page(env, { status: 404, privateLink: true });
  if (path.startsWith("/api/")) return json({ error: "Route not found" }, 404, PUBLIC_ERROR);
  if (safe && env.SITE) {
    // Never expose a percent-encoded alias of the static editorial JSON:
    // the curated catalog must go through visibility checks on this host.
    let decoded;
    try { decoded = decodeURIComponent(path); } catch { throw new HTTPError(400, "Invalid path"); }
    if (decoded === path && path !== "/lerp-web/editorial.json") return env.SITE.fetch(request);
  }
  return json({ error: "Route not found" }, 404, PRIVATE);
}

export function createWorker(fetcher = (...args) => fetch(...args)) {
  return { async fetch(request, env) {
    let response;
    try { response = await handle(request, env, fetcher); }
    catch (error) {
      if (error instanceof HTTPError) response = json({ error: error.message }, error.status, PRIVATE);
      else { console.error("Platform request failed", error); response = json({ error: "Request could not be completed" }, 500, PRIVATE); }
    }
    return request.method === "HEAD" ? new Response(null, response) : response;
  } };
}
export default createWorker();
