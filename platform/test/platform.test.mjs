import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { canonicalJSON, contentReference, parseIJSON, sha256 } from "../src/canonical.js";
import { createWorker } from "../src/index.js";
import { defaultParamValues, detectPreviewCapability, playShader, previewSize, transpile } from "../../docs/lerp-web/engine.js";

const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const key = { ...publicKey.export({ format: "jwk" }), kid: "test-key", alg: "RS256", use: "sig" };
const ISSUER = "https://lerping-test.cloudflareaccess.com";
const AUDIENCE = "test-audience";
const SECRET = "revocations_abcdefghijklmnopqrstuvwxyz0123456789";
const MAIN_EMAIL = "artist@example.com";
const REMIX_EMAIL = "remixer@example.com";
const worker = createWorker(async (url) => {
  assert.equal(url, `${ISSUER}/cdn-cgi/access/certs`);
  return Response.json({ keys: [key] });
});
const migration = readFileSync(new URL("../migrations/0001_init.sql", import.meta.url), "utf8");
const catalogue = readFileSync(new URL("../../docs/lerp-web/editorial.json", import.meta.url), "utf8");
const shell = readFileSync(new URL("../../docs/index.html", import.meta.url), "utf8");
const recordPath = (ref) => "/api/v1/artifacts/" + ref.replace(":sha256:", "/");
const blobPath = (id) => `/api/v1/blobs/${id}`;
const digest = (x) => createHash("sha256").update(x).digest("hex");

function token(email, claims = {}) {
  const enc = (data) => Buffer.from(JSON.stringify(data)).toString("base64url");
  const iat = Math.floor(Date.now() / 1000);
  const message = `${enc({ alg: "RS256", kid: key.kid })}.${enc({ iss: ISSUER, aud: [AUDIENCE], email, iat, exp: iat + 3600, type: "app", ...claims })}`;
  return `${message}.${sign("RSA-SHA256", Buffer.from(message), privateKey).toString("base64url")}`;
}
function fixture(t) {
  const sqlite = new DatabaseSync(":memory:");
  sqlite.exec("PRAGMA foreign_keys = ON;");
  sqlite.exec(migration);
  t.after(() => sqlite.close());
  let primaryReads = 0;
  const DB = {
    withSession(constraint) { assert.equal(constraint, "first-primary"); primaryReads++; return this; },
    prepare(sql) {
      const stmt = sqlite.prepare(sql);
      function bind(...params) {
        return { bind, first: () => stmt.get(...params), run: () => stmt.run(...params), all: () => ({ results: stmt.all(...params) }) };
      }
      return bind();
    },
    batch(stmts) {
      sqlite.exec("BEGIN");
      try { const results = stmts.map((stmt) => stmt.run()); sqlite.exec("COMMIT"); return results; }
      catch (error) { sqlite.exec("ROLLBACK"); throw error; }
    },
  };
  const contents = new Map();
  const env = {
    DB, ACCESS_ISSUER: ISSUER, ACCESS_AUDIENCE: AUDIENCE, ADMIN_TOKEN: SECRET,
    MEDIA: {
      put(id, bytes, options) {
        assert.equal(options.onlyIf.etagDoesNotMatch, "*");
        if (!contents.has(id)) contents.set(id, Buffer.from(bytes));
      },
      head(id) { return contents.has(id) ? { size: contents.get(id).length } : null; },
      get(id, options) {
        const bytes = contents.get(id);
        if (!bytes) return null;
        const range = options?.range;
        return { size: bytes.length, text: () => bytes.toString("utf8"),
          body: range ? bytes.subarray(range.offset, range.offset + range.length) : bytes };
      },
    },
    SITE: { fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/lerp-web/editorial.json") return new Response(catalogue);
      if (path === "/index.html") return new Response(shell);
      return new Response(null, { status: 404 });
    } },
  };
  const call = (path, { body, headers, method = body ? "POST" : "GET" } = {}) => worker.fetch(new Request(`https://lerping.app${path}`, {
    method, headers: body ? { "Content-Type": "application/json", ...headers } : headers,
    body: body && (typeof body === "string" ? body : JSON.stringify(body)),
  }), env);
  const publish = (body, email = MAIN_EMAIL) => call("/api/v1/publish", { body,
    headers: { "CF-Access-Jwt-Assertion": token(email) } });
  const accept = (id) => sqlite.prepare("UPDATE artifacts SET approval='approved', listing='unlisted', remix_enabled=1 WHERE id=?").run(id);
  const revoke = (target) => call("/api/v1/admin/revocations", {
    body: { target, reason: "Withdrawn by request" }, headers: { Authorization: `Bearer ${SECRET}` },
  });
  t.after(() => assert.ok(primaryReads > 0));
  return { sqlite, call, publish, accept, revoke, env, contents };
}

