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

	-- Meta: class, ascendancy, level
	local spec = build.spec
	if spec then
		state.meta.classId = spec.curClassId
		state.meta.ascendClassId = spec.curAscendClassId
		state.meta.className = spec.curClassName or "Unknown"
		if spec.curAscendClassId and spec.curAscendClassId ~= 0 then
			state.meta.ascendancyName = spec.curAscendClassName
		end
		state.meta.level = build.characterLevel or 100
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
	end

	-- Skills: socket groups with gems
	local skillsTab = build.skillsTab
	if skillsTab then
		local activeSet = skillsTab.skillSets[skillsTab.activeSkillSetId]
		if activeSet and activeSet.socketGroupList then
			for i, group in ipairs(activeSet.socketGroupList) do
				if group.enabled and group.gemList and #group.gemList > 0 then
					local skillEntry = {
						label = group.label or ("Group " .. i),
						slot = group.slot,
						gems = {},
					}
					for _, gem in ipairs(group.gemList) do
						t_insert(skillEntry.gems, {
							name = gem.name or gem.baseName or "Unknown",
							level = gem.level or 20,
							quality = gem.quality or 0,
							enabled = gem.enabled,
							isSupport = gem.support or false,
						})
					end
					t_insert(state.skills, skillEntry)
				end
			end
		end
	end

	-- Tree: allocated node IDs and keystones
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

	self.pending = true
	self.lastError = nil

	-- Build the prompt
	local systemPrompt = [[You are an expert Path of Exile 1 build advisor integrated into Path of Building.
You have access to the player's full build state (stats, items, skills, tree).
Give specific, actionable advice with numbers. Reference actual stats from the build.
When suggesting changes, explain the expected impact (e.g. "+15% DPS", "+200 life").
Be concise. Use PoB color codes: ^2=green/good, ^1=red/bad, ^7=white, ^8=gray.
If the user asks "how do I improve", focus on the top 3 highest-impact changes.
Format responses for readability in a game tool UI.

When you can make concrete changes to the build, end your message with an actions block
on its own line, exactly like this (valid JSON array, no prose inside):
<actions>
[{"type":"alloc_node","name":"Resolute Technique"},{"type":"set_config","key":"conditionLowLife","value":true}]
</actions>
Supported action types:
- {"type":"alloc_node","name":"<exact passive node name>"} or {"type":"alloc_node","id":<node id>}
- {"type":"dealloc_node","name":"..."} or {"type":"dealloc_node","id":...}
- {"type":"set_config","key":"<config key>","value":<bool or number>}
Only include actions you are confident about. If no concrete action applies, omit the block entirely.]]

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
