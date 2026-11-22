// RFC 8785 uses ECMAScript number/string serialization and lexicographic
// order of UTF-16 code units. Serialize directly: JSON.stringify(object)
// would move integer-shaped property names back into numeric order.
export function canonicalJSON(value, depth = 0) {
  if (depth > 32) throw new TypeError("JSON is nested too deeply");
  if (value === null || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "string") {
    if (!value.isWellFormed()) throw new TypeError("Unpaired surrogate in JSON string");
    return JSON.stringify(value);
  }
  if (typeof value === "number" && Number.isFinite(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return `[${Array.from(value, (item) => canonicalJSON(item, depth + 1)).join(",")}]`;
  if (value && (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null)) {
    return `{${Object.keys(value).sort().map((key) => `${canonicalJSON(key)}:${canonicalJSON(value[key], depth + 1)}`).join(",")}}`;
  }
  throw new TypeError("Not an I-JSON value");
}

// JSON.parse validates syntax, but would erase duplicate members before JCS
// could reject them. Walk the already validated token stream before hashing.
export function parseIJSON(text) {
  const value = JSON.parse(text);
  const tokens = /"[^"\\]*(?:\\.[^"\\]*)*"|[^\x20\t\r\n{}\[\]:,]+|[{}\[\]:,]/gs;
  const next = () => tokens.exec(text)?.[0];
  function visit(token, depth) {
    if (depth > 32) throw new TypeError("JSON is nested too deeply");
    if (token === "{") {
      const keys = new Set();
      let key = next();
      while (key !== "}") {
        const name = JSON.parse(key);
        if (!name.isWellFormed() || keys.has(name)) throw new TypeError("Invalid or duplicate JSON member");
        keys.add(name);
        next(); // colon
        visit(next(), depth + 1);
        if (next() === "}") break;
        key = next();
      }
    } else if (token === "[") {
      let item = next();
      while (item !== "]") {
        visit(item, depth + 1);
        if (next() === "]") break;
        item = next();
      }
    } else if (token.startsWith('"')) {
      if (!JSON.parse(token).isWellFormed()) throw new TypeError("Unpaired surrogate in JSON string");
    } else if (token !== "true" && token !== "false" && token !== "null" && !Number.isFinite(Number(token))) {
      throw new TypeError("Non-finite JSON number");
    }
  }
  visit(next(), 0);
  return value;
}

export async function sha256(bytes) {
  const input = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", input)),
    (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function contentReference(record) {
  return `${record.kind}:sha256:${await sha256(canonicalJSON(record))}`;
}
