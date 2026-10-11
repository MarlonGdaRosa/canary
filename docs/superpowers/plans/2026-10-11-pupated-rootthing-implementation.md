# Pupated Rootthing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Register a manually spawned Pupated Rootthing with Quara Raider gameplay and a dedicated modern-client plant appearance.

**Architecture:** Compile the verified free look type 1863 in the 15.25 asset catalog, synchronize its selected protobuf to data/items/appearances.dat, and add a Lua monster definition that references it. The pre-import outfit 1841 remains intact. There is no map spawn.

**Tech Stack:** Lua; Tibia 15.25 protobuf/LZMA assets; OTS Creator; Python unittest; OTClient Redemption.

**Spec:** docs/superpowers/specs/2026-10-11-pupated-rootthing-design.md

## Global Constraints

- Do not change an OTBM map or spawn XML; runtime validation is /m Pupated Rootthing.
- Use artifacts/generated-sprites/pupated-rootthing-walksheet-3x4-64px.png unchanged.
- Reserve look type 1863, the lowest unused outfit ID greater than 1841 in the pre-import protobuf; configure it as 2 x 2 sprites, four directions, one layer, three phases. Preserve outfit 1841.
- Retain all Quara Raider combat, loot, corpse, voices, flags, elements, immunities, and monster.race.
- Use Bestiary Plant / BESTY_RACE_PLANT, raceId 2542, Occurrence 0, and Locations Manual spawn only.
- The catalog-selected appearance and data/items/appearances.dat must be byte-identical.

---

## File Structure

- tools/canary_audit/tests/test_pupated_rootthing.py — regression checks.
- data-otservbr-global/monster/plants/pupated_rootthing.lua — autoloaded monster definition.
- .tools/otclient-redemption/data/things/1525/catalog-content.json — updated client catalog.
- The catalog-selected `appearances-*.dat` file and its newly generated `sprites-*.bmp.lzma` files in `.tools/otclient-redemption/data/things/1525` — generated client data.
- data/items/appearances.dat — server copy of the active protobuf.

### Task 1: Add a focused regression gate

**Files:**
- Create: tools/canary_audit/tests/test_pupated_rootthing.py
- Read: data-otservbr-global/monster/aquatics/quara_raider.lua
- Read: .tools/otclient-redemption/data/things/1525/catalog-content.json
- Read: data/items/appearances.dat

**Interfaces:**
- Consumes Quara Raider and the compiled 15.25 catalog.
- Produces PupatedRootthingIntegrationTest for later tasks.

- [ ] **Step 1: Write the failing test**

Create this module:

~~~python
from __future__ import annotations

import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
THINGS = ROOT / ".tools" / "otclient-redemption" / "data" / "things" / "1525"
CATALOG = THINGS / "catalog-content.json"
SERVER_APPEARANCES = ROOT / "data" / "items" / "appearances.dat"
QUARA = ROOT / "data-otservbr-global" / "monster" / "aquatics" / "quara_raider.lua"
PUPATED = ROOT / "data-otservbr-global" / "monster" / "plants" / "pupated_rootthing.lua"


class PupatedRootthingIntegrationTest(unittest.TestCase):
    def test_catalog_appearance_is_the_server_appearance(self) -> None:
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
        entry = next(value for value in catalog if value["type"] == "appearances")
        client_appearance = THINGS / entry["file"]
        self.assertTrue(client_appearance.is_file())
        self.assertEqual(client_appearance.read_bytes(), SERVER_APPEARANCES.read_bytes())

    def test_pupated_is_a_dedicated_plant_copy_of_quara_raider(self) -> None:
        quara = QUARA.read_text(encoding="utf-8")
        pupated = PUPATED.read_text(encoding="utf-8")
        for unchanged in (
            "monster.experience = 8150",
            "monster.health = 12500",
            "monster.maxHealth = 12500",
            'monster.race = "undead"',
            "monster.corpse = 48393",
            "monster.speed = 215",
            "monster.loot = {",
            "monster.attacks = {",
            "monster.defenses = {",
            "monster.elements = {",
            "monster.immunities = {",
        ):
            self.assertIn(unchanged, quara)
            self.assertIn(unchanged, pupated)
        for expected in (
            'Game.createMonsterType("Pupated Rootthing")',
            'monster.description = "a pupated rootthing"',
            "lookType = 1863",
            'class = "Plant"',
            "race = BESTY_RACE_PLANT",
            "monster.raceId = 2542",
            "Occurrence = 0",
            'Locations = "Manual spawn only."',
        ):
            self.assertIn(expected, pupated)


