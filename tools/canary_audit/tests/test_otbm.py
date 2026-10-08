from __future__ import annotations

import struct
import tempfile
import unittest
from dataclasses import FrozenInstanceError
from pathlib import Path

from tools.canary_audit.otbm import OtbmError, walk_otbm


START, END, ESCAPE = 0xFE, 0xFF, 0xFD


def escaped(payload: bytes) -> bytes:
	return payload.replace(bytes([ESCAPE]), bytes([ESCAPE, ESCAPE])) \
		.replace(bytes([START]), bytes([ESCAPE, START])) \
		.replace(bytes([END]), bytes([ESCAPE, END]))


def node(kind: int, props: bytes = b"", children: bytes = b"") -> bytes:
	return bytes([START, kind]) + escaped(props) + children + bytes([END])


def string(value: bytes) -> bytes:
	return struct.pack("<H", len(value)) + value


def map_file(children: bytes = b"", *, version: int = 4, major: int = 3,
		map_props: bytes = b"", root_children: bytes = b"") -> bytes:
	header = struct.pack("<IHHII", version, 18, 18, major, 57)
	return b"OTBM" + node(1, header, node(2, map_props, children) + root_children)


def area(tiles: bytes, x: int = 100, y: int = 100, z: int = 7) -> bytes:
	return node(4, struct.pack("<HHB", x, y, z), tiles)


def tile(items: bytes = b"", attrs: bytes = b"") -> bytes:
	return node(5, b"\x01\x02" + attrs, items)


