-- Path of Building AI Integration
-- AIBridge: serializes build state, calls LLM API, executes actions
-- Uses PoB's existing lcurl subprocess pattern for async HTTP
-- cspell:ignore aguent aljava alocar anel arma armas arvore ascs baixo bandido bloqueio botas
-- cspell:ignore capacete cinto condicao condicoes configuracao dano defesa defensiva desalocar
-- cspell:ignore distancia equipamento equipamentos esta frasco gema gemas habilidade joia luvas
-- cspell:ignore maestria melhor melhorar melhoro melhoria melhorias nodo nodos passiva proximo
-- cspell:ignore realocar recalc resistencias suporte suportes supressao unico unicos

local t_insert = table.insert
local t_remove = table.remove
local dkjson = require "dkjson"
local sha1 = require "sha1"
local AIConfig = LoadModule("Modules/AIConfig")
local AIBridge = {
	pending = false,
	lastError = nil,
	lastResponse = nil,
	gemShortlistCache = nil,
	gemShortlistFingerprint = nil,
	uniqueShortlistCache = nil,
	uniqueShortlistFingerprint = nil,
	activeBuildFingerprint = nil,
	lastMentionsFingerprint = nil,
}

local HISTORY_CHAR_BUDGET = 12000
AIBridge.HISTORY_CHAR_BUDGET = HISTORY_CHAR_BUDGET

local CONTEXT_SCOPE_ORDER = { "gems", "uniques", "tree", "config" }
local CONTEXT_SCOPE_DESCRIPTIONS = {
	gems = "gem catalog and simulated support-gem DPS upgrades",
	uniques = "unique catalog, item bases, and simulated DPS/EHP upgrades",
	tree = "reachable notable and keystone allocation candidates",
	config = "current calculation settings and available configuration keys",
}

local function getChatCompletionURL(endpoint)
	return endpoint:gsub("/+$", "") .. "/chat/completions"
end

local function parseChatCompletionResponse(response, errMsg)
	if errMsg then
		return nil, "API request failed: " .. tostring(errMsg)
	end

	local body = response and response.body
	if not body or body == "" then
		return nil, "Empty response from API"
	end

	local parsed, _, parseError = dkjson.decode(body)
	if parseError or not parsed then
		return nil, "Invalid JSON response from API"
	end
	if parsed.error then
		local message = type(parsed.error) == "table" and parsed.error.message or tostring(parsed.error)
		return nil, "API error: " .. (message or "Unknown API error")
	end
	if not parsed.choices or not parsed.choices[1] or not parsed.choices[1].message then
		return nil, "No content in API response"
	end

	local content = parsed.choices[1].message.content
	if type(content) ~= "string" or content == "" then
		return nil, "No content in API response"
	end
	return content
end

local function containsAny(text, terms)
	for _, rawTerm in ipairs(terms) do
		local isPrefix = rawTerm:sub(-1) == "*"
		local term = isPrefix and rawTerm:sub(1, -2) or rawTerm
		if term:find(" ", 1, true) then
			if text:find(term, 1, true) then
				return true
			end
		else
			local escaped = term:gsub("([^%w])", "%%%1")
			local pattern = "%f[%w]" .. escaped .. (isPrefix and "" or "%f[%W]")
			if text:find(pattern) then
				return true
			end
		end
	end
	return false
end

--- Classify a question locally so expensive context is built only when useful.
-- Input typed in the PoB UI is already transliterated to ASCII.
-- @param userMessage Player question
-- @return table Context inclusion flags and ordered intent names
function AIBridge:ClassifyQuestion(userMessage)
	local text = (userMessage or ""):lower()
	local general = containsAny(text, {
		"how do i improve", "improve this build", "top 3", "next upgrade", "best upgrade",
		"como melhorar", "como melhoro", "melhorar esta build", "proximo upgrade", "melhor upgrade",
	})
	local gems = containsAny(text, {
		"gem", "gems", "support", "supports", "skill gem", "socket link", "link", "links",
		"gema", "gemas", "suporte", "suportes", "habilidade",
	})
	local items = containsAny(text, {
		"unique", "uniques", "item", "items", "gear", "equipment", "equipamento", "equipamentos",
		"unico", "unicos", "rare", "rares", "weapon", "weapons", "arma", "armas",
		"amulet", "anel", "ring", "belt", "cinto", "helmet", "capacete", "gloves", "luvas",
		"boots", "botas", "shield", "escudo", "quiver", "aljava", "flask", "frasco",
		"jewel", "joia",
	})
	local tree = containsAny(text, {
		"tree", "passive", "node", "nodes", "notable", "keystone", "mastery", "allocate",
		"deallocate", "pathing", "arvore", "passiva", "nodo", "nodos", "maestria",
		"alocar", "realocar", "desalocar",
	})
	local config = containsAny(text, {
		"config", "configuration", "boss config", "boss setting", "set boss", "enemy condition",
		"condition", "conditions", "bandit", "pantheon",
		"configuracao", "condicao", "condicoes", "bandido", "distancia",
	})
	local defense = containsAny(text, {
		"defense", "defences", "defensive", "tank", "ehp", "life", "energy shield", "armour",
		"evasion", "resist*", "suppression", "block", "max hit", "survivability",
		"defesa", "defensiva", "aguent*", "vida", "resistencia", "resistencias", "supressao", "bloqueio",
	})
	local offense = containsAny(text, {
		"dps", "damage", "damage over time", "crit*", "damage low", "dano", "dano baixo",
	})
	local broadImprovement = containsAny(text, {
		"upgrade", "upgrades", "improve", "improvement", "melhorar", "melhoria", "melhorias",
	})
	if broadImprovement and not (gems or items or tree or config) then
		general = true
	end

	local intents = {}
	local function addIntent(enabled, name)
		if enabled then
			t_insert(intents, name)
		end
	end
	addIntent(general, "improve")
	addIntent(gems, "gems")
	addIntent(items, "items")
	addIntent(tree, "tree")
	addIntent(config, "config")
	addIntent(defense, "defense")
	addIntent(offense, "offense")
	if #intents == 0 then
		t_insert(intents, "compact")
	end

	return {
		intents = intents,
		includeGemShortlist = general or gems,
		includeUniqueShortlist = general or items,
		includeTreeCandidates = general or tree,
		includeGemReference = gems and not general,
		includeUniqueReference = items and not general,
		includeItemBases = items and not general,
		includeConfigReference = config,
	}
end

--- Keep the newest contiguous conversation history within a character budget.
-- @param history Array of {role, content}
-- @param budget Optional character budget
-- @return table trimmedHistory, number usedChars, number droppedMessages
function AIBridge:TrimHistory(history, budget)
	budget = budget or HISTORY_CHAR_BUDGET
	if not history or #history == 0 or budget <= 0 then
		return {}, 0, history and #history or 0
	end

	local trimmed = {}
	local used = 0
	for index = #history, 1, -1 do
		local message = history[index]
		local content = type(message.content) == "string" and message.content or ""
		local remaining = budget - used
		if #content <= remaining then
			t_insert(trimmed, 1, { role = message.role, content = content })
			used = used + #content
		elseif #trimmed == 0 then
			local prefix = "[...earlier content truncated...]\n"
			local keep = remaining - #prefix
			if keep > 0 then
				t_insert(trimmed, 1, {
					role = message.role,
					content = prefix .. content:sub(-keep),
				})
				used = budget
			end
			break
		else
			break
		end
	end

	return trimmed, used, #history - #trimmed
end