if __name__ == "__main__":
    unittest.main()
~~~

- [ ] **Step 2: Prove the red state**

~~~powershell
python -m unittest tools.canary_audit.tests.test_pupated_rootthing -v
~~~

Expected: the definition test fails with FileNotFoundError for pupated_rootthing.lua; the asset-pair test may also fail until Task 2.

- [ ] **Step 3: Commit the test**

~~~powershell
git add -- tools/canary_audit/tests/test_pupated_rootthing.py
git commit -m "test: cover Pupated Rootthing integration"
~~~

### Task 2: Compile and synchronize the 15.25 appearance

**Files:**
- Modify: .tools/otclient-redemption/data/things/1525/catalog-content.json
- Create/Modify: the `appearances-*.dat` file selected by catalog-content.json
- Create/Modify: the `sprites-*.bmp.lzma` files emitted beside that catalog
- Modify: data/items/appearances.dat
- Test: tools/canary_audit/tests/test_pupated_rootthing.py

**Interfaces:**
- Consumes the 192 x 256 transparent sheet and look type 1863.
- Produces the catalog-selected protobuf and a byte-identical server copy.

- [ ] **Step 1: Create a recoverable backup**

~~~powershell
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$source = '.tools\otclient-redemption\data\things\1525'
$backup = ".tools\otclient-redemption\data\things\1525.before-pupated-rootthing-$stamp"
Copy-Item -LiteralPath $source -Destination $backup -Recurse -ErrorAction Stop
~~~

- [ ] **Step 2: Import the creature in OTS Creator**

Start C:\Users\Marlon\Downloads\otscreator-windows-amd64.exe. Open .tools\otclient-redemption\data\things\1525\catalog-content.json. In Outfits, create ID 1863 called Pupated Rootthing. The raw 192 x 256 sheet is not recognized by OTS Creator's direct sprite-sheet importer, so losslessly transpose its 64 x 64 frames into the documented ObjectBuilder layout, package the idle and walking sheets in a native `.otobj`, and import that package through OTS Creator. Configure:

~~~text
width = 2 sprites
height = 2 sprites
directions = 4; row order North, East, South, West
layers = 1
animation phases = 3; column order 1, 2, 3
~~~

Keep transparency intact; preview all four directions and three walking phases; compile/save back into the same 1525 directory.

- [ ] **Step 3: Synchronize the server protobuf**

~~~powershell
$things = '.tools\otclient-redemption\data\things\1525'
$catalog = Get-Content (Join-Path $things 'catalog-content.json') -Raw | ConvertFrom-Json
$entry = $catalog | Where-Object type -eq 'appearances' | Select-Object -Single
$source = Join-Path $things $entry.file
if (-not $entry -or -not (Test-Path -LiteralPath $source)) {
    throw 'The saved catalog does not reference an existing appearances protobuf.'
}
Copy-Item -LiteralPath $source -Destination 'data\items\appearances.dat' -Force
~~~

- [ ] **Step 4: Verify the asset pairing**

~~~powershell
python -m unittest tools.canary_audit.tests.test_pupated_rootthing.PupatedRootthingIntegrationTest.test_catalog_appearance_is_the_server_appearance -v
~~~

