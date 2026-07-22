local function readFile(path)
	local file = assert(io.open(path, "r"))
	local content = file:read("*a")
	file:close()
	return content
end

local function currentMainGroup(activeBuild)
	local skillsTab = assert(activeBuild.skillsTab)
	local skillSet = assert(skillsTab.skillSets[skillsTab.activeSkillSetId])
	return assert(skillSet.socketGroupList[activeBuild.mainSocketGroup or 1])
end

local function currentGemName(activeBuild)
	local group = currentMainGroup(activeBuild)
	for _, gem in ipairs(group.gemList or {}) do
		if gem.nameSpec and gem.nameSpec ~= "" then
			return gem.nameSpec
		end
	end
	error("Fixture has no main skill gem")
end

describe("AI action preflight isolation matrix", function()
	before_each(function()
		loadBuildFromXML(readFile("../spec/TestBuilds/3.13/OccVortex.xml"), "AI preflight matrix")
	end)

	it("preflights successful mutations only on the isolated clone", function()
		local bridge = LoadModule("Modules/AIBridge")
		bridge:InvalidateBuildContext()
		local fingerprint = assert(bridge:GetBuildFingerprint(build))
		local snapshot = assert(build:SaveDB("AI preflight matrix"))
		local gemName = currentGemName(build)

		local configKey
		local configValue
		for key, value in pairs(build.configTab.input) do
			if type(value) == "boolean" or type(value) == "number" then
				configKey = key
				configValue = value
				break
			end
		end
		assert.is_not_nil(configKey)

		local cases = {
			{ name = "level", action = { type = "set_level", value = build.characterLevel } },
			{ name = "config", action = { type = "set_config", key = configKey, value = configValue } },
			{ name = "bandit", action = { type = "set_bandit", value = "None" } },
			{ name = "pantheon", action = { type = "set_pantheon", major = "None", minor = "None" } },
			{
				name = "item",
				action = {
					type = "equip_item",
					slot = "Amulet",
					raw = "Rarity: Rare\nAI Regression Amulet\nAmber Amulet\nImplicits: 0\n+10 to maximum Life",
				},
			},
			{ name = "add skill", action = { type = "add_skill", label = "AI Test", gems = { gemName } } },
			{ name = "main skill", action = { type = "set_main_skill", name = gemName } },
			{ name = "skill part", action = { type = "set_skill_part", name = gemName, part = 1 } },
		}

		for _, case in ipairs(cases) do
			local report = bridge:PreflightActions(build, { case.action }, snapshot)
			assert.is_true(report.ok, case.name .. ": " .. tostring(report.results[1] and report.results[1].msg))
			assert.are.equal("preflight", report.phase)
			assert.is_table(report.after)
			assert.are.equal(fingerprint, assert(bridge:GetBuildFingerprint(build)), case.name)
		end
	end)

	it("rejects semantic failures without changing the active build", function()
		local bridge = LoadModule("Modules/AIBridge")
		bridge:InvalidateBuildContext()
		local fingerprint = assert(bridge:GetBuildFingerprint(build))
		local snapshot = assert(build:SaveDB("AI preflight failures"))
		local gemName = currentGemName(build)

		local cases = {
			{
				name = "invalid item slot",
				action = {
					type = "equip_item", slot = "Definitely Missing",
					raw = "Rarity: Rare\nAI Regression Ring\nCoral Ring\nImplicits: 0\n+10 to maximum Life",
				},
			},
			{ name = "missing passive", action = { type = "alloc_node", id = 987654321 } },
			{ name = "unknown config", action = { type = "set_config", key = "notARealConfig", value = true } },
			{ name = "unknown class", action = { type = "set_class", name = "NotAClass" } },
			{ name = "unknown ascendancy", action = { type = "set_ascendancy", name = "NotAnAscendancy" } },
			{ name = "invalid bandit", action = { type = "set_bandit", value = "Eramir" } },
			{ name = "invalid pantheon", action = { type = "set_pantheon", major = "NotAGod" } },
			{ name = "unknown gem", action = { type = "add_skill", gems = { "Definitely Not A Real Gem" } } },
			{ name = "missing skill", action = { type = "remove_skill", label = "Definitely Missing" } },
			{
				name = "invalid jewel socket",
				action = {
					type = "equip_jewel", nodeId = 987654321,
					raw = "Rarity: Rare\nAI Regression Jewel\nCrimson Jewel\nImplicits: 0\n+10 to Strength",
				},
			},
			{ name = "missing tattoo node", action = { type = "apply_tattoo", id = 987654321, tattoo = "Tattoo of Test" } },
			{ name = "missing tattoo removal", action = { type = "remove_tattoo", id = 987654321 } },
			{ name = "missing mastery", action = { type = "set_mastery", id = 987654321, effect = 1 } },
			{
				name = "main skill index out of range",
				action = { type = "set_main_skill", name = gemName, skillIndex = 999 },
			},
			{ name = "secondary ascendancy unavailable", action = { type = "set_secondary_ascendancy", name = "Warden" } },
			{ name = "missing skill part", action = { type = "set_skill_part", name = "Definitely Missing", part = 1 } },
		}

		for _, case in ipairs(cases) do
			local report = bridge:PreflightActions(build, { case.action }, snapshot)
			assert.is_false(report.ok, case.name)
			assert.are.equal("preflight", report.phase, case.name)
			assert.is_truthy(report.results[1].msg:find("failed preflight", 1, true), case.name)
			assert.are.equal(fingerprint, assert(bridge:GetBuildFingerprint(build)), case.name)
		end
	end)
end)
