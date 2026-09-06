-- Copyright (c) 2026 REVYTECH, Inc.
-- SPDX-License-Identifier: BSD-2-Clause
--
-- Durable store for nested-virtualization measurements.
--
-- Two properties are enforced here rather than left to convention, because
-- both have been violated by hand in the past and neither failure is visible
-- afterwards:
--
--   1. Results are append-only.  A re-run inserts a new row; nothing ever
--      updates or deletes one.  UPDATE and DELETE triggers abort, so a
--      published figure can always be traced back to the run that produced it
--      even if a later run disagrees.
--
--   2. Every result names the build it was measured against.  A change to
--      shared vmm code voids every prior pass on every machine, so a number
--      without its vmm.ko is not a weaker result, it is not a result at all.
--      run.build_id is NOT NULL for that reason.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------

-- The machine.  `name` is the internal identifier; `public_label` is the
-- anonymised name the website is allowed to print.  Nothing exported for
-- publication may carry `name`.
CREATE TABLE IF NOT EXISTS host (
    host_id      INTEGER PRIMARY KEY,
    name         TEXT    NOT NULL UNIQUE,
    public_label TEXT,
    cpu_model    TEXT,
    cpu_vendor   TEXT,
    virt_type    TEXT,
    cores        INTEGER,
    ram_bytes    INTEGER,
    notes        TEXT,
    first_seen   TEXT    NOT NULL
);

