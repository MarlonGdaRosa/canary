from __future__ import annotations

import json
import lzma
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
PUPATED_SPRITE_FIRST_ID = 290261
PUPATED_SPRITE_LAST_ID = 290272


def decode_cip_sprite_sheet(path: Path) -> bytes:
    """Decode the raw-LZMA bitmap layout used by OTClient sprite sheets."""
    compressed = path.read_bytes()
    offset = 0
    while compressed[offset] == 0:
        offset += 1
    offset += 5
    while compressed[offset] & 0x80:
        offset += 1
    offset += 1

    properties = compressed[offset]
    offset += 1
    dictionary_size = int.from_bytes(compressed[offset : offset + 4], "little")
    offset += 12
    remainder = properties // 9
    raw = lzma.decompress(
        compressed[offset:],
        format=lzma.FORMAT_RAW,
        filters=[
            {
                "id": lzma.FILTER_LZMA1,
                "dict_size": dictionary_size,
                "lc": properties % 9,
                "lp": remainder % 5,
                "pb": remainder // 5,
            }
        ],
    )
    bitmap_offset = int.from_bytes(raw[10:14], "little")
    return raw[bitmap_offset : bitmap_offset + 384 * 384 * 4]


def sprite_visible_pixel_count(pixels: bytes, sprite_offset: int) -> int:
    column, row = sprite_offset % 6, sprite_offset // 6
    visible = 0
    for y in range(64):
        for x in range(64):
            # The stored BMP rows are bottom-up; OTClient flips them while loading.
            bitmap_y = 383 - (row * 64 + y)
            pixel_offset = (bitmap_y * 384 + (column * 64 + x)) * 4
            blue, green, red, alpha = pixels[pixel_offset : pixel_offset + 4]
            if alpha and (blue, green, red) != (255, 0, 255):
                visible += 1
    return visible


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
            "lookType = 1768",
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

    def test_compiled_pupated_frames_are_visible(self) -> None:
        if not CATALOG.is_file():
            self.skipTest("local OTClient 15.25 assets are not available in this checkout")
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
        sheet = next(
            value
            for value in catalog
            if value["type"] == "sprite"
            and value["firstspriteid"] == PUPATED_SPRITE_FIRST_ID
            and value["lastspriteid"] == PUPATED_SPRITE_LAST_ID
        )
        self.assertEqual(sheet["spritetype"], 3)
        pixels = decode_cip_sprite_sheet(THINGS / sheet["file"])
        self.assertEqual(len(pixels), 384 * 384 * 4)
        for sprite_offset in range(PUPATED_SPRITE_LAST_ID - PUPATED_SPRITE_FIRST_ID + 1):
            visible = sprite_visible_pixel_count(pixels, sprite_offset)
            self.assertGreaterEqual(
                visible,
                100,
                f"Pupated Rootthing sprite {PUPATED_SPRITE_FIRST_ID + sprite_offset} is transparent",
            )


if __name__ == "__main__":
    unittest.main()
