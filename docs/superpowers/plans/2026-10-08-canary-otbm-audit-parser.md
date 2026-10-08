# Canary OTBM Audit Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dependency-free, version-aware Python OTBM reader to the Canary content auditor so it validates map item IDs, duplicate UIDs/tiles and local teleport destinations.

**Architecture:** A small `otbm.py` module memory-maps one OTBM file and walks the escaped OTB node stream with strict bounds checks. `extract_otbm` converts visitor events to collapsed `Fact` records and content diagnostics, then the existing runner, rule engine and artifact writers retain their current interfaces.

**Tech Stack:** Python 3.12 standard library (`mmap`, `dataclasses`, `struct`, `pathlib`), existing `jsonschema` dependency, `unittest`.

**Spec:** `docs/superpowers/specs/2026-10-08-canary-otbm-audit-parser-design.md`

## Global Constraints

- Port only the OTBM subset read by `src/io/fileloader.cpp`, `src/io/iomap.cpp`, `src/map/mapcache.cpp`, and `src/io/io_definitions.hpp`.
- Support OTBM map versions 1 through 5; reject every other version before reading map data.
- Add no third-party parser or graphical-editor dependency.
- Parse every discovered `.otbm` below an enabled audit layer; map identity is the repository-relative OTBM path.
- Do not mutate map files, and preserve the user's existing `data-otservbr-global/world/otservbr-monster.xml` and `data-otservbr-global/world/otservbr copy.otbm` changes.
- Use read-only memory mapping and reject files larger than `maxOtbmFileBytes`; default it to `268435456` bytes.
- Represent binary location as `Location(path, 1, byte_offset + 1)` and state that its column is a byte offset in documentation.
- Collapse repeated map item/AID/UID/teleport facts by map path and value, retaining the first location and `occurrenceCount` attribute.
- Treat duplicate UIDs and duplicate tiles within one map as errors; treat a teleport target missing from that same map as a warning; do not create unmatched-handler findings.
- Keep artifact `schemaVersion` at `1`; increment only `TOOL_VERSION` to `1.1.0` because existing artifact shapes already permit the additional fact domains and attributes.

---

## File structure

| File | Responsibility |
| --- | --- |
| `tools/canary_audit/otbm.py` | Read-only OTBM node walker, typed event records, header validation and bounded field decoding. |
| `tools/canary_audit/extractors.py` | Dispatch `.otbm`, collapse map events into facts and turn local map violations into semantic diagnostics. |
| `tools/canary_audit/config.py` | Expose the validated binary-map byte limit as `AuditConfig.max_otbm_file_bytes`. |
| `tools/canary_audit/config.json` | Set the audited repository's 256 MiB OTBM limit and semantic severities. |
| `tools/canary_audit/schemas/config.schema.json` | Require and bound `maxOtbmFileBytes`. |
| `tools/canary_audit/runner.py` | Replace unavailable OTBM coverage with precise map coverage declarations. |
| `tools/canary_audit/models.py` | Update the tool release value while retaining artifact schema compatibility. |
| `tools/canary_audit/tests/test_otbm.py` | Synthetic binary fixture builders and low-level reader tests. |
| `tools/canary_audit/tests/test_extractors.py` | OTBM extractor dispatch, collapsed facts and diagnostic tests. |
| `tools/canary_audit/tests/test_schema_integration.py` | Deterministic full-audit fixture containing an OTBM map. |
| `tools/canary_audit/README.md` | User-facing capability and binary-location contract. |
| `docs/systems/content-reference-auditor.md` | System behavior, coverage boundary and non-goals. |

## Task 1: Add the binary-map configuration contract

**Files:**
- Modify: `tools/canary_audit/config.py`
- Modify: `tools/canary_audit/config.json`
- Modify: `tools/canary_audit/schemas/config.schema.json`
- Modify: `tools/canary_audit/tests/test_workspace_profiles.py`
- Modify: `tools/canary_audit/tests/test_schema_integration.py`

**Interfaces:**
- Consumes: existing `AuditConfig` construction through `config_from_mapping`.
- Produces: `AuditConfig.max_otbm_file_bytes: int`, always positive and available to every extractor.

- [ ] **Step 1: Write the failing configuration tests**

