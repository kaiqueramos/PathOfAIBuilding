-- Path of Building AI Integration
-- AIBridge: serializes build state, calls LLM API, executes actions
-- Uses PoB's existing lcurl subprocess pattern for async HTTP

local t_insert = table.insert
local dkjson = require "dkjson"
local AIConfig = LoadModule("Modules/AIConfig")

local AIBridge = {
	pending = false,
	lastError = nil,
	lastResponse = nil,
}

--- Serialize the current build state into a compact JSON table
-- @param build The active build object (main.modes["BUILD"])
-- @return table Serialized build state
function AIBridge:SerializeBuild(build)
	if not build then
		return nil, "No active build"
	end

	local state = {
		version = 1,
		meta = {},
		stats = {},
		items = {},
		skills = {},
		tree = {},
	}

	-- Meta: class, ascendancy, level, available choices
	local spec = build.spec
	if spec then
		state.meta.classId = spec.curClassId
		state.meta.ascendClassId = spec.curAscendClassId
		state.meta.className = spec.curClassName or "Unknown"
		if spec.curAscendClassId and spec.curAscendClassId ~= 0 then
			state.meta.ascendancyName = spec.curAscendClassName
		end
		state.meta.level = build.characterLevel or 100

		-- Available classes
		if spec.tree and spec.tree.classes then
			local classes = {}
			for classId, class in pairs(spec.tree.classes) do
				if class.name then
					t_insert(classes, class.name)
				end
			end
			state.meta.availableClasses = classes
		end

		-- Available ascendancies for current class
		if spec.curClass and spec.curClass.classes then
			local ascs = {}
			for ascId, ascClass in pairs(spec.curClass.classes) do
				if ascId ~= 0 and ascClass.name then
					t_insert(ascs, ascClass.name)
				end
			end
			state.meta.availableAscendancies = ascs
		end

		-- Secondary ascendancy (league-specific): only present if available in current league
		if spec.tree.alternate_ascendancies then
			local secAscs = {}
			for ascId, ascClass in pairs(spec.tree.alternate_ascendancies) do
				if ascClass.name then
					t_insert(secAscs, ascClass.name)
				end
			end
			state.meta.availableSecondaryAscendancies = secAscs
			if spec.curSecondaryAscendClassId and spec.curSecondaryAscendClassId ~= 0 then
				state.meta.secondaryAscendancyName = spec.curSecondaryAscendClassName
			end
		end
	end

	-- Passive points: used vs available
	if spec and spec.CountAllocNodes then
		local used, ascUsed = spec:CountAllocNodes()
		local extra = build.calcsTab and build.calcsTab.mainOutput and build.calcsTab.mainOutput.ExtraPoints or 0
		local level = build.characterLevel or 1
		local totalMain = (level - 1) + 23 + extra  -- level points + quest points
		state.tree.pointsUsed = used
		state.tree.pointsTotal = totalMain
		state.tree.pointsAvailable = math.max(totalMain - used, 0)
		state.tree.ascendancyUsed = ascUsed
		state.tree.ascendancyTotal = 8
	end

	-- Stats from mainOutput (the calculated values)
	local output = build.calcsTab and build.calcsTab.mainOutput
	if output then
		local statKeys = {
			"Life", "EnergyShield", "Mana", "Armour", "Evasion",
			"FireResist", "ColdResist", "LightningResist", "ChaosResist",
			"TotalDPS", "CombinedDPS", "AverageHit", "AverageDamage",
			"Speed", "CritChance", "CritMultiplier", "HitChance",
			"TotalDot", "BleedDPS", "IgniteDPS", "PoisonDPS", "ImpaleDPS",
			"Str", "Dex", "Int",
			"LifeRegen", "EnergyShieldRegen", "ManaRegen",
			"LifeLeechGainRate", "ManaLeechGainRate",
			"BlockChance", "SpellBlockChance",
			"EffectiveMovementSpeedMod",
			"TotalDotDPS", "WithImpaleDPS",
		}
		for _, key in ipairs(statKeys) do
			if output[key] then
				state.stats[key] = output[key]
			end
		end
		-- Minion stats if present
		if output.Minion then
			state.stats.Minion = {}
			for _, key in ipairs({"CombinedDPS", "AverageHit", "Life"}) do
				if output.Minion[key] then
					state.stats.Minion[key] = output.Minion[key]
				end
			end
		end
	end

	-- Items: equipped gear per slot
	local itemsTab = build.itemsTab
	if itemsTab and itemsTab.slots then
		for slotName, slot in pairs(itemsTab.slots) do
			if slot.selItemId and slot.selItemId > 0 then
				local item = itemsTab.items[slot.selItemId]
				if item then
					state.items[slotName] = {
						name = item.name or item.baseName or "Unknown",
						rarity = item.rarity,
						base = item.baseName,
						raw = item:BuildRaw(),
					}
				end
			end
		end

		-- Abyssal sockets: expose slot names so AI can equip abyssal jewels
		local abyssalSlots = {}
		for slotName, slot in pairs(itemsTab.slots) do
			if slotName:match("Abyssal Socket") then
				local hasJewel = slot.selItemId and slot.selItemId > 0
				t_insert(abyssalSlots, { slot = slotName, filled = hasJewel or false })
			end
		end
		if #abyssalSlots > 0 then
			state.abyssalSockets = abyssalSlots
		end
	end

	-- Skills: socket groups with gems
	local skillsTab = build.skillsTab
	if skillsTab then
		local activeSet = skillsTab.skillSets[skillsTab.activeSkillSetId]
		if activeSet and activeSet.socketGroupList then
			local mainGroupIdx = build.mainSocketGroup or 1
			for i, group in ipairs(activeSet.socketGroupList) do
				if group.enabled and group.gemList and #group.gemList > 0 then
					local skillEntry = {
						label = group.label or ("Group " .. i),
						slot = group.slot,
						isMainSkill = (i == mainGroupIdx),
						gems = {},
					}
					for _, gem in ipairs(group.gemList) do
						t_insert(skillEntry.gems, {
							name = gem.name or gem.baseName or "Unknown",
							level = gem.level or 20,
							quality = gem.quality or 0,
							enabled = gem.enabled,
							isSupport = gem.support or false,
							skillPart = gem.skillPart,
						})
					end
					t_insert(state.skills, skillEntry)
				end
			end
		end
	end

	-- Tree: allocated nodes + available notables/keystones for allocation
	if spec and spec.allocNodes then
		local nodeIds = {}
		local keystones = {}
		local notables = {}
		for nodeId, node in pairs(spec.allocNodes) do
			t_insert(nodeIds, nodeId)
			if node.type == "Keystone" then
				t_insert(keystones, node.name)
			elseif node.type == "Notable" then
				t_insert(notables, node.name)
			end
		end
		state.tree.nodeCount = #nodeIds
		state.tree.keystones = keystones
		state.tree.notables = notables
		state.tree.allocatedNodes = nodeIds
	end

	-- Available nodes for allocation (notables and keystones only, to keep it concise)
	if spec and spec.nodes then
		local availableNodes = {}
		for nodeId, node in pairs(spec.nodes) do
			if (node.type == "Notable" or node.type == "Keystone") and not node.alloc then
				t_insert(availableNodes, {
					id = nodeId,
					name = node.name,
					type = node.type,
				})
			end
		end
		-- Limit to 50 nodes to avoid overwhelming the LLM
		if #availableNodes > 50 then
			availableNodes = {unpack(availableNodes, 1, 50)}
		end
		state.tree.availableNodes = availableNodes
	end

	-- Jewel sockets: allocated sockets and what's in them
	if spec and spec.allocNodes then
		local jewelSockets = {}
		for nodeId, node in pairs(spec.allocNodes) do
			if node.type == "Socket" then
				local jewelId = spec.jewels and spec.jewels[nodeId]
				local jewel
				if jewelId and jewelId > 0 and itemsTab and itemsTab.items[jewelId] then
					local item = itemsTab.items[jewelId]
					jewel = item.name or item.baseName or "Jewel"
				end
				t_insert(jewelSockets, { nodeId = nodeId, jewel = jewel })
			end
		end
		state.tree.jewelSockets = jewelSockets
	end

	-- Masteries: allocated mastery nodes and their selected effect
	if spec and spec.allocNodes then
		local masteries = {}
		for nodeId, node in pairs(spec.allocNodes) do
			if node.type == "Mastery" then
				local effectId = spec.masterySelections and spec.masterySelections[nodeId]
				local effectText
				if effectId and spec.tree.masteryEffects and spec.tree.masteryEffects[effectId] then
					local eff = spec.tree.masteryEffects[effectId]
					if eff.sd then
						effectText = table.concat(eff.sd, ", ")
					end
				end
				t_insert(masteries, { id = nodeId, name = node.name, effect = effectText })
			end
		end
		state.tree.masteries = masteries
	end


	-- Reference menu: compact list of available gems, uniques, config keys
	-- Gives the AI awareness of what exists without sending full stats
	state.reference = {}

	-- Gem names (all gems in the game data)
	if build.data and build.data.gems then
		local gemNames = {}
		for gemId, gemData in pairs(build.data.gems) do
			if gemData.name and not gemData.unsupported then
				t_insert(gemNames, gemData.name)
			end
		end
		table.sort(gemNames)
		state.reference.gemNames = gemNames
	end

	-- Unique item names by slot type
	if build.data and build.data.uniques then
		local uniqueNames = {}
		for slotType, uniques in pairs(build.data.uniques) do
			local names = {}
			for _, unique in ipairs(uniques) do
				if unique.name then
					t_insert(names, unique.name)
				end
			end
			if #names > 0 then
				table.sort(names)
				uniqueNames[slotType] = names
			end
		end
		state.reference.uniqueNames = uniqueNames
	end

	-- Config keys (valid configuration options)
	if build.configTab and build.configTab.varControls then
		local configKeys = {}
		for var, _ in pairs(build.configTab.varControls) do
			t_insert(configKeys, var)
		end
		table.sort(configKeys)
		state.reference.configKeys = configKeys
	end
	return state