Expected: PASS. If it fails, restore the Task 2 backup and inspect the catalog appearances entry before editing Lua.

- [ ] **Step 5: Commit only source assets, not the backup**

~~~powershell
git add -- .tools/otclient-redemption/data/things/1525/catalog-content.json data/items/appearances.dat
git add -- .tools/otclient-redemption/data/things/1525/appearances-*.dat .tools/otclient-redemption/data/things/1525/sprites-*.bmp.lzma
git commit -m "feat: add Pupated Rootthing client appearance"
~~~

### Task 3: Register the Plant monster

**Files:**
- Create: data-otservbr-global/monster/plants/pupated_rootthing.lua
- Source: data-otservbr-global/monster/aquatics/quara_raider.lua
- Test: tools/canary_audit/tests/test_pupated_rootthing.py

**Interfaces:**
- Consumes look type 1863 and Quara Raider gameplay data.
- Produces the exact GM lookup name Pupated Rootthing.

- [ ] **Step 1: Copy the gameplay template**

~~~powershell
Copy-Item -LiteralPath 'data-otservbr-global\monster\aquatics\quara_raider.lua' -Destination 'data-otservbr-global\monster\plants\pupated_rootthing.lua' -ErrorAction Stop
~~~

- [ ] **Step 2: Change only identity and Bestiary values**

Use these exact snippets:

~~~lua
local mType = Game.createMonsterType("Pupated Rootthing")
local monster = {}

monster.description = "a pupated rootthing"
monster.experience = 8150
monster.outfit = {
	lookType = 1863,
~~~

~~~lua
monster.raceId = 2542
monster.Bestiary = {
	class = "Plant",
	race = BESTY_RACE_PLANT,
	toKill = 2500,
	FirstUnlock = 100,
	SecondUnlock = 1000,
	CharmsPoints = 50,
	Stars = 4,
	Occurrence = 0,
	Locations = "Manual spawn only.",
}
~~~

Leave monster.race = "undead", corpse 48393, flags, voices, loot, attacks, defenses, elements, and immunities identical to Quara Raider.

- [ ] **Step 3: Run regression checks**

~~~powershell
python -m unittest tools.canary_audit.tests.test_pupated_rootthing -v
python -m unittest tools.canary_audit.tests.test_schema_integration -v
~~~

Expected: both commands PASS.

- [ ] **Step 4: Commit the definition**

~~~powershell
git add -- data-otservbr-global/monster/plants/pupated_rootthing.lua
git commit -m "feat: add Pupated Rootthing monster"
~~~

### Task 4: Validate GM spawn and visual isolation

**Files:**
- Read: data-otservbr-global/monster/plants/pupated_rootthing.lua
- Read: .tools/otclient-redemption/data/things/1525/catalog-content.json

**Interfaces:**
- Consumes saved client assets and the registered monster.
- Produces runtime evidence for manual spawning.

- [ ] **Step 1: Restart the server and local protocol-1525 OTClient Redemption**

Restart is required so the monster loader discovers the new Lua file. Use the edited data/things/1525 assets rather than a downloaded asset cache.

- [ ] **Step 2: Spawn it as GM**

~~~text
/m Pupated Rootthing
~~~

Expected: the named monster appears with Quara Raider behavior and the rooted plant visual.

- [ ] **Step 3: Verify animation and non-regression**

Inspect all directions and confirm three walking phases. Spawn a Quara Raider in the same session and confirm it remains look type 1759 with its original sprite.

- [ ] **Step 4: Capture final state**

~~~powershell
$catalog = Get-Content '.tools\otclient-redemption\data\things\1525\catalog-content.json' -Raw | ConvertFrom-Json
$entry = $catalog | Where-Object type -eq 'appearances' | Select-Object -Single
"lookType=1863 appearance=$($entry.file)"
git status --short
~~~

Expected: only intentional Pupated Rootthing changes plus pre-existing CanaryAAC files remain.