```python
def test_config_exposes_validated_otbm_byte_limit(self) -> None:
    config = repository_config()
    self.assertEqual(config.max_otbm_file_bytes, 268_435_456)

def test_config_rejects_nonpositive_otbm_byte_limit(self) -> None:
    data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    data["maxOtbmFileBytes"] = 0
    with self.assertRaisesRegex(ConfigError, "maxOtbmFileBytes"):
        config_from_mapping(data)
```

Add a schema test that changes `maxOtbmFileBytes` to `0` and expects
`SchemaError` from `validate_instance("config.schema.json", data)`.

- [ ] **Step 2: Run the focused tests and verify failure**

```powershell
$py = Join-Path $env:LocalAppData 'Programs\Python\Python312\python.exe'
& $py -m unittest tools.canary_audit.tests.test_workspace_profiles tools.canary_audit.tests.test_schema_integration -v
```

Expected: the new property is absent or schema validation accepts no map limit.

- [ ] **Step 3: Implement the validated configuration field**

Add `max_otbm_file_bytes: int` immediately after `max_xml_file_bytes` in
`AuditConfig`. Parse the JSON value using the same positive-limit validation
path as other limits, with this exact diagnostic on invalid input:

```python
raise ConfigError("scan limits must be positive")
```

Require the JSON field in the schema and use this bounded definition:

```json
"maxOtbmFileBytes": { "type": "integer", "minimum": 1, "maximum": 1073741824 }
```

Set the checked-in configuration field to:

```json
"maxOtbmFileBytes": 268435456,
```

Place it next to `maxXmlFileBytes`. Preserve the schema version and all other
limit behavior.

- [ ] **Step 4: Run the focused tests and schema validation**

```powershell
& $py -m unittest tools.canary_audit.tests.test_workspace_profiles tools.canary_audit.tests.test_schema_integration -v
& $py -m tools.canary_audit validate-schemas
```

Expected: all selected tests pass and the bundled schemas validate.

- [ ] **Step 5: Commit the configuration contract**

```powershell
git add tools/canary_audit/config.py tools/canary_audit/config.json tools/canary_audit/schemas/config.schema.json tools/canary_audit/tests/test_workspace_profiles.py tools/canary_audit/tests/test_schema_integration.py
git commit -m "feat(audit): configure bounded OTBM inputs"
```

## Task 2: Implement a strict streaming OTBM reader

**Files:**
- Create: `tools/canary_audit/otbm.py`
- Create: `tools/canary_audit/tests/test_otbm.py`

**Interfaces:**
- Consumes: `Path` and an integer `max_file_bytes` from Task 1.
- Produces: `walk_otbm(path: Path, max_file_bytes: int, on_tile: Callable[[OtbmTile], None], on_item: Callable[[OtbmItem], None]) -> OtbmHeader`.
- Produces: immutable `OtbmHeader(version: int, width: int, height: int)`, `OtbmTile(position: tuple[int, int, int], offset: int)`, and `OtbmItem(item_id: int, position: tuple[int, int, int], offset: int, action_id: int | None, unique_id: int | None, teleport_destination: tuple[int, int, int] | None, depth: int)`.
- Produces: `OtbmError(ValueError)` for every invalid binary input; callers do not need to distinguish internal decoding exceptions.

- [ ] **Step 1: Write failing reader tests with a minimal binary fixture builder**

Create builders inside `test_otbm.py` that use Canary's exact framing:

```python
START, END, ESCAPE = 0xFE, 0xFF, 0xFD

def escaped(payload: bytes) -> bytes:
    return payload.replace(bytes([ESCAPE]), bytes([ESCAPE, ESCAPE])) \
        .replace(bytes([START]), bytes([ESCAPE, START])) \
        .replace(bytes([END]), bytes([ESCAPE, END]))

def node(kind: int, props: bytes = b"", children: bytes = b"") -> bytes:
    return bytes([START, kind]) + escaped(props) + children + bytes([END])
```

Write tests that assert all of the following:

```python
header = walk_otbm(path, 1024, tiles.append, items.append)
self.assertEqual((header.version, header.width, header.height), (4, 18, 18))
self.assertEqual(items[0].item_id, 321)
self.assertEqual(items[0].action_id, 5000)
self.assertEqual(items[0].unique_id, 6000)
self.assertEqual(items[0].teleport_destination, (101, 102, 7))
self.assertEqual(items[1].depth, 1)
```