end

--- Send build state to LLM and get response
-- @param build The active build object
-- @param callback function(response, errMsg) called with AI response or error
-- @param history optional array of prior {role, content} messages
function AIBridge:Ask(build, userMessage, callback, history)
	if self.pending then
		callback(nil, "Request already in progress")
		return
	end

	-- Validate config
	local ok, err = AIConfig:Validate()
	if not ok then
		callback(nil, err)
		return
	end

	-- Serialize build
	local state, serErr = self:SerializeBuild(build)
	if not state then
		callback(nil, serErr)
		return
	end

	-- Debug: log reference menu size
	if state.reference then
		local gemCount = state.reference.gemNames and #state.reference.gemNames or 0
		local uniqueCount = 0
		if state.reference.uniqueNames then
			for _, names in pairs(state.reference.uniqueNames) do
				uniqueCount = uniqueCount + #names
			end
		end
		local configCount = state.reference.configKeys and #state.reference.configKeys or 0
		ConPrintf("[AIBridge] Reference menu: %d gems, %d uniques, %d config keys", gemCount, uniqueCount, configCount)
	end

	self.pending = true
	self.lastError = nil

	-- Build the prompt
	local systemPrompt = [[You are an expert Path of Exile 1 build advisor integrated into Path of Building.
You have access to the player's full build state (stats, items, skills, tree) AND you can
DIRECTLY MODIFY the build by emitting actions. You are not just an advisor - you can act.
Give specific, actionable advice with numbers. Reference actual stats from the build.
When suggesting changes, explain the expected impact (e.g. "+15% DPS", "+200 life").
Be concise. Use PoB color codes: ^2=green/good, ^1=red/bad, ^7=white, ^8=gray.
If the user asks "how do I improve", focus on the top 3 highest-impact changes.
Format responses for readability in a game tool UI.

The build state includes tree.pointsAvailable (free passive points), meta.availableClasses,
meta.availableAscendancies, and tree.availableNodes (notables/keystones you can allocate).
Use these to know what is actually possible right now.

When the user asks you to make a change (allocate, level up, change class, add a skill, etc.),
DO IT by emitting actions. Don't tell the user to do it manually - you can do it for them.
End your message with an actions block on its own line, exactly like this (valid JSON array):
<actions>
[{"type":"set_level","value":100},{"type":"alloc_node","name":"Resolute Technique"}]
</actions>

Supported action types:
- {"type":"set_level","value":<1-100>}  -- change character level
- {"type":"set_class","name":"<class name>"}  -- e.g. "Marauder", "Witch", "Scion"
- {"type":"set_ascendancy","name":"<ascendancy>"}  -- e.g. "Inquisitor", "Necromancer"
- {"type":"set_bandit","value":"None|Oak|Kraityn|Alira"}  -- None = kill all
- {"type":"set_pantheon","major":"<god>","minor":"<god>"}  -- e.g. major="TheBrineKing", minor="Gruthkul"
- {"type":"alloc_node","name":"<exact node name>"} or {"type":"alloc_node","id":<node id>}
  (allocating a distant node auto-paths through intermediate nodes; needs enough points)
- {"type":"dealloc_node","name":"..."} or {"type":"dealloc_node","id":...}
- {"type":"add_skill","label":"<group name>","gems":[{"name":"Righteous Fire","level":20,"quality":0},{"name":"Efficacy"}]}
- {"type":"remove_skill","label":"<group name>"} or {"type":"remove_skill","name":"<gem name>"}
- {"type":"equip_item","slot":"<slot>","raw":"<full item text>"}
- {"type":"equip_jewel","raw":"<jewel item text>","nodeId":<socket node id>}  -- equip jewel in tree socket (omit nodeId for first empty socket)
- {"type":"apply_tattoo","name":"<node name>","tattoo":"<tattoo name>"}  -- apply tattoo to a node
- {"type":"remove_tattoo","name":"<node name>"}  -- remove tattoo from a node
- {"type":"set_mastery","name":"<mastery node name>","effect":<1-based index>}  -- select mastery effect by index
- {"type":"set_mastery","name":"<mastery node name>","effectText":"<substring>"}  -- select mastery effect by description text
- {"type":"set_main_skill","label":"<group name>"} or {"type":"set_main_skill","name":"<gem name>"}  -- set which skill DPS is calculated for (IMPORTANT after adding skills)
- {"type":"set_secondary_ascendancy","name":"<name>"}  -- league-specific secondary ascendancy (only if meta.availableSecondaryAscendancies is present)
- {"type":"set_skill_part","label":"<group name>","part":<number>}  -- set skill variant/stages (e.g. Vaal Blade Vortex stages)
- {"type":"set_config","key":"<config key>","value":<bool or number>}

Order matters: if you need more points to allocate a distant node, emit set_level FIRST,
then the alloc_node actions. For cluster jewels, emit equip_jewel FIRST, then alloc_node
for the cluster's internal nodes. After adding skills, emit set_main_skill so DPS is correct.
Abyssal jewels: use equip_item with an abyssal slot name from state.abyssalSockets.
Only include actions you are confident about.]]

	local userPrompt = "Build state (JSON):\n" .. dkjson.encode(state, {indent = false}) ..
		"\n\nPlayer question: " .. userMessage

	-- Build messages array with conversation history
	local messages = {
		{ role = "system", content = systemPrompt },
	}
	
	-- Add conversation history (if provided)
	if history and #history > 0 then
		for _, msg in ipairs(history) do
			t_insert(messages, msg)
		end
	end
	
	-- Add current user message with build state
	t_insert(messages, { role = "user", content = userPrompt })
	
	-- Request body for OpenAI-compatible API
	local requestBody = dkjson.encode({
		model = AIConfig:GetModel(),
		messages = messages,
		max_tokens = 2048,
		temperature = 0.3,
	}, { indent = false })

	local endpoint = AIConfig:GetEndpoint()
	local url = endpoint .. "/chat/completions"

	local header = "Content-Type: application/json\r\n" ..
		"Authorization: Bearer " .. AIConfig:GetAPIKey()

	-- Use PoB's async HTTP (subprocess with lcurl)
	launch:DownloadPage(url, function(response, errMsg)
		self.pending = false

		if errMsg then
			self.lastError = errMsg
			callback(nil, "API request failed: " .. errMsg)
			return
		end

		local body = response.body
		if not body or body == "" then
			self.lastError = "Empty response"
			callback(nil, "Empty response from API")
			return
		end

		local parsed = dkjson.decode(body)
		if not parsed then
			self.lastError = "Invalid JSON response"
			callback(nil, "Invalid JSON response from API")
			return
		end

		if parsed.error then
			self.lastError = parsed.error.message or "Unknown API error"
			callback(nil, "API error: " .. self.lastError)
			return
		end

		if parsed.choices and parsed.choices[1] and parsed.choices[1].message then
			local content = parsed.choices[1].message.content
			self.lastResponse = content
			callback(content, nil)
		else
			self.lastError = "No content in response"
			callback(nil, "No content in API response")
		end
	end, {
		header = header,
		body = requestBody,
	})
