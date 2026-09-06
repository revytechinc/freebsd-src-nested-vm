# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
"""The one path from the store to anything published.

The store holds machine names, absolute paths and free-text notes written for
ourselves.  None of that may appear on the site.  Rather than relying on
whoever writes the next chart to remember that, publication goes through this
module, which builds the document out of a fixed set of fields and then
*re-reads its own output* looking for internal detail and refuses to emit it.

The check is deliberately a check on the finished text, not on the inputs.  A
filter over inputs only catches the leaks it was told about; a scan of the
output catches a note someone pastes into a new field next year.
"""

from __future__ import annotations

import json
import os
import re
from typing import Any

from .store import Reader, utcnow

#: The backstop, not the control.
#:
#: The control is `build_document`, which constructs the published object out
#: of a fixed list of named fields and copies nothing it was not asked for.
#: These patterns exist to catch the case that control cannot: somebody adding
#: a field next year and putting internal text through it.  A pattern list can
#: only ever catch what it was told about, so a new field is still a decision
#: to be made deliberately -- this just makes the common mistakes loud.
FORBIDDEN = [
    (re.compile(r"freedev\d+", re.I), "an internal machine name"),
    (re.compile(r"(?:/usr)?/home/[A-Za-z0-9._-]+"), "a home-directory path"),
    (re.compile(r"/usr/local/bastille"), "an internal jail path"),
    # Any absolute path under a root this project actually uses.  Nothing in
    # the published document is supposed to be a filesystem path at all.
    (re.compile(r"(?<![\w.])/(?:usr|var|tmp|root|zroot|mnt|net|nesteddemo)/"),
     "an absolute filesystem path"),
    (re.compile(r"\b(?:10|127)\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"), "an internal IP"),
    (re.compile(r"\b192\.168\.\d{1,3}\.\d{1,3}\b"), "an internal IP"),
    (re.compile(r"\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b"), "an internal IP"),
    # IPv6: unique-local and link-local.  The fleet is dual-stack, so these
    # are as reachable a leak as the v4 ones.
    (re.compile(r"\b[fF][cCdD][0-9a-fA-F]{2}:[0-9a-fA-F:]{2,}"), "a ULA IPv6 address"),
    (re.compile(r"\b[fF][eE]80:[0-9a-fA-F:]{2,}"), "a link-local IPv6 address"),
]


class LeakError(RuntimeError):
    pass


def scrub_check(text: str) -> None:
    for pat, what in FORBIDDEN:
        m = pat.search(text)
        if m:
            raise LeakError(
                "refusing to publish: %s (%r) appears in the output"
                % (what, m.group(0)))


def build_document(reader: Reader) -> dict[str, Any]:
    """Assemble the public view of the store.

    Machines appear only under their public label.  A machine with no label
    is omitted entirely and counted, so a missing label is visible as a gap
    rather than as an accidental disclosure.
    """
    machines, unlabelled = [], 0
    for h in reader.hosts():
        if not h["public_label"]:
            unlabelled += 1
            continue
        machines.append({
            "label": h["public_label"],
            "cpu_model": h["cpu_model"],
            "cpu_vendor": h["cpu_vendor"],
            "virt_type": h["virt_type"],
            "cores": h["cores"],
            "ram_gb": round(h["ram_bytes"] / (1024 ** 3)) if h["ram_bytes"] else None,
        })

    builds = [{
        "vmm_sha256": b["vmm_sha256"],
        "release_name": b["release_name"],
        "status": b["status"],
        "git_commit": b["git_commit"],
    } for b in reader.builds()]

    # The width sweep, which is what the site's first chart is drawn from.
    ceiling = reader.select(
        "SELECT public_label, sha_prefix, dims, outcome, ts_utc, "
        "       (SELECT value_num FROM measurement m "
        "         WHERE m.run_id = v.run_id AND m.metric = 'boot_secs') AS boot_secs "
        "FROM v_run v WHERE suite = 'core-ceiling' AND public_label IS NOT NULL "
        "ORDER BY public_label, ts_utc")
    series: dict[str, list] = {}
    for row in ceiling:
        dims = json.loads(row["dims"] or "{}")
        series.setdefault(row["public_label"], []).append({
            "vcpus": dims.get("vcpus"),
            "outcome": row["outcome"],
            "boot_secs": row["boot_secs"],
            "build": row["sha_prefix"],
            "ts": row["ts_utc"],
        })

    summary = [
        {k: r[k] for k in ("grp", "runs", "passed", "failed", "panics",
                           "first_run", "last_run")}
        for r in reader.summary(group_by="public_label")
        if r["grp"]
    ]

    return {
        "generated_at": utcnow(),
        "schema": 1,
        "machines": machines,
        "machines_without_public_label": unlabelled,
        "builds": builds,
        "core_ceiling": series,
        "summary_by_machine": summary,
    }


def export_json(reader: Reader, path: str) -> dict:
    """Write the publication document, atomically.

    The file is built beside its destination and renamed into place, so a
    reader never sees a half-written document and a failure part-way through
    leaves the previous good one intact.  Opening the destination directly
    would truncate it before the first byte was written.
    """
    doc = build_document(reader)
    text = json.dumps(doc, indent=2, sort_keys=True)
    scrub_check(text)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w") as fh:
            fh.write(text + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return {"path": path, "bytes": len(text) + 1,
            "machines": len(doc["machines"]),
            "unlabelled": doc["machines_without_public_label"]}
