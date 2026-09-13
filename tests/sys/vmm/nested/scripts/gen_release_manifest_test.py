#!/usr/bin/env python3
#-
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2026 REVYTECH, Inc.
#
# gen_release_manifest_test.py -- lock the package count against the one thing
# it kept getting wrong.
#
# `pkg repo` writes its catalogue into the same directory as the packages, and
# names those files data.pkg and packagesite.pkg. A generator that counts *.pkg
# therefore counts the index OF the packages AS packages. It published 527 for
# a repository that serves 525, and the discrepancy stood for days being read as
# "two packages went missing in publishing" -- a failure that never happened.
#
# Run: python3 gen_release_manifest_test.py

import os
import sys
import tempfile
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "genmanifest", os.path.join(HERE, "gen_release_manifest.py"))
gm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gm)

FAILED = []


def check(label, got, want):
    if got == want:
        print("PASS: %s" % label)
    else:
        print("FAIL: %s -- got %r, want %r" % (label, got, want))
        FAILED.append(label)


def repo(tmp, version, names):
    d = os.path.join(tmp, version)
    os.makedirs(d)
    for n in names:
        open(os.path.join(d, n), "w").close()
    os.symlink(version, os.path.join(tmp, "latest"))
    return tmp


with tempfile.TemporaryDirectory() as tmp:
    # The shape of a real published repository: base packages, the pkg tool
    # itself, the catalogue, and the plain-text meta files.
    names = ["CloudBSD-kernel-generic-1.pkg", "CloudBSD-bhyve-1.pkg",
             "FreeBSD-clibs-1.pkg", "pkg-2.8.4.pkg",
             "data.pkg", "packagesite.pkg", "meta", "meta.conf"]
    r = package_dir = repo(tmp, "16.0.20260910.deepnest16", names)
    got = gm.package_repo(r, "fallback")
    # Four installable things; the catalogue is not one of them. pkg-2.8.4.pkg
    # IS installable and must be counted -- excluding "anything not CloudBSD-"
    # would be a different bug with the same shape.
    check("catalogue excluded, pkg tool included", got["packages"], 4)
    check("version read from the latest symlink",
          got["version"], "16.0.20260910.deepnest16")

with tempfile.TemporaryDirectory() as tmp:
    # A directory of packages with no catalogue is not a repository. A count
    # here would describe something nobody can install from.
    r = repo(tmp, "v", ["CloudBSD-a-1.pkg", "CloudBSD-b-1.pkg"])
    got = gm.package_repo(r, "f")
    check("no catalogue -> not a count", got["packages"], None)
    check("and it says which kind of none",
          got.get("packages_note"),
          "no catalogue; nothing can install from this")

with tempfile.TemporaryDirectory() as tmp:
    # meta.pkg is excluded from the count, which is NOT the same as it proving
    # a repository exists. One set was doing both jobs and this case passed.
    r = repo(tmp, "v", ["CloudBSD-a-1.pkg", "meta.pkg", "meta", "meta.conf"])
    check("meta.pkg alone is not a repository",
          gm.package_repo(r, "f")["packages"], None)

with tempfile.TemporaryDirectory() as tmp:
    # data.pkg without packagesite.pkg: half a catalogue. pkg cannot resolve
    # anything from it, so it is not a count either.
    r = repo(tmp, "v", ["CloudBSD-a-1.pkg", "data.pkg"])
    check("data.pkg without packagesite.pkg is not a repository",
          gm.package_repo(r, "f")["packages"], None)

with tempfile.TemporaryDirectory() as tmp:
    # packagesite.pkg present is the predicate, and data.pkg is still excluded
    # from the number.
    r = repo(tmp, "v", ["CloudBSD-a-1.pkg", "CloudBSD-b-1.pkg",
                        "packagesite.pkg", "data.pkg"])
    check("packagesite.pkg is the predicate", gm.package_repo(r, "f")["packages"], 2)

with tempfile.TemporaryDirectory() as tmp:
    # Absent directory: could-not-look, not zero. Zero is a claim that the
    # release shipped nothing, which is a different and much louder statement.
    got = gm.package_repo(os.path.join(tmp, "nope"), "fallback")
    check("missing dir -> None, not 0", got["packages"], None)
    check("missing dir says which kind of none",
          got.get("packages_note"), "no package directory to read")
    check("missing dir keeps the fallback version", got["version"], "fallback")

print()
if FAILED:
    print("%d test(s) failed" % len(FAILED))
    sys.exit(1)
print("all tests passed")
