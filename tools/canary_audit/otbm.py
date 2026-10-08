"""Bounded, read-only streaming reader for Canary OTBM versions 1 through 5.

Offsets refer to the original file: node offsets point at START, and inline
ground-item offsets point at their OTBM_ATTR_ITEM tag. Callbacks run in file
order and may receive facts before a later malformed node is rejected.
"""

from __future__ import annotations

import mmap
import os
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path


START, END, ESCAPE = 0xFE, 0xFF, 0xFD

# Node and attribute values from src/io/io_definitions.hpp.
OTBM_ROOTV1 = 1
OTBM_MAP_DATA = 2
OTBM_TILE_AREA = 4
OTBM_TILE = 5
OTBM_ITEM = 6
OTBM_TOWNS = 12
OTBM_TOWN = 13
OTBM_HOUSETILE = 14
OTBM_WAYPOINTS = 15
OTBM_WAYPOINT = 16
OTBM_TILE_ZONE = 19
OTBM_ATTR_TILE_FLAGS = 3
OTBM_ATTR_ACTION_ID = 4
OTBM_ATTR_UNIQUE_ID = 5
OTBM_ATTR_TELE_DEST = 8
OTBM_ATTR_ITEM = 9

_MAP_STRING_ATTRIBUTES = frozenset({1, 2, 11, 13, 23, 24})
_ITEM_STRING_ATTRIBUTES = frozenset({6, 7})
_ITEM_U16_ATTRIBUTES = frozenset({10, 22})
_ITEM_U8_ATTRIBUTES = frozenset({14, 15})


class OtbmError(ValueError):
	"""Malformed or unsupported OTBM binary input."""


@dataclass(frozen=True)
class OtbmHeader:
	version: int
	width: int
	height: int


@dataclass(frozen=True)
class OtbmTile:
	position: tuple[int, int, int]
	offset: int


@dataclass(frozen=True)
class OtbmItem:
	item_id: int
	position: tuple[int, int, int]
	offset: int
	action_id: int | None
	unique_id: int | None
	teleport_destination: tuple[int, int, int] | None
	depth: int


@dataclass
class _Frame:
	kind: int
	offset: int
	position: tuple[int, int, int] | None = None
	depth: int = -1
	# Tracks the map-data/towns/waypoints order in root and map-data contexts.
	phase: int = 0


class _Reader:
	def __init__(self, data: mmap.mmap) -> None:
		self.data = data
		self.offset = 4

	def error(self, message: str, offset: int | None = None) -> OtbmError:
		return OtbmError(f"{message} at byte offset {self.offset if offset is None else offset}")

	def peek(self) -> int:
		if self.offset >= len(self.data):
			raise self.error("truncated OTBM: missing expected end node")
		return self.data[self.offset]

	def has_properties(self) -> bool:
		return self.peek() not in (START, END)

	def read_u8(self) -> int:
		value = self.peek()
		if value in (START, END):
			raise self.error("truncated OTBM field: unescaped structural byte in properties")
		self.offset += 1
		if value == ESCAPE:
			if self.offset >= len(self.data):
				raise self.error("truncated OTBM: dangling escape", self.offset - 1)
			value = self.data[self.offset]
			self.offset += 1
		return value

	def read_u16(self) -> int:
		return self.read_u8() | (self.read_u8() << 8)

	def read_u32(self) -> int:
		return self.read_u16() | (self.read_u16() << 16)

	def skip_string(self) -> None:
		# Strings are u16-length-prefixed in the audit reader's supported subset.
		# Consume directly from the mapping, without copying even large strings.
		for _ in range(self.read_u16()):
			self.read_u8()

	def read_position(self) -> tuple[int, int, int]:
		return self.read_u16(), self.read_u16(), self.read_u8()

	def start_node(self) -> _Frame:
		offset = self.offset
		if self.peek() != START:
			raise self.error("expected OTBM node start")
		self.offset += 1
		kind = self.peek()
		if kind in (START, END, ESCAPE):
			raise self.error("invalid OTBM node type")
		self.offset += 1
		return _Frame(kind, offset)

	def require_property_end(self) -> None:
		if self.has_properties():
			raise self.error("unexpected OTBM properties")