const MSL = `// lerp-param: hue float 0 1 = 0.2 "Hue"
// lerp-param: toggle bool = true "Toggle"
fragment half4 lerpMain(float4 pos [[position]], const LerpUniforms& u) {
  if (u.toggle) return half4(u.hue);
  return half4(0.0);
}`;
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg==", "base64");
const edition = JSON.parse(catalogue);
const MP4 = Buffer.from(edition.entries.find((e) => e.slug === "ink-fluid").video.url.split(",")[1], "base64");
const sourceId = digest(MSL);
const stillId = digest(PNG);
const videoId = digest(MP4);
const piece = { v: 1, kind: "piece", abi: "lerp-metal-1", source: `blob:sha256:${sourceId}`, assets: {}, title: "Reading Lamp", authors: ["Ada"], license: "MIT" };
const pieceInput = { record: piece, artist: { name: "Ada", bio: "An artist of light", url: "https://example.com/ada" },
  postcard: { description: "A quiet glow", still: stillId, video: videoId, tags: { mood: "Quiet", motion: "slow", brightness: "dim", medium: "procedural" } },
  uploads: { [sourceId]: Buffer.from(MSL).toString("base64"), [stillId]: PNG.toString("base64"), [videoId]: MP4.toString("base64") } };
const pieceRef = await contentReference(piece);
const pieceId = pieceRef.split(":").at(-1);
const look = { v: 1, kind: "look", title: "Soft <Lamp>", piece: pieceRef, preset: null, tuning: { hue: 0.3, toggle: false }, authors: ["Bex"] };
const lookRef = await contentReference(look);
const lookInput = { artist: { name: "Bex" }, record: look };
const playlist = { v: 1, kind: "playlist", title: "On the Desk", looks: [lookRef] };
const listRef = await contentReference(playlist);

async function seed(f) {
  const result = await f.publish(pieceInput);
  assert.equal(result.status, 202, await result.clone().text());
  const receipt = await result.json();
  f.accept(pieceId);
  return receipt;
}

test("RFC 8785 number, string and UTF-16 member order; reject duplicate keys and malformed Unicode", async () => {
  const input = parseIJSON('{"numbers":[333333333.33333329,1E30,4.50,2e-3,0.000000000000000000000000001,-0],"string":"€$\\u000f\\nA\'B\\\"\\\\\"}' );
  const canonical = '{"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27,0],"string":"€$\\u000f\\nA\'B\\\"\\\\"}';
  assert.equal(canonicalJSON(input), canonical);
  assert.equal(await sha256(canonical), digest(canonical));
  assert.equal(canonicalJSON({ "2": 2, "10": 10, "\uE000": 1, "😀": 2 }), '{"10":10,"2":2,"😀":2,"":1}');
  assert.throws(() => parseIJSON('{"a":{"x":1,"\\u0078":2}}'), /duplicate/);
  assert.throws(() => parseIJSON('["\\uD800"]'), /surrogate/);
  assert.throws(() => canonicalJSON({ x: Infinity }));
  assert.match(pieceRef, /^piece:sha256:[0-9a-f]{64}$/);
});

