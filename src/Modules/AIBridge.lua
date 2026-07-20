-- Path of Building AI Integration
-- AIBridge: serializes build state, calls LLM API, executes actions
-- Uses PoB's existing lcurl subprocess pattern for async HTTP

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
		state.meta.className = spec.tree.classNameMap and spec.tree.classNameMap[spec.curClassId] or "Unknown"
		if spec.tree.ascendNameMap then
			for name, info in pairs(spec.tree.ascendNameMap) do
				if info.classId == spec.curClassId and info.ascendClassId == spec.curAscendClassId then
					state.meta.ascendancyName = name
					break
				end
			end
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
-- @param userMessage The user's question/instruction
-- @param callback function(response, errMsg) called with AI response or error
function AIBridge:Ask(build, userMessage, callback)
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
Format responses for readability in a game tool UI.]]

	local userPrompt = "Build state (JSON):\n" .. dkjson.encode(state, {indent = false}) ..
		"\n\nPlayer question: " .. userMessage

	-- Request body for OpenAI-compatible API
	local requestBody = dkjson.encode({
		model = AIConfig:GetModel(),
		messages = {
			{ role = "system", content = systemPrompt },
			{ role = "user", content = userPrompt },
		},
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

return AIBridge
