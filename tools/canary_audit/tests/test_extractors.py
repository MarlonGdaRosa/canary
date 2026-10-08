from __future__ import annotations

import tempfile
import struct
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import Mock, patch
from xml.sax import SAXNotSupportedException

from tools.canary_audit.extractors import (
	ExtractionLimitError, extract_appearances, extract_file, extract_lua, extract_otbm, extract_xml,
)

from .helpers import appearances_payload, discovered_file, encode_varint, repository_config
from .test_otbm import area, item, map_file, tile


class OtbmExtractorTests(unittest.TestCase):
	def setUp(self) -> None:
		self.config = repository_config()
		self.temporary = tempfile.TemporaryDirectory()
		self.addCleanup(self.temporary.cleanup)
		self.root = Path(self.temporary.name)
		self.map_path = "data-otservbr-global/world/test.otbm"

	def extract(self, payload: bytes, *, config=None, logical_path=None, dispatch=False):
		path = discovered_file(self.root, logical_path or self.map_path, payload)
		return (extract_file if dispatch else extract_otbm)(path, config or self.config)

	def test_collapses_references_with_first_item_location_and_nested_metadata(self) -> None:
		attrs = b"\x04" + struct.pack("<H", 5000) + b"\x05" + struct.pack("<H", 6000)
		attrs += b"\x08" + struct.pack("<HHB", 101, 102, 7)
		inner = item(322, b"\x05" + struct.pack("<H", 6001))
		outer = item(321, attrs, inner)
		payload = map_file(area(tile(outer, x=2) + tile(item(321))))

		result = self.extract(payload)

		self.assertFalse(result.diagnostics)
		self.assertEqual(
			{(fact.domain, fact.value, dict(fact.attributes)["occurrenceCount"]) for fact in result.facts},
			{
				("item.server_id", 321, "2"), ("item.server_id", 322, "1"),
				("map.action_id", 5000, "1"), ("map.unique_id", 6000, "1"),
				("map.unique_id", 6001, "1"), ("map.teleport.destination", "101,102,7", "1"),
			},
		)
		first = next(fact for fact in result.facts if fact.domain == "item.server_id" and fact.value == 321)
		self.assertEqual(first.location.line, 1)
		self.assertEqual(first.location.column, payload.index(outer) + 1)
		self.assertGreater(result.facts[0].location.column, 1)
		self.assertEqual(dict(first.attributes), {"position": "102,102,7", "depth": "0", "occurrenceCount": "2"})
		nested = next(fact for fact in result.facts if fact.domain == "map.unique_id" and fact.value == 6001)
		self.assertEqual(dict(nested.attributes)["depth"], "1")
		self.assertTrue(all(fact.role == "reference" and fact.extractor == "otbm.map" for fact in result.facts))
		self.assertTrue(all(fact.owner == "OTBM item" and fact.layer == "otservbr-global" for fact in result.facts))
		self.assertTrue(all(fact.profiles == self.config.profiles_for_layer("otservbr-global") for fact in result.facts))

	def test_map_local_duplicates_and_missing_teleport_target(self) -> None:
		uid = b"\x05" + struct.pack("<H", 6000)
		teleport = b"\x08" + struct.pack("<HHB", 999, 999, 7)
		duplicate = item(322, uid + teleport)
		second_tile = tile(duplicate)
		payload = map_file(area(tile(item(321, uid)) + second_tile))

		result = self.extract(payload)

		self.assertEqual({diagnostic.code for diagnostic in result.diagnostics}, {
			"otbm.duplicate-unique-id", "otbm.duplicate-tile", "otbm.missing-teleport-target",
		})
		for diagnostic in result.diagnostics:
			self.assertIn(self.map_path, diagnostic.identity)
			self.assertEqual(diagnostic.location.line, 1)
			self.assertEqual(diagnostic.severity, "error")
			if diagnostic.code == "otbm.duplicate-tile":
				self.assertIn("101,102,7", diagnostic.identity)
				self.assertEqual(diagnostic.location.column, payload.index(second_tile) + 1)
			else:
				self.assertEqual(diagnostic.location.column, payload.index(duplicate) + 1)
				self.assertIn("6000" if diagnostic.code == "otbm.duplicate-unique-id" else "999,999,7", diagnostic.identity)

	def test_dispatch_respects_configured_layers(self) -> None:
		payload = map_file(area(tile(item(321))))
		inside = self.extract(payload, dispatch=True)
		outside = self.extract(payload, logical_path="unconfigured/world/test.otbm", dispatch=True)
		self.assertEqual([(fact.domain, fact.value) for fact in inside.facts], [("item.server_id", 321)])
		self.assertFalse(outside.facts)
		self.assertFalse(outside.diagnostics)

	def test_uid_and_tile_uniqueness_are_scoped_to_each_map_path(self) -> None:
		payload = map_file(area(tile(item(321, b"\x05" + struct.pack("<H", 6000)))))
		for path in (self.map_path, "data-otservbr-global/world/second.otbm"):
			with self.subTest(path=path):
				result = self.extract(payload, logical_path=path)
				self.assertFalse(result.diagnostics)
				self.assertEqual({fact.value for fact in result.facts}, {321, 6000})

	def test_absent_selectors_are_not_fabricated_and_zero_values_are_retained(self) -> None:
		attrs = b"\x04\x00\x00\x05\x00\x00\x08\x00\x00\x00\x00\x00"
		result = self.extract(map_file(area(tile(item(321) + item(322, attrs), x=0, y=0), x=0, y=0, z=0)))
		self.assertEqual({(fact.domain, fact.value) for fact in result.facts}, {
			("item.server_id", 321), ("item.server_id", 322), ("map.action_id", 0),
			("map.unique_id", 0), ("map.teleport.destination", "0,0,0"),
		})
		self.assertFalse(result.diagnostics)

	def test_parse_errors_discard_partial_facts_and_semantic_diagnostics(self) -> None:
		uid = b"\x05" + struct.pack("<H", 6000)
		valid_prefix = map_file(area(tile(item(321, uid)) + tile(item(322, uid))))
		for payload in (b"NOPE", valid_prefix[:-1], map_file(area(tile(item(321, b"\x63"))))):
			with self.subTest(payload=payload):
				result = self.extract(payload)
				self.assertEqual([diagnostic.code for diagnostic in result.diagnostics], ["scan.otbm-error"])
				self.assertFalse(result.facts)

	def test_missing_file_and_file_byte_limit_are_operational_errors(self) -> None:
		payload = map_file(area(tile(item(321))))
		limited = self.extract(payload, config=replace(self.config, max_otbm_file_bytes=len(payload) - 1))
		self.assertEqual([diagnostic.code for diagnostic in limited.diagnostics], ["scan.otbm-error"])
		path = discovered_file(self.root, self.map_path, payload)
		path.absolute_path.unlink()
		missing = extract_otbm(path, self.config)
		self.assertEqual([diagnostic.code for diagnostic in missing.diagnostics], ["scan.otbm-error"])
		self.assertFalse(missing.facts)

	def test_fact_limit_applies_to_distinct_aggregates_not_repeated_items(self) -> None:
		config = replace(self.config, max_facts_per_file=1)
		repeated = self.extract(map_file(area(tile(item(321) * 20))), config=config, dispatch=True)
		self.assertFalse(repeated.diagnostics)
		self.assertEqual(dict(repeated.facts[0].attributes)["occurrenceCount"], "20")
		limited = self.extract(map_file(area(tile(item(321) + item(322)))), config=config, dispatch=True)
		self.assertEqual([diagnostic.code for diagnostic in limited.diagnostics], ["scan.extraction-limit"])
		self.assertFalse(limited.facts)

	def test_tile_and_teleport_retention_are_bounded(self) -> None:
		config = replace(self.config, max_facts_per_file=2)
		teleport = item(321, b"\x08" + struct.pack("<HHB", 101, 102, 7))
		for payload in (map_file(area(tile() + tile(x=2) + tile(x=3))), map_file(area(tile(teleport * 3)))):
			with self.subTest(payload=payload):
				result = self.extract(payload, config=config, dispatch=True)
				self.assertEqual([diagnostic.code for diagnostic in result.diagnostics], ["scan.extraction-limit"])
				self.assertFalse(result.facts)

	def test_diagnostic_limit_uses_existing_extraction_limit_behavior(self) -> None:
		config = replace(self.config, max_diagnostics_per_file=1)
		payload = map_file(area(tile() * 3))
		result = self.extract(payload, config=config, dispatch=True)
		self.assertEqual([diagnostic.code for diagnostic in result.diagnostics], ["scan.extraction-limit"])
		with self.assertRaises(ExtractionLimitError):
			self.extract(payload, config=config)


