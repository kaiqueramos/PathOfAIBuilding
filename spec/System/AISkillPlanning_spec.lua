local function readFile(path)
	local file = assert(io.open(path, "r"))
	local content = file:read("*a")
	file:close()
	return content
end

describe("AI skill planning", function()
	local bridge

	local function startCharacter(className, level)
		newBuild()
		build.characterLevel = level
		build.characterLevelAutoMode = false
		build.spec:ResetNodes()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap[className]))
		build.spec:BuildAllDependsAndPaths()
		build.buildFlag = true
		assert(bridge:RebuildBuild(build))
	end

	local function socketGroups()
		local skillsTab = build.skillsTab
		return skillsTab.skillSets[skillsTab.activeSkillSetId].socketGroupList
	end

	local function findGem(name)
		for _, gemData in pairs(build.data.gems) do
			if gemData.name == name then
				return gemData
			end
		end
		error("Unknown gem " .. name)
	end

	before_each(function()
		bridge = LoadModule("Modules/AIBridge")
		bridge:InvalidateBuildContext()
	end)

	describe("level limits", function()
		it("caps a gem at the highest level the character can use", function()
			newBuild()
			local fireball = findGem("Fireball")
			local lowLevel = assert(bridge:GetMaxLegalGemLevel(fireball, 12))
			local highLevel = assert(bridge:GetMaxLegalGemLevel(fireball, 100))
			assert.is_true(lowLevel < highLevel)
			assert.are.equal(fireball.naturalMaxLevel, highLevel)
			local levels = fireball.grantedEffect.levels
			assert.is_true(levels[lowLevel].levelRequirement <= 12)
			assert.is_true(levels[lowLevel + 1].levelRequirement > 12)
		end)

		it("reports no legal level while the character is below the gem requirement", function()
			newBuild()
			local spellEcho = findGem("Spell Echo")
			local minimum = spellEcho.grantedEffect.levels[1].levelRequirement
			assert.is_nil((bridge:GetMaxLegalGemLevel(spellEcho, minimum - 1)))
			assert.are.equal(1, (bridge:GetMaxLegalGemLevel(spellEcho, minimum)))
		end)

		it("refuses a gem above the character level", function()
			startCharacter("Witch", 30)
			local ok, message = bridge:ActionAddSkill(build, { label = "Echo", gems = { "Fireball", "Spell Echo" } })
			assert.is_false(ok)
			assert.is_truthy(message:find("requires character level", 1, true))
			assert.are.equal(0, #socketGroups())
		end)

		it("lowers gem levels when the character level is lowered", function()
			startCharacter("Witch", 90)
			assert.is_true((bridge:ActionAddSkill(build, {
				label = "Main",
				gems = { { name = "Fireball", level = 20 }, "Efficacy" },
			})))
			assert.are.equal(20, socketGroups()[1].gemList[1].level)
			assert.is_true((bridge:ActionSetLevel(build, { value = 30 })))
			local gem = socketGroups()[1].gemList[1]
			assert.are.equal(bridge:GetMaxLegalGemLevel(findGem("Fireball"), 30), gem.level)
		end)
	end)

	describe("socket budget", function()
		it("grows with the level", function()
			local expected = {
				{ level = 1, links = 3, sockets = 9 },
				{ level = 12, links = 3, sockets = 9 },
				{ level = 13, links = 4, sockets = 14 },
				{ level = 38, links = 4, sockets = 18 },
				{ level = 39, links = 5, sockets = 18 },
				{ level = 67, links = 5, sockets = 24 },
				{ level = 68, links = 6, sockets = 24 },
			}
			for _, row in ipairs(expected) do
				local budget = bridge:GetSocketBudget(nil, row.level)
				assert.are.equal(row.links, budget.maxMainLinks, "links at " .. row.level)
				assert.are.equal(row.sockets, budget.maxTotalSockets, "sockets at " .. row.level)
				assert.is_true(budget.enforceTotal)
			end
		end)

		it("ignores the default sockets PoB gives an item that lists none", function()
			startCharacter("Witch", 30)
			local armour
			for name, base in pairs(build.data.itemBases) do
				if base.type == "Body Armour" and base.socketLimit == 6 and not base.hidden then
					armour = name
					break
				end
			end
			assert.is_not_nil(armour)
			assert.is_true((bridge:ActionEquipItem(build, {
				slot = "Body Armour",
				raw = "Rarity: RARE\nAI Test Armour\n" .. armour .. "\nImplicits: 0\n+10 to maximum Life",
			})))
			local budget = bridge:GetSocketBudget(build, 30)
			assert.are.equal("level", budget.source)
			assert.are.equal(4, budget.maxMainLinks)
			assert.is_true(budget.enforceTotal)
		end)

		it("does not enforce the socket total on a build whose gear has sockets", function()
			loadBuildFromXML(readFile("../spec/TestBuilds/3.13/OccVortex.xml"), "AI socket budget")
			local budget = bridge:GetSocketBudget(build, build.characterLevel)
			assert.is_true(budget.gearSockets > 0)
			assert.is_false(budget.enforceTotal)
		end)

		it("keeps a group inside the link limit of the level", function()
			startCharacter("Witch", 12)
			local ok, message = bridge:ActionAddSkill(build, {
				label = "Big",
				gems = { "Fireball", "Efficacy", "Void Manipulation", "Chance to Poison" },
			})
			assert.is_false(ok)
			assert.is_truthy(message:find("linked gems", 1, true))
			assert.are.equal(0, #socketGroups())
		end)

		it("rejects a skill that does not fit the sockets of a new character", function()
			startCharacter("Witch", 12)
			for index = 1, 3 do
				assert.is_true((bridge:ActionAddSkill(build, {
					label = "Group " .. index,
					gems = { "Fireball", "Efficacy", "Void Manipulation" },
				})))
			end
			local ok, message = bridge:ActionAddSkill(build, { label = "Extra", gems = { "Fireball" } })
			assert.is_false(ok)
			assert.is_truthy(message:find("sockets", 1, true))
			assert.are.equal(3, #socketGroups())
		end)
	end)

	describe("automatic supports", function()
		it("links level-legal supports to a lone active skill", function()
			startCharacter("Witch", 30)
			assert.is_true((bridge:ActionAddSkill(build, { label = "Main", gems = { "Fireball" } })))
			local group = socketGroups()[1]
			local budget = bridge:GetSocketBudget(build, 30)
			assert.is_true(#group.gemList > 1)
			assert.is_true(#group.gemList <= budget.maxMainLinks)
			local seen = {}
			for index, gem in ipairs(group.gemList) do
				local gemData = assert(gem.gemData, gem.nameSpec)
				local legal = assert(bridge:GetMaxLegalGemLevel(gemData, 30), gem.nameSpec)
				assert.is_true(gem.level <= legal, gem.nameSpec)
				assert.is_nil(seen[gem.nameSpec], gem.nameSpec)
				seen[gem.nameSpec] = true
				if index > 1 then
					assert.is_true(gemData.grantedEffect.support, gem.nameSpec)
				end
			end
		end)

		it("uses three links at level 12", function()
			startCharacter("Witch", 12)
			assert.is_true((bridge:ActionAddSkill(build, { label = "Main", gems = { "Fireball" } })))
			local count = #socketGroups()[1].gemList
			assert.is_true(count > 1 and count <= 3)
		end)

		it("keeps the supports the caller named", function()
			startCharacter("Witch", 30)
			assert.is_true((bridge:ActionAddSkill(build, { label = "Main", gems = { "Fireball", "Efficacy" } })))
			assert.are.equal(2, #socketGroups()[1].gemList)
		end)

		it("does not link damage supports to an aura", function()
			startCharacter("Templar", 30)
			assert.is_true((bridge:ActionAddSkill(build, { label = "Aura", gems = { "Hatred" } })))
			assert.are.equal(1, #socketGroups()[1].gemList)
		end)

		it("never picks supports that change how a skill is placed", function()
			startCharacter("Witch", 90)
			assert.is_true((bridge:ActionAddSkill(build, { label = "Main", gems = { "Fireball" } })))
			for _, gem in ipairs(socketGroups()[1].gemList) do
				local effect = gem.gemData.grantedEffect
				assert.is_nil(effect.addFlags and (effect.addFlags.trap or effect.addFlags.mine or effect.addFlags.totem), gem.nameSpec)
				assert.is_falsy(effect.isTrigger, gem.nameSpec)
			end
		end)

		it("measures an attack skill with a temporary weapon and leaves no item behind", function()
			startCharacter("Ranger", 30)
			local before = assert(bridge:GetBuildFingerprint(build))
			local picks = bridge:SelectOptimalSupportGems(build, findGem("Lightning Arrow"), 30, 3)
			assert.are.equal(3, #picks)
			assert.are.equal(before, assert(bridge:GetBuildFingerprint(build)))
			assert.is_nil(next(build.itemsTab.items))
			assert.are.equal(0, #build.itemsTab.itemOrderList)
			assert.are.equal(0, build.itemsTab.slots["Weapon 1"].selItemId)
			assert.is_true((bridge:ActionAddSkill(build, { label = "Main", gems = { "Lightning Arrow" } })))
			assert.is_true(#socketGroups()[1].gemList > 1)
		end)

		it("previews an attack skill on the isolated clone as it applies it", function()
			startCharacter("Ranger", 30)
			local fingerprint = assert(bridge:GetBuildFingerprint(build))
			local snapshot = assert(build:SaveDB("AI skill planning"))
			local actions = { { type = "add_skill", label = "Main", gems = { "Lightning Arrow" } } }
			local preview = bridge:PreflightActions(build, actions, snapshot)
			assert.is_true(preview.ok, preview.results[1] and preview.results[1].msg)
			assert.is_nil(next(build.itemsTab.items))
			local applied = bridge:ApplyActionBatch(build, actions, fingerprint)
			assert.is_true(applied.ok, applied.results[1] and applied.results[1].msg)
			assert.are.equal(preview.results[1].msg, applied.results[1].msg)
		end)

		it("previews the same supports that applying adds", function()
			startCharacter("Witch", 30)
			local fingerprint = assert(bridge:GetBuildFingerprint(build))
			local snapshot = assert(build:SaveDB("AI skill planning"))
			local actions = { { type = "add_skill", label = "Main", gems = { "Fireball" } } }
			local preview = bridge:PreflightActions(build, actions, snapshot)
			assert.is_true(preview.ok, preview.results[1] and preview.results[1].msg)
			assert.are.equal(0, #socketGroups())

			local applied = bridge:ApplyActionBatch(build, actions, fingerprint)
			assert.is_true(applied.ok, applied.results[1] and applied.results[1].msg)
			assert.are.equal(preview.results[1].msg, applied.results[1].msg)
			assert.is_true(#socketGroups()[1].gemList > 1)
		end)

		it("restores the build after selecting supports", function()
			startCharacter("Witch", 30)
			local before = assert(bridge:GetBuildFingerprint(build))
			local picks = bridge:SelectOptimalSupportGems(build, findGem("Fireball"), 30, 3)
			assert.are.equal(3, #picks)
			assert.are.equal(before, assert(bridge:GetBuildFingerprint(build)))
			assert.are.equal(0, #socketGroups())
		end)
	end)

	describe("mana and reservation", function()
		it("rejects reservations that leave no mana", function()
			startCharacter("Witch", 30)
			local snapshot = assert(build:SaveDB("AI skill planning"))
			local report = bridge:PreflightActions(build, {
				{ type = "add_skill", label = "A", gems = { "Hatred" } },
				{ type = "add_skill", label = "B", gems = { "Anger" } },
				{ type = "add_skill", label = "C", gems = { "Wrath" } },
			}, snapshot)
			assert.is_false(report.ok)
			assert.is_truthy(report.results[1].msg:find("unreserved mana", 1, true))
		end)

		it("rejects a skill the character can no longer pay for", function()
			startCharacter("Witch", 30)
			assert.is_true((bridge:ActionAddSkill(build, { label = "Main", gems = { "Fireball" } })))
			assert.is_true((bridge:ActionSetMainSkill(build, { name = "Main" })))
			assert(bridge:RebuildBuild(build))
			local snapshot = assert(build:SaveDB("AI skill planning"))
			local report = bridge:PreflightActions(build, {
				{ type = "add_skill", label = "A", gems = { "Hatred" } },
				{ type = "add_skill", label = "B", gems = { "Anger" } },
			}, snapshot)
			assert.is_false(report.ok)
			assert.is_truthy(report.results[1].msg:find("Cannot afford", 1, true))
		end)

		it("accepts a reservation that leaves mana for the main skill", function()
			startCharacter("Witch", 30)
			assert.is_true((bridge:ActionAddSkill(build, { label = "Main", gems = { "Fireball" } })))
			assert.is_true((bridge:ActionSetMainSkill(build, { name = "Main" })))
			assert(bridge:RebuildBuild(build))
			local snapshot = assert(build:SaveDB("AI skill planning"))
			local report = bridge:PreflightActions(build, {
				{ type = "add_skill", label = "A", gems = { "Hatred" } },
			}, snapshot)
			assert.is_true(report.ok, report.results[1] and report.results[1].msg)
		end)
	end)
end)
