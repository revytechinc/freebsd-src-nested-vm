# nested-virt measurement store

A SQLite database that keeps every nested-virtualization measurement, and the
tools that fill it, query it and publish from it.

Before this existed, figures lived in one-off log files in a home directory on
whichever machine produced them. They were lost between sessions, could not be
compared across weeks, and could not answer the one question that matters most
after a regression: *which build was this measured on?*

## Design, and the two things it refuses to do

**It never overwrites a result.** `UPDATE` and `DELETE` on `run` and
`measurement` abort in a trigger. A re-run inserts a new row. Correcting a
wrong figure means recording a new run that supersedes it and saying so in
`notes`, so a published number can always be traced to the run that produced
it — including when a later run disagrees.

**It never stores a result without a build.** `run.build_id` is `NOT NULL`.
A change to shared vmm code voids every prior pass on every machine, so a
figure that cannot name the `vmm.ko` it was taken against is not a weak result,
it is not a result. Three of the log formats in circulation do not record a
build; for those the identity is supplied on the command line or inferred from
the nearest earlier run on that same machine, and the row's `notes` say which,
so an inference is never mistaken for something a log actually said.

Two smaller decisions follow from the same instinct:

* `run` keeps its own copy of the machine's CPU model, core count and RAM.
  Machines get memory added; a past result must keep saying what the machine
  was on the day, not what it is now.
* A reading that is deliberately not a number — `bench.sh` prints
  `-(cache-warm)` when a read never reached a disk — is stored as text.
  A zero would quietly average into a chart.

## Where it lives, and why it is not on the web

The store belongs on the machine that serves the site, because that is where
published figures are consumed, but it must not be reachable over HTTPS. It
therefore sits on the **host** filesystem, outside every jail root:

    /var/db/nested-stats/nested-stats.db

The web server runs inside a jail and cannot name a path outside its own root,
so there is no configuration mistake, no symlink and no path-traversal bug that
can expose it — the file is not in the server's universe at all. Putting it
under the jail root but outside the document root would have relied on the
server's configuration staying correct forever, which is a weaker promise.

Publication is a separate, deliberate step: `nsdb export` builds an anonymised
document, checks its own output for internal machine names, home paths and
private IPs, and refuses to write the file if it finds any.

## Layout

| file | what it is |
|---|---|
| `schema.sql` | the DDL, with the reasoning for each table |
| `nested_stats/store.py` | connections and the read/write API; `Reader` opens read-only, `Writer` is the only writer |
| `nested_stats/ingest.py` | one parser class per log format |
| `nested_stats/inventory.py` | classification policy for fleet home directories |
| `nested_stats/export.py` | the only path to anything published, with the leak check |
| `nested_stats/cli.py` | `python3 -m nested_stats.cli` |
| `nested_stats/mcp.py` | MCP server over stdio |
| `collect-inventory.sh` | runs on a machine, emits TSV; decides nothing |
| `fleet.conf.sample.json` | shape of the machine/build profile file (the real one is not committed) |

Standard library only. No packages to add on a FreeBSD host.

## Using it

```sh
python3 -m nested_stats.cli init
python3 -m nested_stats.cli seed fleet.conf.json
python3 -m nested_stats.cli ingest /path/to/core-ceiling-*.log
python3 -m nested_stats.cli query --suite core-ceiling --with-measurements
python3 -m nested_stats.cli summary --group-by build
python3 -m nested_stats.cli export /path/to/webroot/stats.json
```

Inventory, collected from a machine and loaded centrally:

```sh
ssh <machine> sh - < collect-inventory.sh > scan.tsv
python3 -m nested_stats.cli inventory-load scan.tsv
python3 -m nested_stats.cli inventory --safe-to-remove 1 --min-bytes 1073741824
```

`safe_to_remove` is an **opinion recorded next to its evidence**, and nothing
here deletes anything. Measurement logs can never carry it; the database
enforces that with a trigger as well as the classifier honouring it, because a
classifier is exactly the kind of code that acquires a clever new rule in a
hurry.

## The MCP server, and why it has no port

`nested_stats/mcp.py` speaks JSON-RPC on stdin and stdout and listens on
nothing. It is launched as `ssh <machine> nested-stats-mcp`, so reaching it
requires already holding an authenticated ssh session on the machine that holds
the database. There is no socket to scan for, no chance of binding the wrong
address, and no forwarded port left open in a shell someone walked away from.

A loopback listener behind `ssh -L` would be equivalent on a good day and worse
on a bad one: a listening socket is reachable by every process on that machine,
including anything in a jail sharing the host's loopback, whereas a process
holding a pipe pair is reachable by its parent and nothing else. The cost is
that the server starts and dies with its client and cannot be shared between
two of them. For a store one orchestration host queries, that is not a cost.

Read and write are different code paths, not a convention: query tools open the
database through SQLite's `mode=ro` URI and physically cannot write, and
`--read-only` drops the writing tools from the advertised list entirely.