end

--- Get a quick summary of the build for display
-- @param build The active build object
-- @return string Human-readable build summary
function AIBridge:GetBuildSummary(build)
	local state = self:SerializeBuild(build)
	if not state then
		return "No active build"
	end

	local parts = {}
	t_insert(parts, state.meta.className or "Unknown")
	if state.meta.ascendancyName then
		t_insert(parts, state.meta.ascendancyName)
	end
	if state.stats.Life then
		t_insert(parts, string.format("%.0f Life", state.stats.Life))
	end
	if state.stats.CombinedDPS and state.stats.CombinedDPS > 0 then
		t_insert(parts, string.format("%.0f DPS", state.stats.CombinedDPS))
	elseif state.stats.TotalDPS and state.stats.TotalDPS > 0 then
		t_insert(parts, string.format("%.0f DPS", state.stats.TotalDPS))
	end
	if state.tree.keystones and #state.tree.keystones > 0 then
		t_insert(parts, "Keystones: " .. table.concat(state.tree.keystones, ", "))
	end

	return table.concat(parts, " | ")
end

--- Parse an <actions> JSON block out of an AI response.
-- @param content The raw AI response text
-- @return string displayText The response with the actions block removed
-- @return table|nil actions Parsed action array, or nil if no valid block
function AIBridge:ParseActions(content)
	if not content then
		return content, nil
	end

	local block = content:match("<actions>%s*(.-)%s*</actions>")
	if not block then
		return content, nil
	end

	local actions = dkjson.decode(block)
	if type(actions) ~= "table" then
		-- Malformed block: show the text without it, no actions
		local displayText = content:gsub("<actions>.-</actions>", ""):gsub("%s+$", "")
		return displayText, nil
	end

	-- Strip the actions block from the display text
	local displayText = content:gsub("<actions>.-</actions>", ""):gsub("%s+$", "")
	return displayText, actions
