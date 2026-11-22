import { parseIJSON, sha256 } from "./canonical.js";

const decoder = new TextDecoder("utf-8", { fatal: true });
const keysByIssuer = new Map();

function decodeBase64Url(input) {
  if (!/^[\w-]+$/.test(input)) throw new TypeError("Invalid JWT encoding");
  return Uint8Array.from(atob(input.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
}

async function keyFor(issuer, kid, fetcher) {
  let cached = keysByIssuer.get(issuer);
  if (!cached || cached.expires < Date.now()) {
    const promise = (async () => {
      const response = await fetcher(`${issuer}/cdn-cgi/access/certs`, { redirect: "error" });
      if (!response.ok) throw new Error("Could not fetch Access keys");
      const { keys } = await response.json();
      return new Map(keys.filter((key) => key.kty === "RSA" && (key.alg === "RS256" || !key.alg)).map((key) => [key.kid, key]));
    })();
    cached = { keys: promise, expires: Date.now() + 60_000 };
    keysByIssuer.set(issuer, cached);
    promise.catch(() => { if (keysByIssuer.get(issuer) === cached) keysByIssuer.delete(issuer); });
  }
  return (await cached.keys).get(kid);
}

// Access must be configured for human login with verified email (one-time
// PIN or a verified-email IdP), not Service Auth or a Bypass application.
export async function verifiedEmail(request, env, fetcher = fetch) {
  const token = request.headers.get("CF-Access-Jwt-Assertion");
  const issuer = env.ACCESS_ISSUER;
  if (!token || token.length > 8192 || !env.ACCESS_AUDIENCE || !/^https:\/\/[a-z0-9-]+\.cloudflareaccess\.com$/.test(issuer)) return null;
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    const [head, payload, sig] = parts;
    const h = parseIJSON(decoder.decode(decodeBase64Url(head)));
    const claims = parseIJSON(decoder.decode(decodeBase64Url(payload)));
    const now = Date.now() / 1000;
    if (h.alg !== "RS256" || typeof h.kid !== "string" || claims.iss !== issuer || claims.type !== "app" ||
        !Array.isArray(claims.aud) || !claims.aud.includes(env.ACCESS_AUDIENCE) ||
        !Number.isFinite(claims.exp) || claims.exp <= now || !Number.isFinite(claims.iat) || claims.iat > now + 30 ||
        (claims.nbf !== undefined && (!Number.isFinite(claims.nbf) || claims.nbf > now + 30)) ||
        typeof claims.email !== "string" || claims.email.length > 254 || !/^[^\s@]+@[^\s@]+$/.test(claims.email)) return null;
    const jwk = await keyFor(issuer, h.kid, fetcher);
    if (!jwk) return null;
    const algo = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };
    const key = await crypto.subtle.importKey("jwk", jwk, algo, false, ["verify"]);
    const signed = new TextEncoder().encode(`${head}.${payload}`);
    if (await crypto.subtle.verify(algo, key, decodeBase64Url(sig), signed)) return claims.email.toLowerCase();
  } catch { /* Malformed, expired, unverified, or no keys: fail closed. */ }
  return null;
}

export async function isAdmin(request, env) {
  const secret = env.ADMIN_TOKEN;
  const presented = request.headers.get("Authorization")?.match(/^Bearer ([A-Za-z0-9_-]{32,256})$/)?.[1];
  if (typeof secret !== "string" || secret.length < 32 || !presented) return false;
  const [a, b] = await Promise.all([sha256(secret), sha256(presented)]);
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return mismatch === 0;
}
