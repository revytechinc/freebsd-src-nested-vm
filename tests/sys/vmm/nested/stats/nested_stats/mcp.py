# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
"""An MCP server over stdio for the measurement store.

Transport, and why there is no port
-----------------------------------

This speaks JSON-RPC on stdin and stdout and listens on nothing.  It is
launched as ``ssh <host> nested-stats-mcp``, so the only way to reach it is to
already hold an authenticated ssh session on the machine that holds the
database.  There is no socket to scan for, nothing to bind to the wrong
address, no forwarded port left open in a shell someone walked away from, and
no second authentication story to get wrong.  A local-only TCP listener plus
``ssh -L`` would give the same reachability on a good day and a different one
on a bad day: a listener is reachable by every process on that machine,
including anything running in a jail with the host's loopback, whereas a
process that owns a pipe pair is reachable by its parent and nothing else.

The cost is that the server has no life of its own -- it starts and dies with
the client, and it cannot be shared between two clients.  For a store that one
orchestration host queries, that is not a cost.

Read and write are separate paths
---------------------------------

Query tools open the database through SQLite's ``mode=ro`` URI, so the
connection they hold physically cannot write.  Only ``record_run``,
``ingest_logs`` and ``load_inventory`` open it read-write, and ``--read-only``
removes those three from the advertised tool list entirely.
"""

from __future__ import annotations

import json
import os
import sys
import traceback
from typing import Any, Callable

from . import export as export_mod
from . import ingest as ingest_mod
from . import inventory as inv_mod
from .store import DEFAULT_DB, Reader, Writer

SERVER_NAME = "nested-stats"
SERVER_VERSION = "1.0"
DEFAULT_PROTOCOL = "2024-11-05"
KNOWN_PROTOCOLS = {"2024-11-05", "2025-03-26", "2025-06-18"}


def _text(obj: Any) -> dict:
    return {"content": [{"type": "text",
                         "text": json.dumps(obj, indent=2, sort_keys=True,
                                            default=str)}]}


def _err(msg: str) -> dict:
    return {"content": [{"type": "text", "text": msg}], "isError": True}