end
--- Execute a list of actions on the build.
-- Each action is a table: { type = "...", ... }
-- Supported types:
--   { type="equip_item", slot="Weapon 1", raw="Rarity: MAGIC\n...\n..." }
--   { type="alloc_node", id=12345 }  or  { type="alloc_node", name="Resolute Technique" }
--   { type="dealloc_node", id=12345 }
--   { type="set_config", key="buffCritChance", value=true }
-- @param build The active build object
-- @param actions Array of action tables
-- @return table results Array of { ok=bool, msg=string } per action
function AIBridge:ExecuteActions(build, actions)
	local results = {}
	if not build then
		return { { ok = false, msg = "No active build" } }
	end

	for _, action in ipairs(actions) do
		local ok, msg = self:ExecuteAction(build, action)
		t_insert(results, { ok = ok, msg = msg or (ok and "OK" or "Failed") })
	end

	-- Trigger a full rebuild after all actions
	build.buildFlag = true

	return results
end

--- Execute a single action on the build
function AIBridge:ExecuteAction(build, action)
	local actionType = action.type

	if actionType == "equip_item" then
		return self:ActionEquipItem(build, action)
	elseif actionType == "alloc_node" then
		return self:ActionAllocNode(build, action)
	elseif actionType == "dealloc_node" then
		return self:ActionDeallocNode(build, action)
	elseif actionType == "set_config" then
		return self:ActionSetConfig(build, action)
	elseif actionType == "set_level" then
		return self:ActionSetLevel(build, action)
	elseif actionType == "set_class" then
		return self:ActionSetClass(build, action)
	elseif actionType == "set_ascendancy" then
		return self:ActionSetAscendancy(build, action)
	elseif actionType == "set_bandit" then
		return self:ActionSetBandit(build, action)
	elseif actionType == "set_pantheon" then
		return self:ActionSetPantheon(build, action)
	elseif actionType == "add_skill" then
		return self:ActionAddSkill(build, action)
	elseif actionType == "remove_skill" then
		return self:ActionRemoveSkill(build, action)
	elseif actionType == "equip_jewel" then
		return self:ActionEquipJewel(build, action)
	elseif actionType == "apply_tattoo" then
		return self:ActionApplyTattoo(build, action)
	elseif actionType == "remove_tattoo" then
		return self:ActionRemoveTattoo(build, action)
	elseif actionType == "set_mastery" then
		return self:ActionSetMastery(build, action)
	elseif actionType == "set_main_skill" then
		return self:ActionSetMainSkill(build, action)
	elseif actionType == "set_secondary_ascendancy" then
		return self:ActionSetSecondaryAscendancy(build, action)
	elseif actionType == "set_skill_part" then
		return self:ActionSetSkillPart(build, action)
	else
		return false, "Unknown action type: " .. tostring(actionType)
	end
