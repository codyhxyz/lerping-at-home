# Lerping postcard platform

The static edition in `docs/` is an offline editorial snapshot, with hash routes on any static host. The first-party Worker at `https://lerping.app` is authoritative for listed and unlisted links, the live catalog, publishing, and revocation. The front door does not create a GPU context until a visitor presses Play. Only known, pinned stock shaders are transpiled in the browser; published works use a poster and an optional recorded clip, never user-supplied GPU code.

## Local checks

Node 22.13+ runs the suite without dependencies. Tests exercise the Worker against SQLite using the real D1 migration, in-memory private R2, and signed Cloudflare Access test assertions.

```sh
node --test platform/test/platform.test.mjs
for file in docs/lerp-web/{engine,app}.js platform/src/*.js; do node --check "$file" || exit; done

cd platform
wrangler d1 migrations apply lerping-platform --local
wrangler dev --local
```

## Bindings and security

- Use an account-owned D1 database and **private** R2 bucket; replace the database ID in `wrangler.toml`. Do not enable R2.dev, a public bucket host, public asset aliases, or CDN cache overrides for `/p/*` and `/api/*`.
- Associate the `lerping.app` custom domain. Keep `run_worker_first = true` so neither `/index.html` nor `/lerp-web/editorial.json` can bypass the Worker on this host.
- Configure a Cloudflare Access self-hosted application to cover only `/api/v1/publish`, `/api/v1/nominations`, and `/api/v1/receipts/*`. Require email OTP or an IdP that supplies verified email; do not use Bypass, Service Auth, or an IdP that permits unverified email. Enter the team issuer (`https://<team>.cloudflareaccess.com`) and the application AUD in `wrangler.toml`. The Worker also verifies the RS256 assertion against the team's published public keys, including issuer, audience, time window, application type, and email. Sending an email field in a request does not authenticate it. Reports are anonymous and rate limited.
- Set `ADMIN_TOKEN` with `wrangler secret put ADMIN_TOKEN`; use a separate random base64url token of at least 32 characters. Keep it out of source, browser clients, and logs. Rate-limit namespace IDs must not collide with other bindings in the account.
- Apply the D1 migrations remotely only in the deployment environment. Operator D1/R2 access controls the manual review queue. No deployment or account setup is required to run the tests.

## Routes

References are `<piece|look|playlist>:sha256:<64 lowercase hex>`. IDs are the lowercase SHA-256 of the UTF-8 RFC 8785 canonical v1 record, with no postcard presentation fields in the digest. JSON parsing rejects duplicate members, invalid Unicode, and non-finite numbers. The Mac URL is always `lerp://open/v1/<kind>/<hex>`; it has no query, fragment, or remote URL override.

| Route | Result |
| --- | --- |
| `GET /p/v1/<kind>/<hex>` | Server-rendered still and credits, then enhanced controls; no autoplay. |
| `GET /api/v1/artifacts/<kind>/<hex>` | Exact canonical native record. `?view=postcard` adds presentation, lineage, and media URLs for the browser. |
| `GET /api/v1/blobs/<hex>` | Revocation-gated private R2 bytes. Supports `HEAD` and one byte range for video. A digest alone is not authorization. |
| `GET /api/v1/editorial` | Curated, listed stock cards after withdrawals are filtered. Does not enumerate unlisted works. |
| `POST /api/v1/publish` | Verified artist submits a portable record. |
| `GET /api/v1/receipts/<hex>` | Verified owner reads quarantine/review status. Other users get 404. |
| `POST /api/v1/nominations` | Verified artist submits `{target, note, artist?}` for editorial consideration. |
| `POST /api/v1/reports` | Anonymous `{target, reason}` for a visible work. |
| `POST /api/v1/admin/revocations` | Admin bearer token + `{target, reason}`; target is an artifact or `blob:sha256:<hex>`. |

All JSON writes use `Content-Type: application/json`. Unlisted direct links and their exclusively unlisted bytes carry `X-Robots-Tag: noindex, nofollow`; unlisted is not private. API reads and postcard pages use `Cache-Control: no-store` so previously shared URLs cannot be fulfilled from the Worker/CDN cache after a withdrawal. The revocation query starts at the D1 primary and follows remix and playlist edges. Revoking a work removes bytes owned only by withdrawn works; if the same digest is legitimately shared by an independent live owner, revoke the digest itself to block all uses. Requests already in flight and copies already downloaded (including local stock shaders and the static edition) cannot be recalled. The browser rechecks the hosted artifact before starting playback.

### Publishing and review

Submit a JSON object with these fields:

- `record`: the portable v1 Piece, Look, or Playlist. Pieces have `abi: "lerp-metal-1"`, a `blob:sha256:…` `source`, and an `assets` map. Looks point at an approved `piece:sha256:…`, exact or `null` `preset`, raw `tuning` values, `title` and `authors`; `remixedFrom` may name that Piece or another available Look of the same Piece. Playlists have a `title` and 1–100 unique approved Look refs in order.
- `artist`: `{name, bio?, url?}` to establish the first submission's public profile. URL must be HTTPS. The Access email stays private and subsequent submissions reuse the verified artist.
- `postcard` (optional): `{description?, tags?, still?, video?}`. Tags use `mood`, `motion`, `brightness`, and `medium`. Still/video are SHA-256 hex IDs and allowed only with a new Piece. Use a PNG, JPEG or WebP up to 1 MiB for the still and optionally an MP4 or WebM up to 4 MiB for the clip.
- `uploads` (Piece only): object mapping every source/asset/media SHA-256 to its base64 bytes. Files are independently hashed. The JSON request is capped at 9 MiB, UTF-8 shader source at 512 KiB; do not use this endpoint for large captures. Asset names are the native portable format's fixed allowlist.

A Playlist or parameter-only Look against an approved, explicitly remix-enabled Piece is published immediately, **unlisted**, with `201` and `{state, ref, href}`. A new Piece never publishes directly; `202` returns an opaque receipt and a receipt URL. R2 objects have no serving permission until an approved, visible revision references them. Failed D1 commits can leave inaccessible orphan bytes; periodically audit bucket keys against `blobs` before deleting old orphans (allow an upload-to-commit grace period).

The review queue is `SELECT * FROM artifacts WHERE approval = 'pending' ORDER BY created_at`; review the `revisions.canonical_json` and the `revision_blobs` referenced by the ID via operator-only tools. Reviewers check authorship, asset rights, the actual still, native syntax/data validation and resource budget before approval. Check video dimensions (≤1 MP) and frame rate (≤30 fps); sniffed formats are not a substitute for decoding or native ingress checks. Do not enable remixes unless rights and the parameter schema allow them. Approve with one guarded D1 update, e.g. `UPDATE artifacts SET approval='approved', listing='unlisted', remix_enabled=1 WHERE id=? AND approval='pending';`. Reject via `approval='rejected'` (leave listing private). A change to the approved record must have a new digest, never rewrite `revisions`. Nominations are reviewed separately; they do not change visibility. The landing shelves are intentionally maintained in `docs/lerp-web/editorial.json`, not assembled from the queue.

The stock catalog uses direct addresses over the exact bundled shader sources. These cards are locally resolved by the Mac client; they do not grant public R2 access or automatically opt in to hosted remixes. To accept community remixes against a stock Piece, register its identical portable record and verified source bytes in D1/R2 and review its remix rights through the same approval workflow before enabling remixes. The bundled native provider is required for the stock Gaussian splats; their web stills are cropped from the credited SuperSplat artwork.
