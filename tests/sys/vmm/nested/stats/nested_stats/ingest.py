# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
"""Parsers for the log formats the fleet already produces.

Every format here was written by a different throwaway script on a different
day, so the parsers are separate objects behind one interface rather than one
regex with branches: adding tomorrow's format means adding a class, not
editing a working parser and hoping.

Two rules shape all of them:

* A line the parser does not understand is reported, never silently dropped.
  A quietly-skipped line looks exactly like a measurement that was never
  taken, which is the failure mode this whole project keeps hitting.

* No row is stored without a build identity.  Three of these formats do not
  record one.  For those the build is either given explicitly or inferred
  from the nearest earlier run on the same machine, and the inference is
  written into the row's notes so nobody later mistakes it for something the
  log said.
"""

from __future__ import annotations

import os
import re
import time
from typing import Iterator, Optional

from .store import Writer, content_key_for, utcnow

# `key=value` with an optional leading ISO-8601 timestamp.
_TS = re.compile(r"\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s+(.*)\Z")
_KV = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(\S+)")

#: Outcomes seen in the wild, mapped onto the schema's vocabulary.
_OUTCOMES = {
    "PASS": "PASS",
    "OK": "PASS",
    "FAIL": "FAIL",
    "FAIL-VMENTRY": "FAIL-VMENTRY",
    "FAIL-TIMEOUT": "FAIL-TIMEOUT",
    "HOST-PANIC": "HOST-PANIC",
    "PANIC": "HOST-PANIC",
    "SKIP": "SKIP",
}


class ParsedRun(dict):
    """One run's worth of parsed fields, before it meets the database."""


def _kv(rest: str) -> dict:
    return {m.group(1): m.group(2) for m in _KV.finditer(rest)}


def _num(text: Optional[str]) -> Optional[float]:
    if text is None:
        return None
    try:
        return float(text)
    except ValueError:
        return None


class Parser:
    """Base class.  `matches` decides on the filename; `parse` yields runs."""

    suite = "unknown"

    def matches(self, basename: str) -> bool:
        raise NotImplementedError

    def parse(self, path: str, lines: list[str]) -> Iterator[ParsedRun]:
        raise NotImplementedError


class CoreCeiling(Parser):
    """``core-ceiling-<host>.log`` -- the vCPU width sweep.

    The only format that carries everything a row needs: its own timestamp,
    its host and its vmm build.
    """

    suite = "core-ceiling"

    def matches(self, basename: str) -> bool:
        return basename.startswith("core-ceiling") and basename.endswith(".log")

    def parse(self, path, lines):
        for n, line in enumerate(lines, 1):
            line = line.strip()
            if not line or line == "DONE":
                continue
            m = _TS.match(line)
            if not m:
                yield ParsedRun(_error=f"no timestamp: {line!r}", line=n)
                continue
            ts, rest = m.group(1), m.group(2)
            kv = _kv(rest)
            if "vmm" not in kv or "result" not in kv:
                yield ParsedRun(_error=f"missing vmm= or result=: {line!r}", line=n)
                continue
            secs = _num(kv.get("secs"))
            yield ParsedRun(
                ts_utc=ts,
                host=kv.get("host"),
                vmm=kv["vmm"],
                suite=self.suite,
                outcome=_OUTCOMES.get(kv["result"].upper(), "FAIL"),
                dims={"vcpus": int(kv["vcpus"])} if kv.get("vcpus", "").isdigit() else {},
                measurements=(
                    [{"metric": "boot_secs", "value_num": secs, "unit": "s"}]
                    if secs is not None else []
                ),
                line=n,
            )


class RepeatSweep(Parser):
    """``repeat-c4-*.log`` / ``repeat-UG-*.log`` -- flakiness repeats.

    Carries neither a timestamp nor a build.  Both come from outside; see the
    module docstring.
    """

    suite = "repeat"

    def matches(self, basename: str) -> bool:
        return basename.startswith("repeat-") and basename.endswith(".log")

    def parse(self, path, lines):
        variant = os.path.basename(path)[len("repeat-"):].split("-")[0]
        for n, line in enumerate(lines, 1):
            line = line.strip()
            if not line or line == "DONE":
                continue
            kv = _kv(line)
            if "result" not in kv:
                yield ParsedRun(_error=f"no result=: {line!r}", line=n)
                continue
            dims = {"variant": variant}
            for k in ("run", "vcpus", "iter"):
                if kv.get(k, "").isdigit():
                    dims[k] = int(kv[k])
            yield ParsedRun(
                ts_utc=None,
                host=None,
                vmm=None,
                suite=self.suite,
                outcome=_OUTCOMES.get(kv["result"].upper(), "FAIL"),
                dims=dims,
                measurements=[],
                line=n,
            )