end

--- Equip an item from its raw string into the appropriate slot
function AIBridge:ActionEquipItem(build, action)
	local raw = action.raw
	if not raw or raw == "" then
		return false, "No item raw string provided"
	end

	local itemsTab = build.itemsTab
	if not itemsTab then
		return false, "Items tab not available"
	end

	-- Create the item from raw text
	local item = new("Item", raw)
	if not item or not item.baseName then
		return false, "Invalid item data"
	end

	-- Determine slot: explicit or auto-detect from item type
	local slotName = action.slot or item:GetPrimarySlot()
	if not slotName then
		return false, "Cannot determine slot for item: " .. (item.name or "unknown")
	end

	-- Validate slot exists
	if not itemsTab.slots[slotName] then
		return false, "Invalid slot: " .. slotName
	end

	-- Add and equip
	itemsTab:AddItem(item, true)
	itemsTab.slots[slotName]:SetSelItemId(item.id)
	itemsTab:PopulateSlots()
	itemsTab:AddUndoState()

	return true, "Equipped " .. (item.name or item.baseName) .. " in " .. slotName
end

--- Allocate a passive tree node by ID or name
function AIBridge:ActionAllocNode(build, action)
	local spec = build.spec
	if not spec then
		return false, "No passive tree spec"
	end

	local node = self:FindNode(spec, action)
	if not node then
		return false, "Node not found: " .. tostring(action.name or action.id)
	end

	if node.alloc then
		return true, "Node already allocated: " .. node.name
	end

	if not node.path then
		return false, "Node not reachable: " .. node.name
	end

	spec:AllocNode(node)
	build.treeTab.modFlag = true

	return true, "Allocated: " .. node.name
end

--- Deallocate a passive tree node by ID or name
function AIBridge:ActionDeallocNode(build, action)
	local spec = build.spec
	if not spec then
		return false, "No passive tree spec"
	end

	local node = self:FindNode(spec, action)
	if not node then
		return false, "Node not found: " .. tostring(action.name or action.id)
	end

	if not node.alloc then
		return true, "Node not allocated: " .. node.name
	end

	spec:DeallocNode(node)
	build.treeTab.modFlag = true

	return true, "Deallocated: " .. node.name
end

--- Set a configuration option
function AIBridge:ActionSetConfig(build, action)
	local configTab = build.configTab
	if not configTab then
		return false, "Config tab not available"
	end

	local key = action.key
	local value = action.value
	if not key then
		return false, "No config key provided"
	end

	configTab.input[key] = value
	configTab:BuildModList()
	configTab.modFlag = true

	return true, "Set config " .. key .. " = " .. tostring(value)
end

--- Set the character level (1-100)
function AIBridge:ActionSetLevel(build, action)
	local level = tonumber(action.value)
	if not level then
		return false, "Invalid level value"
	end
	level = math.min(math.max(level, 1), 100)
	build.characterLevel = level
	build.characterLevelAutoMode = false
	if build.controls and build.controls.characterLevel then
		build.controls.characterLevel:SetText(level)
	end
	if build.configTab then
		build.configTab:BuildModList()
	end
	return true, "Set character level to " .. level
end

--- Change the character class by name (e.g. "Marauder", "Witch", "Scion")
function AIBridge:ActionSetClass(build, action)
	local spec = build.spec
	if not spec then
		return false, "No passive tree spec"
	end
	local name = action.name
	if not name then
		return false, "No class name provided"
	end
	local classId = spec.tree.classNameMap[name]
	if not classId then
		return false, "Unknown class: " .. name
	end
	spec:SelectClass(classId)
	build.treeTab.modFlag = true
	build.buildFlag = true
	return true, "Changed class to " .. name
end

