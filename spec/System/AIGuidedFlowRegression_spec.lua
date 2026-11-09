-- cspell:ignore Upvalue Faca feiti feitico pido
-- Regressions found by running the guided flow against a real model (headless fuzz run).
local dkjson = require "dkjson"

local function readFile(path)
	local file = assert(io.open(path, "r"))
	local content = file:read("*a")
	file:close()
	return content
end

local function findUpvalue(fn, targetName)
	for index = 1, 32 do
		local name, value = debug.getupvalue(fn, index)
		if not name then
			break
		end
		if name == targetName then
			return value
		end
	end
end

local function validBrief()
	return {
		stage = "brief",
		mainSkill = "Fireball",
		class = "Witch",
		ascendancy = "None",
		targetLevel = 30,
		priority = "balanced",
		constraints = { "league starter" },
		assumptions = { "no required uniques" },
	}
end

--- Replace the HTTP layer. The responder returns content, finish reason and an optional error text.
local function withTransport(bridge, responder, run, requestOptions)
	local aiConfig = findUpvalue(bridge.Ask, "AIConfig")
	assert.is_table(aiConfig)
	local names = { "Validate", "GetEndpoint", "GetAPIKey", "GetModel", "GetTimeout", "GetRequestOptions" }
	local saved = {}
	for _, name in ipairs(names) do
		saved[name] = aiConfig[name]
	end
	local originalDownloadPage = launch.DownloadPage
	local requests, timeouts = {}, {}

	aiConfig.Validate = function() return true end
	aiConfig.GetEndpoint = function() return "https://example.invalid/v1" end
	aiConfig.GetAPIKey = function() return "test-key" end
	aiConfig.GetModel = function() return "test-model" end
	aiConfig.GetTimeout = function() return 100 end
	aiConfig.GetRequestOptions = function() return requestOptions or {} end
	launch.DownloadPage = function(_, _, callback, params)
		table.insert(requests, (assert(dkjson.decode(params.body))))
		table.insert(timeouts, params.timeout)
		local content, finish, errMsg, errBody = responder(#requests)
		callback({
			body = errMsg and (errBody or "") or (assert(dkjson.encode({
				choices = { { message = { content = content }, finish_reason = finish or "stop" } },
			}))),
		}, errMsg)
		return #requests
	end

	local ok, err = pcall(run, requests, timeouts)
	for _, name in ipairs(names) do
		aiConfig[name] = saved[name]
	end
	launch.DownloadPage = originalDownloadPage
	assert(ok, err)
end

local ANSWER = 'Full answer.\n<turn>{"next":"answer","goal":"advice","reason":"enough context"}</turn>'

describe("AI model output limit", function()
	before_each(function()
		loadBuildFromXML(readFile("../spec/TestBuilds/3.13/OccVortex.xml"), "AI output limit")
	end)

	it("retries a reply that the limit cut off, with a doubled budget and timeout", function()
		local bridge = LoadModule("Modules/AIBridge")
		local conversation = LoadModule("Modules/AIConversation")
		local session = conversation:NewSession()
		local callbackContent, callbackError

		withTransport(bridge, function(count)
			if count == 1 then
				return "Half of the reply <turn>{\"next\":", "length"
			end
			return ANSWER, "stop"
		end, function(requests, timeouts)
			bridge:Ask(build, "Explain this build", function(content, err)
				callbackContent = content
				callbackError = err
			end, {}, false, session)
			assert.are.equal(2, #requests)
			assert.are.equal(8192, requests[1].max_tokens)
			assert.are.equal(16384, requests[2].max_tokens)
			assert.are.equal(100, timeouts[1])
			assert.are.equal(200, timeouts[2])
		end)

		assert.is_nil(callbackError)
		assert.is_truthy(callbackContent:find("Full answer.", 1, true))
		assert.are.equal("ready", session.state)
		assert.is_false(bridge.pending)
	end)

	it("stops at the ceiling and tells the player what to change", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackContent, callbackError

		withTransport(bridge, function()
			return "Still thinking", "length"
		end, function(requests)
			bridge:Ask(build, "Explain this build", function(content, err)
				callbackContent = content
				callbackError = err
			end, {})
			assert.are.same({ 8192, 16384, 32768 }, {
				requests[1].max_tokens, requests[2].max_tokens, requests[3].max_tokens,
			})
			assert.are.equal(3, #requests)
		end)

		assert.is_nil(callbackContent)
		assert.is_truthy(callbackError:find("ran out of output tokens", 1, true))
		assert.is_truthy(callbackError:find("max_tokens", 1, true))
		assert.is_false(bridge.pending)
	end)

	it("reports a provider that refuses the larger limit instead of a vague API error", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackError

		withTransport(bridge, function(count)
			if count == 1 then
				return "Cut", "length"
			end
			return nil, nil, "Response code: 400"
		end, function(requests)
			bridge:Ask(build, "Explain this build", function(_, err)
				callbackError = err
			end, {})
			assert.are.equal(2, #requests)
		end)

		assert.is_truthy(callbackError:find("did not accept a larger limit", 1, true))
		assert.is_false(bridge.pending)
	end)

	it("accepts a valid build direction that arrives without a turn block", function()
		local bridge = LoadModule("Modules/AIBridge")
		local conversation = LoadModule("Modules/AIConversation")
		local session = conversation:NewSession()
		local callbackError, callbackTurn, callbackBrief

		withTransport(bridge, function()
			return 'Direction below.\n<brief>{"stage":"brief","mainSkill":"Fireball","class":"Witch",'
				.. '"ascendancy":"None","targetLevel":30,"priority":"balanced",'
				.. '"constraints":["league starter"],"assumptions":["no required uniques"]}</brief>'
		end, function()
			bridge:Ask(build, "Create a build", function(_, err, _, turn, brief)
				callbackError = err
				callbackTurn = turn
				callbackBrief = brief
			end, {}, false, session)
		end)

		assert.is_nil(callbackError)
		assert.are.equal("proposal", callbackTurn.next)
		assert.are.equal("Fireball", callbackBrief.mainSkill)
		assert.is_false(bridge.pending)
	end)

	it("halves the budget when the provider says the token limit is too large", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackError

		withTransport(bridge, function(count)
			if count == 1 then
				return nil, nil, "Response code: 400", '{"error":{"message":"max_tokens must be <= 4096"}}'
			end
			return ANSWER, "stop"
		end, function(requests)
			bridge:Ask(build, "Explain this build", function(_, err)
				callbackError = err
			end, {})
			assert.are.same({ 8192, 4096 }, { requests[1].max_tokens, requests[2].max_tokens })
		end)

		assert.is_nil(callbackError)
		assert.is_false(bridge.pending)
	end)

	it("shows the provider's own message and does not retry other failures", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackError

		withTransport(bridge, function()
			return nil, nil, "Response code: 401", '{"error":{"message":"Invalid API key"}}'
		end, function(requests)
			bridge:Ask(build, "Explain this build", function(_, err)
				callbackError = err
			end, {})
			assert.are.equal(1, #requests)
		end)

		assert.is_truthy(callbackError:find("Response code: 401", 1, true))
		assert.is_truthy(callbackError:find("Invalid API key", 1, true))
		assert.is_false(bridge.pending)
	end)

	it("never repeats anything key-like from a provider error", function()
		local bridge = LoadModule("Modules/AIBridge")
		local fakeKey = "sk-" .. string.rep("a1", 20)
		local callbackError

		withTransport(bridge, function()
			return nil, nil, "Response code: 401",
				'{"error":{"message":"Incorrect API key provided: ' .. fakeKey .. '. Check your account."}}'
		end, function()
			bridge:Ask(build, "Explain this build", function(_, err)
				callbackError = err
			end, {})
		end)

		assert.is_truthy(callbackError:find("Incorrect API key provided", 1, true))
		assert.is_nil(callbackError:find(fakeKey, 1, true))
		assert.is_truthy(callbackError:find("[redacted]", 1, true))
	end)

	it("keeps model names readable in a provider error", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackError

		withTransport(bridge, function()
			return nil, nil, "Response code: 400",
				'{"error":{"message":"The model acme/model-v4.1-flash-1017 does not exist"}}'
		end, function()
			bridge:Ask(build, "Explain this build", function(_, err)
				callbackError = err
			end, {})
		end)

		assert.is_truthy(callbackError:find("acme/model-v4.1-flash-1017", 1, true))
	end)

	it("starts from the max_tokens the player configured", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackError

		withTransport(bridge, function()
			return ANSWER
		end, function(requests)
			bridge:Ask(build, "Explain this build", function(_, err)
				callbackError = err
			end, {})
			assert.are.equal(3000, requests[1].max_tokens)
		end, { max_tokens = 3000 })

		assert.is_nil(callbackError)
	end)
end)

describe("AI turn parsing", function()
	it("accepts a plain reply without a turn block as a read-only answer", function()
		local conversation = LoadModule("Modules/AIConversation")
		local text, turn, err = conversation:ParseTurnOrAnswer("Just prose.")
		assert.is_nil(err)
		assert.are.equal("Just prose.", text)
		assert.are.equal("answer", turn.next)
	end)

	it("keeps validating real turn blocks", function()
		local conversation = LoadModule("Modules/AIConversation")
		local _, turn, err = conversation:ParseTurnOrAnswer(ANSWER)
		assert.is_nil(err)
		assert.are.equal("advice", turn.goal)

		local _, brokenTurn, brokenError = conversation:ParseTurnOrAnswer('Text <turn>{"next":')
		assert.is_nil(brokenTurn)
		assert.is_truthy(brokenError:find("incomplete", 1, true))
	end)

	it("never turns a reply with actions or a context request into an answer", function()
		local conversation = LoadModule("Modules/AIConversation")
		for _, reply in ipairs({
			'Do it. <actions>[{"type":"set_level","value":100}]</actions>',
			'<context_request>["gems"]</context_request>',
		}) do
			local _, turn, err = conversation:ParseTurnOrAnswer(reply)
			assert.is_nil(turn, reply)
			assert.is_truthy(err, reply)
		end
	end)

	it("treats a build direction without a turn block as a proposal for the player to review", function()
		local conversation = LoadModule("Modules/AIConversation")
		local _, turn, err = conversation:ParseTurnOrAnswer("Plan <brief>{}</brief>")
		assert.is_nil(err)
		assert.are.equal("proposal", turn.next)
	end)
end)

describe("AI build fingerprint and defaults", function()
	it("ignores minion and Calcs tab choices that PoB fills in on its own", function()
		loadBuildFromXML(readFile("../spec/TestBuilds/3.13/OccVortex.xml"), "AI fingerprint defaults")
		local bridge = LoadModule("Modules/AIBridge")
		local skillsTab = build.skillsTab
		local group = skillsTab.skillSets[skillsTab.activeSkillSetId].socketGroupList[build.mainSocketGroup or 1]
		local gem = group.gemList[1]
		local before = assert(bridge:GetBuildFingerprint(build))

		gem.skillMinion = "ArrowClone"
		gem.skillMinionCalcs = "ArrowClone"
		gem.skillPartCalcs = 2
		gem.skillStageCountCalcs = 3
		assert.are.equal(before, assert(bridge:GetBuildFingerprint(build)))

		gem.level = (tonumber(gem.level) or 20) == 1 and 2 or (tonumber(gem.level) or 20) - 1
		assert.are_not.equal(before, assert(bridge:GetBuildFingerprint(build)))
	end)

	it("tells the player why an attack shows no damage without a weapon", function()
		local bridge = LoadModule("Modules/AIBridge")
		local before = { dps = 0, ehp = 100, maxHits = {}, pointsUsed = 0, ascendancyPointsUsed = 0 }
		local armed = { dps = 0, ehp = 150, maxHits = {}, pointsUsed = 0, ascendancyPointsUsed = 0 }
		local unarmed = { dps = 0, ehp = 150, maxHits = {}, pointsUsed = 0, ascendancyPointsUsed = 0, needsWeapon = true }
		local function joined(lines) return table.concat(lines, "\n") end
		assert.is_nil(joined(bridge:FormatMetricDiff(before, armed)):find("without a weapon", 1, true))
		assert.is_truthy(joined(bridge:FormatMetricDiff(before, unarmed)):find("without a weapon", 1, true))
	end)

	it("shows an amount instead of a meaningless percentage when the base is near zero", function()
		local bridge = LoadModule("Modules/AIBridge")
		local before = { dps = 0.06, ehp = 100, maxHits = {}, pointsUsed = 0, ascendancyPointsUsed = 0 }
		local after = { dps = 378, ehp = 150, maxHits = {}, pointsUsed = 0, ascendancyPointsUsed = 0 }
		local lines = bridge:FormatMetricDiff(before, after)
		assert.is_nil(lines[2]:find("%%"))
		assert.is_truthy(lines[2]:find("+378", 1, true))
		assert.is_truthy(lines[3]:find("+50.0%", 1, true))
	end)
end)

describe("AI passive plan budget", function()
	before_each(function()
		newBuild()
	end)

	local function plannedActions(count)
		local bridge = LoadModule("Modules/AIBridge")
		local planning = LoadModule("Modules/AIPlanning")
		build.characterLevel = 30
		build.characterLevelAutoMode = false
		build.spec:ResetNodes()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Witch))
		build.spec:BuildAllDependsAndPaths()
		assert((bridge:ActionAddSkill(build, { label = "Main", gems = { "Fireball" } })))
		assert((bridge:ActionSetMainSkill(build, { name = "Main" })))
		assert((bridge:RebuildBuild(build)))
		local profile = assert(planning:BuildSkillProfile(build, "Fireball"))
		local candidates = bridge:CollectTreeCandidates(build.spec, 34, 0, {}, profile)
		local actions = {}
		for _, candidate in ipairs(candidates) do
			if candidate.classification == "compatible" or candidate.classification == "defensive" then
				table.insert(actions, { type = "alloc_node", name = candidate.name })
			end
			if #actions == count then
				break
			end
		end
		assert.are.equal(count, #actions)
		return bridge, actions
	end

	it("drops the allocations that the point budget cannot pay for", function()
		local bridge, actions = plannedActions(10)
		build.characterLevel = 12
		assert(bridge:RebuildBuild(build))

		local fitted, dropped = bridge:FitPassivePlanToBudget(build, actions)
		assert.is_true(dropped > 0)
		assert.are.equal(#actions - dropped, #fitted)
		for index, action in ipairs(fitted) do
			assert.are.equal(actions[index], action)
		end
		local snapshot = assert(build:SaveDB("fit"))
		assert.is_true(bridge:PreflightActions(build, fitted, snapshot).ok)
	end)

	it("returns a plan that already fits unchanged", function()
		local bridge, actions = plannedActions(3)
		local fitted, dropped = bridge:FitPassivePlanToBudget(build, actions)
		assert.are.equal(0, dropped)
		assert.are.equal(actions, fitted)
	end)

	it("leaves other kinds of failure for apply time", function()
		local bridge, actions = plannedActions(2)
		table.insert(actions, { type = "alloc_node", name = "Definitely Not A Node" })
		local fitted, dropped = bridge:FitPassivePlanToBudget(build, actions)
		assert.are.equal(0, dropped)
		assert.are.equal(actions, fitted)
	end)
end)

describe("AI item actions", function()
	it("names the item base that PoB does not know", function()
		newBuild()
		local bridge = LoadModule("Modules/AIBridge")
		local ok, message = bridge:ActionEquipItem(build, {
			slot = "Ring 1",
			raw = "Rarity: RARE\nDoom Loop\nRuby Ring Mk Two\nImplicits: 0\n+30 to maximum Life",
		})
		assert.is_false(ok)
		assert.is_truthy(message:find("Ruby Ring Mk Two", 1, true))
		assert.is_truthy(message:find("Invalid item data", 1, true))
	end)
end)

describe("AI gear proposals", function()
	local bridge

	local function levelThirty(className, level)
		newBuild()
		bridge = LoadModule("Modules/AIBridge")
		build.characterLevel = level or 30
		build.characterLevelAutoMode = false
		build.spec:ResetNodes()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap[className or "Ranger"]))
		build.spec:BuildAllDependsAndPaths()
		assert((bridge:RebuildBuild(build)))
	end

	local function rare(name, base, mod)
		return "Rarity: RARE\n" .. name .. "\n" .. base .. "\nImplicits: 0\n" .. (mod or "+10 to maximum Life")
	end

	describe("slot names", function()
		it("accepts the names that models use for the off hand and the other slots", function()
			levelThirty()
			local cases = {
				{ slot = "Main Hand", raw = rare("Wind Bite", "Composite Bow"), expect = "Weapon 1" },
				{ slot = "Quiver", raw = rare("Wind Flight", "Two-Point Arrow Quiver"), expect = "Weapon 2" },
				{ slot = "offhand 1", raw = rare("Wind Flight", "Two-Point Arrow Quiver"), expect = "Weapon 2" },
				{ slot = "helm", raw = rare("Cold Hood", "Leather Cap"), expect = "Helmet" },
				{ slot = "body armor", raw = rare("Cold Shroud", "Buckskin Tunic"), expect = "Body Armour" },
				{ slot = "RING 2", raw = rare("Cold Loop", "Coral Ring"), expect = "Ring 2" },
			}
			for _, case in ipairs(cases) do
				local ok, message = bridge:ActionEquipItem(build, { slot = case.slot, raw = case.raw })
				assert.is_true(ok, case.slot .. ": " .. tostring(message))
				assert.is_truthy(message:find("in " .. case.expect, 1, true), case.slot .. ": " .. message)
				assert.is_true(build.itemsTab.slots[case.expect].selItemId > 0, case.slot)
			end
		end)

		it("does not report a quiver as equipped while Weapon 1 has no bow", function()
			levelThirty("Ranger", 60)
			local ok, message = bridge:ActionEquipItem(build, { slot = "Quiver", raw = rare("Wind Flight", "Two-Point Arrow Quiver") })
			assert.is_false(ok)
			assert.is_truthy(message:find("Weapon 1", 1, true))
			assert.is_nil(next(build.itemsTab.items))
			assert.are.equal(0, build.itemsTab.slots["Weapon 2"].selItemId)
		end)

		it("moves the main weapon ahead of the quiver in a proposal", function()
			levelThirty("Ranger", 60)
			local quiver = { type = "equip_item", slot = "Quiver", raw = rare("Wind Flight", "Two-Point Arrow Quiver") }
			local bow = { type = "equip_item", slot = "Weapon 1", raw = rare("Wind Bite", "Composite Bow") }
			local fitted, notes = bridge:FitProposalToBuild(build, { quiver, bow })

			assert.are.equal(0, #notes)
			assert.are.equal(bow, fitted[1])
			assert.are.equal(quiver, fitted[2])
			local snapshot = assert(build:SaveDB("order"))
			assert.is_true(bridge:PreflightActions(build, fitted, snapshot).ok)
		end)

		it("keeps a proposal that already lists the weapon first", function()
			levelThirty("Ranger", 60)
			local quiver = { type = "equip_item", slot = "Weapon 2", raw = rare("Wind Flight", "Two-Point Arrow Quiver") }
			local bow = { type = "equip_item", slot = "Weapon 1", raw = rare("Wind Bite", "Composite Bow") }
			local actions = { bow, quiver }
			local fitted = bridge:FitProposalToBuild(build, actions)
			assert.are.equal(actions, fitted)
		end)

		it("still rejects a slot that does not exist", function()
			levelThirty()
			local ok, message = bridge:ActionEquipItem(build, { slot = "Pocket", raw = rare("Wind Loop", "Coral Ring") })
			assert.is_false(ok)
			assert.is_truthy(message:find("Invalid slot: Pocket", 1, true))
			assert.is_nil(next(build.itemsTab.items))
		end)
	end)

	describe("item text", function()
		it("repairs a rare that is missing its name line", function()
			levelThirty("Witch")
			local ok, message = bridge:ActionEquipItem(build, {
				slot = "Weapon 1",
				raw = "Rarity: RARE\nCrystal Wand\nImplicits: 0\n+10 to maximum Life",
			})
			assert.is_true(ok, tostring(message))
			assert.is_truthy(message:find("Crystal Wand", 1, true))
		end)

		it("keeps a rare that has both lines unchanged", function()
			levelThirty("Witch")
			local ok, message = bridge:ActionEquipItem(build, { slot = "Weapon 1", raw = rare("Doom Bite", "Crystal Wand") })
			assert.is_true(ok, tostring(message))
			assert.is_truthy(message:find("Doom Bite", 1, true))
		end)
	end)

	describe("items above the character level", function()
		local function unique(name, base)
			return "Rarity: UNIQUE\n" .. name .. "\n" .. base .. "\nImplicits: 0\n+10 to maximum Life"
		end

		local function rawLines(raw)
			local lines = {}
			for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
				table.insert(lines, line)
			end
			return lines
		end

		it("leaves out a unique the character cannot wear and says so", function()
			levelThirty()
			local actions = {
				{ type = "equip_item", slot = "Weapon 1", raw = unique("Too Big", "Thicket Bow") },
				{ type = "equip_item", slot = "Ring 1", raw = rare("Just Right", "Coral Ring") },
			}
			local notes = {}
			local kept = bridge:PruneItemsAboveLevel(build, actions, notes)
			assert.are.equal(1, #kept)
			assert.are.equal("Ring 1", kept[1].slot)
			assert.are.equal(1, #notes)
			assert.is_truthy(notes[1]:find("Left out", 1, true))
			assert.is_truthy(notes[1]:find("Too Big", 1, true))
			assert.is_truthy(notes[1]:find("level 56", 1, true))
		end)

		it("gives a rare the best base the character can wear and keeps its mods", function()
			levelThirty()
			local original = rare("Storm Bite", "Thicket Bow", "+20 to Dexterity")
			local action = { type = "equip_item", slot = "Weapon 1", raw = original }
			local notes = {}

			local kept = bridge:PruneItemsAboveLevel(build, { action }, notes)

			assert.are.equal(1, #kept)
			assert.are.equal(original, action.raw)
			local lines = rawLines(kept[1].raw)
			assert.are.equal("Storm Bite", lines[2])
			assert.are_not.equal("Thicket Bow", lines[3])
			assert.are.equal("+20 to Dexterity", lines[5])
			local base = build.data.itemBases[lines[3]]
			assert.are.equal("Bow", base.type)
			assert.is_true(base.req.level <= 30)
			assert.are.equal(1, #notes)
			assert.is_truthy(notes[1]:find("Changed the base", 1, true))
			assert.is_truthy(notes[1]:find("Storm Bite", 1, true))
			local ok, message = bridge:ActionEquipItem(build, kept[1])
			assert.is_true(ok, tostring(message))
		end)

		it("leaves out a rare whose implicit mods belong to its base", function()
			levelThirty()
			local raw = "Rarity: RARE\nStorm Bite\nThicket Bow\nImplicits: 1\n+20 to Dexterity\n+10 to maximum Life"
			local notes = {}
			local kept = bridge:PruneItemsAboveLevel(build, { { type = "equip_item", slot = "Weapon 1", raw = raw } }, notes)
			assert.are.equal(0, #kept)
			assert.is_truthy(notes[1]:find("Left out", 1, true))
		end)

		it("reports a swap and a removal in the same proposal", function()
			levelThirty()
			local notes = {}
			local kept = bridge:PruneItemsAboveLevel(build, {
				{ type = "equip_item", slot = "Weapon 1", raw = rare("Storm Bite", "Thicket Bow") },
				{ type = "equip_item", slot = "Ring 1", raw = unique("Too Big", "Opal Ring") },
			}, notes)
			assert.are.equal(1, #kept)
			assert.are.equal(2, #notes)
		end)

		it("returns the same table when every item fits", function()
			levelThirty()
			local actions = { { type = "equip_item", slot = "Weapon 1", raw = rare("Light Bow", "Composite Bow") } }
			local notes = {}
			assert.are.equal(actions, bridge:PruneItemsAboveLevel(build, actions, notes))
			assert.are.equal(0, #notes)
		end)
	end)

	describe("skills that the mana cannot carry", function()
		local function witchWithFireball()
			levelThirty("Witch")
			assert.is_true((bridge:ActionAddSkill(build, { label = "Main", gems = { "Fireball" } })))
			assert.is_true((bridge:ActionSetMainSkill(build, { name = "Main" })))
			assert((bridge:RebuildBuild(build)))
		end

		it("keeps the reservations that fit and drops the last ones", function()
			witchWithFireball()
			local actions = {
				{ type = "add_skill", label = "Hatred", gems = { "Hatred" } },
				{ type = "add_skill", label = "Anger", gems = { "Anger" } },
				{ type = "add_skill", label = "Wrath", gems = { "Wrath" } },
			}
			local snapshot = assert(build:SaveDB("fit"))
			assert.is_false(bridge:PreflightActions(build, actions, snapshot).ok)

			local notes = {}
			local fitted = bridge:FitSkillBatchToResources(build, actions, notes)

			assert.is_true(#fitted >= 1 and #fitted < 3)
			assert.are.equal("Hatred", fitted[1].label)
			assert.is_true(bridge:PreflightActions(build, fitted, snapshot).ok)
			assert.are.equal(1, #notes)
			assert.is_truthy(notes[1]:find("Left out", 1, true))
			assert.is_truthy(notes[1]:find("Wrath", 1, true))
		end)

		it("returns the same table when everything fits", function()
			witchWithFireball()
			local actions = { { type = "add_skill", label = "A", gems = { "Hatred" } } }
			local notes = {}
			assert.are.equal(actions, bridge:FitSkillBatchToResources(build, actions, notes))
			assert.are.equal(0, #notes)
		end)

		it("leaves a batch alone when it fails for another reason", function()
			witchWithFireball()
			local actions = { { type = "add_skill", label = "A", gems = { "Definitely Not A Gem" } } }
			local notes = {}
			assert.are.equal(actions, bridge:FitSkillBatchToResources(build, actions, notes))
			assert.are.equal(0, #notes)
		end)

		it("fits a whole proposal in one call", function()
			witchWithFireball()
			local actions = {
				{ type = "equip_item", slot = "Ring 1", raw = rare("Cold Loop", "Coral Ring") },
				{ type = "equip_item", slot = "Amulet", raw = rare("Too Big", "Agate Amulet") },
				{ type = "add_skill", label = "A", gems = { "Hatred" } },
				{ type = "add_skill", label = "B", gems = { "Anger" } },
				{ type = "add_skill", label = "C", gems = { "Wrath" } },
			}
			local fitted, notes = bridge:FitProposalToBuild(build, actions)
			assert.is_true(#fitted < #actions)
			assert.is_true(#notes >= 1)
			local snapshot = assert(build:SaveDB("fit"))
			assert.is_true(bridge:PreflightActions(build, fitted, snapshot).ok)
		end)
	end)
end)

describe("AI turn parsing of unstructured questions", function()
	it("keeps the prose of a clarify turn that has no question", function()
		local conversation = LoadModule("Modules/AIConversation")
		local text, turn, err = conversation:ParseTurnOrAnswer(
			'<turn>{"next":"clarify","goal":"pick a minion","reason":"it decides the tree"}</turn>\n\nWhich minion?\n- Zombies\n- Skeletons'
		)
		assert.is_nil(err)
		assert.are.equal("answer", turn.next)
		assert.is_truthy(text:find("Which minion?", 1, true))
		assert.is_nil(text:find("<turn", 1, true))
	end)

	it("keeps the prose of a clarify turn whose options are malformed", function()
		local conversation = LoadModule("Modules/AIConversation")
		local _, turn, err = conversation:ParseTurnOrAnswer(
			'Pick one.\n<turn>{"next":"clarify","goal":"g","reason":"r","question":{"id":"q","prompt":"Which?","options":5}}</turn>'
		)
		assert.is_nil(err)
		assert.are.equal("answer", turn.next)
	end)

	it("still rejects other damaged turn blocks", function()
		local conversation = LoadModule("Modules/AIConversation")
		local _, turn, err = conversation:ParseTurnOrAnswer('Text <turn>{"next":"fly","goal":"g","reason":"r"}</turn>')
		assert.is_nil(turn)
		assert.is_truthy(err)
	end)
end)

describe("AI action block parsing", function()
	it("adds the closing bracket that the model forgot", function()
		local bridge = LoadModule("Modules/AIBridge")
		local text, actions, err = bridge:ParseActions('Do it.\n<actions>\n[{"type":"set_level","value":30},{"type":"reset_tree"}\n</actions>')
		assert.is_nil(err)
		assert.are.equal("Do it.", text)
		assert.are.equal(2, #actions)
		assert.are.equal("reset_tree", actions[2].type)
	end)

	it("still rejects an array that was cut off in the middle of an item", function()
		local bridge = LoadModule("Modules/AIBridge")
		for _, block in ipairs({
			'[{"type":"set_level","value":30},{"type":"equip_item","raw":"Rarity: RA',
			'[{"type":"set_level","value":30},{"type":"equip_item","raw":"x","extra":{"a":1}',
			'{"type":"set_level","value":30}',
			'[{"type":"set_level","value":30}] trailing words',
		}) do
			local _, actions, err = bridge:ParseActions("Text <actions>" .. block .. "</actions>")
			assert.is_nil(actions, block)
			assert.is_truthy(err, block)
		end
	end)
end)

describe("AI context requests for context that is already included", function()
	before_each(function()
		loadBuildFromXML(readFile("../spec/TestBuilds/3.13/OccVortex.xml"), "AI context repeat")
	end)

	it("answers once more with a note instead of failing", function()
		local bridge = LoadModule("Modules/AIBridge")
		local conversation = LoadModule("Modules/AIConversation")
		local session = conversation:NewSession()
		local callbackContent, callbackError

		withTransport(bridge, function(count)
			if count == 1 then
				return '<context_request>["config"]</context_request>'
			end
			return ANSWER
		end, function(requests)
			bridge:Ask(build, "What config should I set for bosses?", function(content, err)
				callbackContent = content
				callbackError = err
			end, {}, false, session)
			assert.are.equal(2, #requests)
			local secondPrompt = requests[2].messages[#requests[2].messages].content
			assert.is_truthy(secondPrompt:find("already included in this state", 1, true))
			assert.is_truthy(secondPrompt:find('"escalationRemaining":0', 1, true))
		end)

		assert.is_nil(callbackError)
		assert.is_truthy(callbackContent:find("Full answer.", 1, true))
		assert.are.equal("ready", session.state)
		assert.is_false(bridge.pending)
	end)

	it("stops when the model asks again after the note", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackError

		withTransport(bridge, function()
			return '<context_request>["config"]</context_request>'
		end, function(requests)
			bridge:Ask(build, "What config should I set for bosses?", function(_, err)
				callbackError = err
			end, {})
			assert.are.equal(2, #requests)
		end)

		assert.is_truthy(callbackError:find("more than once", 1, true))
		assert.is_false(bridge.pending)
	end)
end)

describe("AI chat tab guided flow", function()
	local chat, bridge, planning

	local function bridgeOf(tab)
		return assert(findUpvalue(tab.SendRequest, "AIBridge"))
	end

	--- A planning session placed in the given stage, as the real flow would leave it.
	local function sessionAt(stage, foundationActions, planActions)
		local fingerprint = assert(bridge:GetBuildFingerprint(build))
		local session = assert(planning:StoreBrief(nil, validBrief(), fingerprint))
		if stage == "brief_pending" then
			return session
		end
		assert(planning:ConfirmBrief(session, fingerprint))
		if stage == "brief_confirmed" then
			return session
		end
		assert(planning:StoreFoundation(session, foundationActions or { { type = "set_level", value = 30 } }, fingerprint))
		if stage == "foundation_pending" then
			return session
		end
		assert(planning:CompleteFoundation(session, fingerprint))
		if stage == "tree" then
			return session
		end
		assert(planning:StorePassivePlan(session, planActions or { { type = "alloc_node", name = "Nothing" } }, fingerprint))
		return session
	end

	before_each(function()
		newBuild()
		chat = build.aiChatTab
		bridge = bridgeOf(chat)
		planning = LoadModule("Modules/AIPlanning")
		bridge:InvalidateBuildContext()
	end)

	describe("clarification chips", function()
		it("keeps AI Decides next to the last option, however many there are", function()
			local autoChip = chat.optionButtons[5]
			for count = 1, 4 do
				local options = {}
				for index = 1, count do
					options[index] = "Option " .. index
				end
				chat:SetClarificationOptions(options)
				assert.is_true(autoChip:IsShown(), count .. " option(s)")
				assert.are.equal(chat.optionButtons[count], autoChip.anchor.other)
				assert.is_true(chat.optionButtons[count]:IsShown())
				if count < 4 then
					assert.is_false(chat.optionButtons[count + 1]:IsShown())
				end
			end
			chat:SetClarificationOptions(nil)
			assert.is_false(autoChip:IsShown())
		end)

		it("shows at most four options and the AI Decides number follows them", function()
			chat:SetClarificationOptions({ "A", "B", "C", "D", "E", "F" })
			assert.is_truthy(chat.optionButtons[5].label:find("[5]", 1, true))
			assert.is_false(chat.optionButtons[4]:IsShown() == false)
		end)

		it("transliterates option text once, so the answer shown matches the chip", function()
			chat:SetClarificationOptions({ "Fa\195\167a um build de feiti\195\167o (r\195\161pido)" })
			assert.are.equal("Faca um build de feitico", chat.optionValues[1])
			assert.is_nil(chat.optionValues[1]:find("[\128-\255]"))
		end)

		it("answers with the chip that a typed digit names", function()
			local fingerprint = assert(bridge:GetBuildFingerprint(build))
			local originalAsk = bridge.Ask
			local answers = {}
			bridge.Ask = function(_, _, userMessage, callback)
				table.insert(answers, userMessage)
				callback(nil, "stopped by the test")
			end

			local ok, err = pcall(function()
				for _, digit in ipairs({ "1", "2", "3", "4" }) do
					chat.conversationSession = {
						state = "awaiting_user", constraints = {}, loadedContexts = {}, contextAttempts = 0,
						fingerprint = fingerprint, clarificationFingerprint = fingerprint,
						pendingQuestion = { id = "q", prompt = "Which one?", options = { "Fireball", "Arc" } },
					}
					chat:SetClarificationOptions({ "Fireball", "Arc" })
					chat:SendMessage(digit)
				end
			end)
			bridge.Ask = originalAsk
			assert(ok, err)

			assert.are.same({ "Fireball", "Arc", "Choose the best option for me", "4" }, answers)
		end)
	end)

	describe("proposals", function()
		local function propose(actions)
			local conversation = LoadModule("Modules/AIConversation")
			local originalAsk = bridge.Ask
			bridge.Ask = function(_, _, _, callback, _, _, session, planningSession)
				local fingerprint = assert(bridge:GetBuildFingerprint(build))
				assert(conversation:BeginRequest(session, fingerprint))
				local turn = { next = "proposal", goal = "gear", reason = "validated proposal" }
				assert(conversation:ApplyTurn(session, turn, fingerprint))
				callback("Here is the gear.\n<actions>" .. assert(dkjson.encode(actions)) .. "</actions>", nil, fingerprint, turn, nil, planningSession)
			end
			local ok, err = pcall(function()
				chat:SendMessage("Recommend gear")
				chat:FinishStream()
			end)
			bridge.Ask = originalAsk
			assert(ok, err)
		end

		local function rareItem(name, base)
			return "Rarity: RARE\n" .. name .. "\n" .. base .. "\nImplicits: 0\n+10 to maximum Life"
		end

		local function uniqueItem(name, base)
			return "Rarity: UNIQUE\n" .. name .. "\n" .. base .. "\nImplicits: 0\n+10 to maximum Life"
		end

		before_each(function()
			build.characterLevel = 30
			build.characterLevelAutoMode = false
			assert((bridge:RebuildBuild(build)))
		end)

		it("offers the items the character can wear and tells the player what was left out", function()
			propose({
				{ type = "equip_item", slot = "Weapon 1", raw = uniqueItem("Too Big", "Thicket Bow") },
				{ type = "equip_item", slot = "Ring 1", raw = rareItem("Just Right", "Coral Ring") },
			})

			assert.are.equal(1, #chat.pendingActions)
			assert.are.equal("Ring 1", chat.pendingActions[1].slot)
			assert.is_true(chat.controls.applyActions.shown)
			local note = chat.messages[#chat.messages]
			assert.are.equal("system", note.role)
			assert.is_truthy(note.text:find("Too Big", 1, true))
			assert.is_truthy(note.text:find("Left out", 1, true))
		end)

		it("offers a rare above the level with a base the character can wear", function()
			propose({ { type = "equip_item", slot = "Weapon 1", raw = rareItem("Storm Bite", "Thicket Bow") } })

			assert.are.equal(1, #chat.pendingActions)
			assert.is_nil(chat.pendingActions[1].raw:find("Thicket Bow", 1, true))
			assert.is_true(chat.controls.applyActions.shown)
			assert.is_truthy(chat.messages[#chat.messages].text:find("Changed the base", 1, true))
			local snapshot = assert(build:SaveDB("fit"))
			assert.is_true(bridge:PreflightActions(build, chat.pendingActions, snapshot).ok)
		end)

		it("hides Apply when nothing in the proposal is usable", function()
			propose({ { type = "equip_item", slot = "Weapon 1", raw = uniqueItem("Too Big", "Thicket Bow") } })

			assert.is_nil(chat.pendingActions)
			assert.is_false(chat.controls.applyActions.shown)
			assert.is_truthy(chat.messages[#chat.messages].text:find("Left out", 1, true))
		end)

		it("shows a proposal that needs no change exactly as it came", function()
			propose({ { type = "equip_item", slot = "Ring 1", raw = rareItem("Just Right", "Coral Ring") } })

			assert.are.equal(1, #chat.pendingActions)
			assert.is_true(chat.controls.applyActions.shown)
			for _, message in ipairs(chat.messages) do
				assert.is_nil((message.text or ""):find("Left out", 1, true))
			end
		end)
	end)

	describe("replies", function()
		it("never shows protocol tags that the model left outside a block", function()
			local conversation = LoadModule("Modules/AIConversation")
			local originalAsk = bridge.Ask
			bridge.Ask = function(_, _, _, callback, _, _, session, planningSession)
				local fingerprint = assert(bridge:GetBuildFingerprint(build))
				assert(conversation:BeginRequest(session, fingerprint))
				local turn = { next = "answer", goal = "advice", reason = "enough context" }
				assert(conversation:ApplyTurn(session, turn, fingerprint))
				callback("Here is the answer.\n\n</turn>\n\nMore <brief> text </context_request>", nil, fingerprint, turn, nil, planningSession)
			end
			local ok, err = pcall(function()
				chat:SendMessage("Explain this build")
				chat:FinishStream()
			end)
			bridge.Ask = originalAsk
			assert(ok, err)

			local reply
			for _, message in ipairs(chat.messages) do
				if message.role == "ai" then
					reply = message
				end
			end
			local shown = assert(reply, "no AI message was added").full:lower()
			assert.is_truthy(shown:find("here is the answer", 1, true))
			for _, tag in ipairs({ "<turn", "</turn", "<brief", "</context_request" }) do
				assert.is_nil(shown:find(tag, 1, true), tag)
			end
		end)
	end)

	describe("proposals that fail to apply", function()
		it("keeps Apply Foundation when the foundation is rejected", function()
			chat.planningSession = sessionAt("foundation_pending", { { type = "set_class", name = "NotAClass" } })
			chat.controls.applyFoundation.shown = true
			chat:ApplyFoundation()

			assert.are.equal("foundation_pending", chat.planningSession.state)
			assert.is_true(chat.controls.applyFoundation.shown)
			assert.is_true(chat.controls.applyFoundation.enabled)
		end)

		it("keeps Apply Passive Plan when the plan is rejected", function()
			chat.planningSession = sessionAt("tree_pending", nil, { { type = "alloc_node", name = "Definitely Not A Node" } })
			chat.controls.applyPassivePlan.shown = true
			chat:ApplyPassivePlan()

			assert.are.equal("tree_pending", chat.planningSession.state)
			assert.is_true(chat.controls.applyPassivePlan.shown)
			assert.is_true(chat.controls.applyPassivePlan.enabled)
		end)
	end)

	describe("skipping the passive tree stage", function()
		it("lets the player move on when no plan is possible", function()
			chat.planningSession = sessionAt("tree")
			assert.is_true(chat.controls.quickTreePlan:IsShown())
			assert.is_true(chat.controls.quickSkipTree:IsShown())

			chat:SkipTreeStage()

			assert.is_true(chat.planningSession.passivePlanApplied)
			assert.is_false(chat.controls.quickTreePlan:IsShown())
			assert.is_false(chat.controls.quickSkipTree:IsShown())
			assert.is_truthy(chat.messages[#chat.messages].text:find("skipped", 1, true))
		end)

		it("does nothing outside the passive tree stage", function()
			chat.planningSession = sessionAt("brief_pending")
			chat:SkipTreeStage()
			assert.is_nil(chat.planningSession.passivePlanApplied)
			assert.are.equal("brief_pending", chat.planningSession.state)
		end)
	end)

	describe("saving and loading a build", function()
		it("restores the buttons and lets the player confirm a pending direction", function()
			chat.planningSession = sessionAt("brief_pending")
			chat:AddMessage("ai", "Review this direction.")
			local xmlText = assert(build:SaveDB("restore"))

			loadBuildFromXML(xmlText, "restore")
			local restored = build.aiChatTab
			assert.are_not.equal(chat, restored)
			assert.are.equal("brief_pending", restored.planningSession.state)
			assert.is_true(restored.controls.confirmBrief.shown)
			assert.is_true(restored.controls.reviseBrief.shown)
			assert.is_false(restored.controls.applyFoundation.shown)

			local restoredBridge = bridgeOf(restored)
			local originalAsk = restoredBridge.Ask
			local requested
			restoredBridge.Ask = function(_, _, userMessage, callback)
				requested = userMessage
				callback(nil, "stopped by the test")
			end
			local ok, err = pcall(function() restored:ConfirmBrief() end)
			restoredBridge.Ask = originalAsk
			assert(ok, err)

			assert.are.equal("brief_confirmed", restored.planningSession.state)
			assert.is_truthy(requested:find("confirmed", 1, true))
		end)

		it("restores a pending foundation and its button", function()
			chat.planningSession = sessionAt("foundation_pending")
			local xmlText = assert(build:SaveDB("restore"))
			loadBuildFromXML(xmlText, "restore")
			local restored = build.aiChatTab
			assert.are.equal("foundation_pending", restored.planningSession.state)
			assert.is_true(restored.controls.applyFoundation.shown)

			restored:ApplyFoundation()
			assert.are.equal("tree", restored.planningSession.state)
		end)

		it("restores a pending clarification with its chips", function()
			local fingerprint = assert(bridge:GetBuildFingerprint(build))
			chat.conversationSession = {
				state = "awaiting_user", constraints = {}, loadedContexts = {}, contextAttempts = 0,
				fingerprint = fingerprint, clarificationFingerprint = fingerprint,
				pendingQuestion = { id = "q", prompt = "Which skill?", options = { "Fireball", "Arc" } },
			}
			local xmlText = assert(build:SaveDB("restore"))
			loadBuildFromXML(xmlText, "restore")
			local restored = build.aiChatTab

			assert.are.equal("awaiting_user", restored.conversationSession.state)
			assert.are.equal("Fireball", restored.optionValues[1])
			assert.are.equal("Arc", restored.optionValues[2])
			assert.is_true(restored.optionButtons[5]:IsShown())

			local restoredBridge = bridgeOf(restored)
			local originalAsk = restoredBridge.Ask
			local requested
			restoredBridge.Ask = function(_, _, userMessage, callback)
				requested = userMessage
				callback(nil, "stopped by the test")
			end
			local ok, err = pcall(function() restored:SendMessage("2") end)
			restoredBridge.Ask = originalAsk
			assert(ok, err)
			assert.are.equal("Arc", requested)
		end)
	end)
end)