test("new shader and bytes are quarantined; verified owner alone can read the private receipt", async (t) => {
  const f = fixture(t);
  assert.equal((await f.call("/api/v1/publish", { body: pieceInput })).status, 401);
  for (const claims of [{ aud: ["wrong"] }, { exp: 0 }, { type: "service" }]) {
    const res = await f.call("/api/v1/publish", { body: pieceInput, headers: { "CF-Access-Jwt-Assertion": token(MAIN_EMAIL, claims) } });
    assert.equal(res.status, 401);
  }
  const mismatched = await f.publish({ ...pieceInput, uploads: { ...pieceInput.uploads, [sourceId]: "VVVV" } });
  assert.equal(mismatched.status, 400);
  assert.equal(f.contents.size, 0);
  const res = await f.publish(pieceInput);
  assert.equal(res.status, 202, await res.clone().text());
  const body = await res.json();
  assert.deepEqual(Object.keys(body).sort(), ["href", "receipt", "state"]);
  assert.equal(body.state, "pending");
  assert.equal(res.headers.get("X-Robots-Tag"), "noindex, nofollow");
  assert.ok(f.contents.has(sourceId));
  assert.equal((await f.call(recordPath(pieceRef))).status, 404);
  assert.equal((await f.call(blobPath(sourceId))).status, 404);
  assert.equal((await f.call(`/p/v1/piece/${pieceId}`)).status, 404);
  assert.equal((await f.call(body.href)).status, 401);
  assert.equal((await f.call(body.href, { headers: { "CF-Access-Jwt-Assertion": token(REMIX_EMAIL) } })).status, 404);
  const own = await f.call(body.href, { headers: { "CF-Access-Jwt-Assertion": token(MAIN_EMAIL) } });
  assert.equal((await own.json()).state, "pending");
  assert.equal(f.sqlite.prepare("SELECT approval FROM artifacts WHERE id=?").get(pieceId).approval, "pending");
  assert.throws(() => f.sqlite.prepare("UPDATE revisions SET canonical_json='{}' WHERE id=?").run(pieceId), /immutable/);
});

test("parameter-only approved remixes and ordered playlists publish unlisted; resolve lineage and stills", async (t) => {
  const f = fixture(t);
  await seed(f);
  assert.equal((await f.publish({ ...lookInput, record: { ...look, tuning: { toggle: 1 } } }, REMIX_EMAIL)).status, 400);
  assert.equal((await f.publish({ ...lookInput, uploads: pieceInput.uploads }, REMIX_EMAIL)).status, 400);
  f.sqlite.prepare("UPDATE artifacts SET remix_enabled=0 WHERE id=?").run(pieceId);
  assert.equal((await f.publish(lookInput, REMIX_EMAIL)).status, 403);
  f.accept(pieceId);
  const immediate = await f.publish(lookInput, REMIX_EMAIL);
  assert.equal(immediate.status, 201, await immediate.clone().text());
  const first = await immediate.json();
  assert.equal(first.ref, lookRef);
  const second = { ...look, title: "Second", remixedFrom: lookRef };
  const remixOfRemix = await f.publish({ record: second }, REMIX_EMAIL);
  assert.equal(remixOfRemix.status, 201, await remixOfRemix.clone().text());
  const secondRef = (await remixOfRemix.json()).ref;
  const listRecord = { ...playlist, looks: [secondRef, lookRef] };
  const collection = await f.publish({ record: listRecord });
  assert.equal(collection.status, 201, await collection.clone().text());
  const list = await collection.json();
  assert.equal(list.ref, await contentReference(listRecord));
  const api = await f.call(recordPath(list.ref));
  assert.equal(api.headers.get("Cache-Control"), "no-store");
  assert.equal(api.headers.get("X-Robots-Tag"), "noindex, nofollow");
  assert.equal(await api.text(), canonicalJSON(listRecord));
  const rich = await (await f.call(`${recordPath(secondRef)}?view=postcard`)).json();
  assert.deepEqual(rich.lineage.map((x) => x.artist.name), ["Bex", "Ada"]);
  assert.equal(rich.license, "MIT");
  assert.equal(rich.still, blobPath(stillId));
  const richList = await (await f.call(`${recordPath(list.ref)}?view=postcard`)).json();
  assert.deepEqual(richList.members.map((m) => m.title), [second.title, look.title]);
  const rendered = await f.call(first.href);
  assert.equal(rendered.headers.get("X-Robots-Tag"), "noindex, nofollow");
  const html = await rendered.text();
  assert.match(html, /Soft &lt;Lamp&gt;/);
  assert.match(html, /Remixed from .*Reading Lamp<\/a> by Ada/);
  assert.match(html, /lerp:\/\/open\/v1\/look\/[0-9a-f]{64}/);
  assert.match(html, /name="robots" content="noindex, nofollow"/);
  assert.doesNotMatch(html, /@example\.com/);
  const asset = await f.call(blobPath(videoId), { headers: { Range: "bytes=4-7" } });
  assert.equal(asset.status, 206);
  assert.equal(asset.headers.get("X-Robots-Tag"), "noindex, nofollow");
  assert.equal(asset.headers.get("Cache-Control"), "no-store");
  assert.equal(await asset.text(), "ftyp");
  assert.equal((await f.call(blobPath(videoId), { headers: { Range: "bytes=99999999-" } })).status, 416);
});