class PerfAB(Parser):
    """``perf-ab*.log`` -- nesting-on versus nesting-off, in alternating blocks.

    Two shapes have existed: the per-iteration one (``iter=``/``boot_secs=``)
    and the blocked one (``block=``/``boots=``/``total_secs=``) that replaced
    it, because single boots could not be resolved by a whole-second clock.
    Both are read; the block shape also records the derived per-boot mean, so
    the two are comparable without the reader having to divide.
    """

    suite = "perf-ab"

    def matches(self, basename: str) -> bool:
        return basename.startswith("perf-ab") and basename.endswith(".log")

    def parse(self, path, lines):
        for n, line in enumerate(lines, 1):
            line = line.strip()
            if not line or line == "DONE":
                continue
            kv = _kv(line)
            if "nested" not in kv:
                yield ParsedRun(_error=f"no nested=: {line!r}", line=n)
                continue
            dims = {"nested": int(kv["nested"])}
            meas = []
            if "block" in kv:
                dims["block"] = int(kv["block"])
                boots = int(kv.get("boots", "0") or 0)
                total = _num(kv.get("total_secs"))
                if total is not None:
                    meas.append({"metric": "block_total_secs",
                                 "value_num": total, "unit": "s"})
                    if boots:
                        dims["boots"] = boots
                        meas.append({"metric": "boot_secs_mean",
                                     "value_num": total / boots, "unit": "s",
                                     "notes": "derived: total_secs / boots"})
            elif "iter" in kv:
                dims["iter"] = int(kv["iter"])
                bs = _num(kv.get("boot_secs"))
                if bs is not None:
                    meas.append({"metric": "boot_secs", "value_num": bs, "unit": "s",
                                 "notes": "single boot on a whole-second clock; "
                                          "resolution is about 20%"})
            if not meas:
                yield ParsedRun(_error=f"no numbers in: {line!r}", line=n)
                continue
            yield ParsedRun(ts_utc=None, host=None, vmm=None, suite=self.suite,
                            outcome=None, dims=dims, measurements=meas, line=n)


class BenchLayer(Parser):
    """``BENCH layer=... `` lines from ``bench.sh``.

    ``read_MBps`` is deliberately allowed to be non-numeric: the script prints
    ``-(cache-warm)`` when the read never reached a disk.  That is stored as
    text, not as a zero, because a zero would average into a chart.
    """

    suite = "bench"
    _UNITS = {
        "cpu_secs": "s",
        "cpu_iter_per_s": "iter/s",
        "write_MBps": "MB/s",
        "read_MBps": "MB/s",
        "total_MB": "MB",
    }

    def matches(self, basename: str) -> bool:
        return True  # content-selected, see `parse`

    def parse(self, path, lines):
        for n, line in enumerate(lines, 1):
            line = line.strip()
            if not line.startswith("BENCH "):
                continue
            kv = _kv(line[len("BENCH "):])
            layer = kv.pop("layer", None)
            if not layer:
                yield ParsedRun(_error=f"BENCH line with no layer=: {line!r}", line=n)
                continue
            meas = []
            for key, raw in kv.items():
                val = _num(raw)
                meas.append({
                    "metric": key,
                    "value_num": val,
                    "unit": self._UNITS.get(key),
                    "value_text": None if val is not None else raw,
                    "notes": None if val is not None else "not measurable in this run",
                })
            yield ParsedRun(ts_utc=None, host=None, vmm=None, suite=self.suite,
                            outcome=None, dims={"layer": layer},
                            measurements=meas, line=n)


class BenchGuestTsv(Parser):
    """``bench-on.log`` / ``bench-off.log`` -- ``bench_guest.sh``'s TSV.

    Three tab-separated columns: a run label such as ``nested-on-7cb6a8a0``,
    a metric name, a value.  All the lines sharing a label are one run, so
    they are gathered rather than emitted one row each.
    """

    suite = "bench-guest"
    _UNITS = {
        "boot_to_login_s": "s", "cpu_loop_s": "s", "exec_4000_s": "s",
        "read_1g_s": "s", "write_1g_s": "s",
    }

    def matches(self, basename: str) -> bool:
        return basename.startswith("bench-") and basename.endswith(".log")

    def parse(self, path, lines):
        groups: dict[str, list] = {}
        order: list[str] = []
        for n, line in enumerate(lines, 1):
            if "\t" not in line:
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3:
                yield ParsedRun(_error=f"not three columns: {line!r}", line=n)
                continue
            label, metric, raw = (p.strip() for p in parts)
            if label not in groups:
                groups[label] = []
                order.append(label)
            val = _num(raw)
            groups[label].append({
                "metric": metric,
                "value_num": val,
                "unit": self._UNITS.get(metric, "count" if val is not None else None),
                "value_text": None if val is not None else raw,
                "_line": n,
            })
        for label in order:
            meas = groups[label]
            dims = {"label": label}
            if label.startswith("nested-on"):
                dims["nested"] = 1
            elif label.startswith("nested-off"):
                dims["nested"] = 0
            first_line = min(m.pop("_line") for m in meas)
            yield ParsedRun(ts_utc=None, host=None, vmm=None, suite=self.suite,
                            outcome=None, dims=dims, measurements=meas,
                            line=first_line)


