#!/usr/bin/env python3
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# gen_release_manifest.py -- describe a release's artifacts in one generated
# file, so nothing about a release is typed twice.
#
# The download page carries twelve facts that are retyped every release: four
# filenames, four sizes and four truncated checksums. They go stale the moment a
# release is cut and come right again only when somebody remembers. A page
# cannot be kept true by discipline; it has to read the artifacts.
#
# So this walks the directory the release build produced and writes
# release.json: the build identity, the package repository, and every artifact
# with its real size and its real checksum. The site reads that. A new image
# format appears on the download page because it appeared in the directory, not
# because a person added a block for it.
#
# Invoke through gen_release_manifest.sh, which finds the interpreter -- the
# build hosts have python3.12 and python3.11 but no bare `python3`.

import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

# Longest suffix first: "mini-memstick.img" must be tested before "memstick.img"
# and ".raw.xz" before ".xz", or the first match is the wrong one. Ordering is
# the whole correctness argument here, so the table is ordered, not a dict.
CLASSES = [
    ("-mini-memstick.img", "installer", "mini-memstick"),
    ("-memstick.img",      "installer", "memstick"),
    ("-bootonly.iso",      "installer", "bootonly-iso"),
    ("-disc1.iso",         "installer", "disc1-iso"),
    (".qcow2.xz",          "vm-image",  "qcow2"),
    (".raw.xz",            "vm-image",  "raw"),
    (".vhd.xz",            "vm-image",  "vhd"),
    (".vmdk.xz",           "vm-image",  "vmdk"),
    (".iso",               "installer", "iso"),
    (".img",               "installer", "img"),
]

PUBLISHED_SUFFIXES = (".iso", ".img", ".xz")

# Units come from a declared set, never a free string a caller invents --
# "sec", "s" and "seconds" would otherwise become three different units and a
# consumer could not exhaust the cases. A size on the wire is a value and its
# unit together, because a bare number leaves what it measures to the reader's
# assumption, and that assumption has been wrong by a factor of a thousand
# often enough to be a rule here.
UNIT_BYTES = "B"


def quantity(value, unit):
    """A number that says what it measures."""
    return {"value": value, "unit": unit}


def uncompressed_size(path):
    """How large a compressed VM image becomes once written out.

    The download page tells a reader both figures, because the one that decides
    whether they have room is the one the file does NOT advertise: a 670 MiB
    download expands to about 6 GiB. That second number was typed by hand and
    had no source, which is the same defect as a hand-typed checksum with a
    slower fuse -- nobody re-measures it, and it quietly describes a previous
    release.

    `xz --robot -l` reports it from the stream footer without decompressing, so
    this costs a syscall rather than six gigabytes of I/O.

    Returns None when it cannot be established. A missing figure makes the page
    omit that half of the line; a WRONG figure would send somebody to free up
    the wrong amount of disk, so guessing is not on the table.
    """
    try:
        out = subprocess.run(["xz", "--robot", "-l", path],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             check=True).stdout.decode("ascii", "replace")
    except (OSError, subprocess.CalledProcessError) as e:
        print("warning: cannot read the uncompressed size of %s: %s"
              % (path, e), file=sys.stderr)
        return None
    for line in out.splitlines():
        f = line.split("\t")
        # totals: streams, blocks, compressed, uncompressed, ...
        if f[0] == "totals" and len(f) > 4:
            try:
                n = int(f[4])
            except ValueError:
                break
            # Zero is what an empty or unreadable stream reports, and it would
            # render as "0 B" beside a 670 MiB download -- a figure a reader
            # would rightly disbelieve, on a page whose whole argument is that
            # its numbers are measured.
            return n if n > 0 else None
    print("warning: xz --robot -l %s printed no totals line" % path,
          file=sys.stderr)
    return None


def classify(name):
    for suffix, kind, fmt in CLASSES:
        if name.endswith(suffix):
            return kind, fmt
    return "other", "unknown"


def filesystem(name):
    """UFS or ZFS, for the VM images that come in both. Reported rather than
    inferred by the page, which would mean the same guess in two places."""
    if "-zfs." in name or name.endswith("-zfs"):
        return "zfs"
    if "-ufs." in name or name.endswith("-ufs"):
        return "ufs"
    return None