test("revocation disables public HTML, canonical import JSON, descendants and private R2 bytes", async (t) => {
  const f = fixture(t);
  await seed(f);
  assert.equal((await f.publish(lookInput, REMIX_EMAIL)).status, 201);
  assert.equal((await f.publish({ record: playlist })).status, 201);
  assert.equal((await f.call(blobPath(sourceId))).status, 200);
  const unauthorized = await f.call("/api/v1/admin/revocations", { body: { target: pieceRef, reason: "test" } });
  assert.equal(unauthorized.status, 401);
  assert.equal((await f.revoke(pieceRef)).status, 200);
  for (const url of [recordPath(pieceRef), recordPath(lookRef), recordPath(listRef), `/p/v1/piece/${pieceId}`, blobPath(sourceId), blobPath(stillId), blobPath(videoId)]) {
    const res = await f.call(url);
    assert.equal(res.status, 410, url);
    assert.equal(res.headers.get("Cache-Control"), "no-store");
    assert.equal(res.headers.get("X-Robots-Tag"), "noindex, nofollow");
  }
  assert.ok(f.contents.has(sourceId), "R2 deletion is not needed for revocation");
});

test("kill by blob digest, report and nominate stock cards, and filter revoked entries from hosted edition", async (t) => {
  const f = fixture(t);
  await seed(f);
  assert.equal((await f.revoke(`blob:sha256:${stillId}`)).status, 200);
  assert.equal((await f.call(recordPath(pieceRef))).status, 410);
  assert.equal((await f.call(blobPath(stillId), { method: "HEAD" })).status, 410);
  const stock = edition.entries[0];
  const ref = await contentReference(stock.record);
  assert.equal(ref.split(":").at(-1), stock.id);
  assert.equal((await f.call(recordPath(ref))).headers.get("X-Robots-Tag"), null);
  assert.equal((await f.call("/api/v1/reports", { body: { target: ref, reason: "Credit correction" } })).status, 202);
  assert.equal((await f.call("/api/v1/nominations", {
    body: { target: ref, note: "A mood for the shelf" }, headers: { "CF-Access-Jwt-Assertion": token(MAIN_EMAIL) },
  })).status, 202);
  assert.equal(f.sqlite.prepare("SELECT count(*) AS n FROM reports").get().n, 1);
  assert.equal(f.sqlite.prepare("SELECT count(*) AS n FROM nominations").get().n, 1);
  assert.equal((await f.revoke(stock.record.source)).status, 200);
  const publicEdition = await (await f.call("/api/v1/editorial")).json();
  assert.ok(!publicEdition.entries.some((e) => e.id === stock.id));
  assert.equal((await f.call(recordPath(ref))).status, 410);
});

test("stock cards are exact hashes of the prior-art source and use renderable inline stills", async () => {
  const featuredSlugs = new Set(edition.shelves.flatMap((s) => s.entries));
  const splats = { "saka-shrine": "splat-shrine-telephoto", trogir: "splat-trogir" };
  for (const card of edition.entries) {
    assert.ok(featuredSlugs.has(card.slug));
    assert.match(card.still, /^data:image\/webp;base64,UklGR/);
    const file = splats[card.slug] || card.slug;
    const source = readFileSync(new URL(`../../Sources/Shaders/${file}.metal`, import.meta.url));
    assert.equal(card.record.source, `blob:sha256:${digest(source)}`);
    assert.equal(await contentReference(card.record), `piece:sha256:${card.id}`);
  }
});

