#!/bin/sh
# The automatic demo. Boots a guest (L1) on this host; that guest boots
# another guest (L2) inside itself, which prints NESTED_DEMO_L2_OK.
# Takes about two minutes and cleans up after itself.
#
# Both guests get one vCPU unless you ask for more:
#
#     sh 1-run-nested-demo.sh -c 4      four vCPUs per guest
#     sh 1-run-nested-demo.sh -c all    every core this host has
#
# or run 3-run-nested-demo-all-cores.sh, which is the second form.
exec doas /usr/local/libexec/cloudbsd-demo/run-auto-demo "$@"
