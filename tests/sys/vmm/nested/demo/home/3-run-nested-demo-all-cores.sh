#!/bin/sh
# The automatic demo, run wide: both the L1 guest and the L2 guest inside it
# get every core this host has, instead of one each.
#
# This is the interesting configuration and the demanding one. A guest with one
# vCPU never has to bring a second processor up through two layers of
# hypervisor; a guest with several does, and that is the part of nested
# virtualization still being stabilised. If this stalls where
# 1-run-nested-demo.sh completes, that is the finding, not a broken demo --
# the console log named at the end is what to keep.
exec doas /usr/local/libexec/cloudbsd-demo/run-auto-demo --all-cores