-- The build under test.  Identity is the sha256 of vmm.ko.  Logs in the wild
-- carry only the leading 16 hex characters, so `sha_prefix` is materialised
-- and indexed and lookups resolve through it; a prefix that matches more than
-- one build is an error, never a silent pick.
CREATE TABLE IF NOT EXISTS build (
    build_id      INTEGER PRIMARY KEY,
    vmm_sha256    TEXT    NOT NULL UNIQUE,
    sha_prefix    TEXT    NOT NULL,
    git_commit    TEXT,
    git_branch    TEXT,
    kernel_ident  TEXT,
    kernel_sha256 TEXT,
    release_name  TEXT,
    status        TEXT    NOT NULL DEFAULT 'unknown'
                  CHECK (status IN ('published', 'candidate', 'experiment',
                                    'superseded', 'unknown')),
    notes         TEXT,
    first_seen    TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS build_sha_prefix ON build (sha_prefix);

-- One ingest invocation.  Rows point back at it so a bad parser can be found
-- and its output identified without guessing.
--
-- `argv` records the command line, which in practice contains absolute paths
-- naming machines.  That is internal provenance and is deliberately kept: the
-- database is not web-reachable.  It must never be exported -- publication
-- builds its document from a fixed field list that does not include this
-- table, and would refuse the paths anyway.
CREATE TABLE IF NOT EXISTS ingest_batch (
    batch_id     INTEGER PRIMARY KEY,
    ts_utc       TEXT    NOT NULL,
    tool_version TEXT    NOT NULL,
    invoked_by   TEXT,
    argv         TEXT,
    notes        TEXT
);

-- ---------------------------------------------------------------------------
-- Facts
-- ---------------------------------------------------------------------------

-- One measured run: one host, one build, one moment, one outcome.
--
-- cpu_model / cores / ram_bytes are copied from the host profile at record
-- time rather than joined at read time.  Machines get RAM added and CPUs
-- swapped; a run must keep saying what the machine was on the day, not what
-- it is now.
--
-- content_key makes re-ingesting the same log file idempotent without ever
-- updating a row.  It hashes the host, the suite, the source file's identity
-- *including its mtime and size*, and the line itself: replaying yesterday's
-- file inserts nothing, while a genuine re-run that rewrites the file with
-- the same text at a new mtime inserts new rows.
CREATE TABLE IF NOT EXISTS run (
    run_id       INTEGER PRIMARY KEY,
    ts_utc       TEXT    NOT NULL,
    host_id      INTEGER NOT NULL REFERENCES host (host_id),
    build_id     INTEGER NOT NULL REFERENCES build (build_id),
    suite        TEXT    NOT NULL,
    outcome      TEXT    CHECK (outcome IS NULL OR outcome IN
                                ('PASS', 'FAIL', 'FAIL-VMENTRY', 'FAIL-TIMEOUT',
                                 'HOST-PANIC', 'SKIP')),
    dims         TEXT,
    cpu_model    TEXT,
    cores        INTEGER,
    ram_bytes    INTEGER,
    source       TEXT,
    source_line  INTEGER,
    content_key  TEXT    NOT NULL UNIQUE,
    ingested_at  TEXT    NOT NULL,
    batch_id     INTEGER REFERENCES ingest_batch (batch_id),
    notes        TEXT
);
CREATE INDEX IF NOT EXISTS run_host_ts  ON run (host_id, ts_utc);
CREATE INDEX IF NOT EXISTS run_build    ON run (build_id);
CREATE INDEX IF NOT EXISTS run_suite_ts ON run (suite, ts_utc);

-- The numbers a run produced.  A run may produce several (bench.sh emits five
-- per line); value_text carries readings that are deliberately not numeric,
-- such as a read figure labelled cache-warm, so an unmeasurable value is
-- recorded as unmeasurable instead of as a zero.
CREATE TABLE IF NOT EXISTS measurement (
    measurement_id INTEGER PRIMARY KEY,
    run_id         INTEGER NOT NULL REFERENCES run (run_id),
    metric         TEXT    NOT NULL,
    value_num      REAL,
    unit           TEXT,
    value_text     TEXT,
    notes          TEXT
);
CREATE INDEX IF NOT EXISTS measurement_run    ON measurement (run_id);
CREATE INDEX IF NOT EXISTS measurement_metric ON measurement (metric);

-- Append-only, enforced.  Correcting a wrong row means recording a new run
-- that supersedes it and saying so in notes -- never editing the old one.
CREATE TRIGGER IF NOT EXISTS run_no_update
    BEFORE UPDATE ON run
    BEGIN SELECT RAISE(ABORT, 'run is append-only: record a new run instead'); END;
CREATE TRIGGER IF NOT EXISTS run_no_delete
    BEFORE DELETE ON run
    BEGIN SELECT RAISE(ABORT, 'run is append-only: rows are never deleted'); END;
CREATE TRIGGER IF NOT EXISTS measurement_no_update
    BEFORE UPDATE ON measurement
    BEGIN SELECT RAISE(ABORT, 'measurement is append-only'); END;
CREATE TRIGGER IF NOT EXISTS measurement_no_delete
    BEFORE DELETE ON measurement
    BEGIN SELECT RAISE(ABORT, 'measurement is append-only'); END;

-- ---------------------------------------------------------------------------
-- Inventory: what is lying around on the fleet, and which of it is data
-- ---------------------------------------------------------------------------

-- Scans are append-only in the same sense: each scan inserts a fresh set of
-- rows, so the record shows what was on a machine in March as well as today,
-- and a later cleanup can be checked against what it claimed to remove.
CREATE TABLE IF NOT EXISTS inventory_scan (
    scan_id      INTEGER PRIMARY KEY,
    ts_utc       TEXT    NOT NULL,
    host_id      INTEGER NOT NULL REFERENCES host (host_id),
    root         TEXT    NOT NULL,
    tool_version TEXT    NOT NULL,
    entry_count  INTEGER NOT NULL DEFAULT 0,
    total_bytes  INTEGER NOT NULL DEFAULT 0,
    notes        TEXT
);

-- One work product.  Source trees and object directories are rolled up to a
-- single entry with their total size and never descended into: at a million
-- files per host the per-file detail is noise, and the question being asked
-- is "is this whole thing worth keeping", not "which .o is biggest".
--
-- safe_to_remove is ADVISORY.  Nothing in this tool deletes anything.  It is
-- a considered opinion recorded with its `reason`, so a human cleanup can be
-- argued with rather than trusted.  Measurement data can never carry it.
CREATE TABLE IF NOT EXISTS inventory_entry (
    entry_id       INTEGER PRIMARY KEY,
    scan_id        INTEGER NOT NULL REFERENCES inventory_scan (scan_id),
    host_id        INTEGER NOT NULL REFERENCES host (host_id),
    path           TEXT    NOT NULL,
    kind           TEXT    NOT NULL CHECK (kind IN ('file', 'dir', 'symlink', 'other')),
    size_bytes     INTEGER,
    mtime_utc      TEXT,
    classification TEXT    NOT NULL CHECK (classification IN (
                       'measurement-data', 'build-log', 'kernel-module',
                       'core-dump', 'one-off-script', 'source-tree', 'objdir',
                       'release-artifact', 'demo-image', 'unknown')),
    sha256         TEXT,
    build_id       INTEGER REFERENCES build (build_id),
    superseded_by  INTEGER REFERENCES build (build_id),
    safe_to_remove INTEGER NOT NULL DEFAULT 0 CHECK (safe_to_remove IN (0, 1)),
    reason         TEXT    NOT NULL,
    UNIQUE (scan_id, path)
);
CREATE INDEX IF NOT EXISTS inv_scan  ON inventory_entry (scan_id);
CREATE INDEX IF NOT EXISTS inv_class ON inventory_entry (classification);
CREATE INDEX IF NOT EXISTS inv_sha   ON inventory_entry (sha256);

-- The one invariant that must not be violated by a future classifier change:
-- the logs this database exists to preserve are never advertised as disposable.
CREATE TRIGGER IF NOT EXISTS inv_data_never_removable_ins
    AFTER INSERT ON inventory_entry
    WHEN NEW.classification = 'measurement-data' AND NEW.safe_to_remove = 1
    BEGIN SELECT RAISE(ABORT, 'measurement-data may never be flagged safe_to_remove'); END;

-- The same invariant on the other edge.  An INSERT trigger alone would let
-- `UPDATE ... SET safe_to_remove = 1`, or a reclassification of an already-
-- flagged row to measurement-data, walk straight past it.
CREATE TRIGGER IF NOT EXISTS inv_data_never_removable_upd
    AFTER UPDATE ON inventory_entry
    WHEN NEW.classification = 'measurement-data' AND NEW.safe_to_remove = 1
    BEGIN SELECT RAISE(ABORT, 'measurement-data may never be flagged safe_to_remove'); END;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

CREATE VIEW IF NOT EXISTS v_run AS
SELECT r.run_id, r.ts_utc, h.name AS host, h.public_label, r.suite, r.outcome,
       r.dims, r.cpu_model, r.cores, r.ram_bytes,
       b.vmm_sha256, b.sha_prefix, b.release_name, b.status AS build_status,
       b.git_commit, r.source, r.source_line, r.notes
FROM run r
JOIN host  h ON h.host_id  = r.host_id
JOIN build b ON b.build_id = r.build_id;

CREATE VIEW IF NOT EXISTS v_measurement AS
SELECT m.measurement_id, v.*, m.metric, m.value_num, m.unit, m.value_text
FROM measurement m
JOIN v_run v ON v.run_id = m.run_id;

-- Newest scan per host, so "what is on the fleet now" is one query and the
-- older scans stay available for "what did we have in March".
CREATE VIEW IF NOT EXISTS v_inventory_current AS
SELECT e.*, h.name AS host, s.ts_utc AS scanned_at
FROM inventory_entry e
JOIN inventory_scan  s ON s.scan_id = e.scan_id
JOIN host            h ON h.host_id = e.host_id
WHERE s.scan_id = (SELECT MAX(s2.scan_id) FROM inventory_scan s2
                   WHERE s2.host_id = e.host_id);