--- Change the ascendancy class by name (e.g. "Inquisitor", "Necromancer")
function AIBridge:ActionSetAscendancy(build, action)
	local spec = build.spec
	if not spec then
		return false, "No passive tree spec"
	end
	local name = action.name
	if not name then
		return false, "No ascendancy name provided"
	end
	local curClass = spec.curClass
	if not curClass or not curClass.classes then
		return false, "No class selected"
	end
	local foundId
	for ascId, ascClass in pairs(curClass.classes) do
		if ascId ~= 0 and ascClass.name == name then
			foundId = ascId
			break
		end
	end
	if not foundId then
		return false, "Unknown ascendancy for " .. (spec.curClassName or "class") .. ": " .. name
	end
	spec:SelectAscendClass(foundId)
	build.treeTab.modFlag = true
	build.buildFlag = true
	return true, "Changed ascendancy to " .. name
end

--- Set the bandit choice: "None" (kill all), "Oak", "Kraityn", "Alira"
function AIBridge:ActionSetBandit(build, action)
	local configTab = build.configTab
	if not configTab then
		return false, "Config tab not available"
	end
	local valid = { None = true, Oak = true, Kraityn = true, Alira = true }
	local val = action.value
	if not valid[val] then
		return false, "Invalid bandit choice: " .. tostring(val) .. " (use None/Oak/Kraityn/Alira)"
	end
	configTab.input.bandit = val
	configTab:BuildModList()
	configTab.modFlag = true
	return true, "Set bandit to " .. val
end

--- Set pantheon gods: { major="TheBrineKing", minor="Gruthkul" }
function AIBridge:ActionSetPantheon(build, action)
	local configTab = build.configTab
	if not configTab then
		return false, "Config tab not available"
	end
	local set = {}
	if action.major then
		configTab.input.pantheonMajorGod = action.major
		t_insert(set, "major=" .. action.major)
	end
	if action.minor then
		configTab.input.pantheonMinorGod = action.minor
		t_insert(set, "minor=" .. action.minor)
	end
	if #set == 0 then
		return false, "No pantheon gods provided (use major/minor)"
	end
	configTab:BuildModList()
	configTab.modFlag = true
	return true, "Set pantheon: " .. table.concat(set, ", ")
end

--- Add a skill (socket group) with gems.
-- action = { label="Main", gems={ {name="Righteous Fire", level=20, quality=0}, ... } }
-- or shorthand: action = { label="Main", gems={"Righteous Fire", "Efficacy"} }
function AIBridge:ActionAddSkill(build, action)
	local skillsTab = build.skillsTab
	if not skillsTab then
		return false, "Skills tab not available"
	end
	local skillSet = skillsTab.skillSets[skillsTab.activeSkillSetId]
	if not skillSet then
		return false, "No active skill set"
	end
	local gems = action.gems
	if not gems or #gems == 0 then
		return false, "No gems provided"
	end

	local newGroup = { label = action.label or "", enabled = true, gemList = {} }
	for _, gem in ipairs(gems) do
		local name, level, quality
		if type(gem) == "string" then
			name, level, quality = gem, 20, 0
		else
			name = gem.name
			level = gem.level or 20
			quality = gem.quality or 0
		end
		if name then
			t_insert(newGroup.gemList, {
				nameSpec = name,
				level = level,
				quality = quality,
				enabled = true,
				count = 1,
				enableGlobal1 = true,
				enableGlobal2 = false,
			})
		end
	end

	if #newGroup.gemList == 0 then
		return false, "No valid gems to add"
	end

	t_insert(skillSet.socketGroupList, newGroup)
	skillsTab:ProcessSocketGroup(newGroup)
	skillsTab.modFlag = true
	build.buildFlag = true

	return true, "Added skill group '" .. (action.label or "unnamed") .. "' with " .. #newGroup.gemList .. " gem(s)"
end

--- Remove a skill (socket group) by label or by a gem name it contains
function AIBridge:ActionRemoveSkill(build, action)
	local skillsTab = build.skillsTab
	if not skillsTab then
		return false, "Skills tab not available"
	end
	local skillSet = skillsTab.skillSets[skillsTab.activeSkillSetId]
	if not skillSet then
		return false, "No active skill set"
	end
	local target = (action.label or action.name or ""):lower()
	if target == "" then
		return false, "No skill label or gem name provided"
	end
	for i, group in ipairs(skillSet.socketGroupList) do
		local match = (group.label or ""):lower() == target
		if not match then
			for _, gem in ipairs(group.gemList or {}) do
				if (gem.nameSpec or ""):lower() == target then
					match = true
					break
				end
			end
		end
		if match then
			table.remove(skillSet.socketGroupList, i)
			skillsTab.modFlag = true
			build.buildFlag = true
			return true, "Removed skill group '" .. (group.label or target) .. "'"
		end
	end
	return false, "Skill not found: " .. target
end