class OtbmReaderTests(unittest.TestCase):
	def setUp(self) -> None:
		self.temporary = tempfile.TemporaryDirectory()
		self.addCleanup(self.temporary.cleanup)
		self.path = Path(self.temporary.name) / "fixture.otbm"
		self.tiles = []
		self.items = []

	def read(self, payload: bytes, limit: int = 1_000_000):
		self.path.write_bytes(payload)
		return walk_otbm(self.path, limit, self.tiles.append, self.items.append)

	def reject(self, payload: bytes, phrase: str) -> None:
		with self.assertRaisesRegex(OtbmError, phrase):
			self.read(payload)

	def test_reads_header_item_attributes_and_nested_item(self) -> None:
		attrs = b"\x04" + struct.pack("<H", 5000) + b"\x05" + struct.pack("<H", 6000)
		attrs += b"\x08" + struct.pack("<HHB", 101, 102, 7)
		inner = node(6, struct.pack("<H", 322))
		outer = node(6, struct.pack("<H", 321) + attrs, inner)
		payload = map_file(area(tile(outer)))

		header = self.read(payload, 1024)

		self.assertEqual((header.version, header.width, header.height), (4, 18, 18))
		self.assertEqual([entry.position for entry in self.tiles], [(101, 102, 7)])
		self.assertEqual([entry.item_id for entry in self.items], [321, 322])
		self.assertEqual(self.items[0].action_id, 5000)
		self.assertEqual(self.items[0].unique_id, 6000)
		self.assertEqual(self.items[0].teleport_destination, (101, 102, 7))
		self.assertEqual([entry.depth for entry in self.items], [0, 1])
		self.assertEqual(self.items[1].position, (101, 102, 7))
		self.assertEqual(payload[self.tiles[0].offset:self.tiles[0].offset + 2], b"\xfe\x05")
		self.assertEqual(payload[self.items[0].offset:self.items[0].offset + 2], b"\xfe\x06")
		self.assertLess(self.items[0].offset, self.items[1].offset)
		with self.assertRaises(FrozenInstanceError):
			header.version = 5
		with self.assertRaises(FrozenInstanceError):
			self.tiles[0].offset = 0
		with self.assertRaises(FrozenInstanceError):
			self.items[0].item_id = 1

	def test_accepts_versions_one_through_five(self) -> None:
		for version in range(1, 6):
			with self.subTest(version=version):
				self.assertEqual(self.read(map_file(version=version)).version, version)

	def test_rejects_non_otbm_identifier(self) -> None:
		self.reject(b"NOPE" + map_file()[4:], "OTBM identifier")

	def test_rejects_wildcard_identifier(self) -> None:
		self.reject(b"\x00" * 4 + map_file()[4:], "OTBM identifier")

	def test_rejects_version_six(self) -> None:
		self.reject(map_file(version=6), "unsupported OTBM version")

	def test_rejects_version_zero(self) -> None:
		self.reject(map_file(version=0), "unsupported OTBM version")

	def test_rejects_old_items_major_version(self) -> None:
		self.reject(map_file(major=2), "unsupported items major version")

	def test_enforces_file_limit_and_accepts_exact_limit(self) -> None:
		payload = map_file()
		with self.assertRaisesRegex(OtbmError, "file size exceeds"):
			self.read(payload, len(payload) - 1)
		self.assertEqual(self.read(payload, len(payload)).version, 4)

	def test_rejects_empty_and_short_files(self) -> None:
		for payload in (b"", b"O", b"OTBM", b"OTBM\xfe"):
			with self.subTest(payload=payload):
				self.reject(payload, "truncated OTBM")

	def test_rejects_dangling_escape(self) -> None:
		self.reject(b"OTBM\xfe\x01\xfd", "dangling escape")

	def test_rejects_truncated_uint16(self) -> None:
		self.reject(map_file(area(tile(node(6, b"\x41")))), "truncated OTBM")

	def test_rejects_unterminated_node(self) -> None:
		self.reject(map_file()[:-1], "truncated OTBM")

	def test_rejects_unexpected_child_of_tile(self) -> None:
		self.reject(map_file(area(tile(node(13)))), "unexpected child node")

	def test_rejects_unexpected_child_of_item(self) -> None:
		self.reject(map_file(area(tile(node(6, b"\x41\x01", node(5))))), "unexpected child node")

	def test_rejects_unexpected_child_of_tile_area(self) -> None:
		self.reject(map_file(area(node(6, b"\x41\x01"))), "unexpected child node")

	def test_rejects_unexpected_child_of_map_data(self) -> None:
		self.reject(map_file(node(6, b"\x41\x01")), "unexpected child node")

	def test_rejects_missing_and_duplicate_map_data(self) -> None:
		header = struct.pack("<IHHII", 4, 18, 18, 3, 57)
		self.reject(b"OTBM" + node(1, header), "missing OTBM_MAP_DATA")
		self.reject(map_file(root_children=node(2)), "unexpected child node")

	def test_rejects_wrong_root_type(self) -> None:
		self.reject(b"OTBM" + node(2), "expected OTBM root")

	def test_rejects_trailing_bytes_and_extra_root(self) -> None:
		for suffix in (b"\x00", node(1), b"\xff"):
			with self.subTest(suffix=suffix):
				self.reject(map_file() + suffix, "trailing bytes")

	def test_rejects_properties_after_child(self) -> None:
		self.reject(map_file()[:-1] + b"\x01\xff", "properties after child")

	def test_structural_bytes_must_be_escaped_inside_fields(self) -> None:
		for value in (START, END):
			with self.subTest(value=value):
				bad_item = bytes([START, 6, 0x41, value, END])
				self.reject(map_file(area(tile(bad_item))), "truncated OTBM.*offset")

	def test_escape_preserves_all_literal_values(self) -> None:
		for value in (0xFD, 0xFE, 0xFF):
			with self.subTest(value=value):
				self.items.clear()
				props = struct.pack("<H", value) + b"\x04" + struct.pack("<H", value)
				self.read(map_file(area(tile(node(6, props)))))
				self.assertEqual(self.items[0].item_id, value)
				self.assertEqual(self.items[0].action_id, value)

	def test_escape_accepts_non_structural_literal(self) -> None:
		item = b"\xfe\x06\xfd\x41\x01\xff"
		self.read(map_file(area(tile(item))))
		self.assertEqual(self.items[0].item_id, 321)

	def test_known_ignored_item_attributes_preserve_following_ids(self) -> None:
		attrs = b"\x06" + string(bytes([ESCAPE, START, END]))
		attrs += b"\x07" + string(b"description")
		attrs += b"\x0a" + struct.pack("<H", 300)
		attrs += b"\x0e\x12\x0f\x13\x16" + struct.pack("<H", 400)
		attrs += b"\x04" + struct.pack("<H", 5000)
		self.read(map_file(area(tile(node(6, struct.pack("<H", 321) + attrs)))))
		self.assertEqual(self.items[0].action_id, 5000)

	def test_unknown_item_attributes_fail_closed(self) -> None:
		for attr in (0, 1, 2, 3, 9, 11, 12, 13, 16, 17, 18, 19, 20, 21, 23, 24, 255):
			with self.subTest(attr=attr):
				self.reject(map_file(area(tile(node(6, b"\x41\x01" + bytes([attr]))))), "unknown item attribute")

	def test_all_known_item_attributes_reject_underflow(self) -> None:
		for attr, payload in ((4, b"\x01"), (5, b"\x01"), (6, b"\x04\x00abc"),
				(7, b"\x01"), (8, b"\x01\x00\x02\x00"), (10, b"\x01"),
				(14, b""), (15, b""), (22, b"\x01")):
			with self.subTest(attr=attr):
				self.reject(map_file(area(tile(node(6, b"\x41\x01" + bytes([attr]) + payload)))), "truncated OTBM")

	def test_map_metadata_strings_preserve_following_tiles(self) -> None:
		attrs = b"".join(bytes([attr]) + string(b"file\xfd\xfe\xff.xml") for attr in (1, 2, 11, 13, 23, 24))
		self.read(map_file(area(tile()), map_props=attrs))
		self.assertEqual(self.tiles[0].position, (101, 102, 7))

	def test_unknown_and_truncated_map_attributes_fail_closed(self) -> None:
		self.reject(map_file(map_props=b"\x04"), "unknown map attribute")
		self.reject(map_file(map_props=b"\x01\x04\x00abc"), "truncated OTBM")

	def test_house_tile_flags_and_ground_item(self) -> None:
		attrs = b"\x03" + struct.pack("<I", 0xFFFEFD01) + b"\x09" + struct.pack("<H", 100)
		house = node(14, b"\x03\x04" + struct.pack("<I", 99) + attrs, node(6, b"\x41\x01"))
		payload = map_file(area(house))
		self.read(payload)
		self.assertEqual(self.tiles[0].position, (103, 104, 7))
		self.assertEqual([entry.item_id for entry in self.items], [100, 321])
		self.assertEqual([entry.depth for entry in self.items], [0, 0])
		self.assertIsNone(self.items[0].action_id)
		self.assertIsNone(self.items[0].unique_id)
		self.assertIsNone(self.items[0].teleport_destination)
		self.assertEqual(payload[self.items[0].offset], 9)
		self.assertEqual(self.items[0].position, (103, 104, 7))

	def test_unknown_tile_attribute_fails_closed(self) -> None:
		self.reject(map_file(area(tile(attrs=b"\x04\x01\x00"))), "unknown tile attribute")

	def test_truncated_tile_flags_ground_and_house_id(self) -> None:
		for entry in (tile(attrs=b"\x03\x01\x02\x03"), tile(attrs=b"\x09\x01"), node(14, b"\x01\x02\x01")):
			with self.subTest(entry=entry):
				self.reject(map_file(area(entry)), "truncated OTBM")

	def test_tile_zones_do_not_emit_items(self) -> None:
		zones = node(19, struct.pack("<HHH", 2, 1, 500))
		self.read(map_file(area(tile(zones + node(6, b"\x41\x01")))))
		self.assertEqual([entry.item_id for entry in self.items], [321])

	def test_tile_zones_reject_truncation_zero_ids_and_children(self) -> None:
		self.reject(map_file(area(tile(node(19, struct.pack("<HH", 2, 1))))), "truncated OTBM")
		self.reject(map_file(area(tile(node(19, struct.pack("<HH", 1, 0))))), "invalid zone id")
		self.reject(map_file(area(tile(node(19, b"\x00\x00", node(6, b"\x41\x01"))))), "unexpected child node")

	def test_towns_and_waypoints_emit_no_facts(self) -> None:
		towns = node(12, children=node(13, struct.pack("<I", 1) + string(b"Town") + struct.pack("<HHB", 101, 102, 7)))
		waypoints = node(15, children=node(16, string(b"Point") + struct.pack("<HHB", 103, 104, 7)))
		for payload in (map_file(root_children=towns + waypoints), map_file(towns + waypoints)):
			with self.subTest(payload=payload):
				self.read(payload)
				self.assertEqual(self.tiles, [])
				self.assertEqual(self.items, [])

	def test_town_and_waypoint_properties_are_validated(self) -> None:
		self.reject(map_file(root_children=node(12, children=node(13, b"\x01"))), "truncated OTBM")
		self.reject(map_file(root_children=node(15, children=node(16, string(b"Point") + b"\x01"))), "truncated OTBM")
		self.reject(map_file(root_children=node(12, children=node(6, b"\x41\x01"))), "unexpected child node")

	def test_root_metadata_order_is_validated(self) -> None:
		self.reject(map_file(root_children=node(15) + node(12)), "unexpected child node")

	def test_deep_nested_items_do_not_leak_recursion_error(self) -> None:
		child = node(6, b"\x41\x01")
		for _ in range(1100):
			child = node(6, b"\x41\x01", child)
		self.read(map_file(area(tile(child))))
		self.assertEqual(len(self.items), 1101)
		self.assertEqual(self.items[-1].depth, 1100)

	def test_every_truncated_prefix_raises_otbm_error(self) -> None:
		payload = map_file(area(tile(node(6, b"\x41\x01\x06" + string(b"\xfd\xfe\xff")))))
		for length in range(len(payload)):
			with self.subTest(length=length):
				self.reject(payload[:length], "OTBM")

	def test_closes_file_and_mapping_after_parse_error(self) -> None:
		self.reject(map_file()[:-1], "truncated OTBM")
		self.path.unlink()
		self.assertFalse(self.path.exists())

	def test_closes_file_and_mapping_after_callback_failure(self) -> None:
		self.path.write_bytes(map_file(area(tile())))

		def failed_callback(_entry):
			raise RuntimeError("callback failed")

		with self.assertRaisesRegex(RuntimeError, "callback failed"):
			walk_otbm(self.path, 1024, failed_callback, self.items.append)
		self.path.unlink()
		self.assertFalse(self.path.exists())


if __name__ == "__main__":
	unittest.main()
