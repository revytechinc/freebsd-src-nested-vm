#!/bin/sh
# The automatic demo, run wide: both the L1 guest and the L2 guest inside it
# get every core this host has, instead of one each.
#
# This is the interesting configuration and the demanding one. A guest with one
# vCPU never has to bring a second processor up through two layers of
# hypervisor; a guest with several does, and that is the part of nested
# virtualization still being stabilised.
#
# It does not always finish, and the ways it fails are the point. So far: 64
# vCPUs per guest completed on AMD; 2 completed on both AMD and Intel; 8 and 16
# on Intel aborted the L2 with a VM-entry failure; and 4 on one Intel host
# panicked the host itself. Run it on a machine you can afford to lose. When it
# fails, the console log named at the end is the artifact worth keeping.
exec doas /usr/local/libexec/cloudbsd-demo/run-auto-demo-all-cores