class LuaExtractorTests(unittest.TestCase):
	def setUp(self) -> None:
		self.config = repository_config()

	def test_comments_constants_and_registered_type_definition(self) -> None:
		source = r'''
-- local fakeType = Game.createMonsterType("Comment Beast")
-- fakeType:register({})
local monsterName = "Canary\z
	 Keeper"
local monsterType = Game.createMonsterType(monsterName)
monsterType:register({})
Game.createMonster("CanaryKeeper", position)
local unregistered = Game.createMonsterType("Not Registered")
'''
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data-canary/monster/test.lua", source)
			result = extract_lua(path, self.config)

		definitions = [fact for fact in result.facts if fact.role == "definition"]
		references = [fact for fact in result.facts if fact.role == "reference"]

		self.assertFalse(result.diagnostics)
		self.assertEqual([(fact.domain, fact.value) for fact in definitions], [("monster.name", "CanaryKeeper")])
		self.assertIn(("monster.name", "CanaryKeeper"), [(fact.domain, fact.value) for fact in references])
		self.assertNotIn("Comment Beast", [fact.value for fact in result.facts])
		self.assertNotIn("Not Registered", [fact.value for fact in result.facts])

	def test_action_item_selector_is_distinct_from_action_and_spell_ids(self) -> None:
		source = '''
local action = Action()
action:id(2160)
action:aid(5000)
action:uid(6000)
action:register()

local spell = Spell("instant")
spell:id(5000)
spell:register()
'''
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/scripts/actions/test.lua", source)
			result = extract_lua(path, self.config)

		facts = {(fact.domain, fact.role, fact.value, fact.owner) for fact in result.facts}
		self.assertIn(("item.server_id", "reference", 2160, "Action.id"), facts)
		self.assertIn(("action.item_id", "registration", 2160, "Action.id"), facts)
		self.assertIn(("action.action_id", "registration", 5000, "Action.aid"), facts)
		self.assertIn(("action.unique_id", "registration", 6000, "Action.uid"), facts)
		self.assertIn(("spell.id", "registration", 5000, "Spell.id"), facts)
		self.assertNotIn(("action.action_id", "registration", 5000, "Spell.id"), facts)

	def test_dynamic_call_is_unresolved_instead_of_fabricated(self) -> None:
		source = '''
local action = Action()
action:id(config.itemId)
action:register()
'''
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/scripts/actions/dynamic.lua", source)
			result = extract_lua(path, self.config)

		unresolved = [fact for fact in result.facts if fact.role == "unresolved"]
		self.assertEqual({fact.domain for fact in unresolved}, {"item.server_id", "action.item_id"})
		self.assertTrue(all(fact.confidence == "dynamic" for fact in unresolved))

	def test_dynamic_reassignment_invalidates_literal_alias(self) -> None:
		source = "local ITEM_ID = 100\nITEM_ID = getId()\nGame.createItem(ITEM_ID)"
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/scripts/dynamic_alias.lua", source)
			result = extract_lua(path, self.config)

		item_facts = [fact for fact in result.facts if fact.domain == "item.server_id"]
		self.assertEqual([(fact.role, fact.value) for fact in item_facts], [("unresolved", "ITEM_ID")])

	def test_aliases_are_not_resolved_across_function_scopes_or_shadowing(self) -> None:
		source = '''function first()
	print("end")
	local ITEM_ID = 100
	Game.createItem(ITEM_ID)
end
function second()
	local ITEM_ID = 200
	Game.createItem(ITEM_ID)
end
Game.createItem(ITEM_ID)
'''
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/scripts/scoped_alias.lua", source)
			result = extract_lua(path, self.config)

		item_facts = [fact for fact in result.facts if fact.domain == "item.server_id"]
		self.assertEqual(len(item_facts), 3)
		self.assertTrue(all(fact.role == "unresolved" for fact in item_facts))

	def test_comparison_does_not_invalidate_action_object(self) -> None:
		source = '''local action = Action()
if action == nil then return end
action:id(2160)
action:register()
'''
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/scripts/actions/comparison.lua", source)
			result = extract_lua(path, self.config)

		self.assertIn(
			("item.server_id", "reference", 2160),
			{(fact.domain, fact.role, fact.value) for fact in result.facts},
		)

	def test_reused_constructor_variable_is_not_misclassified(self) -> None:
		source = '''local event = Action()
event:id(2160)
event = MoveEvent()
event:id(3000)
event:register()
'''
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/scripts/actions/reused.lua", source)
			result = extract_lua(path, self.config)

		self.assertFalse([fact for fact in result.facts if fact.extractor == "lua.selector"])

	def test_string_item_overload_uses_item_name_domain(self) -> None:
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(
				Path(temporary),
				"data/scripts/item_name.lua",
				'Game.createItem("gold coin")',
			)
			result = extract_lua(path, self.config)

		self.assertEqual(
			[(fact.domain, fact.role, fact.value) for fact in result.facts],
			[("item.name", "reference", "gold coin")],
		)

	def test_storage_calls_only_promote_authoritative_static_keys(self) -> None:
		source = '''local STATIC_KEY = 400
player:getStorageValue(Storage.Quest.Known)
player:setStorageValue(config.storage, 1)
player:getStorageValue(STATIC_KEY)
Game.getStorageValue("ephemeral-key")
Game.setStorageValue(GlobalStorage.Event.Active, 1)
'''
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/scripts/storage.lua", source)
			result = extract_lua(path, self.config)

		references = {
			(fact.domain, fact.value, fact.symbol)
			for fact in result.facts
			if fact.role == "reference"
		}
		self.assertEqual(
			references,
			{
				("storage.player", "Storage.Quest.Known", "Storage.Quest.Known"),
				("storage.player", 400, None),
				("storage.global", "GlobalStorage.Event.Active", "GlobalStorage.Event.Active"),
			},
		)
		unresolved = {
			(fact.domain, fact.value)
			for fact in result.facts
			if fact.role == "unresolved"
		}
		self.assertEqual(
			unresolved,
			{
				("storage.player", "config.storage"),
				("storage.global", "'ephemeral-key'"),
			},
		)