def _validate_child(reader: _Reader, parent: _Frame, child: _Frame) -> None:
	kind = child.kind
	allowed = False
	if parent.kind == OTBM_ROOTV1:
		if kind == OTBM_MAP_DATA and parent.phase == 0:
			parent.phase = 1
			allowed = True
		elif kind == OTBM_TOWNS and parent.phase == 1:
			parent.phase = 2
			allowed = True
		elif kind == OTBM_WAYPOINTS and parent.phase in (1, 2):
			parent.phase = 3
			allowed = True
	elif parent.kind == OTBM_MAP_DATA:
		if kind == OTBM_TILE_AREA and parent.phase == 0:
			allowed = True
		elif kind == OTBM_TOWNS and parent.phase == 0:
			parent.phase = 1
			allowed = True
		elif kind == OTBM_WAYPOINTS and parent.phase in (0, 1):
			parent.phase = 2
			allowed = True
	elif parent.kind == OTBM_TILE_AREA:
		allowed = kind in (OTBM_TILE, OTBM_HOUSETILE)
	elif parent.kind in (OTBM_TILE, OTBM_HOUSETILE):
		allowed = kind in (OTBM_ITEM, OTBM_TILE_ZONE)
	elif parent.kind == OTBM_ITEM:
		allowed = kind == OTBM_ITEM
	elif parent.kind == OTBM_TOWNS:
		allowed = kind == OTBM_TOWN
	elif parent.kind == OTBM_WAYPOINTS:
		allowed = kind == OTBM_WAYPOINT
	if not allowed:
		raise reader.error(f"unexpected child node {kind} in OTBM node {parent.kind}", child.offset)


def _read_tile(reader: _Reader, frame: _Frame, parent: _Frame,
		on_tile: Callable[[OtbmTile], None], on_item: Callable[[OtbmItem], None]) -> None:
	assert parent.position is not None
	x = parent.position[0] + reader.read_u8()
	y = parent.position[1] + reader.read_u8()
	if x > 0xFFFF or y > 0xFFFF:
		raise reader.error("invalid OTBM tile coordinate", frame.offset)
	frame.position = (x, y, parent.position[2])
	if frame.kind == OTBM_HOUSETILE:
		reader.read_u32()
	ground: tuple[int, int] | None = None
	flags_seen = False
	while reader.has_properties():
		offset = reader.offset
		attr = reader.read_u8()
		if attr == OTBM_ATTR_TILE_FLAGS and not flags_seen and ground is None:
			reader.read_u32()
			flags_seen = True
		elif attr == OTBM_ATTR_ITEM and ground is None:
			ground = reader.read_u16(), offset
		else:
			raise reader.error(f"unknown tile attribute or invalid order: {attr}", offset)
	on_tile(OtbmTile(frame.position, frame.offset))
	if ground is not None:
		on_item(OtbmItem(ground[0], frame.position, ground[1], None, None, None, 0))


def _read_item(reader: _Reader, frame: _Frame, parent: _Frame,
		on_item: Callable[[OtbmItem], None]) -> None:
	assert parent.position is not None
	frame.position = parent.position
	frame.depth = parent.depth + 1
	item_id = reader.read_u16()
	action_id = unique_id = None
	teleport_destination = None
	while reader.has_properties():
		offset = reader.offset
		attr = reader.read_u8()
		if attr == OTBM_ATTR_ACTION_ID:
			action_id = reader.read_u16()
		elif attr == OTBM_ATTR_UNIQUE_ID:
			unique_id = reader.read_u16()
		elif attr == OTBM_ATTR_TELE_DEST:
			teleport_destination = reader.read_position()
		elif attr in _ITEM_STRING_ATTRIBUTES:
			reader.skip_string()
		elif attr in _ITEM_U16_ATTRIBUTES:
			reader.read_u16()
		elif attr in _ITEM_U8_ATTRIBUTES:
			reader.read_u8()
		else:
			raise reader.error(f"unknown item attribute {attr}", offset)
	on_item(OtbmItem(item_id, frame.position, frame.offset, action_id, unique_id,
		teleport_destination, frame.depth))


