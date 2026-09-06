# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
"""Connection handling and the read/write API over the measurement store.

The read path and the write path are separate objects on purpose.  `Reader`
opens the database with SQLite's ``mode=ro`` URI flag, so a query tool cannot
write even by accident and cannot be talked into writing by a crafted
argument; `Writer` is the only thing that opens it read-write.  The MCP server
hands its query tools a `Reader` and its one recording tool a `Writer`, which
is what makes "read-only query paths" a property of the process rather than a
promise in a docstring.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import time
from typing import Any, Iterable, Mapping, Optional, Sequence

TOOL_VERSION = "1.0"

#: Where the store lives by default.  Deliberately outside every jail root and
#: therefore unreachable from the web server; see README.md.
DEFAULT_DB = os.environ.get("NESTED_STATS_DB", "/var/db/nested-stats/nested-stats.db")

_SCHEMA = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "schema.sql")

_HEX16 = re.compile(r"\A[0-9a-f]{16,64}\Z")


def utcnow() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class StoreError(RuntimeError):
    pass


class AmbiguousBuild(StoreError):
    """A short vmm sha matched more than one build.

    Never resolved by picking the first: a wrong build identity attached to a
    result is exactly the failure this database is built to prevent.
    """


def _row_factory(cursor: sqlite3.Cursor, row: tuple) -> dict:
    return {d[0]: row[i] for i, d in enumerate(cursor.description)}


class _Base:
    def __init__(self, conn: sqlite3.Connection):
        self.conn = conn
        self.conn.row_factory = _row_factory

    def close(self) -> None:
        self.conn.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


class Reader(_Base):
    """Read-only view of the store."""

    @classmethod
    def open(cls, path: str = DEFAULT_DB) -> "Reader":
        uri = "file:" + _uri_escape(os.path.abspath(path)) + "?mode=ro"
        conn = sqlite3.connect(uri, uri=True, timeout=10)
        return cls(conn)

    # -- generic ---------------------------------------------------------
    def select(self, sql: str, params: Sequence = ()) -> list[dict]:
        return list(self.conn.execute(sql, params))

    def select_guarded(self, sql: str, limit: int = 500) -> list[dict]:
        """Run an ad-hoc SELECT.

        The connection is already read-only, so this cannot mutate anything.
        The extra checks here are about keeping the *result* sane and the
        failure mode obvious: one statement, and a bounded row count.
        """
        stripped = sql.strip().rstrip(";").strip()
        if ";" in stripped:
            raise StoreError("one statement only")
        head = stripped.lstrip("(").split(None, 1)[0].lower() if stripped else ""
        if head not in ("select", "with"):
            raise StoreError("only SELECT/WITH queries are accepted here")
        cur = self.conn.execute(stripped)
        return cur.fetchmany(limit)

    # -- domain queries --------------------------------------------------
    def hosts(self) -> list[dict]:
        return self.select("SELECT * FROM host ORDER BY name")

    def builds(self) -> list[dict]:
        return self.select("SELECT * FROM build ORDER BY first_seen")

    def runs(
        self,
        host: Optional[str] = None,
        build: Optional[str] = None,
        suite: Optional[str] = None,
        outcome: Optional[str] = None,
        since: Optional[str] = None,
        until: Optional[str] = None,
        limit: int = 200,
    ) -> list[dict]:
        where, params = [], []
        if host:
            where.append("(host = ? OR public_label = ?)")
            params += [host, host]
        if build:
            where.append("(vmm_sha256 = ? OR sha_prefix = ? OR release_name = ?)")
            params += [build, build[:16], build]
        if suite:
            where.append("suite = ?")
            params.append(suite)
        if outcome:
            where.append("outcome = ?")
            params.append(outcome)
        if since:
            where.append("ts_utc >= ?")
            params.append(since)
        if until:
            where.append("ts_utc <= ?")
            params.append(until)
        sql = "SELECT * FROM v_run"
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY ts_utc DESC, run_id DESC LIMIT ?"
        params.append(max(1, min(int(limit), 5000)))
        return self.select(sql, params)

    def measurements_for(self, run_ids: Iterable[int]) -> list[dict]:
        ids = list(run_ids)
        if not ids:
            return []
        marks = ",".join("?" * len(ids))
        return self.select(
            "SELECT run_id, metric, value_num, unit, value_text "
            f"FROM measurement WHERE run_id IN ({marks}) ORDER BY run_id, metric",
            ids,
        )

    def summary(
        self,
        group_by: str = "host",
        suite: Optional[str] = None,
        build: Optional[str] = None,
    ) -> list[dict]:
        """Counts and pass rate, grouped by one of a fixed set of columns.

        `group_by` is checked against a whitelist rather than interpolated,
        because it is the one part of this query that cannot be a bind
        parameter.
        """
        allowed = {
            "host": "host",
            "public_label": "public_label",
            "build": "sha_prefix",
            "suite": "suite",
            "outcome": "outcome",
            "day": "substr(ts_utc, 1, 10)",
        }
        if group_by not in allowed:
            raise StoreError(
                "group_by must be one of: " + ", ".join(sorted(allowed))
            )
        col = allowed[group_by]
        where, params = [], []
        if suite:
            where.append("suite = ?")
            params.append(suite)
        if build:
            where.append("(vmm_sha256 = ? OR sha_prefix = ?)")
            params += [build, build[:16]]
        sql = (
            f"SELECT {col} AS grp, COUNT(*) AS runs, "
            "SUM(CASE WHEN outcome = 'PASS' THEN 1 ELSE 0 END) AS passed, "
            "SUM(CASE WHEN outcome LIKE 'FAIL%' THEN 1 ELSE 0 END) AS failed, "
            "SUM(CASE WHEN outcome = 'HOST-PANIC' THEN 1 ELSE 0 END) AS panics, "
            "MIN(ts_utc) AS first_run, MAX(ts_utc) AS last_run "
            "FROM v_run"
        )
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " GROUP BY grp ORDER BY grp"
        return self.select(sql, params)

    def inventory(
        self,
        host: Optional[str] = None,
        classification: Optional[str] = None,
        safe_to_remove: Optional[bool] = None,
        min_bytes: int = 0,
        limit: int = 500,
    ) -> list[dict]:
        where, params = ["1=1"], []
        if host:
            where.append("host = ?")
            params.append(host)
        if classification:
            where.append("classification = ?")
            params.append(classification)
        if safe_to_remove is not None:
            where.append("safe_to_remove = ?")
            params.append(1 if safe_to_remove else 0)
        if min_bytes:
            where.append("COALESCE(size_bytes, 0) >= ?")
            params.append(int(min_bytes))
        params.append(max(1, min(int(limit), 5000)))
        return self.select(
            "SELECT host, path, kind, size_bytes, mtime_utc, classification, "
            "sha256, safe_to_remove, reason, scanned_at "
            "FROM v_inventory_current WHERE " + " AND ".join(where) +
            " ORDER BY COALESCE(size_bytes,0) DESC LIMIT ?",
            params,
        )


class Writer(_Base):
    """The only path that writes."""

    @classmethod
    def open(cls, path: str = DEFAULT_DB, create: bool = False) -> "Writer":
        path = os.path.abspath(path)
        if create:
            os.makedirs(os.path.dirname(path), exist_ok=True)
        elif not os.path.exists(path):
            raise StoreError(f"{path} does not exist; run `nsdb init` first")
        conn = sqlite3.connect(path, timeout=30)
        conn.execute("PRAGMA foreign_keys = ON")
        return cls(conn)

    def init_schema(self) -> None:
        with open(os.path.normpath(_SCHEMA), "r") as fh:
            self.conn.executescript(fh.read())
        self.conn.commit()

    # -- dimensions ------------------------------------------------------
    def upsert_host(self, name: str, **fields: Any) -> int:
        """Register or refresh a machine profile.

        Profiles are the one thing that may change in place: they describe the
        machine now.  Runs keep their own snapshot of cpu/cores/ram precisely
        so that refreshing a profile cannot rewrite a past result.
        """
        row = self.conn.execute(
            "SELECT host_id FROM host WHERE name = ?", (name,)
        ).fetchone()
        cols = ("public_label", "cpu_model", "cpu_vendor", "virt_type",
                "cores", "ram_bytes", "notes")
        if row is None:
            vals = [fields.get(c) for c in cols]
            cur = self.conn.execute(
                "INSERT INTO host (name, %s, first_seen) VALUES (?, %s, ?)"
                % (", ".join(cols), ", ".join("?" * len(cols))),
                [name] + vals + [utcnow()],
            )
            self.conn.commit()
            return cur.lastrowid
        given = [(c, fields[c]) for c in cols if fields.get(c) is not None]
        if given:
            self.conn.execute(
                "UPDATE host SET " + ", ".join(f"{c} = ?" for c, _ in given) +
                " WHERE host_id = ?",
                [v for _, v in given] + [row["host_id"]],
            )
            self.conn.commit()
        return row["host_id"]

    def upsert_build(self, vmm_sha256: str, **fields: Any) -> int:
        sha = vmm_sha256.strip().lower()
        if not _HEX16.match(sha):
            raise StoreError(
                "vmm sha must be 16-64 lowercase hex characters, got %r" % vmm_sha256
            )
        existing = self._find_build(sha)
        cols = ("git_commit", "git_branch", "kernel_ident", "kernel_sha256",
                "release_name", "status", "notes")
        if existing is None:
            vals = [fields.get(c) for c in cols]
            if vals[cols.index("status")] is None:
                vals[cols.index("status")] = "unknown"
            cur = self.conn.execute(
                "INSERT INTO build (vmm_sha256, sha_prefix, %s, first_seen) "
                "VALUES (?, ?, %s, ?)" % (", ".join(cols), ", ".join("?" * len(cols))),
                [sha, sha[:16]] + vals + [utcnow()],
            )
            self.conn.commit()
            return cur.lastrowid
        # A full sha arriving for a build first seen as a prefix upgrades the
        # identity in place; that is a completion of the same fact, not a
        # change of it.
        if len(sha) > len(existing["vmm_sha256"]) and sha.startswith(existing["vmm_sha256"]):
            self.conn.execute(
                "UPDATE build SET vmm_sha256 = ? WHERE build_id = ?",
                (sha, existing["build_id"]),
            )
        given = [(c, fields[c]) for c in cols if fields.get(c) is not None]
        if given:
            self.conn.execute(
                "UPDATE build SET " + ", ".join(f"{c} = ?" for c, _ in given) +
                " WHERE build_id = ?",
                [v for _, v in given] + [existing["build_id"]],
            )
        self.conn.commit()
        return existing["build_id"]

    def _find_build(self, sha: str) -> Optional[dict]:
        rows = self.conn.execute(
            "SELECT * FROM build WHERE sha_prefix = ?", (sha[:16],)
        ).fetchall()
        if not rows:
            return None
        if len(rows) > 1:
            raise AmbiguousBuild(
                "%s matches %d builds: %s"
                % (sha, len(rows), ", ".join(r["vmm_sha256"] for r in rows))
            )
        return rows[0]

    def open_batch(self, argv: str, notes: str = "") -> int:
        cur = self.conn.execute(
            "INSERT INTO ingest_batch (ts_utc, tool_version, invoked_by, argv, notes) "
            "VALUES (?, ?, ?, ?, ?)",
            (utcnow(), TOOL_VERSION, os.environ.get("USER", "?"), argv, notes),
        )
        self.conn.commit()
        return cur.lastrowid

    # -- facts -----------------------------------------------------------
    def record_run(
        self,
        ts_utc: str,
        host: str,
        vmm_sha256: str,
        suite: str,
        outcome: Optional[str] = None,
        dims: Optional[Mapping[str, Any]] = None,
        measurements: Optional[Sequence[Mapping[str, Any]]] = None,
        source: Optional[str] = None,
        source_line: Optional[int] = None,
        content_key: Optional[str] = None,
        batch_id: Optional[int] = None,
        notes: Optional[str] = None,
    ) -> Optional[int]:
        """Insert one run and its measurements.

        Returns the new run_id, or None when `content_key` says this exact
        source line has already been ingested.  Nothing is ever updated.
        """
        host_id = self.upsert_host(host)
        build_id = self.upsert_build(vmm_sha256)
        prof = self.conn.execute(
            "SELECT cpu_model, cores, ram_bytes FROM host WHERE host_id = ?",
            (host_id,),
        ).fetchone()
        key = content_key or content_key_for(
            host, suite, source or "", source_line, ts_utc, json.dumps(dims or {}, sort_keys=True)
        )
        try:
            cur = self.conn.execute(
                "INSERT INTO run (ts_utc, host_id, build_id, suite, outcome, dims, "
                "cpu_model, cores, ram_bytes, source, source_line, content_key, "
                "ingested_at, batch_id, notes) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (ts_utc, host_id, build_id, suite, outcome,
                 json.dumps(dims, sort_keys=True) if dims else None,
                 prof["cpu_model"], prof["cores"], prof["ram_bytes"],
                 source, source_line, key, utcnow(), batch_id, notes),
            )
        except sqlite3.IntegrityError as exc:
            if "content_key" in str(exc):
                return None
            raise
        run_id = cur.lastrowid
        for m in measurements or ():
            self.conn.execute(
                "INSERT INTO measurement (run_id, metric, value_num, unit, "
                "value_text, notes) VALUES (?,?,?,?,?,?)",
                (run_id, m["metric"], m.get("value_num"), m.get("unit"),
                 m.get("value_text"), m.get("notes")),
            )
        self.conn.commit()
        return run_id


def content_key_for(*parts: Any) -> str:
    """Stable identity for one ingested source line.

    Includes the source file's mtime and size (the caller folds them into
    `source`), so replaying an unchanged file is a no-op while a genuine re-run
    that rewrites the file produces new rows rather than being swallowed as a
    duplicate.
    """
    h = hashlib.sha256()
    for p in parts:
        h.update(str(p).encode("utf-8", "replace"))
        h.update(b"\x1f")
    return h.hexdigest()


def _uri_escape(path: str) -> str:
    return path.replace("?", "%3f").replace("#", "%23")