test("WebGL bool declarations/types and capability fallbacks match Metal, and the 1 MP cap holds", () => {
  const { glsl, params } = transpile(MSL);
  assert.match(glsl, /uniform int u_toggle;/);
  assert.match(glsl, /if \(bool\(u_toggle\)\)/);
  assert.deepEqual(defaultParamValues(params), { hue: 0.2, toggle: 1 });
  const fakeGL = { isContextLost: () => false };
  const canvas = { getContext: () => fakeGL };
  const video = { canPlayType: (type) => type === "video/mp4" ? "probably" : "" };
  assert.equal(detectPreviewCapability({ canvas, shader: {}, motionAllowed: true }).mode, "webgl2");
  assert.equal(detectPreviewCapability({ video, videoType: "video/mp4", motionAllowed: true }).mode, "video");
  assert.equal(detectPreviewCapability({ canvas, shader: {}, video, videoType: "video/mp4", motionAllowed: false }).mode, "still");
  const [width, height] = previewSize(3000, 2000, 3);
  assert.ok(width * height <= 1_000_000);
  assert.ok(Math.abs(width / height - 1.5) < 0.01);
  assert.equal(typeof playShader, "function");
});

test("a 120 Hz WebGL render loop paces frames and disposes GPU state on stop", (t) => {
  const prevRAF = globalThis.requestAnimationFrame, prevCancel = globalThis.cancelAnimationFrame;
  const pending = new Map();
  let raf = 0, draws = 0, deleted = 0, lost = 0, removed = 0;
  globalThis.requestAnimationFrame = (next) => { pending.set(++raf, next); return raf; };
  globalThis.cancelAnimationFrame = (id) => pending.delete(id);
  t.after(() => {
    if (prevRAF === undefined) delete globalThis.requestAnimationFrame;
    else globalThis.requestAnimationFrame = prevRAF;
    if (prevCancel === undefined) delete globalThis.cancelAnimationFrame;
    else globalThis.cancelAnimationFrame = prevCancel;
  });
  const gl = {
    MAX_VIEWPORT_DIMS: 1, MAX_RENDERBUFFER_SIZE: 2,
    createShader: () => ({}), shaderSource() {}, compileShader() {}, getShaderParameter: () => true, deleteShader() {},
    createProgram: () => ({}), attachShader() {}, linkProgram() {}, getProgramParameter: () => true, useProgram() {},
    getUniformLocation() {}, getParameter: (id) => id === 1 ? [2048, 2048] : 2048,
    viewport() {}, uniform2f() {}, uniform1f() {}, uniform1i() {}, drawArrays() { draws++; },
    deleteProgram() { deleted++; }, isContextLost: () => lost > 0,
    getExtension(name) { assert.equal(name, "WEBGL_lose_context"); return { loseContext() { lost++; } }; },
  };
  const canvas = {
    clientWidth: 1600, clientHeight: 1200,
    addEventListener() {}, removeEventListener() {}, remove() { removed++; },
  };
  const shader = transpile(MSL);
  const dispose = playShader(canvas, gl, shader, defaultParamValues(shader.params), { seed: 0, time: 0 }, () => {});
  const time = performance.now();
  for (let step = 0; step <= 120; step++) {
    assert.equal(pending.size, 1);
    const [next, frame] = [...pending][0];
    pending.delete(next);
    frame(time + 1000 * step / 120);
  }
  assert.ok(draws >= 30 && draws <= 31, `drew ${draws} frames`);
  assert.ok(canvas.width * canvas.height <= 1_000_000);
  dispose();
  dispose();
  assert.deepEqual([deleted, lost, removed, pending.size, canvas.width, canvas.height], [1, 1, 1, 0, 1, 1]);
});