--- Serialize the current build state into a compact JSON table.
-- Optional reference catalogs and tree candidates are controlled by context.
-- Omitting context preserves the legacy full serialization contract.
-- @param build The active build object (main.modes["BUILD"])
-- @param context Optional inclusion flags from ClassifyQuestion
-- @return table Serialized build state
function AIBridge:SerializeBuild(build, context)
	if not build then
		return nil, "No active build"
	end

	local fullContext = context == nil
	context = context or {}
	local includeTreeCandidates = fullContext or context.includeTreeCandidates
	local includeGemReference = fullContext or context.includeGemReference
	local includeUniqueReference = fullContext or context.includeUniqueReference
	local includeConfigReference = fullContext or context.includeConfigReference
	local includeItemBases = fullContext or context.includeItemBases

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
			"Life", "LifeUnreserved", "EnergyShield", "Mana", "Ward", "Armour", "Evasion",
			"FireResist", "ColdResist", "LightningResist", "ChaosResist",
			"TotalDPS", "CombinedDPS", "AverageHit", "AverageDamage",
			"Speed", "CritChance", "CritMultiplier", "HitChance",
			"TotalDot", "BleedDPS", "IgniteDPS", "PoisonDPS", "ImpaleDPS",
			"Str", "Dex", "Int",
			"LifeRegen", "EnergyShieldRegen", "ManaRegen",
			"LifeLeechGainRate", "ManaLeechGainRate",
			"BlockChance", "SpellBlockChance", "EffectiveBlockChance", "EffectiveSpellBlockChance",
			"AttackDodgeChance", "SpellDodgeChance", "EffectiveSpellSuppressionChance",
			"MeleeAvoidChance", "SpellAvoidChance", "ProjectileAvoidChance",
			"PhysicalDamageReduction", "EffectiveMovementSpeedMod",
			"TotalEHP", "TotalNumberOfHits", "SecondMinimalMaximumHitTaken",
			"PhysicalMaximumHitTaken", "FireMaximumHitTaken", "ColdMaximumHitTaken",
			"LightningMaximumHitTaken", "ChaosMaximumHitTaken",
			"TotalDotDPS", "WithImpaleDPS",
		}
		for _, key in ipairs(statKeys) do
			local value = output[key]
			local isFinite = type(value) ~= "number"
				or (value == value and value ~= math.huge and value ~= -math.huge)
			if value ~= nil and isFinite then
				state.stats[key] = value
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
						local gemName = (gem.gemData and gem.gemData.name) or gem.nameSpec or "Unknown"
						t_insert(skillEntry.gems, {
							name = gemName,
							level = gem.level or 20,
							quality = gem.quality or 0,
							enabled = gem.enabled,
							isSupport = (gem.gemData and gem.gemData.grantedEffect and gem.gemData.grantedEffect.support) or false,
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

	-- Available nodes for allocation (only reachable ones with a valid path)
	-- Excludes anoint-only nodes and disconnected nodes
	if includeTreeCandidates and spec and spec.nodes then
		local availableNodes = {}
		for nodeId, node in pairs(spec.nodes) do
			if (node.type == "Notable" or node.type == "Keystone") and not node.alloc and node.path then
				t_insert(availableNodes, {
					id = nodeId,
					name = node.name,
					type = node.type,
					pathLength = #node.path,
				})
			end
		end
		-- Sort by path length (closest first) and limit to 50
		table.sort(availableNodes, function(a, b) return a.pathLength < b.pathLength end)
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


	-- Reference catalogs are optional; most questions only need the compact core state.
	if includeGemReference or includeUniqueReference or includeConfigReference or includeItemBases then
		state.reference = {}
	end

	-- Gem names (all gems in the game data)
	if includeGemReference and build.data and build.data.gems then
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
	-- data.uniques[type] is an array of raw item strings; name = first line
	if includeUniqueReference and build.data and build.data.uniques then
		local uniqueNames = {}
		for slotType, uniques in pairs(build.data.uniques) do
			local names = {}
			for _, unique in ipairs(uniques) do
				local raw = type(unique) == "string" and unique or (type(unique) == "table" and unique[1])
				if raw then
					local name = raw:match("^([^\n]+)")
					if name and name ~= "" then
						t_insert(names, name)
					end
				end
			end
			if #names > 0 then
				table.sort(names)
				uniqueNames[slotType] = names
			end
		end
		state.reference.uniqueNames = uniqueNames
	end

	-- Current config values and valid configuration keys
	if includeConfigReference and build.configTab then
		state.config = {}
		for key, value in pairs(build.configTab.input or {}) do
			local valueType = type(value)
			local isFinite = valueType ~= "number"
				or (value == value and value ~= math.huge and value ~= -math.huge)
			if (valueType == "boolean" or valueType == "number" or valueType == "string")
				and isFinite then
				state.config[key] = value
			end
		end

		local configKeys = {}
		for var in pairs(build.configTab.varControls or {}) do
			t_insert(configKeys, var)
		end
		table.sort(configKeys)
		state.reference.configKeys = configKeys
	end

	-- Item base names by slot type (for crafting/equipping)
	if includeItemBases and build.data and build.data.itemBaseLists then
		local baseNames = {}
		for slotType, bases in pairs(build.data.itemBaseLists) do
			local names = {}
			for _, base in ipairs(bases) do
				if base.name then
					t_insert(names, base.name)
				end
			end
			if #names > 0 then
				table.sort(names)
				baseNames[slotType] = names
			end
		end
		state.reference.itemBases = baseNames
	end
	return state
end

--- Create a local identity for the exact build input state.
-- SaveDB is PoB's canonical serialization; only its digest is retained.
-- @param build The active build object
-- @return string|nil fingerprint, string|nil error
function AIBridge:GetBuildFingerprint(build)
	if not build or type(build.SaveDB) ~= "function" then
		return nil, "Active build cannot be fingerprinted"
	end

	local ok, snapshot = pcall(build.SaveDB, build, "AI fingerprint")
	if not ok or not snapshot then
		return nil, "Could not snapshot the active build"
	end

	return sha1(tostring(build) .. "\0" .. snapshot)
end

--- Clear every cached value that belongs to a specific build state.
function AIBridge:InvalidateBuildContext()
	self.gemShortlistCache = nil
	self.gemShortlistFingerprint = nil
	self.uniqueShortlistCache = nil
	self.uniqueShortlistFingerprint = nil
	self.lastMentions = nil
	self.lastMentionsFingerprint = nil
	self.activeBuildFingerprint = nil
end

--- Switch the bridge to a build state, invalidating data from the previous one.
-- @param fingerprint Current build fingerprint
-- @return boolean changed Whether the active state changed
function AIBridge:SyncBuildFingerprint(fingerprint)
	if self.activeBuildFingerprint == fingerprint then
		return false
	end

	self:InvalidateBuildContext()
	self.activeBuildFingerprint = fingerprint
	return true
end

--- Extract mentions of known entities from AI response text
-- @param text The AI response text
-- @param state The serialized build state (contains reference menu)
-- @return table Array of {type="gem"|"unique"|"node", name=string}
function AIBridge:ExtractMentions(text, state)
	local mentions = {}
	local seen = {}
	local textLower = text:lower()
	
	-- Check gem names (case-insensitive)
	if state.reference and state.reference.gemNames then
		for _, gemName in ipairs(state.reference.gemNames) do
			if textLower:find(gemName:lower(), 1, true) and not seen[gemName:lower()] then
				t_insert(mentions, { type = "gem", name = gemName })
				seen[gemName:lower()] = true
			end
		end
	end

	-- Shortlists remain mention-aware even when the full reference catalog is omitted.
	if state.gemShortlist then
		for _, result in ipairs(state.gemShortlist) do
			local name = result.name
			if name and textLower:find(name:lower(), 1, true) and not seen[name:lower()] then
				t_insert(mentions, { type = "gem", name = name })
				seen[name:lower()] = true
			end
		end
	end
	
	-- Check unique names (case-insensitive)
	if state.reference and state.reference.uniqueNames then
		for _, names in pairs(state.reference.uniqueNames) do
			for _, uniqueName in ipairs(names) do
				if textLower:find(uniqueName:lower(), 1, true) and not seen[uniqueName:lower()] then
					t_insert(mentions, { type = "unique", name = uniqueName })
					seen[uniqueName:lower()] = true
				end
			end
		end
	end

	if state.uniqueShortlist then
		for _, result in ipairs(state.uniqueShortlist) do
			local name = result.name
			if name and textLower:find(name:lower(), 1, true) and not seen[name:lower()] then
				t_insert(mentions, { type = "unique", name = name })
				seen[name:lower()] = true
			end
		end
	end
	
	-- Check node names (case-insensitive)
	if state.tree and state.tree.availableNodes then
		for _, node in ipairs(state.tree.availableNodes) do
			if textLower:find(node.name:lower(), 1, true) and not seen[node.name:lower()] then
				t_insert(mentions, { type = "node", name = node.name })
				seen[node.name:lower()] = true
			end
		end
	end
	
	return mentions
end
-- @param build The active build object
-- @param mention {type="gem"|"unique"|"node", name=string}
-- @return string Formatted detail text
function AIBridge:LookupDetails(build, mention)
	if mention.type == "gem" then
		return self:LookupGemDetails(build, mention.name)
	elseif mention.type == "unique" then
		return self:LookupUniqueDetails(build, mention.name)
	elseif mention.type == "node" then
		return self:LookupNodeDetails(build, mention.name)
	end
	return ""
end

--- Look up gem details
function AIBridge:LookupGemDetails(build, gemName)
	if not build.data or not build.data.gems then
		return ""
	end
	
	for gemId, gemData in pairs(build.data.gems) do
		if gemData.name and gemData.name:lower() == gemName:lower() then
			local lines = { gemName .. ":" }
			
			-- Type and requirements
			if gemData.grantedEffect then
				if gemData.grantedEffect.support then
					t_insert(lines, "  Support Gem")
				else
					t_insert(lines, "  Active Skill")
				end
			end
			
			if gemData.reqStr and gemData.reqStr > 0 then
				t_insert(lines, "  Requires " .. gemData.reqStr .. " Str")
			end
			if gemData.reqDex and gemData.reqDex > 0 then
				t_insert(lines, "  Requires " .. gemData.reqDex .. " Dex")
			end
			if gemData.reqInt and gemData.reqInt > 0 then
				t_insert(lines, "  Requires " .. gemData.reqInt .. " Int")
			end
			
			-- Tags
			if gemData.tags and #gemData.tags > 0 then
				t_insert(lines, "  Tags: " .. table.concat(gemData.tags, ", "))
			end
			
			return table.concat(lines, "\n")
		end
	end
	
	return ""
end

--- Look up unique item details
function AIBridge:LookupUniqueDetails(build, uniqueName)
	if not build.data or not build.data.uniques then
		return ""
	end
	
	for _, uniques in pairs(build.data.uniques) do
		for _, unique in ipairs(uniques) do
			local raw = type(unique) == "string" and unique or (type(unique) == "table" and unique[1])
			if raw then
				local name = raw:match("^([^\n]+)")
				if name and name:lower() == uniqueName:lower() then
					-- Return first 10 lines of the raw item text
					local lines = {}
					local count = 0
					for line in raw:gmatch("[^\n]+") do
						t_insert(lines, "  " .. line)
						count = count + 1
						if count >= 10 then break end
					end
					return table.concat(lines, "\n")
				end
			end
		end
	end
	
	return ""
end

--- Look up passive node details
function AIBridge:LookupNodeDetails(build, nodeName)
	if not build.spec or not build.spec.nodes then
		return ""
	end
	
	for _, node in pairs(build.spec.nodes) do
		if node.name and node.name:lower() == nodeName:lower() then
			local lines = { nodeName .. " (" .. node.type .. "):" }
			
			-- Node stats (sd = stat descriptions)
			if node.sd and #node.sd > 0 then
				for _, stat in ipairs(node.sd) do
					t_insert(lines, "  " .. stat)
				end
			end
			
			-- Path length if available
			if node.path then
				t_insert(lines, "  Path length: " .. #node.path .. " nodes")
			end
			
			return table.concat(lines, "\n")
		end
	end
	
	return ""
end

--- Compute gem shortlist: simulate each support gem and measure DPS gain
-- @param build The active build object
-- @param limit Max number of gems to return (default 10)
-- @param forceRefresh Ignore a matching cache when true
-- @param fingerprint Optional precomputed build fingerprint
-- @return table Array of {name, dpsGain, dpsGainPct, type} sorted by gain
function AIBridge:ComputeGemShortlist(build, limit, forceRefresh, fingerprint)
	limit = limit or 10
	fingerprint = fingerprint or self:GetBuildFingerprint(build)

	if fingerprint and self.gemShortlistFingerprint ~= fingerprint then
		self.gemShortlistCache = nil
		self.gemShortlistFingerprint = nil
	end

	-- Return cached results only for the exact build state that produced them.
	if self.gemShortlistCache and fingerprint
		and self.gemShortlistFingerprint == fingerprint and not forceRefresh then
		return self.gemShortlistCache
	end
	
	local startTime = GetTime()
	
	local skillsTab = build.skillsTab
	local calcsTab = build.calcsTab
	if not skillsTab or not calcsTab or not build.data or not build.data.gems then
		return {}
	end
	
	-- Find the main socket group
	local mainGroupIdx = build.mainSocketGroup or 1
	local skillSet = skillsTab.skillSets[skillsTab.activeSkillSetId]
	if not skillSet or not skillSet.socketGroupList[mainGroupIdx] then
		return {}
	end
	local mainGroup = skillSet.socketGroupList[mainGroupIdx]
	
	-- Get current DPS
	calcsTab:BuildOutput()
	local baseDPS = calcsTab.mainOutput.CombinedDPS or calcsTab.mainOutput.TotalDPS or 0
	if baseDPS == 0 then
		return {}
	end
	
	-- Collect gems already in the group
	local existingGems = {}
	for _, gem in ipairs(mainGroup.gemList) do
		if gem.gemId then
			existingGems[gem.gemId] = true
		end
	end
	
	-- Test each support gem. Every transient mutation is removed even if PoB throws
	-- while resolving the socket group or recalculating the candidate.
	local results = {}
	local originalGemCount = #mainGroup.gemList
	for gemId, gemData in pairs(build.data.gems) do
		if gemData.grantedEffect and gemData.grantedEffect.support
			and not existingGems[gemId] and not gemData.grantedEffect.legacy then
			local testGem = {
				nameSpec = gemData.name,
				gemId = gemId,
				level = 20,
				quality = 0,
				enabled = true,
				count = 1,
				enableGlobal1 = true,
				enableGlobal2 = false,
			}
			local simulationOk, newDPSOrError = pcall(function()
				t_insert(mainGroup.gemList, testGem)
				skillsTab:ProcessSocketGroup(mainGroup)
				calcsTab:BuildOutput()
				return calcsTab.mainOutput.CombinedDPS or calcsTab.mainOutput.TotalDPS or 0
			end)

			local cleanupOk, cleanupError = pcall(function()
				while #mainGroup.gemList > originalGemCount do
					t_remove(mainGroup.gemList)
				end
				if #mainGroup.gemList ~= originalGemCount then
					error("socket group lost an original gem")
				end
				skillsTab:ProcessSocketGroup(mainGroup)
			end)

			if not simulationOk or not cleanupOk then
				local recalcOk, recalcError = pcall(calcsTab.BuildOutput, calcsTab)
				local failure = not simulationOk and newDPSOrError or cleanupError
				if not recalcOk then
					failure = tostring(failure) .. "; recalculation restore failed: " .. tostring(recalcError)
				end
				error("Gem shortlist simulation failed for " .. tostring(gemData.name)
					.. ": " .. tostring(failure), 0)
			end

			local gain = newDPSOrError - baseDPS
			if gain > 0 then
				t_insert(results, {
					name = gemData.name,
					dpsGain = gain,
					dpsGainPct = (gain / baseDPS) * 100,
					type = "support",
				})
			end
		end
	end

	-- Restore the original calculated output after the final candidate.
	calcsTab:BuildOutput()
	
	-- Sort by gain descending and limit
	table.sort(results, function(a, b) return a.dpsGain > b.dpsGain end)
	if #results > limit then
		results = {unpack(results, 1, limit)}
	end
	
	-- Log timing
	local elapsed = GetTime() - startTime
	local dbg = io.open("ai_debug.log", "a")
	if dbg then
		dbg:write(string.format("[AIBridge] Gem shortlist: %d supports tested, %d with gain, %.1f ms\n", #results, #results, elapsed))
		dbg:close()
	end
	
	-- Cache the result with the build state that produced it.
	self.gemShortlistCache = results
	self.gemShortlistFingerprint = fingerprint
	return results
end

local UNIQUE_RELEVANCE_RULES = {
	{ "to level of all skill gems", 45 },
	{ "to level of all ", 25 },
	{ "to level of socketed", 20 },
	{ "more damage", 18 },
	{ "damage over time multiplier", 18 },
	{ "reservation efficiency", 16 },
	{ "maximum resistance", 16 },
	{ "spell suppression", 16 },
	{ "maximum life", 14 },
	{ "maximum energy shield", 14 },
	{ "critical strike multiplier", 12 },
	{ "chance to block", 10 },
	{ "movement speed", 8 },
	{ "increased damage", 6 },
}

local function addKeywordScore(score, text, keywords, weight)
	for _, keyword in ipairs(keywords) do
		if text:find(keyword, 1, true) then
			return score + weight
		end
	end
	return score
end

local function activeUniqueModText(item)
	local lines = {}
	local modLineGroups = {
		item.implicitModLines,
		item.enchantModLines,
		item.explicitModLines,
		item.scourgeModLines,
		item.crucibleModLines,
	}
	for _, modLines in ipairs(modLineGroups) do
		if modLines then
			for _, modLine in ipairs(modLines) do
				if item:CheckModLineVariant(modLine) then
					t_insert(lines, (modLine.line or ""):lower())
				end
			end
		end
	end
	return table.concat(lines, "\n")
end

local function scoreUniqueCandidate(item, baseOutput, mainSkill)
	local text = activeUniqueModText(item)
	local score = 0
	for _, rule in ipairs(UNIQUE_RELEVANCE_RULES) do
		if text:find(rule[1], 1, true) then
			score = score + rule[2]
		end
	end

	local skillFlags = mainSkill and mainSkill.skillFlags or {}
	local skillTypes = mainSkill and mainSkill.skillTypes or {}
	score = addKeywordScore(score, text, { "{tags:resource}", "life", "energy shield" }, 8)
	score = addKeywordScore(score, text, { "{tags:defences}", "armour", "evasion" }, 5)
	score = addKeywordScore(score, text, { "{tags:resistance}", "resistance" }, 6)
	score = addKeywordScore(score, text, { "{tags:attribute}", "attributes" }, 3)

	if skillFlags.attack then
		score = addKeywordScore(score, text, { "{tags:attack", "attack damage", "attack speed" }, 18)
	end
	if skillFlags.spell then
		score = addKeywordScore(score, text, { "{tags:caster", "spell damage", "cast speed" }, 18)
	end
	if skillFlags.minion then
		score = addKeywordScore(score, text, { "minion" }, 24)
	end
	if skillFlags.melee then
		score = addKeywordScore(score, text, { "melee" }, 10)
	end
	if skillFlags.projectile then
		score = addKeywordScore(score, text, { "projectile" }, 10)
	end
	if skillFlags.totem then
		score = addKeywordScore(score, text, { "totem" }, 12)
	end
	if skillFlags.trap then
		score = addKeywordScore(score, text, { "trap" }, 12)
	end
	if skillFlags.mine then
		score = addKeywordScore(score, text, { "mine" }, 12)
	end

	if SkillType and skillTypes[SkillType.Fire] then
		score = addKeywordScore(score, text, { "fire damage", "burning damage", "fire skill gems" }, 18)
	end
	if SkillType and skillTypes[SkillType.Cold] then
		score = addKeywordScore(score, text, { "cold damage", "cold skill gems" }, 18)
	end
	if SkillType and skillTypes[SkillType.Lightning] then
		score = addKeywordScore(score, text, { "lightning damage", "lightning skill gems" }, 18)
	end
	if SkillType and skillTypes[SkillType.Chaos] then
		score = addKeywordScore(score, text, { "chaos damage", "chaos skill gems", "poison" }, 18)
	end
	if SkillType and skillTypes[SkillType.Physical] then
		score = addKeywordScore(score, text, { "physical damage", "physical skill gems", "bleed" }, 18)
	end
	if SkillType and skillTypes[SkillType.DamageOverTime] then
		score = addKeywordScore(score, text, { "damage over time", "burning damage", "poison", "bleed" }, 18)
	end
	if (baseOutput.CritChance or 0) > 5 then
		score = addKeywordScore(score, text, { "{tags:critical}", "critical strike" }, 8)
	end

	if (baseOutput.FireResist or 0) < 75 then
		score = addKeywordScore(score, text, { "fire resistance" }, 12)
	end
	if (baseOutput.ColdResist or 0) < 75 then
		score = addKeywordScore(score, text, { "cold resistance" }, 12)
	end
	if (baseOutput.LightningResist or 0) < 75 then
		score = addKeywordScore(score, text, { "lightning resistance" }, 12)
	end
	if (baseOutput.ChaosResist or 0) < 0 then
		score = addKeywordScore(score, text, { "chaos resistance" }, 12)
	end

	if skillFlags.attack and item.weaponData and item.weaponData[1] then
		local weapon = item.weaponData[1]
		local weaponDPS = (weapon.PhysicalDPS or 0) + (weapon.ElementalDPS or 0) + (weapon.ChaosDPS or 0)
		score = score + math.min(weaponDPS / 20, 25)
	end
	return score
end

local function preselectUniqueCandidates(itemsTab, uniques, slotName, baseOutput, mainSkill, maxCandidates)
	local candidates = {}
	for _, unique in ipairs(uniques) do
		local raw = type(unique) == "string" and unique or (type(unique) == "table" and unique[1])
		if raw and not raw:lower():find("source: no longer obtainable", 1, true) then
			local item = new("Item", raw)
			if item and item.baseName and itemsTab:IsItemValidForSlot(item, slotName) then
				item:BuildModList()
				t_insert(candidates, {
					item = item,
					score = scoreUniqueCandidate(item, baseOutput, mainSkill),
				})
			end
		end
	end

	table.sort(candidates, function(a, b)
		if a.score == b.score then
			return (a.item.name or a.item.baseName) < (b.item.name or b.item.baseName)
		end
		return a.score > b.score
	end)
	if #candidates <= maxCandidates then
		return candidates, #candidates
	end

	-- Keep mostly high-affinity items, plus a deterministic sample of the tail so
	-- unusual build-enabling uniques are not excluded solely by the heuristic.
	local selected = {}
	local explorationCount = math.min(10, math.floor(maxCandidates / 4))
	local rankedCount = maxCandidates - explorationCount
	for index = 1, rankedCount do
		t_insert(selected, candidates[index])
	end
	local remainingCount = #candidates - rankedCount
	for index = 1, explorationCount do
		local candidateIndex = rankedCount + math.ceil(index * remainingCount / explorationCount)
		t_insert(selected, candidates[candidateIndex])
	end
	return selected, #candidates
end

--- Compute unique item shortlist using PoB's non-mutating item calculator
-- @param build The active build object
-- @param limit Max number of uniques per slot to return (default 3)
-- @param forceRefresh Ignore a matching cache when true
-- @param fingerprint Optional precomputed build fingerprint
-- @return table Array of {slot, name, dpsGain, dpsGainPct, ehpGain, ehpGainPct} sorted by gain
function AIBridge:ComputeUniqueShortlist(build, limit, forceRefresh, fingerprint)
	limit = limit or 3
	fingerprint = fingerprint or self:GetBuildFingerprint(build)

	if fingerprint and self.uniqueShortlistFingerprint ~= fingerprint then
		self.uniqueShortlistCache = nil
		self.uniqueShortlistFingerprint = nil
	end

	if self.uniqueShortlistCache and fingerprint
		and self.uniqueShortlistFingerprint == fingerprint and not forceRefresh then
		return self.uniqueShortlistCache
	end

	local startTime = GetTime()
	local maxTestPerType = 40
	local itemsTab = build.itemsTab
	local calcsTab = build.calcsTab
	if not itemsTab or not calcsTab or not build.data or not build.data.uniques then
		return {}
	end

	-- BuildOutput refreshes GetMiscCalculator(). The returned calculator applies
	-- repItem in an isolated calculation environment without touching itemsTab.
	calcsTab:BuildOutput()
	local calcFunc, baseOutput = calcsTab:GetMiscCalculator()
	if not calcFunc or not baseOutput then
		return {}
	end
	local baseDPS = baseOutput.CombinedDPS or baseOutput.TotalDPS or 0
	local baseEHP = baseOutput.TotalEHP or 0
	if baseDPS == 0 and baseEHP == 0 then
		return {}
	end
	local mainSkill = calcsTab.mainEnv and calcsTab.mainEnv.player and calcsTab.mainEnv.player.mainSkill

	local slotToType = {
		["Weapon 1"] = {"axe", "bow", "claw", "dagger", "mace", "staff", "sword", "wand"},
		["Weapon 2"] = {"shield", "quiver"},
		["Helmet"] = {"helmet"},
		["Body Armour"] = {"body"},
		["Gloves"] = {"gloves"},
		["Boots"] = {"boots"},
		["Amulet"] = {"amulet"},
		["Ring 1"] = {"ring"},
		["Ring 2"] = {"ring"},
		["Belt"] = {"belt"},
	}

	local results = {}
	local candidateCount = 0
	local testedCount = 0
	local itemCountBefore = #itemsTab.itemOrderList
	for slotName in pairs(itemsTab.slots) do
		local uniqueTypes = slotToType[slotName]
		if uniqueTypes then
			for _, uniqueType in ipairs(uniqueTypes) do
				local uniques = build.data.uniques[uniqueType]
				if uniques then
					local candidates, availableCount = preselectUniqueCandidates(
						itemsTab,
						uniques,
						slotName,
						baseOutput,
						mainSkill,
						maxTestPerType
					)
					candidateCount = candidateCount + availableCount
					for _, candidate in ipairs(candidates) do
						testedCount = testedCount + 1
						local output = calcFunc({
							repSlotName = slotName,
							repItem = candidate.item,
						}, false)
						local newDPS = output.CombinedDPS or output.TotalDPS or 0
						local newEHP = output.TotalEHP or 0
						local dpsGain = newDPS - baseDPS
						local dpsGainPct = baseDPS > 0 and (dpsGain / baseDPS) * 100 or 0
						local ehpGain = newEHP - baseEHP
						local ehpGainPct = baseEHP > 0 and (ehpGain / baseEHP) * 100 or 0
						local balancedGainPct = 0
						if dpsGainPct > 0 and ehpGainPct > 0 then
							balancedGainPct = math.min(dpsGainPct, ehpGainPct)
						end

						if dpsGain > 0 or ehpGain > 0 then
							t_insert(results, {
								slot = slotName,
								name = candidate.item.name or candidate.item.baseName,
								dpsGain = dpsGain,
								dpsGainPct = dpsGainPct,
								ehpGain = ehpGain,
								ehpGainPct = ehpGainPct,
								balancedGainPct = balancedGainPct,
							})
						end
					end
				end
			end
		end
	end

	local function positivePct(value)
		return value > 0 and value or 0
	end

	local function generalScore(result)
		return math.max(positivePct(result.dpsGainPct), positivePct(result.ehpGainPct))
	end

	local resultsBySlot = {}
	for _, result in ipairs(results) do
		resultsBySlot[result.slot] = resultsBySlot[result.slot] or {}
		t_insert(resultsBySlot[result.slot], result)
	end

	local limited = {}
	for _, slotResults in pairs(resultsBySlot) do
		local selected = {}
		local selectedCount = 0

		local function selectBest(predicate, score)
			if selectedCount >= limit then
				return
			end
			local best
			local bestScore
			for _, result in ipairs(slotResults) do
				if not selected[result] and predicate(result) then
					local resultScore = score(result)
					if not best or resultScore > bestScore
						or (resultScore == bestScore and result.name < best.name) then
						best = result
						bestScore = resultScore
					end
				end
			end
			if best then
				selected[best] = true
				selectedCount = selectedCount + 1
				t_insert(limited, best)
			end
		end

		-- Preserve all three useful upgrade objectives per slot: balanced, DPS, and EHP.
		selectBest(function(result)
			return result.balancedGainPct > 0
		end, function(result)
			return result.balancedGainPct
		end)
		selectBest(function(result)
			return result.dpsGainPct > 0
		end, function(result)
			return result.dpsGainPct
		end)
		selectBest(function(result)
			return result.ehpGainPct > 0
		end, function(result)
			return result.ehpGainPct
		end)

		table.sort(slotResults, function(a, b)
			local aScore = generalScore(a)
			local bScore = generalScore(b)
			if aScore == bScore then
				return a.name < b.name
			end
			return aScore > bScore
		end)
		for _, result in ipairs(slotResults) do
			if selectedCount >= limit then
				break
			end
			if not selected[result] then
				selected[result] = true
				selectedCount = selectedCount + 1
				t_insert(limited, result)
			end
		end
	end

	table.sort(limited, function(a, b)
		if a.balancedGainPct ~= b.balancedGainPct then
			return a.balancedGainPct > b.balancedGainPct
		end
		local aScore = generalScore(a)
		local bScore = generalScore(b)
		if aScore ~= bScore then
			return aScore > bScore
		end
		if a.slot ~= b.slot then
			return a.slot < b.slot
		end
		return a.name < b.name
	end)

	local elapsed = GetTime() - startTime
	local itemCountAfter = #itemsTab.itemOrderList
	local dbg = io.open("ai_debug.log", "a")
	if dbg then
		dbg:write(string.format(
			"[AIBridge] Unique shortlist: %d results, %d/%d candidates tested, items %+d, %.1f ms\n",
			#limited,
			testedCount,
			candidateCount,
			itemCountAfter - itemCountBefore,
			elapsed
		))
		dbg:close()
	end
	self.uniqueShortlistCache = limited
	self.uniqueShortlistFingerprint = fingerprint
	return limited
end

local function isContextScopeIncluded(context, scope)
	if scope == "gems" then
		return context.includeGemShortlist and context.includeGemReference
	elseif scope == "uniques" then
		return context.includeUniqueShortlist
			and context.includeUniqueReference
			and context.includeItemBases
	elseif scope == "tree" then
		return context.includeTreeCandidates
	elseif scope == "config" then
		return context.includeConfigReference
	end
	return false
end

--- Validate and normalize an AI context scope array.
-- @param scopes Array of scope names
-- @param currentContext Optional current inclusion flags; already-included scopes are removed
-- @return table|nil normalizedScopes
-- @return string|nil error
function AIBridge:ValidateContextScopes(scopes, currentContext)
	if type(scopes) ~= "table" then
		return nil, "Context request must be a JSON array"
	end
	local length = #scopes
	if length == 0 then
		return nil, "Context request cannot be empty"
	end
	if length > #CONTEXT_SCOPE_ORDER then
		return nil, "Context request contains too many scopes"
	end

	local keyCount = 0
	for key in pairs(scopes) do
		if type(key) ~= "number" or key < 1 or key > length or key ~= math.floor(key) then
			return nil, "Context request must be a dense JSON array"
		end
		keyCount = keyCount + 1
	end
	if keyCount ~= length then
		return nil, "Context request must be a dense JSON array"
	end

	local normalized = {}
	local seen = {}
	for index, rawScope in ipairs(scopes) do
		if type(rawScope) ~= "string" or rawScope == "" then
			return nil, "Context scope " .. index .. " must be a non-empty string"
		end
		local scope = rawScope:lower()
		if not CONTEXT_SCOPE_DESCRIPTIONS[scope] then
			return nil, "Unknown context scope: " .. rawScope
		end
		if not seen[scope] then
			seen[scope] = true
			if not currentContext or not isContextScopeIncluded(currentContext, scope) then
				t_insert(normalized, scope)
			end
		end
	end
	if #normalized == 0 then
		return nil, "Requested context is already included"
	end
	return normalized
end

--- Expand deterministic context flags with scopes explicitly requested by the AI.
function AIBridge:ApplyContextScopes(context, scopes)
	for _, scope in ipairs(scopes or {}) do
		if scope == "gems" then
			context.includeGemShortlist = true
			context.includeGemReference = true
		elseif scope == "uniques" then
			context.includeUniqueShortlist = true
			context.includeUniqueReference = true
			context.includeItemBases = true
		elseif scope == "tree" then
			context.includeTreeCandidates = true
		elseif scope == "config" then
			context.includeConfigReference = true
		end
	end
	return context
end

--- Describe included and requestable context without sending the omitted data itself.
function AIBridge:BuildContextManifest(context, escalated)
	local included = {}
	local available = {}
	for _, scope in ipairs(CONTEXT_SCOPE_ORDER) do
		if isContextScopeIncluded(context, scope) then
			t_insert(included, scope)
		else
			t_insert(available, {
				scope = scope,
				provides = CONTEXT_SCOPE_DESCRIPTIONS[scope],
			})
		end
	end
	return included, available, escalated and 0 or 1
end

--- Parse a response that consists only of a structured context request.
-- Valid form: <context_request>["gems","tree"]</context_request>
-- @return string displayText
-- @return table|nil scopes
-- @return string|nil error
function AIBridge:ParseContextRequest(content)
	if type(content) ~= "string" then
		return content, nil, "AI response content must be a string"
	end
	local lower = content:lower()
	local hasMarker = lower:find("<context_request", 1, true)
		or lower:find("</context_request", 1, true)
	if not hasMarker then
		return content, nil, nil
	end

	local hasOpen = content:find("<context_request>", 1, true)
	local hasClose = content:find("</context_request>", 1, true)
	if not hasOpen or not hasClose then
		return content, nil, "Malformed context_request tags"
	end

	local prefix, block, suffix = content:match(
		"^(.-)<context_request>%s*(.-)%s*</context_request>(.-)$"
	)
	if not block then
		return content, nil, "Malformed context_request block"
	end
	if (prefix .. suffix):find("%S") then
		return content, nil, "Context request must not include text or actions"
	end

	local decoded, _, decodeError = dkjson.decode(block, 1, dkjson.null)
	if decodeError or type(decoded) ~= "table" then
		return content, nil, "Invalid context request JSON"
	end
	local scopes, scopeError = self:ValidateContextScopes(decoded)
	if not scopes then
		return content, nil, scopeError
	end
	return "", scopes, nil
end

--- Build only the optional state required by the current question.
-- @return table|nil state, table|string contextOrError
function AIBridge:BuildQuestionState(build, userMessage, fingerprint, requestedScopes, escalated)
	local context = self:ClassifyQuestion(userMessage)
	local normalizedScopes = {}
	if requestedScopes then
		local scopeError
		normalizedScopes, scopeError = self:ValidateContextScopes(requestedScopes, context)
		if not normalizedScopes then
			return nil, scopeError
		end
		self:ApplyContextScopes(context, normalizedScopes)
	end

	local state, err = self:SerializeBuild(build, context)
	if not state then
		return nil, err
	end

	if context.includeGemShortlist then
		state.gemShortlist = self:ComputeGemShortlist(build, 10, false, fingerprint)
	end
	if context.includeUniqueShortlist then
		state.uniqueShortlist = self:ComputeUniqueShortlist(build, 3, false, fingerprint)
	end

	local includedContexts, availableContexts, escalationRemaining =
		self:BuildContextManifest(context, escalated)
	state.context = {
		intents = context.intents,
		gemShortlist = context.includeGemShortlist,
		uniqueShortlist = context.includeUniqueShortlist,
		treeCandidates = context.includeTreeCandidates,
		gemReference = context.includeGemReference,
		uniqueReference = context.includeUniqueReference,
		itemBases = context.includeItemBases,
		configReference = context.includeConfigReference,
		includedContexts = includedContexts,
		availableContexts = availableContexts,
		requestedContexts = normalizedScopes,
		escalated = escalated or false,
		escalationRemaining = escalationRemaining,
	}
	return state, context
end

--- Verify an unsaved OpenAI-compatible configuration with a minimal chat request.
-- @param config table Candidate api_endpoint, api_key, model, and timeout values
-- @param callback function(ok, errMsg) called when the request completes
function AIBridge:TestConnection(config, callback)
	config = config or {}
	local apiKey = config.api_key
	local endpoint = config.api_endpoint
	local model = config.model
	local timeout = tonumber(config.timeout) or AIConfig:GetTimeout()

	if type(apiKey) ~= "string" or #apiKey < 10 then
		callback(false, "Invalid or empty API Key")
		return
	end
	if type(endpoint) ~= "string" or endpoint == "" then
		callback(false, "Endpoint cannot be empty")
		return
	end
	if not endpoint:match("^https://") then
		callback(false, "Endpoint must use HTTPS")
		return
	end
	if type(model) ~= "string" or model == "" then
		callback(false, "Model cannot be empty")
		return
	end
	if timeout < 1 or timeout > 600 then
		callback(false, "Timeout must be between 1 and 600 seconds")
		return
	end

	local requestBody, encodeError = dkjson.encode({
		model = model,
		messages = {
			{ role = "user", content = "Reply with OK." },
		},
		max_tokens = 16,
		temperature = 0,
	}, { indent = false })
	if not requestBody then
		callback(false, "Could not encode connection test: " .. tostring(encodeError))
		return
	end

	local header = "Content-Type: application/json\r\n"
		.. "Authorization: Bearer " .. apiKey
	launch:DownloadPage(getChatCompletionURL(endpoint), function(response, errMsg)
		local _, responseError = parseChatCompletionResponse(response, errMsg)
		if responseError then
			callback(false, responseError)
			return
		end
		callback(true)
	end, {
		header = header,
		body = requestBody,
		timeout = timeout,
	})
end

--- Send build state to LLM and get response
-- @param build The active build object
-- @param callback function(response, errMsg, fingerprint) called with the result
-- @param history optional array of prior {role, content} messages
function AIBridge:Ask(build, userMessage, callback, history)
	if self.pending then
		callback(nil, "Request already in progress")
		return
	end

	local ok, err = AIConfig:Validate()
	if not ok then
		callback(nil, err)
		return
	end

	local requestFingerprint, fingerprintErr = self:GetBuildFingerprint(build)
	if not requestFingerprint then
		callback(nil, fingerprintErr)
		return
	end
	self:SyncBuildFingerprint(requestFingerprint)

	local state, contextOrErr = self:BuildQuestionState(build, userMessage, requestFingerprint)
	if not state then
		callback(nil, contextOrErr)
		return
	end
	local context = contextOrErr

	self.pending = true
	self.lastError = nil

	local systemPrompt = [[You are an expert Path of Exile 1 build advisor integrated into Path of Building.
You have access to the player's current core build state and selected optional context.
You can DIRECTLY MODIFY the build by emitting actions; you are not just an advisor.
Give specific, actionable advice with numbers. Reference actual stats from the build.
When suggesting changes, explain the expected impact (e.g. "+15% DPS", "+200 life").
Be concise. Use PoB color codes: ^2=green/good, ^1=red/bad, ^7=white, ^8=gray.
If the user asks "how do I improve", focus on the top 3 highest-impact changes.
Format responses for readability in a game tool UI.

state.context declares which optional sections are included and lists omitted sections in
availableContexts. Missing data does not mean that no candidates exist.
If omitted context is required for a reliable answer and escalationRemaining is 1, respond ONLY
with one valid JSON array inside this exact block:
<context_request>
["gems","tree"]
</context_request>
Allowed scopes are: "gems", "uniques", "tree", and "config". Request only the smallest set needed.
Never include prose or an <actions> block with a context request. The bridge will obtain the
requested PoB data and repeat the original question automatically. If escalationRemaining is 0,
do not request more context; answer from the available evidence and state any limitation.

The simulated uniqueShortlist is a preselected sample, not an exhaustive proof about every
unique in the catalog. If no entry improves both DPS and EHP, say "none among the tested
candidates", never "no unique exists". balancedGainPct is positive only when both metrics improve.
If the build has no configured main skill or has near-zero DPS/EHP, state that upgrade analysis
is not meaningful yet and ask the player to load/configure the intended build before concluding.

When state.context.treeCandidates is true, tree.availableNodes contains reachable notables and
keystones. Use tree.pointsAvailable and these candidates to know what can be allocated now.

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
- {"type":"equip_jewel","raw":"<jewel item text>","nodeId":<socket node id>}
- {"type":"apply_tattoo","name":"<node name>","tattoo":"<tattoo name>"}
- {"type":"remove_tattoo","name":"<node name>"}
- {"type":"set_mastery","name":"<mastery node name>","effect":<1-based index>}
- {"type":"set_mastery","name":"<mastery node name>","effectText":"<substring>"}
- {"type":"set_main_skill","label":"<group name>"} or {"type":"set_main_skill","name":"<gem name>"}
- {"type":"set_secondary_ascendancy","name":"<name>"}
- {"type":"set_skill_part","label":"<group name>","part":<number>}
- {"type":"set_config","key":"<config key>","value":<bool or number>}

Order matters: if you need more points to allocate a distant node, emit set_level FIRST,
then the alloc_node actions. For cluster jewels, emit equip_jewel FIRST, then alloc_node
for the cluster's internal nodes. After adding skills, emit set_main_skill so DPS is correct.
Abyssal jewels: use equip_item with an abyssal slot name from state.abyssalSockets.
Only include actions you are confident about.]]

	local detailSections = {}
	if self.lastMentions and #self.lastMentions > 0 then
		for _, mention in ipairs(self.lastMentions) do
			local detail = self:LookupDetails(build, mention)
			if detail ~= "" then
				t_insert(detailSections, detail)
			end
		end
	end
	self.lastMentions = nil
	self.lastMentionsFingerprint = nil
	local mentionDetails = #detailSections > 0
		and table.concat(detailSections, "\n\n")
		or nil

	local trimmedHistory, historyChars, historyDropped = self:TrimHistory(history)
	local endpoint = AIConfig:GetEndpoint()
	local url = getChatCompletionURL(endpoint)
	local header = "Content-Type: application/json\r\n"
		.. "Authorization: Bearer " .. AIConfig:GetAPIKey()

	local function fail(message)
		self.pending = false
		self.lastError = message
		callback(nil, message)
	end

	local function complete(content, finalState)
		self.pending = false
		self.lastError = nil
		self.lastResponse = content
		self.lastMentions = self:ExtractMentions(content, finalState)
		self.lastMentionsFingerprint = requestFingerprint
		callback(content, nil, requestFingerprint)
	end

	local function buildRequest(currentState)
		local stateJson, stateEncodeError = dkjson.encode(currentState, { indent = false })
		if not stateJson then
			return nil, nil, "Could not encode build state: " .. tostring(stateEncodeError)
		end
		local userPrompt = "Build state (JSON):\n" .. stateJson
		if mentionDetails then
			userPrompt = userPrompt
				.. "\n\nDetails of items mentioned in previous response:\n"
				.. mentionDetails
		end
		userPrompt = userPrompt .. "\n\nPlayer question: " .. userMessage

		local messages = {
			{ role = "system", content = systemPrompt },
		}
		for _, msg in ipairs(trimmedHistory) do
			t_insert(messages, msg)
		end
		t_insert(messages, { role = "user", content = userPrompt })

		local requestBody, requestEncodeError = dkjson.encode({
			model = AIConfig:GetModel(),
			messages = messages,
			max_tokens = 2048,
			temperature = 0.3,
		}, { indent = false })
		if not requestBody then
			return nil, nil, "Could not encode API request: " .. tostring(requestEncodeError)
		end
		return requestBody, stateJson, nil
	end

	local sendRequest
	sendRequest = function(currentState, currentContext, expansionsUsed)
		local requestBody, stateJson, requestError = buildRequest(currentState)
		if not requestBody then
			fail(requestError)
			return
		end

		local requested = currentState.context and currentState.context.requestedContexts or {}
		local contextLabel = table.concat(currentContext.intents or {}, ",")
		if #requested > 0 then
			contextLabel = contextLabel .. "+" .. table.concat(requested, ",")
		end
		local dbg = io.open("ai_debug.log", "a")
		if dbg then
			dbg:write(string.format(
				"[AIBridge] Context attempt %d: %s, state %d bytes, history %d chars/%d dropped, request %d bytes\n",
				expansionsUsed + 1,
				contextLabel,
				#stateJson,
				historyChars,
				historyDropped,
				#requestBody
			))
			dbg:close()
		end

		launch:DownloadPage(url, function(response, errMsg)
			local content, responseError = parseChatCompletionResponse(response, errMsg)
			if not content then
				fail(responseError)
				return
			end

			local currentFingerprint, currentFingerprintError = self:GetBuildFingerprint(build)
			if not currentFingerprint then
				fail(currentFingerprintError)
				return
			end
			if currentFingerprint ~= requestFingerprint then
				fail("Build changed while the AI was responding")
				return
			end

			local lowerContent = content:lower()
			local hasContextMarker = lowerContent:find("<context_request", 1, true)
				or lowerContent:find("</context_request", 1, true)
			local hasActionMarker = lowerContent:find("<actions", 1, true)
				or lowerContent:find("</actions", 1, true)
			if hasContextMarker and hasActionMarker then
				fail("AI cannot return actions while requesting additional context")
				return
			end

			local _, requestedScopes, contextRequestError = self:ParseContextRequest(content)
			if contextRequestError then
				fail("Invalid AI context request: " .. contextRequestError)
				return
			end
			if requestedScopes then
				if expansionsUsed >= 1 then
					fail("AI requested additional context more than once")
					return
				end

				local missingScopes, scopeError =
					self:ValidateContextScopes(requestedScopes, currentContext)
				if not missingScopes then
					fail("Invalid AI context request: " .. scopeError)
					return
				end

				local expandedState, expandedContextOrError = self:BuildQuestionState(
					build,
					userMessage,
					requestFingerprint,
					missingScopes,
					true
				)
				if not expandedState then
					fail("Could not expand AI context: " .. tostring(expandedContextOrError))
					return
				end

				local expandedFingerprint, expandedFingerprintError =
					self:GetBuildFingerprint(build)
				if not expandedFingerprint then
					fail(expandedFingerprintError)
					return
				end
				if expandedFingerprint ~= requestFingerprint then
					fail("Build changed while preparing additional AI context")
					return
				end

				sendRequest(expandedState, expandedContextOrError, expansionsUsed + 1)
				return
			end

			complete(content, currentState)
		end, {
			header = header,
			body = requestBody,
			timeout = AIConfig:GetTimeout(),
		})
	end

	sendRequest(state, context, 0)
end

--- Get a quick summary of the build for display
-- @param build The active build object
-- @return string Human-readable build summary
function AIBridge:GetBuildSummary(build)
	local state = self:SerializeBuild(build, {})
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
	if state.stats.TotalEHP and state.stats.TotalEHP > 0 then
		t_insert(parts, string.format("%.0f EHP", state.stats.TotalEHP))
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

	local actions = dkjson.decode(block, 1, dkjson.null)
	if type(actions) ~= "table" then
		-- Malformed block: show the text without it, no actions
		local displayText = content:gsub("<actions>.-</actions>", ""):gsub("%s+$", "")
		return displayText, nil
	end

	-- Strip the actions block from the display text
	local displayText = content:gsub("<actions>.-</actions>", ""):gsub("%s+$", "")
	return displayText, actions
end

local SUPPORTED_ACTION_TYPES = {
	equip_item = true,
	alloc_node = true,
	dealloc_node = true,
	set_config = true,
	set_level = true,
	set_class = true,
	set_ascendancy = true,
	set_bandit = true,
	set_pantheon = true,
	add_skill = true,
	remove_skill = true,
	equip_jewel = true,
	apply_tattoo = true,
	remove_tattoo = true,
	set_mastery = true,
	set_main_skill = true,
	set_secondary_ascendancy = true,
	set_skill_part = true,
}

local function isNonEmptyString(value)
	return type(value) == "string" and value ~= ""
end

local function isInteger(value)
	return type(value) == "number" and value == math.floor(value)
end

local function validateDenseArray(value, label)
	if type(value) ~= "table" then
		return false, label .. " must be a dense array"
	end
	local count = 0
	local highestIndex = 0
	for key in pairs(value) do
		if not isInteger(key) or key < 1 then
			return false, label .. " must be a dense array"
		end
		count = count + 1
		highestIndex = math.max(highestIndex, key)
	end
	if count == 0 then
		return false, label .. " must be a non-empty dense array"
	end
	if highestIndex ~= count then
		return false, label .. " must be a dense array without gaps"
	end
	return true
end

local function hasNodeSelector(action)
	return isInteger(action.id) or isNonEmptyString(action.name)
end

--- Validate an action's structure without touching the build.
-- Semantic validation happens against an isolated CompareEntry during preflight.
-- @param action Action table
-- @return boolean valid
-- @return string|nil error
function AIBridge:ValidateActionShape(action)
	if type(action) ~= "table" then
		return false, "Action must be an object"
	end
	local actionType = action.type
	if not isNonEmptyString(actionType) then
		return false, "Action type is required"
	end
	if not SUPPORTED_ACTION_TYPES[actionType] then
		return false, "Unknown action type: " .. actionType
	end

	if actionType == "equip_item" then
		if not isNonEmptyString(action.raw) then
			return false, "equip_item requires a non-empty raw item string"
		end
		if action.slot ~= nil and not isNonEmptyString(action.slot) then
			return false, "equip_item slot must be a non-empty string"
		end
	elseif actionType == "alloc_node" or actionType == "dealloc_node"
		or actionType == "remove_tattoo" then
		if not hasNodeSelector(action) then
			return false, actionType .. " requires a numeric id or node name"
		end
	elseif actionType == "set_config" then
		if not isNonEmptyString(action.key) then
			return false, "set_config requires a key"
		end
		local valueType = type(action.value)
		if valueType ~= "boolean" and valueType ~= "number" then
			return false, "set_config value must be boolean or number"
		end
	elseif actionType == "set_level" then
		local level = tonumber(action.value)
		if not level or level ~= math.floor(level) or level < 1 or level > 100 then
			return false, "set_level value must be an integer between 1 and 100"
		end
	elseif actionType == "set_class" or actionType == "set_ascendancy"
		or actionType == "set_secondary_ascendancy" then
		if not isNonEmptyString(action.name) then
			return false, actionType .. " requires a name"
		end
	elseif actionType == "set_bandit" then
		if not isNonEmptyString(action.value) then
			return false, "set_bandit requires a value"
		end
	elseif actionType == "set_pantheon" then
		if action.major ~= nil and not isNonEmptyString(action.major) then
			return false, "set_pantheon major must be a non-empty string"
		end
		if action.minor ~= nil and not isNonEmptyString(action.minor) then
			return false, "set_pantheon minor must be a non-empty string"
		end
		if action.major == nil and action.minor == nil then
			return false, "set_pantheon requires major or minor"
		end
	elseif actionType == "add_skill" then
		local validGems, gemsError = validateDenseArray(action.gems, "add_skill gems")
		if not validGems then
			return false, gemsError
		end
		if action.label ~= nil and type(action.label) ~= "string" then
			return false, "add_skill label must be a string"
		end
		for index, gem in ipairs(action.gems) do
			if type(gem) == "string" then
				if gem == "" then
					return false, "add_skill gem " .. index .. " is empty"
				end
			elseif type(gem) == "table" then
				if not isNonEmptyString(gem.name) then
					return false, "add_skill gem " .. index .. " requires a name"
				end
				if gem.level ~= nil and not tonumber(gem.level) then
					return false, "add_skill gem " .. index .. " has an invalid level"
				end
				if gem.quality ~= nil and not tonumber(gem.quality) then
					return false, "add_skill gem " .. index .. " has an invalid quality"
				end
			else
				return false, "add_skill gem " .. index .. " must be a string or object"
			end
		end
	elseif actionType == "remove_skill" or actionType == "set_main_skill"
		or actionType == "set_skill_part" then
		if not isNonEmptyString(action.label) and not isNonEmptyString(action.name) then
			return false, actionType .. " requires a label or gem name"
		end
		if actionType == "set_main_skill" and action.skillIndex ~= nil
			and (not isInteger(action.skillIndex) or action.skillIndex < 1) then
			return false, "set_main_skill skillIndex must be a positive integer"
		end
		if actionType == "set_skill_part" then
			local part = tonumber(action.part)
			if not part or part ~= math.floor(part) or part < 1 then
				return false, "set_skill_part requires a positive integer part number"
			end
		end
	elseif actionType == "equip_jewel" then
		if not isNonEmptyString(action.raw) then
			return false, "equip_jewel requires a non-empty raw item string"
		end
		if action.nodeId ~= nil and not isInteger(action.nodeId) then
			return false, "equip_jewel nodeId must be an integer"
		end
	elseif actionType == "apply_tattoo" then
		if not hasNodeSelector(action) then
			return false, "apply_tattoo requires a numeric id or node name"
		end
		if not isNonEmptyString(action.tattoo) then
			return false, "apply_tattoo requires a tattoo name"
		end
	elseif actionType == "set_mastery" then
		if not hasNodeSelector(action) then
			return false, "set_mastery requires a numeric id or node name"
		end
		if action.effect ~= nil and (not isInteger(action.effect) or action.effect < 1) then
			return false, "set_mastery effect must be a positive integer"
		end
		if action.effect == nil and not isNonEmptyString(action.effectText) then
			return false, "set_mastery requires an effect index or effectText"
		end
	end

	return true
end

--- Run PoB's complete synchronous calculation cycle.
-- @param build Build or CompareEntry
-- @return boolean success
-- @return string|nil error
function AIBridge:RebuildBuild(build)
	if not build or not build.calcsTab then
		return false, "Calculation tab not available"
	end
	local ok, err = pcall(function()
		wipeGlobalCache()
		build.outputRevision = (build.outputRevision or 0) + 1
		build.calcsTab:BuildOutput()
		build.buildFlag = false
		if build.RefreshStatList then
			build:RefreshStatList()
		end
	end)
	if not ok then
		return false, tostring(err)
	end
	return true
end

local function finiteMetric(value)
	if type(value) ~= "number" or value ~= value
		or value == math.huge or value == -math.huge then
		return 0
	end
	return value
end

--- Capture the calculated values shown in the action diff.
-- @param build Active build or CompareEntry
-- @return table|nil metrics
-- @return string|nil error
function AIBridge:CaptureBuildMetrics(build)
	local output = build and build.calcsTab and build.calcsTab.mainOutput
	if not output then
		return nil, "Calculated output not available"
	end

	local dps = finiteMetric(output.CombinedDPS)
	if dps <= 0 then
		dps = finiteMetric(output.TotalDPS)
	end
	if dps <= 0 and output.Minion then
		dps = finiteMetric(output.Minion.CombinedDPS or output.Minion.TotalDPS)
	end

	local pointsUsed, ascendancyPointsUsed = 0, 0
	if build.spec and build.spec.CountAllocNodes then
		local countOk, used, ascUsed = pcall(build.spec.CountAllocNodes, build.spec)
		if countOk then
			pointsUsed = tonumber(used) or 0
			ascendancyPointsUsed = tonumber(ascUsed) or 0
		end
	end

	return {
		dps = dps,
		ehp = finiteMetric(output.TotalEHP),
		maxHits = {
			physical = finiteMetric(output.PhysicalMaximumHitTaken),
			fire = finiteMetric(output.FireMaximumHitTaken),
			cold = finiteMetric(output.ColdMaximumHitTaken),
			lightning = finiteMetric(output.LightningMaximumHitTaken),
			chaos = finiteMetric(output.ChaosMaximumHitTaken),
		},
		pointsUsed = pointsUsed,
		ascendancyPointsUsed = ascendancyPointsUsed,
	}
end

local function formatMetricNumber(value)
	local absolute = math.abs(value)
	if absolute >= 1000000000 then
		return string.format("%.2fB", value / 1000000000)
	elseif absolute >= 1000000 then
		return string.format("%.2fM", value / 1000000)
	elseif absolute >= 1000 then
		return string.format("%.1fk", value / 1000)
	end
	return string.format("%.0f", value)
end

local function formatMetricChange(label, beforeValue, afterValue)
	local delta = afterValue - beforeValue
	if math.abs(delta) < 0.000001 then
		return string.format("^7%s: %s -> %s (^8no change^7)",
			label, formatMetricNumber(beforeValue), formatMetricNumber(afterValue))
	end
	local colour = delta > 0 and "^2" or "^1"
	local change
	if math.abs(beforeValue) > 0.000001 then
		change = string.format("%s%+.1f%%^7", colour, delta / math.abs(beforeValue) * 100)
	else
		change = colour .. (delta > 0 and "+" or "") .. formatMetricNumber(delta) .. "^7"
	end
	return string.format("^7%s: %s -> %s (%s)",
		label, formatMetricNumber(beforeValue), formatMetricNumber(afterValue), change)
end

--- Format before/after metrics from real PoB calculations.
-- @return table Array of display lines
function AIBridge:FormatMetricDiff(before, after)
	if not before or not after then
		return {}
	end
	local lines = {
		"^7--- Real PoB diff ---",
		formatMetricChange("DPS", before.dps, after.dps),
		formatMetricChange("EHP", before.ehp, after.ehp),
	}
	local maxHitLabels = {
		{ "Physical max hit", "physical" },
		{ "Fire max hit", "fire" },
		{ "Cold max hit", "cold" },
		{ "Lightning max hit", "lightning" },
		{ "Chaos max hit", "chaos" },
	}
	for _, entry in ipairs(maxHitLabels) do
		local beforeValue = before.maxHits[entry[2]] or 0
		local afterValue = after.maxHits[entry[2]] or 0
		if beforeValue ~= 0 or afterValue ~= 0 then
			t_insert(lines, formatMetricChange(entry[1], beforeValue, afterValue))
		end
	end
	local pointDelta = after.pointsUsed - before.pointsUsed
	t_insert(lines, string.format("^7Passive points used: %d -> %d (%+d)",
		before.pointsUsed, after.pointsUsed, pointDelta))
	local ascDelta = after.ascendancyPointsUsed - before.ascendancyPointsUsed
	t_insert(lines, string.format("^7Ascendancy points used: %d -> %d (%+d)",
		before.ascendancyPointsUsed, after.ascendancyPointsUsed, ascDelta))
	return lines
end

--- Validate a complete action batch against an isolated build clone.
-- Earlier simulated actions may satisfy dependencies of later actions.
-- @param build Active build
-- @param actions Action array
-- @param snapshotXml Canonical SaveDB snapshot
-- @return table preflight report
function AIBridge:PreflightActions(build, actions, snapshotXml)
	local validActions, actionsError = validateDenseArray(actions, "Actions")
	if not validActions then
		return {
			ok = false,
			phase = "validation",
			results = { { ok = false, msg = actionsError } },
		}
	end

	for index, action in ipairs(actions) do
		local valid, validationError = self:ValidateActionShape(action)
		if not valid then
			return {
				ok = false,
				phase = "validation",
				results = { {
					ok = false,
					index = index,
					msg = string.format("Action %d invalid: %s", index, validationError),
				} },
			}
		end
	end

	if not isNonEmptyString(snapshotXml) then
		return {
			ok = false,
			phase = "snapshot",
			results = { { ok = false, msg = "Could not snapshot the current build" } },
		}
	end

	local cloneOk, shadowBuild = pcall(new, "CompareEntry", snapshotXml, "AI action preflight")
	if not cloneOk or not shadowBuild or not shadowBuild.calcsTab or not shadowBuild.spec then
		return {
			ok = false,
			phase = "preflight",
			results = { {
				ok = false,
				msg = "Could not create an isolated build for preflight: " .. tostring(shadowBuild),
			} },
		}
	end

	local simulatedResults = {}
	for index, action in ipairs(actions) do
		local callOk, actionOk, actionMsg = pcall(self.ExecuteAction, self, shadowBuild, action)
		if not callOk then
			return {
				ok = false,
				phase = "preflight",
				results = { {
					ok = false,
					index = index,
					msg = string.format("Action %d crashed during preflight: %s", index, tostring(actionOk)),
				} },
			}
		end
		if not actionOk then
			return {
				ok = false,
				phase = "preflight",
				results = { {
					ok = false,
					index = index,
					msg = string.format("Action %d failed preflight: %s", index, actionMsg or "unknown error"),
				} },
			}
		end
		t_insert(simulatedResults, { ok = true, index = index, msg = actionMsg or "OK" })
	end

	local rebuilt, rebuildError = self:RebuildBuild(shadowBuild)
	if not rebuilt then
		return {
			ok = false,
			phase = "preflight",
			results = { {
				ok = false,
				msg = "Preflight calculation failed: " .. (rebuildError or "unknown error"),
			} },
		}
	end
	local previewMetrics, metricsError = self:CaptureBuildMetrics(shadowBuild)
	if not previewMetrics then
		return {
			ok = false,
			phase = "preflight",
			results = { { ok = false, msg = metricsError or "Could not capture preview metrics" } },
		}
	end

	return {
		ok = true,
		phase = "preflight",
		results = simulatedResults,
		after = previewMetrics,
	}
end

--- Preflight, apply, fully rebuild, and measure an action batch.
-- @param build Active build
-- @param actions Action array
-- @param expectedFingerprint Fingerprint attached to the AI response
-- @return table report
function AIBridge:ApplyActionBatch(build, actions, expectedFingerprint)
	if not build then
		return {
			ok = false,
			applied = false,
			results = { { ok = false, msg = "No active build" } },
		}
	end
	if not expectedFingerprint then
		return {
			ok = false,
			applied = false,
			results = { { ok = false, msg = "Missing build fingerprint; ask again before applying" } },
		}
	end

	local currentFingerprint, fingerprintError = self:GetBuildFingerprint(build)
	if not currentFingerprint then
		return {
			ok = false,
			applied = false,
			results = { {
				ok = false,
				msg = "Could not verify build state: " .. (fingerprintError or "unknown error"),
			} },
		}
	end
	if currentFingerprint ~= expectedFingerprint then
		return {
			ok = false,
			applied = false,
			results = { {
				ok = false,
				msg = "Build changed since this suggestion. Ask again before applying it.",
			} },
		}
	end

	local rebuilt, rebuildError
	if build.buildFlag then
		rebuilt, rebuildError = self:RebuildBuild(build)
		if not rebuilt then
			return {
				ok = false,
				applied = false,
				results = { {
					ok = false,
					msg = "Could not calculate current build: " .. tostring(rebuildError),
				} },
			}
		end
		currentFingerprint, fingerprintError = self:GetBuildFingerprint(build)
		if not currentFingerprint or currentFingerprint ~= expectedFingerprint then
			return {
				ok = false,
				applied = false,
				results = { {
					ok = false,
					msg = "Build changed while preparing the action batch. Ask again before applying it.",
				} },
			}
		end
	end

	local beforeMetrics, metricsError = self:CaptureBuildMetrics(build)
	if not beforeMetrics then
		return {
			ok = false,
			applied = false,
			results = { { ok = false, msg = metricsError or "Could not capture current metrics" } },
		}
	end

	local snapshotOk, snapshotXml = pcall(build.SaveDB, build)
	if not snapshotOk or not snapshotXml then
		return {
			ok = false,
			applied = false,
			results = { {
				ok = false,
				msg = "Could not snapshot the current build: " .. tostring(snapshotXml),
			} },
		}
	end

	local preflight = self:PreflightActions(build, actions, snapshotXml)
	if not preflight.ok then
		preflight.applied = false
		preflight.before = beforeMetrics
		return preflight
	end

	local verifiedFingerprint = self:GetBuildFingerprint(build)
	if verifiedFingerprint ~= expectedFingerprint then
		return {
			ok = false,
			applied = false,
			before = beforeMetrics,
			results = { {
				ok = false,
				msg = "Build changed during preflight. Ask again before applying it.",
			} },
		}
	end

	local results = {}
	local appliedCount = 0
	local failed = false
	for index, action in ipairs(actions) do
		local callOk, actionOk, actionMsg = pcall(self.ExecuteAction, self, build, action)
		if not callOk then
			t_insert(results, {
				ok = false,
				index = index,
				msg = string.format("Action %d failed unexpectedly: %s", index, tostring(actionOk)),
			})
			failed = true
			break
		end
		t_insert(results, {
			ok = actionOk,
			index = index,
			msg = actionMsg or (actionOk and "OK" or "Failed"),
		})
		if not actionOk then
			failed = true
			break
		end
		appliedCount = appliedCount + 1
	end

	build.buildFlag = true
	rebuilt, rebuildError = self:RebuildBuild(build)
	self:InvalidateBuildContext()
	local afterMetrics
	if rebuilt then
		local afterError
		afterMetrics, afterError = self:CaptureBuildMetrics(build)
		if not afterMetrics then
			t_insert(results, {
				ok = false,
				msg = "Could not capture post-apply metrics: " .. tostring(afterError),
			})
			failed = true
		end
	else
		t_insert(results, {
			ok = false,
			msg = "Post-apply calculation failed: " .. (rebuildError or "unknown error"),
		})
		failed = true
	end

	return {
		ok = not failed and rebuilt,
		applied = appliedCount > 0,
		partial = failed and appliedCount > 0,
		appliedCount = appliedCount,
		results = results,
		before = beforeMetrics,
		after = afterMetrics,
		preview = preflight.after,
	}
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
		local callOk, actionOk, actionMsg = pcall(self.ExecuteAction, self, build, action)
		if callOk then
			t_insert(results, {
				ok = actionOk,
				msg = actionMsg or (actionOk and "OK" or "Failed"),
			})
		else
			t_insert(results, { ok = false, msg = "Action failed: " .. tostring(actionOk) })
		end
	end

	build.buildFlag = true
	self:InvalidateBuildContext()
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

	if configTab.input[key] == nil then
		return false, "Unknown config key: " .. key
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
	local pantheons = build.data and build.data.pantheons or {}
	if action.major ~= nil then
		local major = action.major ~= "None" and pantheons[action.major] or nil
		if action.major ~= "None" and (not major or not major.isMajorGod) then
			return false, "Invalid major pantheon: " .. tostring(action.major)
		end
	end
	if action.minor ~= nil then
		local minor = action.minor ~= "None" and pantheons[action.minor] or nil
		if action.minor ~= "None" and (not minor or minor.isMajorGod) then
			return false, "Invalid minor pantheon: " .. tostring(action.minor)
		end
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

	skillsTab:ProcessSocketGroup(newGroup)
	for index, gem in ipairs(newGroup.gemList) do
		if not gem.gemData and not gem.grantedEffect then
			return false, string.format(
				"Gem %d is unknown or unsupported: %s",
				index,
				gem.errMsg or gem.nameSpec or "unknown"
			)
		end
	end
	t_insert(skillSet.socketGroupList, newGroup)
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

	itemsTab:AddItem(item, true)
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
			if action.skillIndex then
				if not group.displaySkillList or not group.displaySkillList[action.skillIndex] then
					return false, "Skill index out of range for '" .. (group.label or target) .. "'"
				end
				group.mainActiveSkill = action.skillIndex
			end
			build.mainSocketGroup = i
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
