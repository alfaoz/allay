# allay

allay is a package manager for CC: Tweaked.

## Why allay

Most CC software gets installed with `wget run`, which is fine until you're
installing programs that depend on other programs that depend on libraries
you didn't know existed. Then you're managing a small forest of files by
hand, and updates are an exercise in patience.

allay handles the actual problem. Dependencies install themselves, updates
apply across everything at once, and removals can clean up the things that
came along just for the package you're removing.

## Install

    wget run https://raw.githubusercontent.com/allaycc/allay/main/install.lua

## Use

    allay install <package>
    allay update
    allay search <query>
    allay help

## Sources

Sources are configured at `/etc/allay/sources.lua`. Add one with:

    allay source add <user/repo>           # GitHub shorthand
    allay source add https://example.com/  # any HTTPS URL

allay supports HTTPS and floppy-disk sources out of the box. For rednet
sources, install `allay-rednet-transport`. Packages in unicornpkg format
work too (after `allay install alicorn`).

## Authoring

Drop an `allay.lua` in your repo, list it in your source's `index.lua`,
and tag a release. See [allay-spec](https://github.com/allaycc/spec)
for the format.

## Repository layout

This repo contains allay's CLI and core libraries.

- `bin/allay.lua` — the CLI entry point
- `lib/` — internal modules
- `install.lua` — bootstrap installer
- `tests/` — test suites

Related repos:

- [allay-spec](https://github.com/allaycc/spec) — file format
  documentation
- [allay-core](https://github.com/allaycc/core) — default source
  catalog (allay's own libs as packages)
- [lualibs](https://github.com/allaycc/lualibs) — source code for hash,
  httpkit, pathkit, log, argparse
- [allay-rednet-transport](https://github.com/allaycc/rednet-transport) —
  rednet:// transport extension
- [allay-server](https://github.com/allaycc/server) — rednet
  package host
- [alicorn](https://github.com/allaycc/alicorn) —
  read packages in unicornpkg's format

## Tests

    cd tests && lua run_all.lua

## License

MIT.
