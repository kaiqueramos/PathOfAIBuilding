local function readFile(path)
	local file = assert(io.open(path, "r"))
	local content = file:read("*a")
	file:close()
	return content
end

local function uniqueRaw(name, baseName, modLine, sourceLine)
	local lines = {
		name,
		baseName,
		"Requires Level 1",
	}
	if sourceLine then
		table.insert(lines, sourceLine)
	end
	table.insert(lines, "Implicits: 0")
	table.insert(lines, modLine)
	return table.concat(lines, "\n")
end

describe("AI unique shortlist", function()
	it("uses TotalEHP, preserves items, and preselects beyond the first 40", function()
		loadBuildFromXML(readFile("../spec/TestBuilds/3.13/OccVortex.xml"), "AI shortlist regression")
		local bridge = LoadModule("Modules/AIBridge")
		bridge.uniqueShortlistCache = nil

		local state = assert(bridge:SerializeBuild(build))
		local output = build.calcsTab.mainOutput
		assert.is_number(state.stats.TotalEHP)
		assert.are.equal(output.TotalEHP, state.stats.TotalEHP)
		for _, damageType in ipairs({ "Physical", "Fire", "Cold", "Lightning", "Chaos" }) do
			local stat = damageType .. "MaximumHitTaken"
			assert.are.equal(output[stat], state.stats[stat])
		end

		local amulets = {}
		for index = 1, 45 do
			table.insert(amulets, uniqueRaw(string.format("Weak Candidate %02d", index), "Amber Amulet", "+1 to Strength"))
		end
		local strongRaw = uniqueRaw("Strong Candidate", "Onyx Amulet", "+1 to Level of all Skill Gems")
		local lifeRaw = uniqueRaw("Life Candidate", "Amber Amulet", "+5000 to maximum Life")
		local balancedRaw = uniqueRaw(
			"Balanced Candidate",
			"Onyx Amulet",
			"+1 to Level of all Skill Gems\n+1000 to maximum Life"
		)
		table.insert(amulets, strongRaw)
		table.insert(amulets, lifeRaw)
		table.insert(amulets, balancedRaw)
		table.insert(amulets, uniqueRaw("Unavailable Candidate", "Onyx Amulet", "+10 to Level of all Skill Gems", "Source: No longer obtainable"))
		local originalUniques = build.data.uniques
		build.data.uniques = { amulet = amulets }

		local itemCountBefore = #build.itemsTab.itemOrderList
		local slotsBefore = {}
		for slotName, slot in pairs(build.itemsTab.slots) do
			slotsBefore[slotName] = slot.selItemId
		end

		local ok, results = pcall(bridge.ComputeUniqueShortlist, bridge, build, 3, true)
		build.data.uniques = originalUniques
		bridge.uniqueShortlistCache = nil
		assert(ok, results)
		assert.are.equal(itemCountBefore, #build.itemsTab.itemOrderList)
		for slotName, itemId in pairs(slotsBefore) do
			assert.are.equal(itemId, build.itemsTab.slots[slotName].selItemId)
		end

		local function findResult(name)
			for _, result in ipairs(results) do
				if result.name:find(name, 1, true) == 1 then
					return result
				end
			end
		end
		local strongResult = findResult("Strong Candidate")
		local lifeResult = findResult("Life Candidate")
		local balancedResult = findResult("Balanced Candidate")
		assert.is_not_nil(strongResult)
		assert.is_not_nil(lifeResult)
		assert.is_not_nil(balancedResult)
		assert.is_true(balancedResult.dpsGainPct > 0)
		assert.is_true(balancedResult.ehpGainPct > 0)
		assert.is_true(balancedResult.balancedGainPct > 0)
		assert.is_nil(findResult("Unavailable Candidate"))

		local calcFunc, baseOutput = build.calcsTab:GetMiscCalculator()
		local lifeItem = new("Item", lifeRaw)
		lifeItem:BuildModList()
		local lifeOutput = calcFunc({ repSlotName = "Amulet", repItem = lifeItem }, false)
		local expectedEHPGain = (lifeOutput.TotalEHP or 0) - (baseOutput.TotalEHP or 0)
		assert.is_true(math.abs(lifeResult.ehpGain - expectedEHPGain) < 0.001)
	end)
end)