Add individual tests for a non-`OTBM` identifier, version `6`, a file larger
than the passed limit, a dangling escape byte, a truncated `uint16`, an
unterminated node and an unexpected child node. Each must use
`self.assertRaisesRegex(OtbmError, ...)` with a stable phrase such as
`"unsupported OTBM version"` or `"truncated OTBM"`.

- [ ] **Step 2: Run the reader tests and verify failure**

```powershell
& $py -m unittest tools.canary_audit.tests.test_otbm -v
```

Expected: import failure because `tools.canary_audit.otbm` does not exist.

- [ ] **Step 3: Implement the OTBM node walker**

Create `otbm.py` with these constants copied from `io_definitions.hpp`:

```python
OTBM_ROOTV1 = 1
OTBM_MAP_DATA = 2
OTBM_TILE_AREA = 4
OTBM_TILE = 5
OTBM_ITEM = 6
OTBM_HOUSETILE = 14
OTBM_TILE_ZONE = 19
OTBM_ATTR_TILE_FLAGS = 3
OTBM_ATTR_ACTION_ID = 4
OTBM_ATTR_UNIQUE_ID = 5
OTBM_ATTR_TELE_DEST = 8
OTBM_ATTR_ITEM = 9
```

Map the file read-only with `mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ)`
only after `path.stat().st_size <= max_file_bytes`. Validate the first four
bytes equal `b"OTBM"`. Decode escaped property streams so `0xFD` removes
itself and makes the next byte literal, exactly as `OTB::Loader::getProps`.

For a root node, decode the five header fields in this order:

```python
version = read_u32()
width = read_u16()
height = read_u16()
major_items = read_u32()
minor_items = read_u32()
```

Reject `version > 5`, reject `major_items < 3`, require `OTBM_MAP_DATA`, and
walk each `OTBM_TILE_AREA` as `base_x:u16`, `base_y:u16`, `base_z:u8`. Accept
only normal/house tile children. Decode a normal tile's `x:u8`, `y:u8`; skip a
house tile's `house_id:u32`; then parse the optional tile flags and ground-item
attribute before child item nodes.

For every item node, read `item_id:u16`, then consume these fields where
present: action and unique IDs as `u16`, teleport destination as `u16,u16,u8`,
and known ignored attributes using their exact fixed/string sizes. Recursively
visit only nested `OTBM_ITEM` nodes. Raise `OtbmError` at the byte offset for
any field underflow, unescaped structural byte in properties, unknown node in a
tile/item context, or missing expected end node. Always close the memory map
and file handle with nested context managers.

- [ ] **Step 4: Run reader tests and static syntax compilation**

```powershell
& $py -m unittest tools.canary_audit.tests.test_otbm -v
& $py -m py_compile tools/canary_audit/otbm.py
```

Expected: every reader test passes and `py_compile` emits no output.

- [ ] **Step 5: Commit the standalone reader**

```powershell
git add tools/canary_audit/otbm.py tools/canary_audit/tests/test_otbm.py
git commit -m "feat(audit): add bounded Canary OTBM reader"
```

## Task 3: Extract map facts and map-local semantic diagnostics

**Files:**
- Modify: `tools/canary_audit/extractors.py`
- Modify: `tools/canary_audit/tests/test_extractors.py`
- Modify: `tools/canary_audit/tests/test_otbm.py`

**Interfaces:**
- Consumes: `walk_otbm` from Task 2 and `AuditConfig.max_otbm_file_bytes` from Task 1.
- Produces: `extract_otbm(path: DiscoveredFile, config: AuditConfig) -> ExtractionResult`.
- Produces: `Fact` domains `item.server_id`, `map.action_id`, `map.unique_id`, and `map.teleport.destination`, all with role `reference` and extractor `otbm.map`.
- Produces: semantic diagnostics `otbm.duplicate-unique-id`, `otbm.duplicate-tile`, and `otbm.missing-teleport-target`; operational parse failures use `scan.otbm-error`.

- [ ] **Step 1: Write failing extractor tests**