--- Equip a jewel into a passive tree socket.
-- action = { raw="<jewel item text>", nodeId=<socket node id> }
-- If nodeId is omitted, uses the first empty allocated socket.
function AIBridge:ActionEquipJewel(build, action)
	local spec = build.spec
	local itemsTab = build.itemsTab
	if not spec or not itemsTab then
		return false, "Build spec or items tab not available"
	end
	local raw = action.raw
	if not raw or raw == "" then
		return false, "No jewel raw string provided"
	end

	-- Create the jewel item
	local item = new("Item", raw)
	if not item or not item.baseName then
		return false, "Invalid jewel item data"
	end
	itemsTab:AddItem(item, true)

	-- Determine target socket node
	local nodeId = action.nodeId
	if not nodeId then
		-- Find first empty allocated socket
		for id, node in pairs(spec.allocNodes) do
			if node.type == "Socket" and (not spec.jewels[id] or spec.jewels[id] == 0) then
				nodeId = id
				break
			end
		end
	end
	if not nodeId then
		return false, "No available jewel socket found (allocate a socket node first)"
	end
	if not spec.nodes[nodeId] or spec.nodes[nodeId].type ~= "Socket" then
		return false, "Node " .. tostring(nodeId) .. " is not a jewel socket"
	end

	spec.jewels[nodeId] = item.id
	spec:BuildClusterJewelGraphs()
	itemsTab:PopulateSlots()
	itemsTab:AddUndoState()
	build.buildFlag = true

	return true, "Equipped jewel '" .. (item.name or item.baseName) .. "' in socket " .. nodeId
end

--- Apply a tattoo to a passive tree node.
-- action = { name="<node name>", tattoo="<tattoo name>" }  or  { id=<node id>, tattoo="..." }
function AIBridge:ActionApplyTattoo(build, action)
	local spec = build.spec
	if not spec then
		return false, "No passive tree spec"
	end
	local node = self:FindNode(spec, action)
	if not node then
		return false, "Node not found: " .. tostring(action.name or action.id)
	end

	local tattooName = action.tattoo
	if not tattooName then
		return false, "No tattoo name provided"
	end

	-- Find the tattoo in the tree's tattoo nodes by display name
	local tattooNodes = spec.tree.tattoo and spec.tree.tattoo.nodes
	if not tattooNodes then
		return false, "No tattoo data available in this tree version"
	end
	local tattooNode
	local target = tattooName:lower()
	for _, tn in pairs(tattooNodes) do
		if tn.dn and tn.dn:lower() == target then
			tattooNode = tn
			break
		end
	end
	if not tattooNode then
		return false, "Tattoo not found: " .. tattooName
	end

	-- Apply the tattoo (mirrors TreeTab:addModifier)
	local newTattooNode = copyTable(tattooNode, true)
	newTattooNode.id = node.id
	spec.hashOverrides[node.id] = newTattooNode
	spec:ReplaceNode(node, newTattooNode)
	spec:BuildAllDependsAndPaths()
	build.treeTab.modFlag = true
	build.buildFlag = true

	return true, "Applied tattoo '" .. tattooName .. "' to node '" .. (node.name or node.id) .. "'"
end

--- Remove a tattoo from a passive tree node.
-- action = { name="<node name>" }  or  { id=<node id> }
function AIBridge:ActionRemoveTattoo(build, action)
	local spec = build.spec
	if not spec then
		return false, "No passive tree spec"
	end
	local node = self:FindNode(spec, action)
	if not node then
		return false, "Node not found: " .. tostring(action.name or action.id)
	end
	if not spec.hashOverrides[node.id] then
		return true, "Node has no tattoo: " .. (node.name or node.id)
	end

	-- Remove the tattoo (mirrors TreeTab:RemoveTattooFromNode)
	spec.tree.nodes[node.id].isTattoo = false
	spec.hashOverrides[node.id] = nil
	spec:ReplaceNode(node, spec.tree.nodes[node.id])
	spec:BuildAllDependsAndPaths()
	build.treeTab.modFlag = true
	build.buildFlag = true

	return true, "Removed tattoo from node '" .. (node.name or node.id) .. "'"
end

--- Select a mastery effect for a mastery node.
-- action = { name="<mastery node name>", effect=<effect index 1-based> }
-- or       { name="<mastery node name>", effectText="<substring of effect description>" }
function AIBridge:ActionSetMastery(build, action)
	local spec = build.spec
	if not spec then
		return false, "No passive tree spec"
	end
	local node = self:FindNode(spec, action)
	if not node then
		return false, "Mastery node not found: " .. tostring(action.name or action.id)
	end
	if node.type ~= "Mastery" then
		return false, "Node is not a mastery: " .. (node.name or node.id)
	end
	if not node.masteryEffects or #node.masteryEffects == 0 then
		return false, "Mastery has no selectable effects: " .. (node.name or node.id)
	end

	-- Resolve the effect
	local effectId
	if action.effect and type(action.effect) == "number" then
		local idx = action.effect
		if idx < 1 or idx > #node.masteryEffects then
			return false, "Effect index out of range (1-" .. #node.masteryEffects .. ")"
		end
		effectId = node.masteryEffects[idx].effect
	elseif action.effectText then
		local target = action.effectText:lower()
		for _, me in ipairs(node.masteryEffects) do
			local eff = spec.tree.masteryEffects[me.effect]
			if eff and eff.sd then
				local desc = table.concat(eff.sd, " "):lower()
				if desc:find(target, 1, true) then
					effectId = me.effect
					break
				end
			end
		end
		if not effectId then
			return false, "No mastery effect matches text: " .. action.effectText
		end
	else
		return false, "Provide 'effect' (index) or 'effectText' (description substring)"
	end

	local effect = spec.tree.masteryEffects[effectId]
	if not effect then
		return false, "Invalid mastery effect id: " .. tostring(effectId)
	end

	-- Apply the effect (mirrors TreeTab:SaveMasteryPopup)
	node.sd = effect.sd
	node.allMasteryOptions = false
	node.reminderText = { "Tip: Right click to select a different effect" }
	spec.tree:ProcessStats(node)
	spec.masterySelections[node.id] = effect.id
	if not node.alloc then
		spec:AllocNode(node)
	end
	spec:AddUndoState()
	build.treeTab.modFlag = true
	build.buildFlag = true

	return true, "Set mastery '" .. (node.name or node.id) .. "' effect to: " .. table.concat(effect.sd, ", ")
