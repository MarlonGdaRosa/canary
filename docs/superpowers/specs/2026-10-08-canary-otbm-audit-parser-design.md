# Canary OTBM audit parser — design

**Date:** 2026-10-08  
**Status:** approved design; implementation pending plan review

## Context

`tools/canary_audit` currently extracts semantic facts from Lua, XML and the
item appearance catalog, but reports OTBM coverage as unavailable. The active
OTServBR Global map is OTBM version 4 and is about 185 MiB. A compatible
extractor must therefore be binary-safe, bounded, deterministic and independent
of the graphical map editor.

The source of truth is the repository's Canary reader:

- `src/io/fileloader.cpp` for OTB's `START`/`END`/`ESCAPE` node encoding;
- `src/io/iomap.cpp` for the OTBM header and tile hierarchy; and
- `src/io/io_definitions.hpp` for node and attribute identifiers.

No third-party OTBM parser will be introduced. The investigated Python/Go
alternatives do not cover this map version and its current node conventions.

## Scope

Every discovered `*.otbm` below an enabled audit layer is parsed. Files are
kept as separate map identities: a duplicate UID or duplicate tile is reported
only within the same OTBM file. This permits audit of main maps and optional
fragments without falsely treating separately loadable maps as one world.

Git discovery includes untracked files by design, so a local map copy is also
audited when it is beneath an enabled layer. The extractor never writes map
files.

The first delivery covers OTBM versions 1 through 5, which is the acceptance
range in Canary. It reads map data, tile areas, normal tiles, house tiles,
item nodes and recursively nested item nodes. It records item IDs, action IDs,
unique IDs, tile coordinates and teleport destinations.

It deliberately does not prove the runtime load order of arbitrary
`Game.loadMap` calls, emulate item serialization, validate monster/NPC spawns,
or decide whether an AID/UID must be served by Action versus MoveEvent. Those
claims need runtime context that the static audit does not have.

## Architecture

`tools/canary_audit/otbm.py` will contain a small, dependency-free reader.
It opens a map read-only with Python's `mmap`, walks the escaped node stream
without building the complete node tree, and exposes typed, bounds-checked
little-endian reads. The reader produces concise map records while scanning:

```text
OTBM file
  -> binary node walker
  -> tile/item visitor (including container children)
  -> facts + structural diagnostics
  -> existing audit runner and report artifacts
```

The extractor will be dispatched from `extract_file` for `.otbm` files.
`mmap` keeps peak memory proportional to the operating system page cache and
the audit's retained facts, rather than requiring a second 185 MiB Python byte
buffer. A new `maxOtbmFileBytes` configuration limit will reject unexpectedly
large binary inputs before mapping them; the repository default will be 256
MiB, above the current 184,776,037-byte maps.

Facts use existing immutable `Fact` objects:

- `item.server_id` / `reference` for every map item ID, allowing the existing
  authoritative appearance-ID rule to find unknown items;
- `map.action_id` / `reference` and `map.unique_id` / `reference` for item
  selectors; and
- `map.teleport.destination` / `reference` for recorded teleport targets.

Binary locations use `line=1` and `column=byte_offset + 1`; documentation and
report text will label that column as an OTBM byte offset. Coordinate, map path
and item ancestry are retained as fact attributes so a finding can be located
in the editor or source map.

## Validation and reporting

Malformed identifiers, unterminated/invalid escaped nodes, truncated fields,
unsupported versions, invalid node relationships and configured size/fact
limits yield a `scan.otbm-*` error. Such errors make the run incomplete, like
the existing Lua/XML input failures.

Exact semantic checks added in the initial delivery are:

1. repeated unique ID inside one OTBM file;
2. repeated tile coordinate inside one OTBM file;
3. teleport destination with no tile in that same OTBM file; and
4. map item ID without an `Appearances.object` definition, via the existing
   `item.server_id` reference rule.

Map AIDs/UIDs and Action/MoveEvent registrations will appear together in the
symbol registry and coverage report. Their unmatched relationship is initially
an informational inventory, not a missing-handler finding or CI gate: an item
can intentionally be handled by engine behavior, and a selector alone does not
identify the event type it needs.

Coverage changes to say that OTBM structural parsing and map-to-item validation
are authoritative, while runtime fragment loading and handler completeness are
partial/informational.

## Tests and documentation

Tests will construct tiny OTBM byte fixtures rather than commit binary map
fixtures. They cover a valid escaped tree, map versions, nested items,
AID/UID/teleport extraction, duplicate UIDs and tiles, missing teleport target,
truncation, unknown attributes/nodes, and size/fact limits. Integration tests
will prove deterministic, schema-valid artifacts that include an OTBM file.

`docs/systems/content-reference-auditor.md`, configuration schema validation,
coverage assertions and audit summaries will be updated with the new boundary
and the meaning of binary locations.

## Safety and rollout

The parser is read-only, does not invoke the map editor or server executable,
and does not alter the user's modified `otservbr-monster.xml` or local
`otservbr copy.otbm`. It will first be run against synthetic fixtures and then
against both repository profiles. Any new findings in the existing maps will be
reported separately for review; no baseline waiver will be added automatically.