def _read_properties(reader: _Reader, frame: _Frame, parent: _Frame,
		on_tile: Callable[[OtbmTile], None], on_item: Callable[[OtbmItem], None]) -> None:
	if frame.kind == OTBM_MAP_DATA:
		while reader.has_properties():
			offset = reader.offset
			attr = reader.read_u8()
			if attr not in _MAP_STRING_ATTRIBUTES:
				raise reader.error(f"unknown map attribute {attr}", offset)
			reader.skip_string()
	elif frame.kind == OTBM_TILE_AREA:
		frame.position = reader.read_position()
	elif frame.kind in (OTBM_TILE, OTBM_HOUSETILE):
		_read_tile(reader, frame, parent, on_tile, on_item)
	elif frame.kind == OTBM_ITEM:
		_read_item(reader, frame, parent, on_item)
	elif frame.kind == OTBM_TILE_ZONE:
		for _ in range(reader.read_u16()):
			if reader.read_u16() == 0:
				raise reader.error("invalid zone id")
	elif frame.kind == OTBM_TOWN:
		reader.read_u32()
		reader.skip_string()
		reader.read_position()
	elif frame.kind == OTBM_WAYPOINT:
		reader.skip_string()
		reader.read_position()
	reader.require_property_end()


def _walk(data: mmap.mmap, on_tile: Callable[[OtbmTile], None],
		on_item: Callable[[OtbmItem], None]) -> OtbmHeader:
	if len(data) < 4:
		raise OtbmError("truncated OTBM identifier at byte offset 0")
	if data[:4] != b"OTBM":
		raise OtbmError("invalid OTBM identifier at byte offset 0")
	reader = _Reader(data)
	root = reader.start_node()
	if root.kind != OTBM_ROOTV1:
		raise reader.error("expected OTBM root", root.offset)
	version = reader.read_u32()
	width = reader.read_u16()
	height = reader.read_u16()
	major_items = reader.read_u32()
	reader.read_u32()  # minor_items
	if not 1 <= version <= 5:
		raise reader.error(f"unsupported OTBM version {version}", root.offset)
	if major_items < 3:
		raise reader.error(f"unsupported items major version {major_items}", root.offset)
	reader.require_property_end()
	stack = [root]
	while stack:
		parent = stack[-1]
		value = reader.peek()
		if value == START:
			child = reader.start_node()
			_validate_child(reader, parent, child)
			_read_properties(reader, child, parent, on_tile, on_item)
			stack.append(child)
		elif value == END:
			if parent.kind == OTBM_ROOTV1 and parent.phase == 0:
				raise reader.error("missing OTBM_MAP_DATA", parent.offset)
			reader.offset += 1
			stack.pop()
		else:
			raise reader.error("invalid OTBM properties after child node")
	if reader.offset != len(data):
		raise reader.error("trailing bytes after OTBM root")
	return OtbmHeader(version, width, height)


def walk_otbm(path: Path, max_file_bytes: int, on_tile: Callable[[OtbmTile], None],
		on_item: Callable[[OtbmItem], None]) -> OtbmHeader:
	"""Visit tiles and items without a node tree or an owned copy of the file.

	The byte cap is checked before mapping; the opened file and mapping are also
	checked in case the path was replaced or grew between those operations.
	Invalid binary input raises OtbmError. I/O and callback errors propagate.
	"""
	if path.stat().st_size > max_file_bytes:
		raise OtbmError("OTBM file size exceeds configured limit at byte offset 0")
	with path.open("rb") as handle:
		size = os.fstat(handle.fileno()).st_size
		if size > max_file_bytes:
			raise OtbmError("OTBM file size exceeds configured limit at byte offset 0")
		if size == 0:
			raise OtbmError("truncated OTBM identifier at byte offset 0")
		with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
			if len(data) > max_file_bytes:
				raise OtbmError("OTBM file size exceeds configured limit at byte offset 0")
			return _walk(data, on_tile, on_item)
