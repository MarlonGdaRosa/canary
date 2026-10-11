from __future__ import annotations

import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]
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
            "lookType = 1841",
            'class = "Plant"',
            "race = BESTY_RACE_PLANT",
            "monster.raceId = 2542",
            "Occurrence = 0",
            'Locations = "Manual spawn only."',
        ):
            self.assertIn(expected, pupated)


if __name__ == "__main__":
    unittest.main()
