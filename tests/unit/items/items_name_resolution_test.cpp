/**
 * Canary - A free and open-source MMORPG server emulator
 * Copyright (©) 2019–present OpenTibiaBR <https://github.com/opentibiabr/canary>
 * License: https://github.com/opentibiabr/canary/blob/main/LICENSE
 */

#include "items/items.hpp"

#include <pugixml.hpp>

namespace {
	void addAppearanceName(Items &items, uint16_t id, const std::string &name, bool indexName = true) {
		auto &itemTypes = items.getItems();
		if (itemTypes.size() <= id) {
			itemTypes.resize(static_cast<size_t>(id) + 1);
		}

		itemTypes[id].id = id;
		itemTypes[id].name = name;
		if (indexName) {
			items.nameToItems.emplace(name, id);
		}
	}

	void parseXmlName(Items &items, uint16_t id, const std::string &name) {
		pugi::xml_document document;
		ASSERT_TRUE(document.load_string(fmt::format("<item id=\"{}\" name=\"{}\" />", id, name).c_str()));
		items.parseItemNode(document.child("item"), id);
	}
}

TEST(ItemsNameResolutionTest, UsesUniqueXmlNameOverDuplicateAppearanceNames) {
	Items items;
	addAppearanceName(items, 43860, "bag you covet");
	addAppearanceName(items, 43895, "bag you covet", false);
	addAppearanceName(items, 43896, "bag you covet");
	addAppearanceName(items, 43897, "bag you covet");
	addAppearanceName(items, 43898, "bag you covet");

	parseXmlName(items, 43895, "bag you covet");

	EXPECT_EQ(items.getItemIdByName("bag you covet"), 43895);
}

TEST(ItemsNameResolutionTest, RetainsAppearanceFallbackForAmbiguousXmlName) {
	Items items;
	addAppearanceName(items, 777, "shared test name");
	addAppearanceName(items, 500, "shared test name", false);
	addAppearanceName(items, 501, "shared test name", false);

	parseXmlName(items, 500, "shared test name");
	parseXmlName(items, 501, "shared test name");

	EXPECT_EQ(items.getItemIdByName("shared test name"), 777);
}