end

--- Set the main skill for DPS calculation
-- action = { label="<socket group label>" } or { name="<gem name>" }
function AIBridge:ActionSetMainSkill(build, action)
	local skillsTab = build.skillsTab
	if not skillsTab then
		return false, "Skills tab not available"
	end
	local skillSet = skillsTab.skillSets[skillsTab.activeSkillSetId]
	if not skillSet then
		return false, "No active skill set"
	end

	local target = (action.label or action.name or ""):lower()
	if target == "" then
		return false, "No skill label or gem name provided"
	end

	for i, group in ipairs(skillSet.socketGroupList) do
		local match = (group.label or ""):lower() == target
		if not match then
			for _, gem in ipairs(group.gemList or {}) do
				if (gem.nameSpec or ""):lower() == target then
					match = true
					break
				end
			end
		end
		if match then
			build.mainSocketGroup = i
			if action.skillIndex and group.displaySkillList and group.displaySkillList[action.skillIndex] then
				group.mainActiveSkill = action.skillIndex
			end
			build.buildFlag = true
			return true, "Set main skill to '" .. (group.label or target) .. "'"
		end
	end
	return false, "Skill not found: " .. target
end

--- Set the secondary ascendancy (league-specific, e.g. Warden/Primalist/Warlock)
-- action = { name="<secondary ascendancy name>" }
function AIBridge:ActionSetSecondaryAscendancy(build, action)
	local spec = build.spec
	if not spec then
		return false, "No passive tree spec"
	end

	-- Check if secondary ascendancies are available in this league
	if not spec.tree.alternate_ascendancies then
		return false, "Secondary ascendancies not available in current league"
	end

	local name = action.name
	if not name then
		return false, "No secondary ascendancy name provided"
	end

	-- Find the secondary ascendancy by name
	local foundId
	for ascId, ascClass in pairs(spec.tree.alternate_ascendancies) do
		if ascClass.name and ascClass.name:lower() == name:lower() then
			foundId = ascId
			break
		end
	end

	if not foundId then
		return false, "Unknown secondary ascendancy: " .. name
	end

	spec:SelectSecondaryAscendClass(foundId)
	build.treeTab.modFlag = true
	build.buildFlag = true
	return true, "Set secondary ascendancy to " .. name
end

--- Set the skill part/variant for a gem (e.g. Vaal Blade Vortex stages, Herald of Agony virulence)
-- action = { label="<socket group label>", part=<number> } or { name="<gem name>", part=<number> }
function AIBridge:ActionSetSkillPart(build, action)
	local skillsTab = build.skillsTab
	if not skillsTab then
		return false, "Skills tab not available"
	end
	local skillSet = skillsTab.skillSets[skillsTab.activeSkillSetId]
	if not skillSet then
		return false, "No active skill set"
	end

	local target = (action.label or action.name or ""):lower()
	if target == "" then
		return false, "No skill label or gem name provided"
	end

	local part = tonumber(action.part)
	if not part then
		return false, "No skill part number provided"
	end

	for i, group in ipairs(skillSet.socketGroupList) do
		local match = (group.label or ""):lower() == target
		local gemIndex = nil
		if not match then
			for j, gem in ipairs(group.gemList or {}) do
				if (gem.nameSpec or ""):lower() == target then
					match = true
					gemIndex = j
					break
				end
			end
		else
			gemIndex = 1  -- Default to first gem if matched by label
		end

		if match and gemIndex and group.gemList[gemIndex] then
			group.gemList[gemIndex].skillPart = part
			skillsTab:ProcessSocketGroup(group)
			skillsTab.modFlag = true
			build.buildFlag = true
			return true, "Set skill part to " .. part .. " for '" .. (group.label or target) .. "'"
		end
	end
	return false, "Skill not found: " .. target
end

--- Find a passive node by ID or name
function AIBridge:FindNode(spec, action)
	if action.id then
		return spec.nodes[action.id]
	end

	if action.name then
		local targetName = action.name:lower()
		for _, node in pairs(spec.nodes) do
			if node.name and node.name:lower() == targetName then
				return node
			end
		end
	end

	return nil
end

return AIBridge