def sha256_of(path):
    h = hashlib.sha256()
    # A release image is over a gigabyte; read it in blocks rather than into
    # memory on a build host that is also compiling.
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def read_identity(path):
    """Parse build-identity.txt: '  key:   value' lines, written by the release
    build. Absent or unreadable gives an empty mapping and the caller decides —
    a manifest with no identity is refused below rather than published."""
    out = {}
    if not path or not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if ":" not in line:
                continue
            key, _, value = line.partition(":")
            key = key.strip()
            if key:
                out[key] = value.strip()
    return out


def package_repo(pkgdir, fallback_version):
    if not pkgdir or not os.path.isdir(pkgdir):
        return {"version": fallback_version, "packages": None}
    version = fallback_version
    latest = os.path.join(pkgdir, "latest")
    if os.path.islink(latest):
        version = os.path.basename(os.readlink(latest))
    verdir = os.path.join(pkgdir, version) if version else None
    count = None
    if verdir and os.path.isdir(verdir):
        count = sum(1 for f in os.listdir(verdir) if f.endswith(".pkg"))
    return {"version": version, "packages": count}


def main():
    ap = argparse.ArgumentParser(description="Generate a release manifest.")
    ap.add_argument("-d", "--dir", required=True, help="directory of release artifacts")
    ap.add_argument("-i", "--identity", help="build-identity.txt from the build")
    ap.add_argument("-u", "--url-base", default="", help="URL path the artifacts are served under")
    ap.add_argument("-p", "--pkg-dir", help="package repository directory, for version and count")
    ap.add_argument("-a", "--abi", default="FreeBSD:16:amd64")
    ap.add_argument("-o", "--out", help="output file (default stdout)")
    args = ap.parse_args()

    if not os.path.isdir(args.dir):
        sys.exit("no such directory: %s" % args.dir)

    identity_path = args.identity
    if not identity_path:
        for candidate in (os.path.join(args.dir, os.pardir, "logs", "build-identity.txt"),
                          os.path.join(args.dir, "build-identity.txt")):
            if os.path.isfile(candidate):
                identity_path = candidate
                break
    ident = read_identity(identity_path)

    # A manifest whose entire job is to say which build these images are cannot
    # be published without one. This is the same rule the README generator got.
    if not ident.get("commit"):
        sys.exit("no build identity found (looked at %s) -- refusing to write a "
                 "manifest that cannot say which build these artifacts are"
                 % (identity_path or "the default locations"))

    # Sorted, so identical inputs give an identical file and a diff of this
    # manifest means something.
    artifacts = []
    for name in sorted(os.listdir(args.dir)):
        if not name.endswith(PUBLISHED_SUFFIXES):
            continue
        path = os.path.join(args.dir, name)
        if not os.path.isfile(path):
            continue
        kind, fmt = classify(name)
        entry = {
            "name": name,
            "kind": kind,
            "format": fmt,
            "size": quantity(os.path.getsize(path), UNIT_BYTES),
            "sha256": sha256_of(path),
        }
        if name.endswith(".xz"):
            unpacked = uncompressed_size(path)
            if unpacked is not None:
                entry["uncompressed_size"] = quantity(unpacked, UNIT_BYTES)
        fs = filesystem(name)
        if fs:
            entry["filesystem"] = fs
        if args.url_base:
            entry["url"] = "%s/%s" % (args.url_base.rstrip("/"), name)
        artifacts.append(entry)

    if not artifacts:
        sys.exit("no artifacts in %s -- refusing to publish an empty manifest" % args.dir)

    manifest = {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "release": ident.get("release", ""),
        "commit": ident["commit"],
        "branch": ident.get("branch", ""),
        "vmm_ko_sha256": ident.get("vmm.ko", ""),
        # What `uname -v` prints on a machine running this build, so the page
        # that tells a reader to check it does not carry its own copy.
        "kernel_ident": ident.get("kernel", ""),
        "built": ident.get("built", ""),
        "abi": args.abi,
        "pkg_repo": package_repo(args.pkg_dir, ident.get("release", "")),
        "artifacts": artifacts,
    }

    text = json.dumps(manifest, indent=1, ensure_ascii=False) + "\n"
    if args.out:
        # Write and rename, so a reader never sees half a manifest and a failure
        # part-way leaves the previous one in place.
        tmp = args.out + ".tmp%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, args.out)
        print("wrote %s: %d artifacts, release %s"
              % (args.out, len(artifacts), manifest["release"] or "(untagged)"),
              file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