class Server:
    def __init__(self, db: str = DEFAULT_DB, read_only: bool = False):
        self.db = db
        self.read_only = read_only
        self.tools = self._build_tools()

    # -- tool implementations -------------------------------------------
    def _list_hosts(self, _args):
        with Reader.open(self.db) as r:
            return _text(r.hosts())

    def _list_builds(self, _args):
        with Reader.open(self.db) as r:
            return _text(r.builds())

    def _query_runs(self, a):
        with Reader.open(self.db) as r:
            rows = r.runs(host=a.get("host"), build=a.get("build"),
                          suite=a.get("suite"), outcome=a.get("outcome"),
                          since=a.get("since"), until=a.get("until"),
                          limit=int(a.get("limit", 100)))
            if a.get("with_measurements"):
                byrun: dict = {}
                for m in r.measurements_for(x["run_id"] for x in rows):
                    byrun.setdefault(m["run_id"], []).append(m)
                for row in rows:
                    row["measurements"] = byrun.get(row["run_id"], [])
            return _text(rows)

    def _summarize(self, a):
        with Reader.open(self.db) as r:
            return _text(r.summary(group_by=a.get("group_by", "host"),
                                   suite=a.get("suite"), build=a.get("build")))

    def _query_inventory(self, a):
        safe = a.get("safe_to_remove")
        with Reader.open(self.db) as r:
            return _text(r.inventory(
                host=a.get("host"), classification=a.get("classification"),
                safe_to_remove=None if safe is None else bool(safe),
                min_bytes=int(a.get("min_bytes", 0)),
                limit=int(a.get("limit", 200))))

    def _sql_select(self, a):
        with Reader.open(self.db) as r:
            return _text(r.select_guarded(a["query"], limit=int(a.get("limit", 200))))

    def _export_public(self, a):
        with Reader.open(self.db) as r:
            return _text(export_mod.export_json(r, a["path"]))

    def _record_run(self, a):
        with Writer.open(self.db) as w:
            run_id = w.record_run(
                ts_utc=a["ts_utc"], host=a["host"], vmm_sha256=a["vmm_sha256"],
                suite=a["suite"], outcome=a.get("outcome"),
                dims=a.get("dims"), measurements=a.get("measurements"),
                source=a.get("source"), notes=a.get("notes"))
        return _text({"run_id": run_id, "duplicate": run_id is None})

    def _ingest_logs(self, a):
        out = []
        with Writer.open(self.db) as w:
            batch = w.open_batch("mcp:ingest_logs", a.get("notes", ""))
            for p in a["paths"]:
                out.append(ingest_mod.ingest_file(
                    w, p, host=a.get("host"), vmm=a.get("vmm"),
                    batch_id=batch, dry_run=bool(a.get("dry_run"))))
        return _text(out)

    def _load_inventory(self, a):
        with Writer.open(self.db) as w:
            return _text(inv_mod.load_scan(
                w, iter(a["tsv"].splitlines(True)), host=a.get("host")))

    # -- tool table ------------------------------------------------------
    def _build_tools(self) -> dict[str, dict]:
        S = lambda **kw: dict(type="object", **kw)  # noqa: E731
        read: list[tuple[str, str, dict, Callable]] = [
            ("list_hosts", "Every machine known to the store, with its "
             "hardware profile and the anonymised label the website may use.",
             S(properties={}), self._list_hosts),
            ("list_builds", "Every vmm.ko build results have been recorded "
             "against, with its status (published, candidate, experiment).",
             S(properties={}), self._list_builds),
            ("query_runs", "Measurement runs, newest first. Every row names "
             "the build it was measured against.",
             S(properties={
                 "host": {"type": "string", "description":
                          "internal name or public label"},
                 "build": {"type": "string", "description":
                           "full vmm sha256, its 16-character prefix, or a "
                           "release name"},
                 "suite": {"type": "string", "description":
                           "core-ceiling, repeat, perf-ab, bench, bench-guest"},
                 "outcome": {"type": "string"},
                 "since": {"type": "string", "description": "ISO-8601 UTC"},
                 "until": {"type": "string", "description": "ISO-8601 UTC"},
                 "with_measurements": {"type": "boolean"},
                 "limit": {"type": "integer"},
             }), self._query_runs),
            ("summarize", "Run counts and pass/fail totals grouped by host, "
             "public_label, build, suite, outcome or day.",
             S(properties={
                 "group_by": {"type": "string", "enum":
                              ["host", "public_label", "build", "suite",
                               "outcome", "day"]},
                 "suite": {"type": "string"},
                 "build": {"type": "string"},
             }), self._summarize),
            ("query_inventory", "What is sitting in the fleet's home "
             "directories, from the most recent scan of each machine, with a "
             "classification and an ADVISORY safe-to-remove opinion. Nothing "
             "here deletes anything.",
             S(properties={
                 "host": {"type": "string"},
                 "classification": {"type": "string", "enum":
                                    ["measurement-data", "build-log",
                                     "kernel-module", "core-dump",
                                     "one-off-script", "source-tree", "objdir",
                                     "release-artifact", "demo-image",
                                     "unknown"]},
                 "safe_to_remove": {"type": "boolean"},
                 "min_bytes": {"type": "integer"},
                 "limit": {"type": "integer"},
             }), self._query_inventory),
            ("sql_select", "Run one read-only SELECT or WITH query against "
             "the store. The connection is opened read-only, so this cannot "
             "modify anything. Useful views: v_run, v_measurement, "
             "v_inventory_current.",
             S(properties={"query": {"type": "string"},
                           "limit": {"type": "integer"}},
               required=["query"]), self._sql_select),
        ]
        write: list[tuple[str, str, dict, Callable]] = [
            ("record_run", "Append one measurement run. Never updates an "
             "existing row; a re-run is a new row.",
             S(properties={
                 "ts_utc": {"type": "string"},
                 "host": {"type": "string"},
                 "vmm_sha256": {"type": "string", "description":
                                "sha256 of the vmm.ko under test; required, "
                                "because a result without one is not a result"},
                 "suite": {"type": "string"},
                 "outcome": {"type": "string", "enum":
                             ["PASS", "FAIL", "FAIL-VMENTRY", "FAIL-TIMEOUT",
                              "HOST-PANIC", "SKIP"]},
                 "dims": {"type": "object"},
                 "measurements": {"type": "array", "items": S(properties={
                     "metric": {"type": "string"},
                     "value_num": {"type": "number"},
                     "unit": {"type": "string"},
                     "value_text": {"type": "string"},
                 }, required=["metric"])},
                 "source": {"type": "string"},
                 "notes": {"type": "string"},
             }, required=["ts_utc", "host", "vmm_sha256", "suite"]),
             self._record_run),
            ("ingest_logs", "Parse fleet log files already present on this "
             "machine and append what they contain.",
             S(properties={
                 "paths": {"type": "array", "items": {"type": "string"}},
                 "host": {"type": "string"},
                 "vmm": {"type": "string"},
                 "dry_run": {"type": "boolean"},
                 "notes": {"type": "string"},
             }, required=["paths"]), self._ingest_logs),
            ("load_inventory", "Load one machine's collect-inventory.sh "
             "output as a new scan.",
             S(properties={"tsv": {"type": "string"},
                           "host": {"type": "string"}},
               required=["tsv"]), self._load_inventory),
            ("export_public", "Write the anonymised publication JSON. Refuses "
             "to emit a document containing an internal machine name, a home "
             "path or an internal IP.",
             S(properties={"path": {"type": "string"}}, required=["path"]),
             self._export_public),
        ]
        entries = read if self.read_only else read + write
        return {name: {"description": desc, "schema": schema, "fn": fn}
                for name, desc, schema, fn in entries}

    # -- JSON-RPC --------------------------------------------------------
    def handle(self, msg: dict) -> Any:
        method = msg.get("method")
        mid = msg.get("id")
        params = msg.get("params") or {}

        if method == "initialize":
            want = params.get("protocolVersion")
            return self._ok(mid, {
                "protocolVersion": want if want in KNOWN_PROTOCOLS else DEFAULT_PROTOCOL,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            })
        if method in ("notifications/initialized", "initialized"):
            return None
        if method == "ping":
            return self._ok(mid, {})
        if method == "tools/list":
            return self._ok(mid, {"tools": [
                {"name": n, "description": t["description"],
                 "inputSchema": t["schema"]}
                for n, t in self.tools.items()]})
        if method in ("resources/list", "prompts/list"):
            return self._ok(mid, {method.split("/")[0]: []})
        if method == "tools/call":
            name = params.get("name")
            tool = self.tools.get(name)
            if tool is None:
                return self._ok(mid, _err("no such tool: %r" % name))
            try:
                return self._ok(mid, tool["fn"](params.get("arguments") or {}))
            except Exception as exc:  # a bad argument must not kill the server
                traceback.print_exc(file=sys.stderr)
                return self._ok(mid, _err("%s: %s" % (type(exc).__name__, exc)))
        if mid is None:
            return None
        return {"jsonrpc": "2.0", "id": mid,
                "error": {"code": -32601, "message": "method not found: %s" % method}}

    @staticmethod
    def _ok(mid, result):
        if mid is None:
            return None
        return {"jsonrpc": "2.0", "id": mid, "result": result}

    #: Largest single JSON-RPC message accepted.  `load_inventory` carries a
    #: whole machine's scan inline, so the cap has to be generous -- but
    #: unbounded is not generous, it is a way to be killed by one bad client.
    MAX_LINE = 16 * 1024 * 1024

    def _lines(self, stdin):
        """Yield whole lines, or None for one that ran past MAX_LINE.

        An oversized line is drained and discarded rather than accumulated, so
        the session survives it and reports a parse error instead of dying.
        """
        buf = ""
        overlong = False
        while True:
            chunk = stdin.read(65536)
            if not chunk:
                break
            buf += chunk
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                if overlong:
                    overlong = False
                    yield None
                elif len(line) > self.MAX_LINE:
                    # A complete but oversized line is rejected too, not just
                    # one that outran the buffer: whether the terminator has
                    # arrived yet is an accident of read timing, and a cap
                    # that depends on that is not a cap.
                    yield None
                else:
                    yield line
            if len(buf) > self.MAX_LINE:
                buf = ""
                overlong = True
        if buf and not overlong:
            yield buf
        elif overlong:
            yield None

    def serve(self, stdin=None, stdout=None) -> int:
        stdin = stdin or sys.stdin
        stdout = stdout or sys.stdout
        for line in self._lines(stdin):
            if line is None:
                stdout.write(json.dumps({
                    "jsonrpc": "2.0", "id": None,
                    "error": {"code": -32700,
                              "message": "message exceeded %d bytes"
                                         % self.MAX_LINE}}) + "\n")
                stdout.flush()
                continue
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                stdout.write(json.dumps({
                    "jsonrpc": "2.0", "id": None,
                    "error": {"code": -32700, "message": "parse error"}}) + "\n")
                stdout.flush()
                continue
            reply = self.handle(msg)
            if reply is not None:
                stdout.write(json.dumps(reply, default=str) + "\n")
                stdout.flush()
        return 0


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    db = DEFAULT_DB
    read_only = False
    while argv:
        arg = argv.pop(0)
        if arg == "--db" and argv:
            db = argv.pop(0)
        elif arg == "--read-only":
            read_only = True
        elif arg in ("-h", "--help"):
            sys.stderr.write(__doc__ + "\nusage: [--db PATH] [--read-only]\n")
            return 0
        else:
            sys.stderr.write("unknown argument: %s\n" % arg)
            return 2
    if not os.path.exists(db):
        sys.stderr.write("nested-stats: no database at %s\n" % db)
        return 2
    return Server(db, read_only=read_only).serve()


if __name__ == "__main__":
    sys.exit(main())