Import `extract_otbm` and fixture helpers from `test_otbm.py`. Use a valid map
with two copies of item `321`, one AID `5000`, one UID `6000`, one nested UID
`6001`, and a teleport to an existing tile. Assert collapsed facts rather than
one fact per repeated item:

```python
facts = {(fact.domain, fact.value, dict(fact.attributes).get("occurrenceCount")) for fact in result.facts}
self.assertIn(("item.server_id", 321, "2"), facts)
self.assertIn(("map.action_id", 5000, "1"), facts)
self.assertIn(("map.unique_id", 6001, "1"), facts)
self.assertIn(("map.teleport.destination", "101,102,7", "1"), facts)
self.assertEqual(result.facts[0].location.line, 1)
self.assertGreater(result.facts[0].location.column, 1)
```

Add fixtures that produce a repeated UID, a repeated tile coordinate and a
teleport to `(999, 999, 7)`. Assert their diagnostic codes are exactly:

```python
{"otbm.duplicate-unique-id", "otbm.duplicate-tile", "otbm.missing-teleport-target"}
```

Add dispatch tests for `extract_file`: `.otbm` inside `data-otservbr-global`
returns OTBM facts, while one outside configured layers returns no facts. Add
a malformed OTBM fixture and assert the only diagnostic is `scan.otbm-error`.

- [ ] **Step 2: Run extractor tests and verify failure**

```powershell
& $py -m unittest tools.canary_audit.tests.test_extractors -v
```

Expected: import failure for `extract_otbm` or no `.otbm` dispatch.

- [ ] **Step 3: Implement extractor integration and bounded aggregation**

Add this dispatch before the Lua/XML cases in `extract_file`:

```python
if path.extension == ".otbm":
    return extract_otbm(path, config)
```

Implement `extract_otbm` with three per-file maps:

```python
seen_tiles: dict[tuple[int, int, int], OtbmTile] = {}
seen_uids: dict[int, OtbmItem] = {}
teleports: list[OtbmItem] = []
aggregates: dict[tuple[str, int | str], tuple[Fact, int]] = {}
```

`on_tile` stores the first coordinate and emits `otbm.duplicate-tile` for a
second occurrence. `on_item` creates an `item.server_id` fact, and creates
selector/teleport facts only when the relevant field is non-`None`. Use facts
with these exact common fields:

```python
Fact(
    domain=domain,
    role="reference",
    value=value,
    layer=layer,
    profiles=config.profiles_for_layer(layer),
    location=Location(path.path, 1, item.offset + 1),
    extractor="otbm.map",
    owner="OTBM item",
    attributes=(("position", f"{x},{y},{z}"), ("depth", str(item.depth))),
)
```

When a key repeats, retain the first fact and replace its attributes with the
same position/depth plus `("occurrenceCount", str(count))`. Before returning,
also assign `occurrenceCount="1"` to single facts. Emit duplicate-UID and
missing-teleport-target diagnostics with `identity` that includes map path and
the UID or coordinate; use the duplicate item's binary location. Catch only
`OSError` and `OtbmError`, converting them to one `scan.otbm-error` diagnostic.
Honor `max_facts_per_file` and `max_diagnostics_per_file` while appending, using
the same extraction-limit behavior as existing extractors.

- [ ] **Step 4: Run focused extractor and reader tests**

```powershell
& $py -m unittest tools.canary_audit.tests.test_otbm tools.canary_audit.tests.test_extractors -v
```

Expected: all map fact, duplicate, missing-target and malformed-input tests pass.

- [ ] **Step 5: Commit map extraction**

```powershell
git add tools/canary_audit/extractors.py tools/canary_audit/tests/test_extractors.py tools/canary_audit/tests/test_otbm.py
git commit -m "feat(audit): extract OTBM map references"
```

## Task 4: Publish coverage, integrate artifacts, and verify real maps

**Files:**
- Modify: `tools/canary_audit/config.json`
- Modify: `tools/canary_audit/models.py`
- Modify: `tools/canary_audit/runner.py`
- Modify: `tools/canary_audit/tests/test_schema_integration.py`
- Modify: `tools/canary_audit/README.md`
- Modify: `docs/systems/content-reference-auditor.md`

**Interfaces:**
- Consumes: `extract_otbm` facts and semantic diagnostic codes from Task 3.
- Produces: schema-valid audit artifacts whose coverage marks OTBM parsing available and selector linkage informational.
- Produces: tool version `1.1.0` with unchanged artifact schema version.

