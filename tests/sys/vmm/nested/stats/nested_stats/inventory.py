# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
"""Turning a fleet home directory into an inventory of data and litter.

`collect-inventory.sh` walks a machine and says what is there; nothing in it
decides what any of it *is*.  That decision lives here, in one place, as an
ordered list of rules, so the policy can be argued with, changed, and
re-applied to old scans without touching a single machine.

Two things are load-bearing:

* `safe_to_remove` is advisory and nothing here deletes anything.  It is an
  opinion recorded next to the evidence for it, so a later cleanup can be
  reviewed instead of trusted.

* Measurement data can never carry it.  The rule that says so is first, and
  the database enforces the same thing with a trigger, because a classifier
  is exactly the kind of code that gets a clever new rule added to it in a
  hurry.
"""

from __future__ import annotations

import os
import re
import time
from typing import Iterator, Optional

from .store import Writer, TOOL_VERSION, utcnow

#: Filenames that are measurement records.  These are the history the store
#: exists to preserve; the classifier is not permitted to call them disposable.
_DATA_NAMES = re.compile(
    r"\A(core-ceiling-|repeat-|perf-ab|bench-on|bench-off|"
    r"many-run|ceiling-run|l2stats-|nested-results)", re.I)

_BUILD_LOG_NAMES = re.compile(
    r"(buildworld|buildkernel|installworld|installkernel|make\.log|"
    r"build[-.]|\.out\Z|bhyve\.log|console\.log|deploy)", re.I)

_RELEASE_ARTIFACT = re.compile(
    r"\.(iso|img|txz|tgz|pkg|xz)\Z|memstick|disc1", re.I)

_DEMO_IMAGE = re.compile(r"(nested-demo.*\.raw|l2\.raw|\A.*\.raw)\Z", re.I)

_CORE_DUMP = re.compile(r"(\.core\Z|\Avmcore\.|\Ainfo\.\d+\Z|\.core\.txt\Z)", re.I)

_SCRIPT = re.compile(r"\.(sh|py|pl|awk|lua|subr)\Z", re.I)


class Classified(dict):
    pass


def _iso(epoch: str) -> Optional[str]:
    try:
        e = int(epoch)
    except (TypeError, ValueError):
        return None
    if e <= 0:
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e))


def classify(path: str, kind: str, hint: str, sha256: Optional[str],
             known_builds: dict) -> Classified:
    """Decide what one entry is, and whether it is arguably disposable.

    `known_builds` maps a full or 16-character vmm sha to the build row it
    belongs to.  It is what lets a stray ``vmm-something.ko`` be called an
    exhausted experiment on the evidence of its own hash rather than on the
    strength of its filename, which is exactly how these accumulate.
    """
    base = os.path.basename(path)
    lower = base.lower()

    # 1. Measurement data.  First, and never removable.
    if kind == "file" and _DATA_NAMES.match(base) and (
            lower.endswith(".log") or lower.endswith(".out")
            or lower.endswith(".tsv") or lower.endswith(".json")):
        return Classified(classification="measurement-data", safe_to_remove=0,
                          reason="a measurement log; this is the historical "
                                 "record the store exists to preserve")
    if kind == "file" and os.sep + "nested-demo" + os.sep in path and lower.endswith(".log"):
        return Classified(classification="measurement-data", safe_to_remove=0,
                          reason="a log under nested-demo/; measurement record")

    # 2. Kernel modules, judged by hash rather than by name.
    if kind == "file" and lower.endswith(".ko"):
        sha = (sha256 or "").strip().lower()
        rec = _match_build(sha, known_builds)
        if rec is None:
            published = known_builds.get("__published__")
            return Classified(
                classification="kernel-module", safe_to_remove=1,
                sha256=sha or None,
                superseded_by=published["build_id"] if published else None,
                reason="its sha256 matches no published or candidate build, so "
                       "it is an experiment that has served its purpose"
                       + (" (superseded by %s)" % published["vmm_sha256"][:16]
                          if published else ""))
        return Classified(
            classification="kernel-module", safe_to_remove=0,
            sha256=sha, build_id=rec["build_id"],
            reason="sha256 matches the %s build %s; keep it"
                   % (rec["status"], rec["vmm_sha256"][:16]))

    # 3. Crash residue.
    if kind == "file" and _CORE_DUMP.search(base):
        return Classified(classification="core-dump", safe_to_remove=1,
                          reason="crash residue; the finding it supported is "
                                 "either written down or lost already")

    # 4. Whole trees, rolled up by the collector.
    if hint == "srctree":
        return Classified(classification="source-tree", safe_to_remove=0,
                          reason="a checked-out tree that may hold unpushed "
                                 "work; confirm it is pushed before removing")
    if hint == "objdir":
        return Classified(classification="objdir", safe_to_remove=1,
                          reason="build output, regenerable by rebuilding")
    if hint == "rolled":
        return Classified(classification="unknown", safe_to_remove=0,
                          reason="below the scan depth; rolled up unexamined")
    if hint == "plain":
        return Classified(classification="unknown", safe_to_remove=0,
                          reason="a container directory; its contents are "
                                 "listed separately")

    # 5. Files, in decreasing order of how sure we can be.
    if kind == "file":
        if _DEMO_IMAGE.search(base):
            return Classified(classification="demo-image", safe_to_remove=0,
                              reason="a guest disk image; large, and possibly "
                                     "the patched one a demo depends on")
        if _RELEASE_ARTIFACT.search(base):
            return Classified(classification="release-artifact", safe_to_remove=0,
                              reason="a release artifact; check it is published "
                                     "before removing the only copy")
        if _BUILD_LOG_NAMES.search(base):
            return Classified(classification="build-log", safe_to_remove=1,
                              reason="build or run output; whatever it describes "
                                     "is either installed or gone")
        if _SCRIPT.search(base):
            return Classified(classification="one-off-script", safe_to_remove=0,
                              reason="small, and may be the only surviving "
                                     "record of how a measurement was taken")
        if lower.endswith(".log"):
            return Classified(classification="build-log", safe_to_remove=1,
                              reason="an unrecognised log; not matched by any "
                                     "measurement-data rule")

    return Classified(classification="unknown", safe_to_remove=0,
                      reason="unrecognised; left alone")


