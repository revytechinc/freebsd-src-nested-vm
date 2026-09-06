# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
"""Command-line front end: ``python3 -m nested_stats.cli <command>``.

Everything the MCP server can do is reachable here too, and by the same code
paths, so the store can be driven by hand on the machine when an agent is not
in the loop -- which is the standing requirement for every measurement tool in
this project.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

from . import export as export_mod
from . import ingest as ingest_mod
from . import inventory as inv_mod
from .store import DEFAULT_DB, Reader, Writer, StoreError


def _out(obj) -> None:
    json.dump(obj, sys.stdout, indent=2, sort_keys=True, default=str)
    sys.stdout.write("\n")


def cmd_init(a):
    with Writer.open(a.db, create=True) as w:
        w.init_schema()
    _out({"initialised": os.path.abspath(a.db)})


def cmd_seed(a):
    """Load machine profiles and build identities from a JSON file.

    This file is the only place fleet-specific facts live.  It is kept off the
    machine that holds the source, because the source repository is public and
    machine names are not.
    """
    with open(a.file) as fh:
        cfg = json.load(fh)
    counts = {"hosts": 0, "builds": 0}
    with Writer.open(a.db) as w:
        for h in cfg.get("hosts", []):
            w.upsert_host(h.pop("name"), **h)
            counts["hosts"] += 1
        for b in cfg.get("builds", []):
            w.upsert_build(b.pop("vmm_sha256"), **b)
            counts["builds"] += 1
    _out(counts)


def cmd_ingest(a):
    results = []
    with Writer.open(a.db) as w:
        batch = w.open_batch(" ".join(sys.argv[1:]), a.notes or "")
        for path in a.paths:
            if not os.path.isfile(path):
                results.append({"path": path, "errors": ["not a file"]})
                continue
            results.append(ingest_mod.ingest_file(
                w, path, host=a.host, vmm=a.vmm, batch_id=batch,
                dry_run=a.dry_run))
    total = {
        "inserted": sum(r.get("inserted", 0) for r in results),
        "duplicate": sum(r.get("duplicate", 0) for r in results),
        "errors": sum(len(r.get("errors", ())) for r in results),
    }
    _out({"files": results, "totals": total})
    return 0 if total["errors"] == 0 else 1


def cmd_record(a):
    dims = json.loads(a.dims) if a.dims else None
    meas = json.loads(a.measurements) if a.measurements else None
    with Writer.open(a.db) as w:
        run_id = w.record_run(
            ts_utc=a.ts, host=a.host, vmm_sha256=a.vmm, suite=a.suite,
            outcome=a.outcome, dims=dims, measurements=meas, notes=a.notes,
            source=a.source)
    _out({"run_id": run_id, "duplicate": run_id is None})


def cmd_inv_load(a):
    stream = sys.stdin if a.file == "-" else open(a.file)
    try:
        with Writer.open(a.db) as w:
            _out(inv_mod.load_scan(w, stream, host=a.host))
    finally:
        if stream is not sys.stdin:
            stream.close()


def cmd_query(a):
    with Reader.open(a.db) as r:
        rows = r.runs(host=a.host, build=a.build, suite=a.suite,
                      outcome=a.outcome, since=a.since, until=a.until,
                      limit=a.limit)
        if a.with_measurements:
            byrun: dict = {}
            for m in r.measurements_for(x["run_id"] for x in rows):
                byrun.setdefault(m["run_id"], []).append(m)
            for row in rows:
                row["measurements"] = byrun.get(row["run_id"], [])
        _out(rows)


def cmd_summary(a):
    with Reader.open(a.db) as r:
        _out(r.summary(group_by=a.group_by, suite=a.suite, build=a.build))


def cmd_inv_list(a):
    safe = None if a.safe_to_remove is None else bool(int(a.safe_to_remove))
    with Reader.open(a.db) as r:
        _out(r.inventory(host=a.host, classification=a.classification,
                         safe_to_remove=safe, min_bytes=a.min_bytes,
                         limit=a.limit))


def cmd_sql(a):
    with Reader.open(a.db) as r:
        _out(r.select_guarded(a.query, limit=a.limit))


def cmd_export(a):
    with Reader.open(a.db) as r:
        _out(export_mod.export_json(r, a.out))


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="nsdb",
                                description="nested-virt measurement store")
    p.add_argument("--db", default=DEFAULT_DB)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init").set_defaults(fn=cmd_init)

    s = sub.add_parser("seed", help="load machine and build facts from JSON")
    s.add_argument("file")
    s.set_defaults(fn=cmd_seed)

    s = sub.add_parser("ingest", help="read fleet log files into the store")
    s.add_argument("paths", nargs="+")
    s.add_argument("--host")
    s.add_argument("--vmm", help="vmm.ko sha for formats that name none")
    s.add_argument("--notes")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_ingest)

    s = sub.add_parser("record", help="record one run by hand")
    s.add_argument("--ts", required=True)
    s.add_argument("--host", required=True)
    s.add_argument("--vmm", required=True)
    s.add_argument("--suite", required=True)
    s.add_argument("--outcome")
    s.add_argument("--dims", help="JSON object")
    s.add_argument("--measurements", help="JSON array")
    s.add_argument("--source")
    s.add_argument("--notes")
    s.set_defaults(fn=cmd_record)

    s = sub.add_parser("inventory-load", help="load collector TSV")
    s.add_argument("file", help="path or - for stdin")
    s.add_argument("--host")
    s.set_defaults(fn=cmd_inv_load)

    s = sub.add_parser("inventory", help="list the current inventory")
    s.add_argument("--host")
    s.add_argument("--classification")
    s.add_argument("--safe-to-remove", dest="safe_to_remove")
    s.add_argument("--min-bytes", type=int, default=0)
    s.add_argument("--limit", type=int, default=200)
    s.set_defaults(fn=cmd_inv_list)

    s = sub.add_parser("query", help="query runs")
    s.add_argument("--host")
    s.add_argument("--build")
    s.add_argument("--suite")
    s.add_argument("--outcome")
    s.add_argument("--since")
    s.add_argument("--until")
    s.add_argument("--limit", type=int, default=100)
    s.add_argument("--with-measurements", action="store_true")
    s.set_defaults(fn=cmd_query)

    s = sub.add_parser("summary")
    s.add_argument("--group-by", default="host")
    s.add_argument("--suite")
    s.add_argument("--build")
    s.set_defaults(fn=cmd_summary)

    s = sub.add_parser("sql", help="ad-hoc read-only SELECT")
    s.add_argument("query")
    s.add_argument("--limit", type=int, default=200)
    s.set_defaults(fn=cmd_sql)

    s = sub.add_parser("export", help="write the anonymised publication JSON")
    s.add_argument("out")
    s.set_defaults(fn=cmd_export)

    a = p.parse_args(argv)
    try:
        return a.fn(a) or 0
    except (StoreError, export_mod.LeakError, ValueError) as exc:
        sys.stderr.write("nsdb: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