- [ ] **Step 1: Write failing integration and coverage tests**

Extend `_write_minimal_workspace` to add a synthetic
`data-canary/world/test.otbm` constructed by the shared fixture builder. Add
these assertions after the two deterministic scans:

```python
self.assertIn(
    "map.action_id",
    {fact["domain"] for fact in first.symbol_registry["facts"]},
)
coverage = {entry["domain"]: entry for entry in first.symbol_registry["coverage"]}
self.assertEqual(coverage["map.otbm"]["status"], "authoritative")
self.assertEqual(coverage["action/movement selectors"]["status"], "partial")
self.assertEqual(first.symbol_registry["toolVersion"], "1.1.0")
```

Add a direct `run_audit(..., prefer_git=False)` fixture containing an unknown
map item ID `65530`; assert it creates the existing
`reference.missing-definition` finding for `item.server_id`.

- [ ] **Step 2: Run integration tests and verify failure**

```powershell
& $py -m unittest tools.canary_audit.tests.test_schema_integration -v
```

Expected: map coverage remains unavailable, `map.action_id` is absent, or the
tool version is still `1.0.0`.

- [ ] **Step 3: Update reporting configuration and documentation**

Set these severities in `config.json`:

```json
"otbm.duplicate-unique-id:*": "error",
"otbm.duplicate-tile:*": "error",
"otbm.missing-teleport-target:*": "warning"
```

Set `TOOL_VERSION = "1.1.0"`. Replace the two OTBM-related coverage records in
`runner._coverage()` with:

```python
{
    "domain": "action/movement selectors",
    "status": "partial",
    "details": "Lua registrations and OTBM AID/UID selector instances are indexed; handler completeness is informational",
},
{
    "domain": "map.otbm",
    "status": "authoritative",
    "details": "OTBM v1-v5 tiles, nested items, item IDs, AIDs, UIDs and local teleport destinations are structurally validated per map file",
},
```

Replace the README and system-document statements that OTBM is unavailable.
Document the three map diagnostics, per-file UID/tile scope, the 256 MiB limit,
the binary `column` convention, all-discovered-map scope, and why unmatched
handlers remain informational.

- [ ] **Step 4: Run the complete automated verification suite**

```powershell
& $py -m tools.canary_audit validate-schemas
& $py -m unittest discover -s tools/canary_audit/tests -t . -p "test_*.py" -v
& $py -m tools.canary_audit scan --profile all --output-dir artifacts/canary-audit-otbm --fail-on error
& $py -m tools.canary_audit validate --input-dir artifacts/canary-audit-otbm
```

Expected: schemas and tests pass; the scan is complete; generated artifacts
validate. If the scan returns a finding exit code, preserve the artifacts,
report each new finding to the user, and do not add a baseline waiver without
their review.

- [ ] **Step 5: Review the change and commit**

```powershell
git diff --check
git status --short
git add tools/canary_audit/config.json tools/canary_audit/models.py tools/canary_audit/runner.py tools/canary_audit/tests/test_schema_integration.py tools/canary_audit/README.md docs/systems/content-reference-auditor.md
git commit -m "feat(audit): validate OTBM map content"
```

Inspect `git status --short` before staging. Stage only the files listed above;
do not stage the user's modified monster XML, local OTBM copy, or generated
artifacts.

## Plan self-review

- **Spec coverage:** Tasks 1–3 implement the bounded, version-aware,
  read-only parser, all-map discovery, nested items, map facts and local
  diagnostics. Task 4 adds the documented coverage, release value, schema-valid
  integration test and real-map verification. Runtime map order and handler
  completeness remain explicitly informational.
- **Placeholder scan:** The plan contains concrete paths, interfaces, tests,
  commands, diagnostic codes, configuration values and commits; it has no
  deferred implementation markers.
- **Type consistency:** Task 2 defines `walk_otbm`, `OtbmHeader`, `OtbmTile`,
  `OtbmItem` and `OtbmError`; Task 3 consumes those exact names. Task 1 defines
  `max_otbm_file_bytes`, which Task 3 passes to the reader. Task 4 consumes the
  fact and diagnostic domains produced by Task 3.