class XmlAndProtobufExtractorTests(unittest.TestCase):
	def setUp(self) -> None:
		self.config = repository_config()

	def test_minimal_appearances_protobuf_defines_ids_and_fluid_range(self) -> None:
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(
				Path(temporary),
				"data/items/appearances.dat",
				appearances_payload(100, 321, 65535),
			)
			result = extract_appearances(path, self.config)

		self.assertFalse(result.diagnostics)
		self.assertIn((0, 99), [(fact.value, fact.end_value) for fact in result.facts])
		self.assertEqual(
			{fact.value for fact in result.facts if fact.end_value is None},
			{100, 321, 65535},
		)
		self.assertTrue(all(fact.role == "definition" for fact in result.facts))

	def test_truncated_appearances_protobuf_is_an_explicit_diagnostic(self) -> None:
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/items/appearances.dat", b"\x0a\x05\x08")
			result = extract_appearances(path, self.config)

		self.assertEqual([item.code for item in result.diagnostics], ["scan.protobuf-error"])

	def test_appearance_requires_flags_and_uint16_id(self) -> None:
		messages = (
			b"\x08" + encode_varint(100),
			b"\x1a\x00",
			b"\x08" + encode_varint(65536) + b"\x1a\x00",
		)
		payload = b"".join(b"\x0a" + encode_varint(len(message)) + message for message in messages)
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/items/appearances.dat", payload)
			result = extract_appearances(path, self.config)

		self.assertEqual(
			{diagnostic.code for diagnostic in result.diagnostics},
			{
				"protobuf.item-missing-flags",
				"protobuf.item-missing-id",
				"protobuf.item-id-out-of-range",
			},
		)
		self.assertEqual([(fact.value, fact.end_value) for fact in result.facts], [(0, 99)])

	def test_appearance_parser_validates_fields_after_id(self) -> None:
		message = b"\x08" + encode_varint(321) + b"\x1a\x00\x22\x05x"
		payload = b"\x0a" + encode_varint(len(message)) + message
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/items/appearances.dat", payload)
			result = extract_appearances(path, self.config)

		self.assertEqual([diagnostic.code for diagnostic in result.diagnostics], ["scan.protobuf-error"])
		self.assertEqual([(fact.value, fact.end_value) for fact in result.facts], [(0, 99)])

	def test_item_xml_ranges_are_references_not_authoritative_definitions(self) -> None:
		xml = '''<?xml version="1.0"?>
<items>
	<item id="321" name="one" />
	<item fromid="400" toid="402" name="range" />
</items>
'''
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/items/items.xml", xml)
			result = extract_xml(path, self.config)

		self.assertFalse(result.diagnostics)
		self.assertEqual(
			[(fact.role, fact.value, fact.end_value) for fact in result.facts],
			[("reference", 321, None), ("reference", 400, 402)],
		)

	def test_invalid_item_xml_range_is_reported(self) -> None:
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(
				Path(temporary),
				"data/items/items.xml",
				'<items><item fromid="402" toid="400" /></items>',
			)
			result = extract_xml(path, self.config)

		self.assertEqual([item.code for item in result.diagnostics], ["xml.invalid-item-range"])
		self.assertFalse(result.facts)

	def test_xml_dtd_and_internal_entities_are_rejected(self) -> None:
		xml = '''<!DOCTYPE items [
	<!ENTITY itemId "321">
]>
<items><item id="&itemId;" /></items>'''
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/items/items.xml", xml)
			result = extract_xml(path, self.config)

		self.assertEqual([item.code for item in result.diagnostics], ["scan.xml-security"])
		self.assertIn("DTD declarations are not allowed", result.diagnostics[0].message)
		self.assertFalse(result.facts)

	def test_xml_parser_without_dtd_controls_fails_closed(self) -> None:
		parser = Mock()
		parser.setProperty.side_effect = SAXNotSupportedException("lexical handler unavailable")
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/items/items.xml", "<items />")
			with patch("tools.canary_audit.extractors.xml.sax.make_parser", return_value=parser):
				result = extract_xml(path, self.config)

		self.assertEqual([item.code for item in result.diagnostics], ["scan.xml-security"])
		self.assertIn("cannot reject DTD declarations", result.diagnostics[0].message)
		parser.parse.assert_not_called()

	def test_world_xml_names_are_references_not_definitions(self) -> None:
		xml = '''<spawns>
	<monster name="Dragon" />
	<singlespawn name="Demon" />
	<npc name="Canary" />
</spawns>'''
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data-canary/world/spawns.xml", xml)
			result = extract_xml(path, self.config)

		self.assertEqual(
			{(fact.domain, fact.role, fact.value) for fact in result.facts},
			{
				("monster.name", "reference", "Dragon"),
				("monster.name", "reference", "Demon"),
				("npc.name", "reference", "Canary"),
			},
		)

	def test_storage_xml_range_overlap_and_out_of_range_are_reported(self) -> None:
		xml = '''<storages>
	<range start="100" end="110"><storage name="valid" key="1" /></range>
	<range start="105" end="120"><storage name="invalid" key="20" /></range>
</storages>'''
		with tempfile.TemporaryDirectory() as temporary:
			path = discovered_file(Path(temporary), "data/XML/storages.xml", xml)
			result = extract_xml(path, self.config)

		self.assertEqual(
			{item.code for item in result.diagnostics},
			{"xml.overlapping-storage-range", "xml.invalid-storage"},
		)
		self.assertEqual([(fact.value, fact.symbol) for fact in result.facts], [(101, "valid")])


if __name__ == "__main__":
	unittest.main()
