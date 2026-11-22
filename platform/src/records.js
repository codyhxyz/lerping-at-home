import { parseIJSON, sha256 } from "./canonical.js";
import { isSPDX } from "./licenses.js";
import { parseShader } from "../../docs/lerp-web/engine.js";

export const DIGEST = /^[0-9a-f]{64}$/;
const REFERENCE = /^(piece|look|playlist|blob):sha256:([0-9a-f]{64})$/;
const nativeAssets = {
  "assets/capture.lsplat": "application/octet-stream",
  "assets/capture.path.json": "application/json",
  "assets/image.png": "image/png",
  "assets/image.depth.png": "image/png",
};
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
export const LIMIT = 9 * 1024 * 1024;

export class HTTPError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
export function check(condition, message, status = 400) {
  if (!condition) throw new HTTPError(status, message);
}
export function object(o, keys) {
  return o !== null && typeof o === "object" && !Array.isArray(o) &&
    (!keys || Object.keys(o).every((k) => keys.includes(k)));
}
export function text(value, max) {
  return typeof value === "string" && value.trim().length > 0 && !/\p{Cc}/u.test(value) && encoder.encode(value).length <= max;
}
export function reference(value, kinds = ["piece", "look", "playlist"]) {
  const match = typeof value === "string" && value.match(REFERENCE);
  return match && kinds.includes(match[1]) ? { kind: match[1], id: match[2], value } : null;
}
export async function requestJSON(request, limit = LIMIT) {
  check(request.headers.get("Content-Type")?.split(";")[0].trim().toLowerCase() === "application/json", "Expected application/json", 415);
  check(!(Number(request.headers.get("Content-Length")) > limit), "Request too large", 413);
  check(request.body, "Missing JSON body");
  const reader = request.body.getReader();
  const pieces = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) { await reader.cancel(); throw new HTTPError(413, "Request too large"); }
      pieces.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const part of pieces) { bytes.set(part, offset); offset += part.byteLength; }
    return parseIJSON(decoder.decode(bytes));
  } catch (error) {
    if (error instanceof HTTPError) throw error;
    throw new HTTPError(400, "Invalid I-JSON request");
  } finally { reader.releaseLock(); }
}

function color(x) { return Array.isArray(x) && x.length === 4 && x.every((n) => Number.isFinite(n) && n >= 0 && n <= 1); }
function tuningValue(x) {
  if (typeof x === "boolean" || Number.isFinite(x) || color(x)) return true;
  if (!object(x, ["animate"]) || !object(x.animate, ["low", "high", "period"])) return false;
  const { low, high, period } = x.animate;
  return Number.isFinite(period) && period > 0 && ((color(low) && color(high)) || (Number.isFinite(low) && Number.isFinite(high)));
}
export function validateRecord(record) {
  check(object(record) && record.v === 1, "Expected a v1 portable record");
  const { kind, title, authors, license, remixedFrom } = record;
  const credit = ["title", "authors", "license", "remixedFrom"];
  check(title === undefined || text(title, 240), "Invalid title");
  check(authors === undefined || (Array.isArray(authors) && authors.length <= 16 && authors.every((a) => text(a, 120))), "Invalid authors");
  check(license === undefined || isSPDX(license), "Invalid SPDX license");
  check(remixedFrom === undefined || reference(remixedFrom, ["piece", "look"]), "Invalid remix reference");
  if (kind === "piece") {
    check(object(record, ["v", "kind", "abi", "source", "assets", ...credit]) && record.abi === "lerp-metal-1" &&
      reference(record.source, ["blob"]) && object(record.assets, Object.keys(nativeAssets)), "Invalid Piece");
    const capture = Object.hasOwn(record.assets, "assets/capture.lsplat");
    const img = Object.hasOwn(record.assets, "assets/image.png");
    check(!(capture && img) && (!Object.hasOwn(record.assets, "assets/capture.path.json") || capture) &&
      (!Object.hasOwn(record.assets, "assets/image.depth.png") || img), "Conflicting or incomplete Piece assets");
    for (const asset of Object.values(record.assets)) {
      check(object(asset, ["sha256", "credit", "license"]) && typeof asset.sha256 === "string" && DIGEST.test(asset.sha256) &&
        text(asset.credit, 1024) && isSPDX(asset.license), "Invalid asset metadata");
    }
  } else if (kind === "look") {
    check(object(record, ["v", "kind", "piece", "preset", "tuning", ...credit]) && reference(record.piece, ["piece"]) &&
      title !== undefined && authors !== undefined && (record.preset === null || text(record.preset, 120)) && object(record.tuning), "Invalid Look");
    const values = Object.entries(record.tuning);
    check(values.length <= 128 && values.every(([name, value]) => /^[_\p{L}][_\p{L}\p{N}]*$/u.test(name) && tuningValue(value)), "Invalid tuning");
  } else if (kind === "playlist") {
    check(object(record, ["v", "kind", "title", "looks"]) && title !== undefined && Array.isArray(record.looks) &&
      record.looks.length >= 1 && record.looks.length <= 100 && new Set(record.looks).size === record.looks.length &&
      record.looks.every((look) => reference(look, ["look"])), "Invalid Playlist");
  } else throw new HTTPError(400, "Unknown artifact kind");
}