def _match_build(sha: str, known: dict) -> Optional[dict]:
    if not sha:
        return None
    rec = known.get(sha) or known.get(sha[:16])
    if rec and rec.get("status") in ("published", "candidate"):
        return rec
    return rec if rec else None


def known_builds(writer: Writer) -> dict:
    """Index the build table by full sha and by 16-character prefix.

    Also picks out the newest published build under ``__published__``, which
    is what a superseded module is superseded *by*.
    """
    out: dict = {}
    published = None
    for row in writer.conn.execute("SELECT * FROM build ORDER BY first_seen"):
        out[row["vmm_sha256"]] = row
        out[row["sha_prefix"]] = row
        if row["status"] == "published":
            published = row
    if published is not None:
        out["__published__"] = published
    return out


def load_scan(writer: Writer, stream: Iterator[str], host: Optional[str] = None,
              root: Optional[str] = None) -> dict:
    """Read one collector's TSV into a new scan.

    Each call creates a new scan; earlier scans are left alone, so the record
    shows what a machine held last month as well as today and a cleanup can
    afterwards be checked against what it said it would remove.
    """
    builds = known_builds(writer)
    meta_host, meta_root, entries = None, None, []
    errors: list[str] = []

    for lineno, raw in enumerate(stream, 1):
        line = raw.rstrip("\n")
        if not line:
            continue
        if line.startswith("#"):
            parts = line[1:].split("\t", 1)
            if len(parts) == 2:
                if parts[0] == "host":
                    meta_host = parts[1].strip()
                elif parts[0] == "root":
                    meta_root = parts[1].strip()
            continue
        cols = line.split("\t", 5)
        if len(cols) != 6:
            errors.append("line %d: expected 6 columns, got %d" % (lineno, len(cols)))
            continue
        kind, hint, size, mtime, sha, path = cols
        if kind not in ("file", "dir", "symlink", "other"):
            errors.append("line %d: unknown kind %r" % (lineno, kind))
            continue
        entries.append((kind, hint, size, mtime, None if sha == "-" else sha, path))

    host = host or meta_host
    root = root or meta_root or "?"
    if not host:
        raise ValueError("the collector output names no host and none was given")

    host_id = writer.upsert_host(host)
    cur = writer.conn.execute(
        "INSERT INTO inventory_scan (ts_utc, host_id, root, tool_version, notes) "
        "VALUES (?,?,?,?,?)",
        (utcnow(), host_id, root, TOOL_VERSION,
         "; ".join(errors[:5]) if errors else None),
    )
    scan_id = cur.lastrowid

    # A container directory's own size is -1 and is summed from its contents,
    # so totals must not double-count it.
    total = 0
    stored = 0
    for kind, hint, size, mtime, sha, path in entries:
        c = classify(path, kind, hint, sha, builds)
        try:
            size_b = int(size)
        except ValueError:
            size_b = -1
        if size_b >= 0 and hint != "plain":
            total += size_b
        writer.conn.execute(
            "INSERT OR IGNORE INTO inventory_entry "
            "(scan_id, host_id, path, kind, size_bytes, mtime_utc, "
            " classification, sha256, build_id, superseded_by, safe_to_remove, "
            " reason) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (scan_id, host_id, path, kind, None if size_b < 0 else size_b,
             _iso(mtime), c["classification"], c.get("sha256"),
             c.get("build_id"), c.get("superseded_by"),
             c["safe_to_remove"], c["reason"]),
        )
        stored += 1

    writer.conn.execute(
        "UPDATE inventory_scan SET entry_count = ?, total_bytes = ? WHERE scan_id = ?",
        (stored, total, scan_id),
    )
    writer.conn.commit()
    return {"scan_id": scan_id, "host": host, "root": root,
            "entries": stored, "total_bytes": total, "errors": errors}
