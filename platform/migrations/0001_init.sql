CREATE TABLE artists (
  id TEXT PRIMARY KEY,
  verified_email TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  bio TEXT,
  url TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE artifacts (
  id TEXT PRIMARY KEY CHECK(length(id) = 64 AND id NOT GLOB '*[^0-9a-f]*'),
  kind TEXT NOT NULL CHECK(kind IN ('piece', 'look', 'playlist')),
  artist_id TEXT NOT NULL REFERENCES artists(id),
  approval TEXT NOT NULL CHECK(approval IN ('pending', 'approved', 'rejected')),
  listing TEXT NOT NULL CHECK(listing IN ('private', 'unlisted', 'listed')),
  remix_enabled INTEGER NOT NULL DEFAULT 0 CHECK(remix_enabled IN (0, 1)),
  title TEXT NOT NULL,
  description TEXT,
  tags TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(tags) AND json_type(tags) = 'object'),
  receipt TEXT UNIQUE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK(approval = 'approved' OR listing = 'private'),
  CHECK(remix_enabled = 0 OR (kind = 'piece' AND approval = 'approved'))
) STRICT;
CREATE INDEX review_queue ON artifacts(created_at) WHERE approval = 'pending';

-- The artifact ID is its exact revision digest. Changes create a new artifact,
-- not a silent update to the record behind a shared postcard.
CREATE TABLE revisions (
  id TEXT PRIMARY KEY REFERENCES artifacts(id),
  canonical_json TEXT NOT NULL CHECK(json_valid(canonical_json))
) STRICT;
CREATE TRIGGER immutable_revision_update BEFORE UPDATE ON revisions BEGIN
  SELECT RAISE(ABORT, 'revisions are immutable');
END;
CREATE TRIGGER immutable_revision_delete BEFORE DELETE ON revisions BEGIN
  SELECT RAISE(ABORT, 'revisions are immutable');
END;

CREATE TABLE lineage (
  artifact_id TEXT NOT NULL REFERENCES revisions(id),
  target_id TEXT NOT NULL REFERENCES revisions(id),
  relation TEXT NOT NULL CHECK(relation IN ('remix_of', 'contains')),
  position INTEGER NOT NULL DEFAULT 0 CHECK(position >= 0),
  PRIMARY KEY(artifact_id, relation, position),
  UNIQUE(artifact_id, relation, target_id),
  CHECK(artifact_id <> target_id)
) STRICT;
CREATE INDEX lineage_target ON lineage(target_id);

CREATE TABLE blobs (
  sha256 TEXT PRIMARY KEY CHECK(length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
  size INTEGER NOT NULL CHECK(size > 0)
) STRICT;
CREATE TABLE revision_blobs (
  artifact_id TEXT NOT NULL REFERENCES revisions(id),
  sha256 TEXT NOT NULL REFERENCES blobs(sha256),
  role TEXT NOT NULL,
  content_type TEXT NOT NULL,
  PRIMARY KEY(artifact_id, role)
) STRICT;
CREATE INDEX blob_references ON revision_blobs(sha256, artifact_id);

CREATE TABLE nominations (
  artist_id TEXT NOT NULL REFERENCES artists(id),
  target TEXT NOT NULL,
  note TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'new' CHECK(state IN ('new', 'accepted', 'declined')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY(artist_id, target)
) STRICT;

CREATE TABLE reports (
  id TEXT PRIMARY KEY,
  target TEXT NOT NULL,
  reason TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'new' CHECK(state IN ('new', 'resolved')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE revocations (
  target TEXT PRIMARY KEY,
  reason TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

-- Dirty roots include directly revoked artifacts and every owner of explicitly
-- revoked bytes. Follow incoming lineage edges so dependent works stop too.
CREATE VIEW withdrawn_artifacts AS
  WITH RECURSIVE withdrawn(id) AS (
    SELECT a.id FROM artifacts a JOIN revocations k ON k.target = a.kind || ':sha256:' || a.id
    UNION
    SELECT b.artifact_id FROM revision_blobs b JOIN revocations k ON k.target = 'blob:sha256:' || b.sha256
    UNION
    SELECT l.artifact_id FROM lineage l JOIN withdrawn w ON l.target_id = w.id
  ) SELECT id FROM withdrawn;

CREATE VIEW public_artifacts AS
  WITH RECURSIVE hidden(id) AS (
    SELECT id FROM artifacts WHERE approval <> 'approved' OR listing = 'private'
    UNION
    SELECT id FROM withdrawn_artifacts
    UNION
    SELECT l.artifact_id FROM lineage l JOIN hidden h ON l.target_id = h.id
  ) SELECT a.* FROM artifacts a WHERE a.id NOT IN (SELECT id FROM hidden);
