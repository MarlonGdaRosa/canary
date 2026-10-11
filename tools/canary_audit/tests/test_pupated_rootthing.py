from __future__ import annotations

import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
THINGS = ROOT / ".tools" / "otclient-redemption" / "data" / "things" / "1525"
CATALOG = THINGS / "catalog-content.json"
SERVER_APPEARANCES = ROOT / "data" / "items" / "appearances.dat"
QUARA = ROOT / "data-otservbr-global" / "monster" / "aquatics" / "quara_raider.lua"
PUPATED = ROOT / "data-otservbr-global" / "monster" / "plants" / "pupated_rootthing.lua"
MONSTERS = ROOT / "data-otservbr-global" / "monster"


class PupatedRootthingIntegrationTest(unittest.TestCase):
    def test_catalog_appearance_is_the_server_appearance(self) -> None:
        if not CATALOG.is_file():
            self.skipTest("local OTClient 15.25 assets are not available in this checkout")
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
            "monster.raceId = 2544",
            "Occurrence = 0",
            'Locations = "Manual spawn only."',
        ):
            self.assertIn(expected, pupated)

    def test_pupated_race_id_is_not_assigned_to_another_monster(self) -> None:
        race_id_assignment = re.compile(r"^\s*monster\.raceId\s*=\s*2544\b", re.MULTILINE)
        duplicates = [
            path.relative_to(ROOT).as_posix()
            for path in MONSTERS.rglob("*.lua")
            if path != PUPATED and race_id_assignment.search(path.read_text(encoding="utf-8"))
        ]
        self.assertEqual(duplicates, [], f"Pupated Rootthing raceId 2544 is also assigned in: {duplicates}")


if __name__ == "__main__":
    unittest.main()
