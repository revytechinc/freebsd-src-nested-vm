#!/bin/sh
# The step-through demo. Boots Layer 1 and hands you its console, so you
# can descend a layer at a time and look around at each one:
#
#     uname -a           where am I
#     cat go-deeper.sh   read what the next step does
#     sh ./go-deeper.sh  descend one layer
#     poweroff           climb back up one layer
#
# Each run gets a private copy of the disk, so it always starts clean.
#
# Each layer gets one vCPU unless you ask for more:
#
#     sh 2-step-through.sh -c 4        four vCPUs per layer
#     sh 2-step-through.sh -c all      every core this host has
exec doas /usr/local/libexec/cloudbsd-demo/run-stepthrough "$@"
