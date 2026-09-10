#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# gen_gate_report.py -- turn the logs release gates leave behind into one
# machine-readable record.
#
# The gates already say what they proved; the problem is that they say it in
# prose, in a file per gate, on whichever host ran it. Anyone wanting to know
# what a release has actually passed has had to read four logs on two machines
# and remember. That is how a website ends up with a status somebody typed.
#
# So this reads the gates' own output and emits one file. Nothing here decides
# whether a gate passed -- the gate decided that, and this reports it. A log
# with no verdict line is reported as "unknown" rather than assumed either way,
# because a gate that did not finish is not a gate that failed and is certainly
# not one that passed.
import io
import json
import os
import re
import sys
import datetime

# Every line a gate writes is "<script>: <text>". The script name identifies
# the gate, so it is not passed in separately and cannot disagree with the log.
LINE = re.compile(r"^([A-Za-z0-9_.-]+\.sh):\s*(.*)$")

# What each gate is FOR, in the words of the release criteria rather than the
# script's name. A reader should not have to know that verify_media_nested is
# criterion 4.
CLAIMS = {
    "verify_stock_install.sh":
        "a stock, unmodified FreeBSD installs the published packages by the "
        "published route and comes up nesting",
    "verify_media_nested.sh":
        "the published VM image boots and runs a guest inside itself",
    "verify_upgrade.sh":
        "a previously published release upgrades to this one",
    "check_release_contract.sh":
        "the built repository satisfies the release contract",
    "nested-demo.sh":
        "the published one-liner boots a guest inside a guest on this host",
}


def parse(path):
    """Read one gate log into a record. Returns None if it is not a gate log."""
    rec = {
        "log": path,
        "script": None,
        "result": "unknown",
        "summary": "",
        "host": "",
        "cpu": "",
        "evidence": "",
        "from_version": "",
        "to_version": "",
    }
    try:
        with io.open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        rec["summary"] = "could not be read: %s" % exc
        return rec

    for line in lines:
        m = LINE.match(line.strip())
        if not m:
            continue
        script, text = m.group(1), m.group(2)
        # The first script name wins. A gate that invokes another one must not
        # have its verdict attributed to the helper.
        if rec["script"] is None:
            rec["script"] = script
        elif script != rec["script"]:
            continue

        if text.startswith("PASS"):
            rec["result"] = "pass"
            rec["summary"] = text[4:].lstrip(": ").strip()
        elif text.startswith("FAIL"):
            rec["result"] = "fail"
            rec["summary"] = text[4:].lstrip(": ").strip()
        elif text.startswith("host: "):
            hostcpu = text[6:].strip()
            if "," in hostcpu:
                rec["host"], rec["cpu"] = [p.strip() for p in hostcpu.split(",", 1)]
            else:
                rec["host"] = hostcpu
        elif text.startswith("console: "):
            rec["evidence"] = text[9:].strip()
        elif text.startswith("starting version: "):
            rec["from_version"] = text[18:].strip()
        elif text.startswith("ending version: "):
            rec["to_version"] = text[16:].strip()

    if rec["script"] is None:
        return None
    rec["claim"] = CLAIMS.get(rec["script"], "")
    try:
        rec["finished"] = datetime.datetime.fromtimestamp(
            os.path.getmtime(path), datetime.timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
    except OSError:
        rec["finished"] = ""
    return rec


def main(argv):
    if len(argv) < 4:
        sys.stderr.write(
            "usage: gen_gate_report.py <release> <version> <out.json> <log>...\n")
        return 2
    release, version, out = argv[1], argv[2], argv[3]
    gates = []
    for path in argv[4:]:
        rec = parse(path)
        if rec is None:
            sys.stderr.write("%s: not a gate log, skipped\n" % path)
            continue
        gates.append(rec)

    if not gates:
        # Emitting a report with no gates would publish "nothing was tested"
        # in a shape that looks like a result.
        sys.stderr.write("gen_gate_report: no gate logs were readable; "
                         "refusing to write an empty report\n")
        return 1

    counts = {"pass": 0, "fail": 0, "unknown": 0}
    for g in gates:
        counts[g["result"]] = counts.get(g["result"], 0) + 1

    doc = {
        "release": release,
        "version": version,
        "generated": datetime.datetime.now(datetime.timezone.utc)
                     .strftime("%Y-%m-%dT%H:%M:%SZ"),
        # Counts carry their unit, like every other quantity we publish.
        "gate_count": {"value": len(gates), "unit": "gates"},
        "passed": {"value": counts["pass"], "unit": "gates"},
        "failed": {"value": counts["fail"], "unit": "gates"},
        "unknown": {"value": counts["unknown"], "unit": "gates"},
        "gates": sorted(gates, key=lambda g: (g["script"], g["log"])),
    }
    tmp = out + ".tmp%d" % os.getpid()
    with io.open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, out)
    sys.stderr.write("wrote %s: %d gates, %d pass, %d fail, %d unknown\n"
                     % (out, len(gates), counts["pass"], counts["fail"],
                        counts["unknown"]))
    # An UNKNOWN gate is one that produced no verdict -- it was interrupted,
    # it never started, or its log was truncated. That is "could not look",
    # and reporting it as success is how a release round comes to be certified
    # by gates that did not run. Non-zero for either.
    return 1 if counts["fail"] or counts["unknown"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