#: Order matters only in that the first match wins; the patterns are disjoint
#: except for BenchLayer, which is content-selected and therefore last.
PARSERS: list[Parser] = [
    CoreCeiling(), RepeatSweep(), PerfAB(), BenchGuestTsv(), BenchLayer(),
]


def parser_for(path: str, lines: list[str]) -> Optional[Parser]:
    base = os.path.basename(path)
    for p in PARSERS[:-1]:
        if p.matches(base):
            return p
    if any(l.startswith("BENCH ") for l in lines):
        return PARSERS[-1]
    return None


class IngestResult(dict):
    pass


def ingest_file(
    writer: Writer,
    path: str,
    host: Optional[str] = None,
    vmm: Optional[str] = None,
    batch_id: Optional[int] = None,
    dry_run: bool = False,
) -> IngestResult:
    """Read one log file into the store.

    `host` and `vmm` supply what a format cannot say for itself.  When `vmm`
    is absent and the format does not carry one, the build is inferred from
    the newest run already recorded for that machine at or before the file's
    mtime -- and the row says so.  If nothing can be inferred the file is
    refused: a measurement with a guessed build is worse than no measurement.
    """
    with open(path, "r", errors="replace") as fh:
        lines = fh.readlines()
    parser = parser_for(path, lines)
    res = IngestResult(path=path, parser=None, inserted=0, duplicate=0,
                       errors=[], skipped=0)
    if parser is None:
        res["errors"].append("no parser recognised this file")
        return res
    res["parser"] = type(parser).__name__

    st = os.stat(path)
    file_mtime = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(st.st_mtime))
    # The source identity folded into every content key: replaying an
    # unchanged file inserts nothing, a rewritten one inserts new rows.
    source_id = "%s@%d:%d" % (os.path.basename(path), int(st.st_mtime), st.st_size)

    host = host or _host_from_name(os.path.basename(path))

    for rec in parser.parse(path, lines):
        if rec.get("_error"):
            res["errors"].append("line %s: %s" % (rec.get("line"), rec["_error"]))
            continue
        rec_host = rec.get("host") or host
        if not rec_host:
            res["errors"].append(
                "line %s: no host in the line or the filename; pass --host"
                % rec.get("line"))
            continue
        note_bits = []
        rec_vmm = rec.get("vmm") or vmm
        ts = rec.get("ts_utc") or file_mtime
        if not rec.get("ts_utc"):
            note_bits.append("timestamp taken from the log file's mtime; "
                             "the format carries none")
        if not rec_vmm:
            inferred = _infer_build(writer, rec_host, ts)
            if inferred is None:
                res["errors"].append(
                    "line %s: no build identity available for %s at %s; "
                    "pass --vmm" % (rec.get("line"), rec_host, ts))
                continue
            rec_vmm, when = inferred
            note_bits.append(
                "build inferred from the nearest earlier recorded run on this "
                "machine (%s); the log itself names no vmm.ko" % when)
        elif not rec.get("vmm"):
            note_bits.append("build supplied on the command line, not by the log")

        if dry_run:
            res["skipped"] += 1
            continue

        key = content_key_for(rec_host, parser.suite, source_id, rec.get("line"))
        run_id = writer.record_run(
            ts_utc=ts, host=rec_host, vmm_sha256=rec_vmm, suite=parser.suite,
            outcome=rec.get("outcome"), dims=rec.get("dims"),
            measurements=rec.get("measurements"),
            source=source_id, source_line=rec.get("line"),
            content_key=key, batch_id=batch_id,
            notes="; ".join(note_bits) or None,
        )
        if run_id is None:
            res["duplicate"] += 1
        else:
            res["inserted"] += 1
    return res


def _host_from_name(basename: str) -> Optional[str]:
    """Recover the machine name from names like ``core-ceiling-<host>.log``.

    The trailing component before ``.log`` is the machine when the file was
    named by one of the sweep scripts.  Returns None rather than a guess when
    the shape does not fit.
    """
    stem = basename[:-4] if basename.endswith(".log") else basename
    parts = stem.split("-")
    if len(parts) < 2:
        return None
    cand = parts[-1]
    return cand if re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]{2,}", cand) else None


def _infer_build(writer: Writer, host: str, ts: str) -> Optional[tuple[str, str]]:
    row = writer.conn.execute(
        "SELECT b.vmm_sha256, r.ts_utc FROM run r "
        "JOIN host h ON h.host_id = r.host_id "
        "JOIN build b ON b.build_id = r.build_id "
        "WHERE h.name = ? AND r.ts_utc <= ? "
        "ORDER BY r.ts_utc DESC LIMIT 1",
        (host, ts),
    ).fetchone()
    if row:
        return row["vmm_sha256"], row["ts_utc"]
    row = writer.conn.execute(
        "SELECT b.vmm_sha256, r.ts_utc FROM run r "
        "JOIN host h ON h.host_id = r.host_id "
        "JOIN build b ON b.build_id = r.build_id "
        "WHERE h.name = ? ORDER BY r.ts_utc ASC LIMIT 1",
        (host,),
    ).fetchone()
    if row:
        return row["vmm_sha256"], row["ts_utc"] + " (later, not earlier)"
    return None