export function validateParameters(record, source) {
  const params = new Map(parseShader(source).params.map((p) => [p.name, p]));
  if (record.preset !== null) {
    const hasPreset = source.split("\n").some((line) => {
      const m = line.match(/^\s*\/\/\s*lerp-preset:\s*(?:"([^"]+)"|([^"\s]+))\s+\S/);
      return m && (m[1] ?? m[2]) === record.preset;
    });
    check(hasPreset, "Preset does not belong to this Piece");
  }
  for (const [name, value] of Object.entries(record.tuning)) {
    const param = params.get(name);
    check(param, `Unknown parameter: ${name}`);
    const valid = (n) => param.type === "color" ? color(n) : param.type === "bool" ? typeof n === "boolean" :
      Number.isFinite(Math.fround(n)) && typeof n === "number" && n >= param.min && n <= param.max &&
      (param.type !== "int" || Number.isInteger(n) && n >= -2147483648 && n <= 2147483647);
    const animation = object(value) ? value.animate : null;
    const differs = (a, b) => Array.isArray(a) ? a.some((x, i) => Math.fround(x) !== Math.fround(b[i])) : a !== b;
    check(animation ? ["float", "color"].includes(param.type) && animation.period >= 10 &&
      valid(animation.low) && valid(animation.high) && differs(animation.low, animation.high) : valid(value),
    `Value does not match parameter: ${name}`);
  }
}

function starts(bytes, ...head) { return head.every((s, i) => s === bytes[i]); }
function asciiAt(bytes, offset, s) { return [...s].every((c, i) => c.charCodeAt(0) === bytes[offset + i]); }
function sniffImage(bytes) {
  if (starts(bytes, 137, 80, 78, 71, 13, 10, 26, 10)) return "image/png";
  if (starts(bytes, 255, 216, 255)) return "image/jpeg";
  if (asciiAt(bytes, 0, "RIFF") && asciiAt(bytes, 8, "WEBP")) return "image/webp";
}
function sniffVideo(bytes) {
  if (asciiAt(bytes, 4, "ftyp")) return "video/mp4";
  if (starts(bytes, 26, 69, 223, 163)) return "video/webm";
}

// A bounded JSON upload is deliberately the only upload protocol for Milestone
// 1. Large external captures are not accepted through this preview platform.
export async function prepareUpload(record, postcard, uploads) {
  check(object(uploads), "Invalid uploads");
  const wanted = new Map();
  for (const role of ["still", "video"]) {
    if (postcard[role] !== undefined) {
      check(typeof postcard[role] === "string" && DIGEST.test(postcard[role]), `Invalid ${role} digest`);
      wanted.set(role, postcard[role]);
    }
  }
  if (record.kind === "piece") {
    wanted.set("source", reference(record.source, ["blob"]).id);
    for (const [role, asset] of Object.entries(record.assets)) wanted.set(role, asset.sha256);
  }
  check(record.kind === "piece" || wanted.size === 0, "Only new Pieces may upload assets");
  check(Object.keys(uploads).every((key) => [...wanted.values()].includes(key)), "Unexpected upload");
  const out = [];
  const attachments = new Map();
  for (const [role, digest] of wanted) {
    if (!attachments.has(digest)) {
      const encoded = uploads[digest];
      check(typeof encoded === "string" && /^[A-Za-z0-9+/]+={0,2}$/.test(encoded), `Missing or invalid upload for ${role}`);
      let decoded;
      try { decoded = Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0)); }
      catch { throw new HTTPError(400, `Invalid base64 for ${role}`); }
      check(decoded.length > 0 && await sha256(decoded) === digest, `Digest mismatch for ${role}`);
      attachments.set(digest, decoded);
    }
    const bytes = attachments.get(digest);
    let type = nativeAssets[role];
    if (role === "source") {
      try { check(bytes.length <= 512 * 1024 && !decoder.decode(bytes).includes("\0"), "Metal source is too large or invalid"); }
      catch { throw new HTTPError(400, "Expected UTF-8 Metal source under 512 KiB"); }
      type = "text/plain; charset=utf-8";
    } else if (role === "still") {
      type = sniffImage(bytes);
      check(type && bytes.length <= 1024 * 1024, "Still must be PNG, JPEG or WebP under 1 MiB");
    } else if (role === "video") {
      type = sniffVideo(bytes);
      check(type && bytes.length <= 4 * 1024 * 1024, "Preview clip must be MP4 or WebM under 4 MiB");
    } else if (type === "image/png") check(sniffImage(bytes) === type, "Expected PNG asset");
    else if (role === "assets/capture.lsplat") check(bytes.length >= 48 && asciiAt(bytes, 0, "LSPL"), "Expected LSPLAT asset");
    else if (type === "application/json") {
      try { parseIJSON(decoder.decode(bytes)); }
      catch { throw new HTTPError(400, "Invalid capture path JSON"); }
    }
    check(!out.some((other) => other.digest === digest && other.type !== type), "Conflicting roles for the same blob");
    out.push({ role, digest, bytes, type });
  }
  return out;
}
