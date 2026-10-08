from __future__ import annotations

import json
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.canary_audit.cli import _write_artifacts
from tools.canary_audit.runner import run_audit
from tools.canary_audit.schema_tools import (
	SchemaError,
	load_and_validate_json,
	stable_json,
	validate_all_schemas,
	validate_instance,
)

from .helpers import (
	BASELINE_PATH,
	CONFIG_PATH,
	appearances_payload,
	repository_config,
)
from .test_otbm import area, item, map_file, tile


class SchemaAndDeterministicIntegrationTests(unittest.TestCase):
	def test_bundled_schemas_config_and_baseline_are_valid(self) -> None:
		validate_all_schemas()
		load_and_validate_json(CONFIG_PATH, "config.schema.json")
		load_and_validate_json(BASELINE_PATH, "baseline.schema.json")

	def test_config_schema_requires_an_excluded_directory(self) -> None:
		config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
		config["excludedDirectories"] = []

		with self.assertRaises(SchemaError):
			validate_instance("config.schema.json", config)

	def test_config_schema_rejects_nonpositive_otbm_byte_limit(self) -> None:
		data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
		data["maxOtbmFileBytes"] = 0

		with self.assertRaises(SchemaError):
			validate_instance("config.schema.json", data)

	def test_config_schema_requires_a_positive_integer_otbm_tile_limit(self) -> None:
		data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
		data["maxOtbmTilePositions"] = 2_500_000
		validate_instance("config.schema.json", data)
		for limit in (0, -1, 1.5, "2500000", True):
			with self.subTest(limit=limit):
				data["maxOtbmTilePositions"] = limit
				with self.assertRaises(SchemaError):
					validate_instance("config.schema.json", data)
		data.pop("maxOtbmTilePositions")
		with self.assertRaises(SchemaError):
			validate_instance("config.schema.json", data)

	def test_same_workspace_produces_byte_stable_schema_valid_artifacts(self) -> None:
		with tempfile.TemporaryDirectory() as temporary:
			root = Path(temporary)
			self._write_minimal_workspace(root)
			config = repository_config()
			kwargs = {
				"selected_profiles": ("canary", "otservbr-global"),
				"base_sha": "a" * 40,
				"head_sha": "b" * 40,
				"prefer_git": False,
			}

			first = run_audit(root, config, **kwargs)
			second = run_audit(root, config, **kwargs)
			_write_artifacts(root, "artifacts/test-audit", first)
			after_output = run_audit(root, config, **kwargs)
			with_stale_waiver = run_audit(
				root,
				config,
				waived_fingerprints=frozenset({"c" * 64}),
				**kwargs,
			)

		self.assertFalse(first.incomplete)
		self.assertIn("map.action_id", {fact["domain"] for fact in first.symbol_registry["facts"]})
		coverage = {entry["domain"]: entry for entry in first.symbol_registry["coverage"]}
		self.assertEqual(coverage["map.otbm"]["status"], "authoritative")
		self.assertEqual(coverage["action/movement selectors"]["status"], "partial")
		self.assertEqual(first.symbol_registry["toolVersion"], "1.1.0")
		self.assertEqual(stable_json(first.project_index), stable_json(second.project_index))
		self.assertEqual(stable_json(first.symbol_registry), stable_json(second.symbol_registry))
		self.assertEqual(stable_json(first.reference_report), stable_json(second.reference_report))
		self.assertEqual(first.summary_markdown, second.summary_markdown)
		self.assertEqual(stable_json(first.project_index), stable_json(after_output.project_index))
		self.assertEqual(stable_json(first.symbol_registry), stable_json(after_output.symbol_registry))
		self.assertEqual(stable_json(first.reference_report), stable_json(after_output.reference_report))
		validate_instance("project-index.schema.json", first.project_index)
		validate_instance("symbol-registry.schema.json", first.symbol_registry)
		validate_instance("reference-report.schema.json", first.reference_report)

		self.assertEqual(with_stale_waiver.reference_report["summary"]["staleWaiverCount"], 1)

	def test_unknown_map_item_creates_missing_definition_finding(self) -> None:
		with tempfile.TemporaryDirectory() as temporary:
			root = Path(temporary)
			self._write_minimal_workspace(root)
			self._write(root, "data-canary/world/test.otbm", map_file(area(tile(item(65530)))))

			result = run_audit(root, repository_config(), selected_profiles=("canary",), prefer_git=False)

		self.assertFalse(result.incomplete)
		findings = [
			finding for finding in result.reference_report["findings"]
			if finding["ruleId"] == "reference.missing-definition" and finding["domain"] == "item.server_id"
		]
		self.assertEqual(len(findings), 1)
		self.assertEqual(findings[0]["value"], 65530)
		self.assertEqual(findings[0]["severity"], "error")
		self.assertEqual(findings[0]["locations"][0]["path"], "data-canary/world/test.otbm")
		validate_instance("reference-report.schema.json", result.reference_report)

	def test_git_discovery_includes_ignored_maps_but_not_ignored_unrelated_content(self) -> None:
		with tempfile.TemporaryDirectory() as temporary:
			root = Path(temporary)
			self._write_minimal_workspace(root)
			tracked = [path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file()]
			self._write(
				root, "data-canary/world/ignored.OTBM",
				map_file(area(tile(item(321, b"\x04" + struct.pack("<H", 6001))))),
			)
			self._write(root, "data-canary/ignored.lua", "Game.createItem(65530)")
			self._write(root, "data-canary/ignored.xml", '<items><item id="65530" /></items>')
			self._write(root, "artifacts/ignored.otbm", b"invalid excluded map")
			self._write(root, "unconfigured/ignored.otbm", b"invalid unconfigured map")
			self._write(root, "data-otservbr-global/world/ignored.otbm", b"invalid unselected map")

			with patch("tools.canary_audit.workspace._git_file_names", return_value=tracked):
				result = run_audit(root, repository_config(), selected_profiles=("canary",))

		self.assertFalse(result.incomplete)
		self.assertIn(
			("map.action_id", 6001, "data-canary/world/ignored.OTBM"),
			{(fact["domain"], fact["value"], fact["location"]["path"]) for fact in result.symbol_registry["facts"]},
		)
		paths = {entry["path"] for entry in result.project_index["files"]}
		self.assertIn("data-canary/world/test.otbm", paths)
		self.assertNotIn("data-canary/ignored.lua", paths)
		self.assertNotIn("data-canary/ignored.xml", paths)
		self.assertNotIn("artifacts/ignored.otbm", paths)
		self.assertFalse(result.reference_report["findings"])

	def test_map_semantic_findings_use_repository_gate_severities(self) -> None:
		with tempfile.TemporaryDirectory() as temporary:
			root = Path(temporary)
			self._write_minimal_workspace(root)
			uid = b"\x05" + struct.pack("<H", 6000)
			teleport = b"\x08" + struct.pack("<HHB", 999, 999, 7)
			self._write(
				root, "data-canary/world/test.otbm",
				map_file(area(tile(item(321, uid)) + tile(item(321, uid + teleport)))),
			)

			result = run_audit(root, repository_config(), selected_profiles=("canary",), prefer_git=False)

		self.assertFalse(result.incomplete)
		self.assertEqual(
			{finding["ruleId"]: finding["severity"] for finding in result.reference_report["findings"]},
			{
				"otbm.duplicate-unique-id": "error",
				"otbm.duplicate-tile": "error",
				"otbm.missing-teleport-target": "warning",
			},
		)
		validate_instance("reference-report.schema.json", result.reference_report)

	@staticmethod
	def _write(root: Path, relative: str, content: str | bytes) -> None:
		path = root / relative
		path.parent.mkdir(parents=True, exist_ok=True)
		if isinstance(content, bytes):
			path.write_bytes(content)
		else:
			path.write_text(content, encoding="utf-8")

	@classmethod
	def _write_minimal_workspace(cls, root: Path) -> None:
		cls._write(
			root, "data-canary/world/test.otbm",
			map_file(area(tile(item(321, b"\x04" + struct.pack("<H", 5000))))),
		)
		cls._write(root, "data/items/appearances.dat", appearances_payload(321))
		cls._write(root, "data/items/items.xml", '<items><item id="321" name="test item" /></items>')
		cls._write(
			root,
			"data/XML/storages.xml",
			'<storages><range start="1000000" end="1000010"><storage name="test.one" key="1" /></range></storages>',
		)
		cls._write(root, "data/libs/core/global_storage.lua", "Global = { Storage = { Shared = 70000 } }")
		cls._write(
			root,
			"data-canary/lib/core/storages.lua",
			"Storage = { Canary = 80000 }\nGlobalStorage = { Canary = 81000 }",
		)
		cls._write(
			root,
			"data-otservbr-global/lib/core/storages.lua",
			"Storage = { Global = 90000 }\nGlobalStorage = { Global = 91000 }",
		)
		cls._write(
			root,
			"data-canary/monster/canary_test.lua",
			'''local mType = Game.createMonsterType("Canary Test")
mType:register({})
Game.createMonster("Canary Test", position)
local action = Action()
action:id(321)
action:register()
''',
		)
		cls._write(
			root,
			"data-otservbr-global/monster/global_test.lua",
			'''local mType = Game.createMonsterType("Global Test")
mType:register({})
Game.createMonster("Global Test", position)
''',
		)


if __name__ == "__main__":
	unittest.main()
