-- Path of Building AI Integration
-- AIBridge: serializes build state, calls LLM API, executes actions
-- Uses PoB's existing lcurl subprocess pattern for async HTTP
-- cspell:ignore aguent aljava alocar anel arma armas arvore ascs baixo bandido bloqueio botas
-- cspell:ignore capacete cinto condicao condicoes configuracao dano defesa defensiva desalocar
-- cspell:ignore distancia equipamento equipamentos esta frasco gema gemas habilidade invocacao invocacoes invocador joia luvas
-- cspell:ignore cria faca maestria melhor melhorar melhoro melhoria melhorias minion minions monta montar nivel nodo nodos passiva proximo
-- cspell:ignore realocar recalc reconstruir refaz refazer resetar resistencias summon summoner suporte suportes supressao unico unicos zerar
-- cspell:ignore armadilha armadilhas armadura ataque ataques caos choque congel corpo critico criticos
-- cspell:ignore energia escudo evasao feitico feiticos fisico fogo frio ignicao longo magia magias
-- cspell:ignore mina minas projeteis raio sangramento veneno vida
-- cspell:ignore elementalist jsontype

local t_insert = table.insert
local t_remove = table.remove
local dkjson = require "dkjson"
local sha1 = require "sha1"
local AIConfig = LoadModule("Modules/AIConfig")
local AIConversation = LoadModule("Modules/AIConversation")
local AIPlanning = LoadModule("Modules/AIPlanning")
local AIBridge = {
	pending = false,
	lastError = nil,
	lastResponse = nil,
	gemShortlistCache = nil,
	gemShortlistFingerprint = nil,
	uniqueShortlistCache = nil,
	uniqueShortlistFingerprint = nil,
	treeSimulationCache = nil,
	treeSimulationFingerprint = nil,
	treeSimulationKey = nil,
	activeBuildFingerprint = nil,
	lastMentionsFingerprint = nil,
}

local HISTORY_CHAR_BUDGET = 12000
-- Reasoning models spend most of their output budget thinking, so a reply can need several thousand tokens.
-- A reply cut off by the limit is retried once with a doubled budget, up to the ceiling.
local DEFAULT_MAX_TOKENS = 8192
local MAX_TOKENS_CEILING = 32768
-- A provider that rejects the budget as too large gets it halved, down to this floor.
local MIN_TOKENS_FALLBACK = 2048
AIBridge.HISTORY_CHAR_BUDGET = HISTORY_CHAR_BUDGET

local CONTEXT_SCOPE_ORDER = { "gems", "uniques", "tree", "config" }
local CONTEXT_SCOPE_DESCRIPTIONS = {
	gems = "gem catalog and simulated support-gem DPS upgrades",
	uniques = "unique catalog, item bases, and simulated DPS/EHP upgrades",
	tree = "reachable notable and keystone allocation candidates",
	config = "current calculation settings and available configuration keys",
}

-- Tree recommendations are derived from skill mechanics and the player's stated
-- goal, rather than from a build archetype hard-coded into the planner.
local TREE_GOAL_RULES = {
	{ id = "minion", label = "minion scaling", weight = 140, primary = true,
		queryTerms = { "minion", "minions", "summon", "summoner", "zombie", "zombies", "skeleton", "skeletons", "spectre", "spectres", "invocador", "invocacao", "invocacoes" },
		statTerms = { "minion", "minions" }, skillTypes = { "Minion", "CreatesMinion" } },
	{ id = "totem", label = "totem scaling", weight = 125, primary = true,
		queryTerms = { "totem", "totems" }, statTerms = { "totem", "totems" }, skillTypes = { "SummonsTotem", "Totem" } },
	{ id = "trap", label = "trap scaling", weight = 125, primary = true,
		queryTerms = { "trap", "traps", "armadilha", "armadilhas" }, statTerms = { "trap", "traps" }, skillTypes = { "Trap" } },
	{ id = "mine", label = "mine scaling", weight = 125, primary = true,
		queryTerms = { "mine", "mines", "mina", "minas" }, statTerms = { "mine", "mines" }, skillTypes = { "Mine" } },
	{ id = "attack", label = "attack scaling", weight = 85, primary = true,
		queryTerms = { "attack", "attacks", "ataque", "ataques", "bow", "arco", "melee", "corpo a corpo" },
		statTerms = { "attack damage", "attack speed", "accuracy rating", "melee physical damage", "projectile attack damage" }, skillTypes = { "Attack" } },
	{ id = "spell", label = "spell scaling", weight = 85, primary = true,
		queryTerms = { "spell", "spells", "magia", "magias", "feitico", "feiticos" },
		statTerms = { "spell damage", "cast speed", "spell critical strike" }, skillTypes = { "Spell" } },
	{ id = "projectile", label = "projectile scaling", weight = 55,
		queryTerms = { "projectile", "projectiles", "projeteis" },
		statTerms = { "projectile damage", "projectile speed", "additional projectile" }, skillTypes = { "Projectile" } },
	{ id = "melee", label = "melee scaling", weight = 55,
		queryTerms = { "melee", "corpo a corpo" }, statTerms = { "melee damage", "melee attack speed", "melee physical" }, skillTypes = { "Melee" } },
	{ id = "fire", label = "fire scaling", weight = 75, primary = true,
		queryTerms = { "fire", "fogo", "ignite", "ignition", "ignicao" },
		statTerms = { "fire damage", "fire penetration", "burning damage", "ignite" }, skillTypes = { "Fire" } },
	{ id = "cold", label = "cold scaling", weight = 75, primary = true,
		queryTerms = { "cold", "frio", "freeze", "congel" },
		statTerms = { "cold damage", "cold penetration", "cold damage over time", "freeze" }, skillTypes = { "Cold" } },
	{ id = "lightning", label = "lightning scaling", weight = 75, primary = true,
		queryTerms = { "lightning", "raio", "shock", "choque" },
		statTerms = { "lightning damage", "lightning penetration", "shock effect" }, skillTypes = { "Lightning" } },
	{ id = "chaos", label = "chaos scaling", weight = 75, primary = true,
		queryTerms = { "chaos", "caos", "poison", "veneno" },
		statTerms = { "chaos damage", "chaos damage over time", "chaos resistance" }, skillTypes = { "Chaos" } },
	{ id = "physical", label = "physical scaling", weight = 70, primary = true,
		queryTerms = { "physical", "fisico", "bleed", "bleeding", "sangramento" },
		statTerms = { "physical damage", "physical damage over time", "impale" }, skillTypes = { "Physical" } },
	{ id = "damage_over_time", label = "damage over time scaling", weight = 90, primary = true,
		queryTerms = { "damage over time", "dot", "dano ao longo do tempo" },
		statTerms = { "damage over time", "damage over time multiplier", "dot multiplier" }, skillTypes = { "DamageOverTime" } },
	{ id = "critical", label = "critical scaling", weight = 50,
		queryTerms = { "crit", "critical", "critico", "criticos" },
		statTerms = { "critical strike chance", "critical strike multiplier" }, skillTypes = { "CriticalStrike" } },
	{ id = "aura", label = "aura scaling", weight = 65,
		queryTerms = { "aura", "auras" }, statTerms = { "aura effect", "reservation efficiency", "mana reservation" }, skillTypes = { "Aura" } },
	{ id = "life", label = "life", weight = 35,
		queryTerms = { "life", "vida", "survivability", "defense", "defences", "defesa", "defensiva", "tank", "ehp" },
		statTerms = { "maximum life", "increased maximum life", "life regeneration" } },
	{ id = "energy_shield", label = "energy shield", weight = 45,
		queryTerms = { "energy shield", "es", "escudo de energia" },
		statTerms = { "energy shield", "es recharge", "energy shield recharge" } },
	{ id = "armour", label = "armour", weight = 35,
		queryTerms = { "armour", "armor", "armadura" }, statTerms = { "armour", "armor", "physical damage reduction" } },
	{ id = "evasion", label = "evasion", weight = 35,
		queryTerms = { "evasion", "evasao" }, statTerms = { "evasion", "chance to evade" } },
	{ id = "block", label = "block", weight = 35,
		queryTerms = { "block", "bloqueio" }, statTerms = { "block chance", "spell block" } },
	{ id = "suppression", label = "spell suppression", weight = 35,
		queryTerms = { "suppression", "supressao" }, statTerms = { "spell suppression", "suppression chance" } },
}

local TREE_GOAL_BY_ID = {}
for _, rule in ipairs(TREE_GOAL_RULES) do
	TREE_GOAL_BY_ID[rule.id] = rule
end

local PLANNING_CLASS_RULES = {
	{ className = "Marauder", terms = { "marauder", "juggernaut", "berserker", "chieftain" } },
	{ className = "Ranger", terms = { "ranger", "deadeye", "raider", "pathfinder", "warden" } },
	{ className = "Witch", terms = { "witch", "necromancer", "occultist", "elementalist" } },
	{ className = "Duelist", terms = { "duelist", "slayer", "gladiator", "champion" } },
	{ className = "Templar", terms = { "templar", "inquisitor", "hierophant", "guardian" } },
	{ className = "Shadow", terms = { "shadow", "assassin", "saboteur", "trickster" } },
	{ className = "Scion", terms = { "scion", "ascendant" } },
}

-- These thresholds mirror PoB's progress estimator. They deliberately make
-- unavailable campaign/lab rewards unavailable to AI actions as well.
local QUEST_POINT_STEPS = {
	{ level = 67, points = 23 },
	{ level = 64, points = 20 },
	{ level = 60, points = 18 },
	{ level = 54, points = 15 },
	{ level = 50, points = 12 },
	{ level = 44, points = 9 },
	{ level = 40, points = 7 },
	{ level = 32, points = 6 },
	{ level = 22, points = 4 },
	{ level = 12, points = 2 },
	{ level = 1, points = 0 },
}

local ASCENDANCY_POINT_STEPS = {
	{ level = 75, points = 8 },
	{ level = 68, points = 6 },
	{ level = 55, points = 4 },
	{ level = 33, points = 2 },
	{ level = 1, points = 0 },
}

local function isPassiveOnlyBatch(actions)
	if type(actions) ~= "table" or #actions == 0 then
		return false
	end
	for _, action in ipairs(actions) do
		if type(action) ~= "table" or action.type ~= "alloc_node" then
			return false
		end
	end
	return true
end

local function getChatCompletionURL(endpoint)
	return endpoint:gsub("/+$", "") .. "/chat/completions"
end

-- Merges validated provider options without binding the bridge to a model family.
local function applyRequestOptions(request, options)
	for key, value in pairs(options or {}) do
		request[key] = value
	end
	return request
end

--- The provider's own explanation of a failed request, when it sent one.
local function describeApiError(response)
	local body = response and response.body
	if type(body) ~= "string" or body == "" then
		return nil
	end
	local parsed = dkjson.decode(body)
	if type(parsed) ~= "table" or not parsed.error then
		return nil
	end
	local message = type(parsed.error) == "table" and parsed.error.message or parsed.error
	if type(message) ~= "string" or message == "" then
		return nil
	end
	message = message:gsub("%s+", " ")
	-- A provider can echo the key it rejected. Nothing key-like is kept, because error text ends
	-- up in the chat history, which is saved inside the build file.
	message = message:gsub("[%w_%-]+", function(word)
		return #word >= 24 and "[redacted]" or nil
	end)
	return (message:sub(1, 200))
end

--- Whether a failed response says that the requested output token limit is not allowed.
local function apiRejectedTokenLimit(response)
	local detail = describeApiError(response)
	if not detail then
		return false
	end
	detail = detail:lower()
	return detail:find("max_tokens", 1, true) ~= nil
		or detail:find("max_completion_tokens", 1, true) ~= nil
		or detail:find("output tokens", 1, true) ~= nil
end

local function parseChatCompletionResponse(response, errMsg)
	if errMsg then
		local detail = describeApiError(response)
		return nil, "API request failed: " .. tostring(errMsg) .. (detail and (" - " .. detail) or "")
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

	local finishReason = parsed.choices[1].finish_reason
	local content = parsed.choices[1].message.content
	if type(content) ~= "string" or content == "" then
		return nil, "No content in API response", finishReason
	end
	return content, nil, finishReason
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

-- Resolves a harmless singular/plural variation only when it maps to one canonical gem.
-- Model output must still use the catalog name whenever it is available.
local function resolveGemAlias(build, name)
	if type(name) ~= "string" or not build or not build.data or type(build.data.gems) ~= "table" then
		return name
	end
	local normalized = name:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
	if normalized == "" then
		return name
	end
	local singular = normalized:sub(-1) == "s" and normalized:sub(1, -2) or normalized
	local candidate
	for _, gemData in pairs(build.data.gems) do
		local canonical = gemData.name
		if canonical and not gemData.unsupported then
			local canonicalNormalized = canonical:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
			if canonicalNormalized == normalized then
				return canonical
			end
			local canonicalSingular = canonicalNormalized:sub(-1) == "s"
				and canonicalNormalized:sub(1, -2)
				or canonicalNormalized
			if canonicalSingular == singular then
				if candidate then
					return name
				end
				candidate = canonical
			end
		end
	end
	return candidate or name
end

local function findGemDataByName(build, name)
	if type(name) ~= "string" or not build or not build.data or type(build.data.gems) ~= "table" then
		return nil, nil
	end
	local canonical = resolveGemAlias(build, name)
	local target = canonical:lower():gsub("^%s+", ""):gsub("%s+$", "")
	for gemId, gemData in pairs(build.data.gems) do
		if gemData.name and not gemData.unsupported and gemData.name:lower() == target then
			return gemData, gemId
		end
	end
	return nil, nil
end

--- Return the highest legal gem level for a given character level, or nil if the gem's
--- level 1 requirement exceeds the character level.
function AIBridge:GetMaxLegalGemLevel(gemData, characterLevel)
	local ge = gemData and gemData.grantedEffect
	local levels = ge and ge.levels
	if type(levels) ~= "table" then
		return 1, 1
	end
	local charLv = math.max(1, math.min(math.floor(tonumber(characterLevel) or 1), 100))
	local minReqLv = levels[1] and tonumber(levels[1].levelRequirement) or 1
	if minReqLv > charLv then
		return nil, minReqLv
	end
	local bestLevel = 1
	local maxNormalLevel = tonumber(gemData.naturalMaxLevel) or 20
	for lvl = 1, maxNormalLevel do
		local lvlData = levels[lvl]
		if lvlData then
			local reqLv = tonumber(lvlData.levelRequirement) or 1
			if reqLv <= charLv then
				bestLevel = lvl
			else
				break
			end
		end
	end
	return bestLevel, minReqLv
end

local function finiteOrZero(value)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return value
end

--- Damage figure used to compare skill setups: hit and DoT first, then minion damage.
local function readSkillDps(output)
	if type(output) ~= "table" then
		return 0
	end
	local dps = finiteOrZero(output.CombinedDPS)
	if dps <= 0 then
		dps = finiteOrZero(output.TotalDPS)
	end
	if dps <= 0 and type(output.Minion) == "table" then
		dps = finiteOrZero(output.Minion.CombinedDPS or output.Minion.TotalDPS)
	end
	return dps
end

--- Count the gems in enabled socket groups. Every gem needs one socket.
local function countSocketsUsed(skillSet)
	local used = 0
	for _, group in ipairs(skillSet and skillSet.socketGroupList or { }) do
		if group.enabled and type(group.gemList) == "table" then
			for _, gem in ipairs(group.gemList) do
				if gem.enabled ~= false then
					used = used + 1
				end
			end
		end
	end
	return used
end

--- PoB gives an item without a Sockets line the base's maximum sockets, all linked. Those are
-- placeholders, so only items that spell out their sockets count as real gear.
local function itemDeclaresSockets(item)
	return type(item.raw) == "string" and ("\n" .. item.raw):find("\nSockets:", 1, true) ~= nil
end

--- Count sockets on equipped gear. Jewel, abyssal and swap weapon sockets are excluded.
-- @return number total sockets, number largest linked group
local function countEquippedSockets(build)
	local itemsTab = build and build.itemsTab
	if not itemsTab or not itemsTab.slots or not itemsTab.items then
		return 0, 0
	end
	local total, largestLink = 0, 0
	for slotName, slot in pairs(itemsTab.slots) do
		local item = slot.selItemId and slot.selItemId > 0 and itemsTab.items[slot.selItemId]
		if item and item.sockets and itemDeclaresSockets(item) and not slot.nodeId
			and not tostring(slotName):find("Swap", 1, true) then
			local linked = { }
			for _, socket in ipairs(item.sockets) do
				if socket.color ~= "A" then
					total = total + 1
					linked[socket.group or 0] = (linked[socket.group or 0] or 0) + 1
				end
			end
			for _, size in pairs(linked) do
				largestLink = math.max(largestLink, size)
			end
		end
	end
	return total, largestLink
end

--- Names of the skills whose mana or life cost exceeds the unreserved pool, as flagged by
-- PoB's own calculation. Rage and energy shield costs depend on gear and charges, so they
-- are not treated as planning errors.
local function collectUnaffordableSkills(output)
	local names = { }
	if type(output) == "table" then
		for _, key in ipairs({ "ManaCostWarningList", "LifeCostWarningList" }) do
			if type(output[key]) == "table" then
				for _, name in ipairs(output[key]) do
					names[name] = true
				end
			end
		end
	end
	return names
end

--- Return the socket and link limits a player can realistically use. The campaign figures
-- for the level are a floor, and equipped gear raises them when it offers more.
function AIBridge:GetSocketBudget(build, characterLevel)
	local charLv = math.max(1, math.min(math.floor(tonumber(characterLevel) or 1), 100))
	local maxMainLinks
	if charLv <= 12 then
		maxMainLinks = 3
	elseif charLv <= 38 then
		maxMainLinks = 4
	elseif charLv <= 67 then
		maxMainLinks = 5
	else
		maxMainLinks = 6
	end
	local maxTotalSockets = charLv <= 12 and 9 or (charLv <= 28 and 14 or (charLv <= 50 and 18 or 24))
	local source = "level"
	local gearSockets, gearLinks = countEquippedSockets(build)
	if gearSockets > maxTotalSockets or gearLinks > maxMainLinks then
		maxTotalSockets = math.max(maxTotalSockets, gearSockets)
		maxMainLinks = math.max(maxMainLinks, gearLinks)
		source = "gear"
	end
	return {
		maxMainLinks = maxMainLinks,
		maxTotalSockets = maxTotalSockets,
		source = source,
		gearSockets = gearSockets,
		-- The total is a hard limit only while no gear is equipped. With gear the player
		-- owns real sockets, so the total stays advisory and the link size stays binding.
		enforceTotal = gearSockets == 0,
	}
end

-- A support is skipped when it would push one cast above this share of the unreserved mana.
local MAX_COST_SHARE_OF_MANA = 0.30
-- Supports re-tested after the first pick, which keeps the number of recalculations bounded.
local SUPPORT_REFINEMENT_POOL = 8
-- Skills used for their effect or utility. Damage supports on them waste sockets, except when
-- the skill is the build's first group, which is its main skill (Leap Slam, Shield Charge, ...).
local SUPPORTLESS_SKILL_TYPES = { "Herald", "Warcry", "Movement", "Guard", "AppliesCurse" }

local function hasSupportlessRole(grantedEffect)
	local skillTypes = grantedEffect and grantedEffect.skillTypes
	if type(skillTypes) ~= "table" or not SkillType then
		return false
	end
	for _, typeName in ipairs(SUPPORTLESS_SKILL_TYPES) do
		local typeId = SkillType[typeName]
		if typeId and skillTypes[typeId] then
			return true
		end
	end
	return false
end

-- Supports that change how a skill is placed or triggered rather than how it performs.
local EXCLUDED_SUPPORT_FLAGS = { trap = true, mine = true, totem = true, ballista = true }

--- True for supports a player can realistically buy or find at any level and that change
-- the performance of the skill, not how it is triggered, placed or unlocked.
local function isSelectableSupport(gemData)
	local grantedEffect = gemData and gemData.grantedEffect
	if not grantedEffect or not gemData.name or not grantedEffect.support
		or grantedEffect.legacy or gemData.unsupported then
		return false
	end
	if grantedEffect.isTrigger or grantedEffect.plusVersionOf or grantedEffect.cannotBeSupported then
		return false
	end
	local tags = gemData.tags
	if type(tags) == "table" and (tags.exceptional or tags.awakened or tags.vaal) then
		return false
	end
	for flag in pairs(grantedEffect.addFlags or { }) do
		if EXCLUDED_SUPPORT_FLAGS[flag] then
			return false
		end
	end
	return true
end

--- Whether one cast stays payable and sustainable. A cost that was already above the share
-- before the candidate is never allowed to grow.
local function skillIsAffordable(output, baseline)
	if output.ManaHasCost then
		local cost = finiteOrZero(output.ManaCost)
		local pool = math.max(finiteOrZero(output.ManaUnreserved), 0)
		if cost > pool or cost > math.max(pool * MAX_COST_SHARE_OF_MANA, baseline.manaCost) then
			return false
		end
	end
	if output.LifeHasCost then
		local cost = finiteOrZero(output.LifeCost)
		local pool = math.max(finiteOrZero(output.LifeUnreserved), 0)
		if cost >= pool and cost > baseline.lifeCost then
			return false
		end
	end
	return true
end

--- Run fn with `group` appended to the active skill set and selected as the main skill.
-- The group list, the main skill and the calculated output are restored even when fn throws.
function AIBridge:WithTemporaryMainGroup(build, group, fn)
	local skillsTab = build and build.skillsTab
	local skillSet = skillsTab and skillsTab.skillSets and skillsTab.skillSets[skillsTab.activeSkillSetId]
	if not skillSet or type(skillSet.socketGroupList) ~= "table" then
		error("No active skill set", 0)
	end
	local list = skillSet.socketGroupList
	local originalCount = #list
	local originalMain = build.mainSocketGroup
	t_insert(list, group)
	build.mainSocketGroup = #list
	local ok, result = pcall(fn)
	while #list > originalCount do
		t_remove(list)
	end
	build.mainSocketGroup = originalMain
	local rebuilt, rebuildError = self:RebuildBuild(build)
	if not ok then
		error(result, 0)
	end
	if not rebuilt then
		error("Could not restore the calculated build: " .. tostring(rebuildError), 0)
	end
	return result
end

--- True for an attack that deals no damage only because no weapon is equipped.
-- @return boolean, table|nil the granted effect of the main skill
local function attackLacksWeapon(build)
	local slot = build and build.itemsTab and build.itemsTab.slots and build.itemsTab.slots["Weapon 1"]
	if not slot or (slot.selItemId or 0) > 0 then
		return false, nil
	end
	local calcsTab = build.calcsTab
	local skill = calcsTab and calcsTab.mainEnv and calcsTab.mainEnv.player and calcsTab.mainEnv.player.mainSkill
	local effect = skill and skill.activeEffect and skill.activeEffect.grantedEffect
	if not effect or not effect.weaponTypes or readSkillDps(calcsTab.mainOutput) > 0 then
		return false, nil
	end
	return true, effect
end

-- Plain weapon types in the order a new character is most likely to use them.
local WEAPON_TYPE_PREFERENCE = {
	"Bow", "Wand", "One Handed Sword", "One Handed Axe", "One Handed Mace", "Claw", "Dagger",
	"Rune Dagger", "Sceptre", "Staff", "Warstaff", "Two Handed Sword", "Two Handed Axe", "Two Handed Mace",
}
-- Returned by a selection pass that found no damage to compare, so it can be retried with a weapon.
local NEEDS_WEAPON = { }

--- Name of a plain weapon base the character could use at this level, for attack skills that
-- deal no damage until a matching weapon is equipped.
local function pickPlanningWeaponBase(build, grantedEffect, characterLevel)
	local allowed = grantedEffect and grantedEffect.weaponTypes
	if type(allowed) ~= "table" or not build.data or not build.data.itemBases then
		return nil
	end
	local wantedType
	for _, typeName in ipairs(WEAPON_TYPE_PREFERENCE) do
		if allowed[typeName] then
			wantedType = typeName
			break
		end
	end
	if not wantedType then
		return nil
	end
	local bestName, bestLevel
	for name, base in pairs(build.data.itemBases) do
		if base.type == wantedType and base.weapon and not base.hidden then
			local requiredLevel = base.req and tonumber(base.req.level) or 0
			if requiredLevel <= characterLevel and (not bestLevel or requiredLevel > bestLevel
				or (requiredLevel == bestLevel and name < bestName)) then
				bestName, bestLevel = name, requiredLevel
			end
		end
	end
	return bestName
end

--- Run fn with a plain weapon of the given base in the main weapon slot. The slot, the item
-- list and the calculated output are restored even when fn throws.
function AIBridge:WithTemporaryWeapon(build, baseName, fn)
	local itemsTab = build and build.itemsTab
	local slot = itemsTab and itemsTab.slots and itemsTab.slots["Weapon 1"]
	if not slot then
		error("No weapon slot", 0)
	end
	local item = new("Item"):Item("Rarity: NORMAL\n" .. baseName)
	if not item.base then
		error("Unknown weapon base " .. tostring(baseName), 0)
	end
	local previous = slot.selItemId or 0
	itemsTab:AddItem(item, true)
	slot:SetSelItemId(item.id)
	local ok, result = self:RebuildBuild(build)
	if ok then
		ok, result = pcall(fn)
	end
	slot:SetSelItemId(previous)
	itemsTab:DeleteItem(item, true)
	itemsTab:PopulateSlots()
	local rebuilt, rebuildError = self:RebuildBuild(build)
	if not ok then
		error(result, 0)
	end
	if not rebuilt then
		error("Could not restore the calculated build: " .. tostring(rebuildError), 0)
	end
	return result
end

--- Plain weapon base to test with when the main skill is an attack that does no damage unarmed.
-- @return string|nil base name, nil when no weapon is needed
function AIBridge:GetPlanningWeaponBase(build)
	local lacks, effect = attackLacksWeapon(build)
	if not lacks then
		return nil
	end
	return pickPlanningWeaponBase(build, effect, build.characterLevel or 1)
end

--- Pick the supports that add the most damage to an active skill at this character level.
-- Only supports that are legal at the level, compatible with the skill, realistic to own and
-- affordable with the available mana are considered. Attack skills that need a weapon are
-- measured with a temporary one. The build is restored afterwards.
-- @param excludedNames Lower-cased gem names that must not be picked
-- @return table Array of {name, level, quality, dpsGain}, string|nil error
function AIBridge:SelectOptimalSupportGems(build, activeGemData, characterLevel, maxSupports, excludedNames)
	maxSupports = math.floor(tonumber(maxSupports) or 3)
	local activeEffect = activeGemData and activeGemData.grantedEffect
	if maxSupports <= 0 or not build or not activeEffect or activeEffect.support then
		return { }
	end
	if not build.skillsTab or not build.calcsTab or not build.calcsTab.calcs or not build.itemsTab
		or not build.data or not build.data.gems then
		return { }
	end
	local activeLevel = self:GetMaxLegalGemLevel(activeGemData, characterLevel)
	if not activeLevel then
		return { }
	end

	local excluded = excludedNames or { }
	local calcs = build.calcsTab.calcs
	local simGroup = { label = "AI Support Sim", enabled = true, gemList = { } }

	local function newGem(name, level)
		return {
			nameSpec = name,
			level = level,
			quality = 0,
			enabled = true,
			count = 1,
			enableGlobal1 = true,
			enableGlobal2 = false,
		}
	end

	local function selectSupports(allowWeaponProbe)
		local chosen = { }
		local function evaluate(extra)
			local list = { newGem(activeGemData.name, activeLevel) }
			for _, support in ipairs(chosen) do
				t_insert(list, newGem(support.name, support.level))
			end
			if extra then
				t_insert(list, newGem(extra.name, extra.level))
			end
			simGroup.gemList = list
			build.skillsTab:ProcessSocketGroup(simGroup)
			wipeGlobalCache()
			local env = calcs.buildOutput(build, "MAIN")
			return env.player.output, env.player.mainSkill
		end

		local baseOutput, mainSkill = evaluate(nil)
		local currentDps = readSkillDps(baseOutput)
		if currentDps <= 0 or not mainSkill then
			if allowWeaponProbe and activeEffect.weaponTypes then
				return NEEDS_WEAPON
			end
			return chosen
		end
		local baseline = {
			manaCost = baseOutput.ManaHasCost and finiteOrZero(baseOutput.ManaCost) or 0,
			lifeCost = baseOutput.LifeHasCost and finiteOrZero(baseOutput.LifeCost) or 0,
		}

		local pool = { }
		for _, gemData in pairs(build.data.gems) do
			if isSelectableSupport(gemData) and not excluded[gemData.name:lower()] then
				local level = self:GetMaxLegalGemLevel(gemData, characterLevel)
				if level and calcLib.canGrantedEffectSupportActiveSkill(gemData.grantedEffect, mainSkill) then
					t_insert(pool, { name = gemData.name, level = level })
				end
			end
		end
		table.sort(pool, function(a, b) return a.name < b.name end)

		for _ = 1, maxSupports do
			local scored = { }
			for _, candidate in ipairs(pool) do
				local evalOk, output = pcall(evaluate, candidate)
				if evalOk then
					local dps = readSkillDps(output)
					if dps > currentDps and skillIsAffordable(output, baseline) then
						t_insert(scored, {
							name = candidate.name,
							level = candidate.level,
							dps = dps,
							gain = dps - currentDps,
						})
					end
				end
			end
			if #scored == 0 then
				break
			end
			table.sort(scored, function(a, b)
				if a.gain ~= b.gain then
					return a.gain > b.gain
				end
				return a.name < b.name
			end)
			t_insert(chosen, scored[1])
			currentDps = scored[1].dps
			pool = { }
			for index = 2, math.min(#scored, SUPPORT_REFINEMENT_POOL + 1) do
				t_insert(pool, scored[index])
			end
		end
		return chosen
	end

	local function runPass(allowWeaponProbe)
		return self:WithTemporaryMainGroup(build, simGroup, function()
			return selectSupports(allowWeaponProbe)
		end)
	end

	local ok, picked = pcall(runPass, true)
	if ok and picked == NEEDS_WEAPON then
		local weaponBase = pickPlanningWeaponBase(build, activeEffect, characterLevel)
		if weaponBase then
			ok, picked = pcall(self.WithTemporaryWeapon, self, build, weaponBase, function()
				return runPass(false)
			end)
		else
			picked = { }
		end
	end
	if not ok then
		return { }, tostring(picked)
	end

	local selected = { }
	for _, support in ipairs(picked or { }) do
		t_insert(selected, { name = support.name, level = support.level, quality = 0, dpsGain = support.gain })
	end
	return selected
end

local function pointsAtLevel(steps, level)
	for _, step in ipairs(steps) do
		if level >= step.level then
			return step.points
		end
	end
	return 0
end

local function isFreeStartNode(node)
	return node.type == "ClassStart" or node.type == "AscendClassStart"
end

--- Return the campaign-legal passive and ascendancy point caps for this build.
--- The cap is intentionally based on level and completed campaign milestones,
--- not on an optimistic level-100 total.
function AIBridge:GetPassivePointLimits(build, levelOverride, includeExtraPoints)
	local level = math.floor(tonumber(levelOverride or (build and build.characterLevel)) or 1)
	level = math.max(1, math.min(level, 100))

	local extraPoints = 0
	if includeExtraPoints ~= false then
		local output = build and build.calcsTab and build.calcsTab.mainOutput
		if output then
			extraPoints = math.max(0, tonumber(output.ExtraPoints) or 0)
		end

		local configInput = build and build.configTab and build.configTab.input
		local bandit = configInput and configInput.bandit
		if level < 22 then
			extraPoints = 0
		elseif bandit == "None" then
			-- BuildModList has already changed, but mainOutput may not yet have been
			-- recalculated when set_bandit and alloc_node share an action batch.
			extraPoints = math.max(extraPoints, 1)
		elseif bandit and extraPoints == 1 then
			-- Avoid retaining a stale kill-all-bandits point after switching away.
			extraPoints = 0
		end
	end

	local mainPoints = level - 1 + pointsAtLevel(QUEST_POINT_STEPS, level) + extraPoints
	local ascendancyPoints = pointsAtLevel(ASCENDANCY_POINT_STEPS, level)
	return mainPoints, ascendancyPoints
end

--- Compute the newly consumed points when PoB allocates node.path.
--- This mirrors PassiveSpec:CountAllocNodes: normal passives cost main points,
--- while real ascendancy nodes cost ascendancy points; starts are free.
local function getNodeAllocationPath(node)
	local path
	if node.intuitiveLeapLikesAffecting and #node.intuitiveLeapLikesAffecting > 0 then
		path = { node }
	else
		path = node.path or {}
	end
	if #path == 0 then
		path = { node }
	end
	return path
end

--- Compute the newly consumed points when PoB allocates node.path.
--- reservedNodes lets a planner account for paths already selected earlier.
function AIBridge:GetAllocationCosts(node, reservedNodes)
	local mainCost, ascendancyCost = 0, 0
	local seen = {}
	for _, pathNode in ipairs(getNodeAllocationPath(node)) do
		local key = pathNode.id or pathNode
		if not seen[key] and not pathNode.alloc and not (reservedNodes and reservedNodes[key]) then
			seen[key] = true
			if not isFreeStartNode(pathNode) then
				if pathNode.ascendancyName and not pathNode.isMultipleChoiceOption then
					ascendancyCost = ascendancyCost + 1
				else
					mainCost = mainCost + 1
				end
			end
		end
	end
	return mainCost, ascendancyCost
end

local function reserveNodeAllocationPath(node, reservedNodes)
	for _, pathNode in ipairs(getNodeAllocationPath(node)) do
		reservedNodes[pathNode.id or pathNode] = true
	end
end

local function getNodeStatLines(node)
	local rawStats = node.sd
	if type(rawStats) ~= "table" or #rawStats == 0 then
		rawStats = node.stats
	end
	local stats = {}
	if type(rawStats) == "table" then
		for _, stat in ipairs(rawStats) do
			if type(stat) == "string" and stat ~= "" then
				t_insert(stats, stat)
			end
		end
	elseif type(rawStats) == "string" and rawStats ~= "" then
		t_insert(stats, rawStats)
	end
	return stats
end

local function scoreTreeCandidate(name, nodeType, stats, mainPointCost, goals)
	if nodeType == "Keystone" then
		-- Keystones have build-defining tradeoffs. A planner must never infer one
		-- from a matching keyword; the player must request it explicitly.
		return -1000, "keystone requires an explicit request"
	end

	local text = ((name or "") .. " " .. table.concat(stats, " ")):lower()
	local score = 0
	local reasons = {}
	for _, goalId in ipairs(goals or {}) do
		local rule = TREE_GOAL_BY_ID[goalId]
		if rule and containsAny(text, rule.statTerms) then
			score = score + rule.weight
			t_insert(reasons, rule.label)
		end
	end
	if score > 0 then
		score = score - mainPointCost * 2
	end
	return score, #reasons > 0 and table.concat(reasons, ", ") or nil
end

--- Return reachable notable and keystone candidates with their real PoB stat lines.
--- Scoring is driven by generic skill mechanics, never by a named build archetype.
function AIBridge:CollectTreeCandidates(spec, mainAvailable, ascendancyAvailable, goals, skillProfile, explicitNodeNames)
	local candidates = {}
	for _, node in pairs(spec.nodes or {}) do
		if (node.type == "Notable" or node.type == "Keystone") and node.name and not node.alloc and node.path then
			local mainPointCost, ascendancyPointCost = self:GetAllocationCosts(node)
			if mainPointCost <= mainAvailable and ascendancyPointCost <= ascendancyAvailable then
				local stats = getNodeStatLines(node)
				local goalScore, goalReason =
					scoreTreeCandidate(node.name, node.type, stats, mainPointCost, goals)
				local semanticClassification, semanticReason, semanticScore
				if skillProfile then
					semanticClassification, semanticReason, semanticScore =
						AIPlanning:ClassifyPassiveNode(node, skillProfile, explicitNodeNames)
					if semanticClassification == "compatible" or semanticClassification == "defensive" then
						local adjustedSemanticScore = math.max(semanticScore - mainPointCost * 2, 1)
						if adjustedSemanticScore > goalScore then
							goalScore = adjustedSemanticScore
						end
						goalReason = semanticReason or goalReason
					elseif semanticClassification == "manual_only" then
						goalScore = -1000
						goalReason = semanticReason
					else
						goalScore = 0
						goalReason = semanticReason
					end
				end
				t_insert(candidates, {
					name = node.name,
					type = node.type,
					stats = stats,
					pathLength = #node.path,
					mainPointCost = mainPointCost,
					ascendancyPointCost = ascendancyPointCost,
					goalScore = goalScore,
					goalReason = goalReason,
					classification = semanticClassification,
				})
			end
		end
	end

	table.sort(candidates, function(a, b)
		if (#goals > 0 or skillProfile ~= nil) and a.goalScore ~= b.goalScore then
			return a.goalScore > b.goalScore
		end
		if a.pathLength ~= b.pathLength then
			return a.pathLength < b.pathLength
		end
		return a.name < b.name
	end)

	if #candidates > 50 then
		candidates = { unpack(candidates, 1, 50) }
	end
	return candidates
end

--- Select a bounded, path-aware sequence from the mechanic-matched notables.
function AIBridge:BuildTreeRecommendationPlan(spec, candidates, mainAvailable, ascendancyAvailable, goals, skillProfile)
	if #goals == 0 and not skillProfile then
		return {}, 0, 0
	end

	local nodesByName = {}
	for _, node in pairs(spec.nodes or {}) do
		if node.name then
			nodesByName[node.name:lower()] = node
		end
	end

	local reservedNodes = {}
	local plan = {}
	local mainUsed, ascendancyUsed = 0, 0
	for _, candidate in ipairs(candidates) do
		local eligible = candidate.goalScore > 0
		if skillProfile then
			eligible = eligible and (candidate.classification == "compatible" or candidate.classification == "defensive")
		end
		if eligible then
			local node = nodesByName[candidate.name:lower()]
			if node then
				local mainCost, ascendancyCost = self:GetAllocationCosts(node, reservedNodes)
				if (mainCost > 0 or ascendancyCost > 0)
					and mainUsed + mainCost <= mainAvailable
					and ascendancyUsed + ascendancyCost <= ascendancyAvailable then
					mainUsed = mainUsed + mainCost
					ascendancyUsed = ascendancyUsed + ascendancyCost
					reserveNodeAllocationPath(node, reservedNodes)
					t_insert(plan, {
						name = candidate.name,
						type = candidate.type,
						stats = candidate.stats,
						classification = candidate.classification,
						goalReason = candidate.goalReason,
						mainPointCost = mainCost,
						ascendancyPointCost = ascendancyCost,
						cumulativeMainPoints = mainUsed,
						cumulativeAscendancyPoints = ascendancyUsed,
						simulatedDelta = candidate.simulatedDelta,
						tradeoff = candidate.tradeoff,
					})
					if #plan == 12 then
						break
					end
				end
			end
		end
	end
	return plan, mainUsed, ascendancyUsed
end

local function computePriorityScore(priority, dpsGainPct, ehpGainPct, maxHitGainPct, sustainGain)
	local posDps = dpsGainPct > 0 and dpsGainPct or 0
	local posEhp = ehpGainPct > 0 and ehpGainPct or 0
	local posHit = maxHitGainPct > 0 and maxHitGainPct or 0
	local posSustain = sustainGain > 0 and math.min(sustainGain / 5, 10) or 0
	if priority == "damage" then
		return posDps * 1.6 + posEhp * 0.25 + posHit * 0.15 + posSustain
	elseif priority == "defense" then
		return posEhp * 1.5 + posHit * 0.6 + posSustain * 1.5 + posDps * 0.2
	end
	local bothBonus = (posDps > 0 and posEhp > 0) and math.min(posDps, posEhp) * 0.5 or 0
	return posDps + posEhp + posHit * 0.35 + posSustain + bothBonus
end

--- Rank passive candidates by simulation. An attack that deals no damage because no weapon is
--- equipped is measured with a temporary plain weapon. Without it every candidate would be ranked
--- by defence alone, and fillers for another weapon type could outrank the nodes that matter.
function AIBridge:RankPassiveCandidatesBySimulation(build, candidates, skillProfile, priority, fingerprint, maxSimulations)
	if build and build.calcsTab and build.buildFlag then
		pcall(self.RebuildBuild, self, build)
	end
	local weaponBase = self:GetPlanningWeaponBase(build)
	if not weaponBase then
		return self:RankPassiveCandidatesCore(build, candidates, skillProfile, priority, fingerprint, maxSimulations)
	end
	fingerprint = fingerprint or self:GetBuildFingerprint(build)
	local ok, result = pcall(self.WithTemporaryWeapon, self, build, weaponBase, function()
		local ranked, excluded = self:RankPassiveCandidatesCore(
			build, candidates, skillProfile, priority, fingerprint, maxSimulations
		)
		return { ranked, excluded }
	end)
	if not ok then
		return candidates, {}
	end
	return result[1], result[2]
end

--- Rank a bounded semantic shortlist of passive candidates using isolated PoB simulations (US-006).
--- Never brute-forces the passive tree: simulates at most maxSimulations compatible/defensive candidates
--- from the same current build snapshot, caching by build fingerprint + skill profile + priority.
function AIBridge:RankPassiveCandidatesCore(build, candidates, skillProfile, priority, fingerprint, maxSimulations)
	maxSimulations = maxSimulations or 12
	priority = (priority == "damage" or priority == "defense" or priority == "balanced") and priority or "balanced"
	if not build or not skillProfile or type(candidates) ~= "table" or #candidates == 0 then
		return candidates, {}
	end
	if type(build.SaveDB) ~= "function" then
		return candidates, {}
	end

	fingerprint = fingerprint or self:GetBuildFingerprint(build)
	local cacheKey = tostring(skillProfile.skillName) .. "|" .. tostring(priority) .. "|" .. tostring(maxSimulations)
	if fingerprint and self.treeSimulationCache
		and self.treeSimulationFingerprint == fingerprint
		and self.treeSimulationKey == cacheKey then
		local cachedByName = self.treeSimulationCache.byName or {}
		for _, candidate in ipairs(candidates) do
			local sim = cachedByName[candidate.name]
			if sim then
				candidate.simulatedDelta = sim.simulatedDelta
				candidate.tradeoff = sim.tradeoff
				candidate.simulationRankScore = sim.simulationRankScore
				candidate.simulationStatus = sim.simulationStatus
				candidate.simulationExcludedReason = sim.simulationExcludedReason
			end
		end
		table.sort(candidates, function(a, b)
			local aSim = a.simulationRankScore or -1
			local bSim = b.simulationRankScore or -1
			if aSim ~= bSim then
				return aSim > bSim
			end
			if a.goalScore ~= b.goalScore then
				return a.goalScore > b.goalScore
			end
			if a.pathLength ~= b.pathLength then
				return a.pathLength < b.pathLength
			end
			return a.name < b.name
		end)
		return candidates, self.treeSimulationCache.excluded or {}
	end

	if build.calcsTab and build.buildFlag then
		pcall(self.RebuildBuild, self, build)
	end
	local baseMetrics = self:CaptureBuildMetrics(build)
	if not baseMetrics or (baseMetrics.dps <= 0 and baseMetrics.ehp <= 0) then
		return candidates, {}
	end
	local baseOutput = build.calcsTab and build.calcsTab.mainOutput or {}
	local baseSustain = (tonumber(baseOutput.LifeRegen) or 0) + (tonumber(baseOutput.EnergyShieldRegen) or 0)
	local baseMinMaxHit = math.min(
		baseMetrics.maxHits.physical > 0 and baseMetrics.maxHits.physical or math.huge,
		baseMetrics.maxHits.fire > 0 and baseMetrics.maxHits.fire or math.huge,
		baseMetrics.maxHits.cold > 0 and baseMetrics.maxHits.cold or math.huge,
		baseMetrics.maxHits.lightning > 0 and baseMetrics.maxHits.lightning or math.huge
	)
	if baseMinMaxHit == math.huge then
		baseMinMaxHit = 0
	end

	local snapshotOk, snapshotXml = pcall(build.SaveDB, build, "AI passive shortlist simulation")
	if not snapshotOk or not snapshotXml then
		return candidates, {}
	end

	local simulatedCount = 0
	local byName = {}
	local excluded = {}
	for _, candidate in ipairs(candidates) do
		if simulatedCount >= maxSimulations then
			break
		end
		if candidate.classification == "compatible" or candidate.classification == "defensive" then
			simulatedCount = simulatedCount + 1
			local cloneOk, shadowBuild = pcall(function()
				return new("CompareEntry"):CompareEntry(snapshotXml, "AI passive candidate sim")
			end)
			if not cloneOk or not shadowBuild or not shadowBuild.spec or not shadowBuild.calcsTab then
				candidate.simulationStatus = "excluded"
				candidate.simulationExcludedReason = "simulation clone could not be initialized"
				candidate.simulationRankScore = -10
				t_insert(excluded, { name = candidate.name, reason = candidate.simulationExcludedReason })
			else
				local node = self:FindNode(shadowBuild.spec, { name = candidate.name })
				if not node or not node.path then
					candidate.simulationStatus = "excluded"
					candidate.simulationExcludedReason = "candidate node is not reachable in simulation snapshot"
					candidate.simulationRankScore = -10
					t_insert(excluded, { name = candidate.name, reason = candidate.simulationExcludedReason })
				else
					local allocOk = pcall(shadowBuild.spec.AllocNode, shadowBuild.spec, node)
					local rebuiltOk, rebuildErr = self:RebuildBuild(shadowBuild)
					local afterMetrics = (allocOk and rebuiltOk) and self:CaptureBuildMetrics(shadowBuild) or nil
					if not afterMetrics then
						candidate.simulationStatus = "excluded"
						candidate.simulationExcludedReason = "simulation calculation failed: " .. tostring(rebuildErr or "no metrics")
						candidate.simulationRankScore = -10
						t_insert(excluded, { name = candidate.name, reason = candidate.simulationExcludedReason })
					else
						local afterOutput = shadowBuild.calcsTab.mainOutput or {}
						local afterSustain = (tonumber(afterOutput.LifeRegen) or 0) + (tonumber(afterOutput.EnergyShieldRegen) or 0)
						local afterMinMaxHit = math.min(
							afterMetrics.maxHits.physical > 0 and afterMetrics.maxHits.physical or math.huge,
							afterMetrics.maxHits.fire > 0 and afterMetrics.maxHits.fire or math.huge,
							afterMetrics.maxHits.cold > 0 and afterMetrics.maxHits.cold or math.huge,
							afterMetrics.maxHits.lightning > 0 and afterMetrics.maxHits.lightning or math.huge
						)
						if afterMinMaxHit == math.huge then
							afterMinMaxHit = 0
						end

						local dpsGain = afterMetrics.dps - baseMetrics.dps
						local dpsGainPct = baseMetrics.dps > 0 and (dpsGain / baseMetrics.dps) * 100 or 0
						local ehpGain = afterMetrics.ehp - baseMetrics.ehp
						local ehpGainPct = baseMetrics.ehp > 0 and (ehpGain / baseMetrics.ehp) * 100 or 0
						local maxHitGain = afterMinMaxHit - baseMinMaxHit
						local maxHitGainPct = baseMinMaxHit > 0 and (maxHitGain / baseMinMaxHit) * 100 or 0
						local sustainGain = afterSustain - baseSustain
						local pointCost = math.max(candidate.mainPointCost or 1, 1)

						local tradeoffs = {}
						if dpsGain < -0.5 then
							t_insert(tradeoffs, string.format("%.1f%% DPS", dpsGainPct))
						end
						if ehpGain < -0.5 then
							t_insert(tradeoffs, string.format("%.1f%% EHP", ehpGainPct))
						end
						if maxHitGain < -0.5 then
							t_insert(tradeoffs, string.format("%.1f%% max hit", maxHitGainPct))
						end

						local rawPriorityScore = computePriorityScore(priority, dpsGainPct, ehpGainPct, maxHitGainPct, sustainGain)
						local perPointScore = rawPriorityScore / pointCost
						candidate.simulationStatus = "simulated"
						candidate.simulatedDelta = {
							priority = priority,
							dpsGain = dpsGain,
							dpsGainPct = dpsGainPct,
							ehpGain = ehpGain,
							ehpGainPct = ehpGainPct,
							maxHitGain = maxHitGain,
							maxHitGainPct = maxHitGainPct,
							sustainGain = sustainGain,
							perPointScore = perPointScore,
						}
						candidate.tradeoff = #tradeoffs > 0 and table.concat(tradeoffs, ", ") or nil
						candidate.simulationRankScore = perPointScore * 100 + (candidate.goalScore or 0) * 0.1
					end
				end
			end
			byName[candidate.name] = {
				simulatedDelta = candidate.simulatedDelta,
				tradeoff = candidate.tradeoff,
				simulationRankScore = candidate.simulationRankScore,
				simulationStatus = candidate.simulationStatus,
				simulationExcludedReason = candidate.simulationExcludedReason,
			}
		end
	end

	-- Restore the active build's global calculation cache after shadow simulations.
	if build.calcsTab then
		pcall(self.RebuildBuild, self, build)
	end

	table.sort(candidates, function(a, b)
		local aSim = a.simulationRankScore or -1
		local bSim = b.simulationRankScore or -1
		if aSim ~= bSim then
			return aSim > bSim
		end
		if a.goalScore ~= b.goalScore then
			return a.goalScore > b.goalScore
		end
		if a.pathLength ~= b.pathLength then
			return a.pathLength < b.pathLength
		end
		return a.name < b.name
	end)

	if fingerprint then
		self.treeSimulationCache = {
			byName = byName,
			excluded = excluded,
		}
		self.treeSimulationFingerprint = fingerprint
		self.treeSimulationKey = cacheKey
	end

	return candidates, excluded
end

--- Reject a requested allocation before it can over-spend the current build.
function AIBridge:ValidateNodeAllocationBudget(build, node)
	local spec = build and build.spec
	if not spec or not spec.CountAllocNodes then
		return true
	end

	local ok, mainUsed, ascendancyUsed = pcall(spec.CountAllocNodes, spec)
	if not ok then
		return false, "Could not count allocated passive points: " .. tostring(mainUsed)
	end

	local mainCost, ascendancyCost = self:GetAllocationCosts(node)
	local mainLimit, ascendancyLimit = self:GetPassivePointLimits(build)
	if mainUsed + mainCost > mainLimit then
		return false, string.format(
			"Not enough passive points: %d/%d used, allocation needs %d more",
			mainUsed,
			mainLimit,
			mainCost
		)
	end
	if ascendancyUsed + ascendancyCost > ascendancyLimit then
		return false, string.format(
			"Not enough ascendancy points: %d/%d used, allocation needs %d more",
			ascendancyUsed,
			ascendancyLimit,
			ascendancyCost
		)
	end
	return true
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
		"gem", "gems", "skill", "skills", "support", "supports", "skill gem", "socket link", "link", "links",
		"minion", "minions", "summon", "summoner", "gema", "gemas", "suporte", "suportes",
		"habilidade", "invocador", "invocacao", "invocacoes",
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
	local buildCreation = containsAny(text, {
		"create a build", "make a build", "build me a", "starter build", "league starter",
		"cria uma build", "monta uma build", "monte uma build", "faz uma build",
		"faca uma build", "montar uma build",
	})
	local targetLevel = tonumber(text:match("level%s+(%d+)") or text:match("nivel%s+(%d+)"))
	if not targetLevel or targetLevel < 1 or targetLevel > 100 then
		targetLevel = nil
	end
	local planningClass
	if buildCreation then
		for _, rule in ipairs(PLANNING_CLASS_RULES) do
			if containsAny(text, rule.terms) then
				planningClass = rule.className
				break
			end
		end
	end
	local resetTreePlanning = buildCreation or containsAny(text, {
		"reset tree", "resetar tree", "resetar arvore", "refaz", "refazer", "rebuild tree",
		"reconstruir arvore", "zerar tree", "zerar arvore",
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
		includeTreeCandidates = general or tree or buildCreation,
		targetLevel = targetLevel,
		treeGoals = self:DeriveTreeGoals(nil, userMessage),
		planningClass = planningClass,
		resetTreePlanning = resetTreePlanning,
		includeGemReference = gems and not general,
		includeUniqueReference = items and not general,
		includeItemBases = items and not general,
		includeConfigReference = config,
	}
end

local function addSkillTypes(skillTypes, gemData)
	local grantedEffect = gemData and gemData.grantedEffect
	if grantedEffect and type(grantedEffect.skillTypes) == "table" then
		for skillTypeId in pairs(grantedEffect.skillTypes) do
			skillTypes[skillTypeId] = true
		end
	end
end

local function collectMainSkillTypes(build, skillTypes)
	local skillsTab = build and build.skillsTab
	local activeSet = skillsTab and skillsTab.skillSets and skillsTab.skillSets[skillsTab.activeSkillSetId]
	local group = activeSet and activeSet.socketGroupList
		and activeSet.socketGroupList[build.mainSocketGroup or 1]
	if group and group.gemList then
		for _, gem in ipairs(group.gemList) do
			local gemData = gem.gemData
			if gemData and gemData.grantedEffect and not gemData.grantedEffect.support then
				addSkillTypes(skillTypes, gemData)
			end
		end
	end
end

local function collectMentionedSkillTypes(build, text, skillTypes)
	local gems = build and build.data and build.data.gems
	if type(gems) ~= "table" then
		return
	end
	for _, gemData in pairs(gems) do
		local name = gemData and gemData.name
		if type(name) == "string" and #name >= 4 and text:find(name:lower(), 1, true) then
			addSkillTypes(skillTypes, gemData)
		end
	end
end

local function ruleMatchesSkillTypes(rule, skillTypes)
	if type(SkillType) ~= "table" then
		return false
	end
	for _, skillTypeName in ipairs(rule.skillTypes or {}) do
		local skillTypeId = SkillType[skillTypeName]
		if skillTypeId and skillTypes[skillTypeId] then
			return true
		end
	end
	return false
end

--- Derive mechanic goals from actual active/mentioned skills and the player's words.
--- This allows the same planner to support every class and damage archetype.
function AIBridge:DeriveTreeGoals(build, userMessage)
	local text = (userMessage or ""):lower()
	local skillTypes = {}
	collectMainSkillTypes(build, skillTypes)
	collectMentionedSkillTypes(build, text, skillTypes)

	local selected = {}
	local hasPrimary = false
	for _, rule in ipairs(TREE_GOAL_RULES) do
		if containsAny(text, rule.queryTerms) or ruleMatchesSkillTypes(rule, skillTypes) then
			selected[rule.id] = true
			hasPrimary = hasPrimary or rule.primary or false
		end
	end

	-- Summons use their own minion modifiers, not the caster's generic spell damage.
	if selected.minion then
		selected.spell = nil
	end
	if hasPrimary and not selected.life then
		selected.life = true
	end

	local goals = {}
	for _, rule in ipairs(TREE_GOAL_RULES) do
		if selected[rule.id] then
			t_insert(goals, rule.id)
		end
	end
	return goals
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

	-- Passive points: cap recommendations to the character's actual campaign progress.
	if spec and spec.CountAllocNodes then
		local used, ascUsed = spec:CountAllocNodes()
		local totalMain, totalAscendancy = self:GetPassivePointLimits(build)
		state.tree.pointsUsed = used
		state.tree.pointsTotal = totalMain
		state.tree.pointsAvailable = math.max(totalMain - used, 0)
		state.tree.ascendancyUsed = ascUsed
		state.tree.ascendancyTotal = totalAscendancy
		state.tree.ascendancyAvailable = math.max(totalAscendancy - ascUsed, 0)

		-- A request such as "build me to level 30" needs candidates for that
		-- future level, even when the currently open build is still level 1.
		-- Exclude a possible bandit point so this planning cap stays safe.
		local currentLevel = math.floor(tonumber(build.characterLevel) or 1)
		local planningLevel = context.targetLevel
		if planningLevel and planningLevel > currentLevel then
			local planningMain, planningAscendancy =
				self:GetPassivePointLimits(build, planningLevel, false)
			state.tree.planningLevel = planningLevel
			state.tree.planningPointsTotal = planningMain
			state.tree.planningPointsAvailable = math.max(planningMain - used, 0)
			state.tree.planningAscendancyTotal = planningAscendancy
			state.tree.planningAscendancyAvailable = math.max(planningAscendancy - ascUsed, 0)
		end
	end

	-- Stats from mainOutput (the calculated values)
	local output = build.calcsTab and build.calcsTab.mainOutput
	if output then
		local statKeys = {
			"Life", "LifeUnreserved", "LifeUnreservedPercent", "EnergyShield",
			"Mana", "ManaUnreserved", "ManaUnreservedPercent", "ManaCost", "ManaHasCost",
			"Ward", "Armour", "Evasion",
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

	-- Skills: socket groups with gems and socket budget
	local skillsTab = build.skillsTab
	local totalSocketsUsed = 0
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
						if gem.enabled ~= false then
							totalSocketsUsed = totalSocketsUsed + 1
						end
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
	local effectiveLevel = context.targetLevel or (build.characterLevel or 100)
	local socketBudget = self:GetSocketBudget(build, effectiveLevel)
	state.socketBudget = {
		maxMainLinks = socketBudget.maxMainLinks,
		maxTotalSockets = socketBudget.maxTotalSockets,
		socketsUsed = totalSocketsUsed,
		socketsRemaining = math.max(0, socketBudget.maxTotalSockets - totalSocketsUsed),
		source = socketBudget.source,
	}

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

	-- Reachable tree candidates which fit the relevant level-appropriate budget.
	-- A requested class or reset is projected into a clone before candidates are
	-- serialized, so paths always match the route the actions will create.
	if includeTreeCandidates and spec and spec.nodes then
		local candidateSpec = spec
		local candidateMainUsed = state.tree.pointsUsed or 0
		local candidateAscendancyUsed = state.tree.ascendancyUsed or 0
		local candidateClass
		local projectsClass = context.planningClass and spec.curClassName ~= context.planningClass
		local projectsReset = context.resetTreePlanning
		local candidateResetsTree
		if (projectsClass or projectsReset) and build.SaveDB and spec.tree and spec.tree.classNameMap then
			local snapshotOk, snapshotXml = pcall(build.SaveDB, build)
			if snapshotOk and snapshotXml then
				local cloneOk, projectedBuild = pcall(function()
					return new("CompareEntry"):CompareEntry(snapshotXml, "AI tree planning")
				end)
				local projectedSpec = cloneOk and projectedBuild and projectedBuild.spec
				local classId = projectsClass and projectedSpec
					and projectedSpec.tree.classNameMap[context.planningClass]
				if projectedSpec and (not projectsClass or classId) then
					projectedSpec:ResetNodes()
					if projectsClass then
						projectedSpec:SelectClass(classId)
					elseif projectedSpec.BuildAllDependsAndPaths then
						projectedSpec:BuildAllDependsAndPaths()
					end
					candidateSpec = projectedSpec
					candidateMainUsed, candidateAscendancyUsed = projectedSpec:CountAllocNodes()
					candidateClass = projectsClass and context.planningClass or nil
					candidateResetsTree = (projectsClass or projectsReset) or nil
				end
			end
		end

		local mainTotal = state.tree.planningPointsTotal or state.tree.pointsTotal or 0
		local ascendancyTotal = state.tree.planningAscendancyTotal or state.tree.ascendancyTotal or 0
		local mainAvailable = math.max(mainTotal - candidateMainUsed, 0)
		local ascendancyAvailable = math.max(ascendancyTotal - candidateAscendancyUsed, 0)
		local goals = context.treeGoals or {}
		local skillProfile = context.skillProfile
		if not skillProfile and #goals == 0 then
			skillProfile = AIPlanning:BuildSkillProfile(build, context.planningSkill)
		end
		local explicitNodeNames = context.explicitNodeNames
		local availableNodes =
			self:CollectTreeCandidates(
				candidateSpec,
				mainAvailable,
				ascendancyAvailable,
				goals,
				skillProfile,
				explicitNodeNames
			)
		local excludedTreeCandidates
		if skillProfile and context.simulatePassiveShortlist and not (projectsClass or projectsReset) then
			availableNodes, excludedTreeCandidates = self:RankPassiveCandidatesBySimulation(
				build,
				availableNodes,
				skillProfile,
				context.planningPriority or "balanced",
				context.fingerprint
			)
		end
		state.tree.availableNodes = availableNodes
		if excludedTreeCandidates and #excludedTreeCandidates > 0 then
			state.tree.excludedSimulationCandidates = excludedTreeCandidates
		end
		if skillProfile then
			state.tree.skillProfile = {
				skillName = skillProfile.skillName,
				categories = skillProfile.categories,
			}
		end
		if #goals > 0 or skillProfile ~= nil then
			local recommendedPlan, planMainPoints, planAscendancyPoints =
				self:BuildTreeRecommendationPlan(
					candidateSpec,
					availableNodes,
					mainAvailable,
					ascendancyAvailable,
					goals,
					skillProfile
				)
			state.tree.goals = goals
			state.tree.recommendedPlan = recommendedPlan
			state.tree.recommendedPlanMainPoints = planMainPoints
			state.tree.recommendedPlanAscendancyPoints = planAscendancyPoints
		end
		if candidateClass then
			state.tree.candidateClass = candidateClass
		end
		if candidateResetsTree then
			state.tree.candidateResetsTree = true
		end
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

	-- Gem names (only gems unlocked at the character's current/target level)
	if includeGemReference and build.data and build.data.gems then
		local gemNames = {}
		local levelCap = context.targetLevel or (build.characterLevel or 100)
		for gemId, gemData in pairs(build.data.gems) do
			if gemData.name and not gemData.unsupported then
				local maxLegalLevel = self:GetMaxLegalGemLevel(gemData, levelCap)
				if maxLegalLevel then
					t_insert(gemNames, gemData.name)
				end
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
	-- Strip the conversational <AIChat> XML section so saving messages never invalidates the build fingerprint.
	snapshot = snapshot:gsub("<AIChat>[%s%S]-</AIChat>", ""):gsub("<AIChat%s*/>", "")
	-- PoB's calculations fill in default minion choices and Calcs tab selections on their own.
	-- Those are not player edits, so they must not make a build look changed.
	snapshot = snapshot:gsub(' skillMinion%w*="[^"]*"', ""):gsub(' skill%w+Calcs="[^"]*"', "")

	return sha1(tostring(build) .. "\0" .. snapshot)
end

--- Clear every cached value that belongs to a specific build state.
function AIBridge:InvalidateBuildContext()
	self.gemShortlistCache = nil
	self.gemShortlistFingerprint = nil
	self.uniqueShortlistCache = nil
	self.uniqueShortlistFingerprint = nil
	self.treeSimulationCache = nil
	self.treeSimulationFingerprint = nil
	self.treeSimulationKey = nil
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
	
	-- Test each support gem that is level-legal for this character. Every transient mutation is removed even if PoB throws
	-- while resolving the socket group or recalculating the candidate.
	local results = {}
	local originalGemCount = #mainGroup.gemList
	local charLevel = build.characterLevel or 100
	for gemId, gemData in pairs(build.data.gems) do
		if gemData.grantedEffect and gemData.grantedEffect.support
			and not existingGems[gemId] and not gemData.grantedEffect.legacy then
			local legalLevel = self:GetMaxLegalGemLevel(gemData, charLevel)
			if legalLevel then
				local testGem = {
					nameSpec = gemData.name,
					gemId = gemId,
					level = legalLevel,
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
						level = legalLevel,
						dpsGain = gain,
						dpsGainPct = (gain / baseDPS) * 100,
						type = "support",
					})
				end
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
			local item = new("Item"):Item(raw)
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

--- Parse one structured context request, ignoring surrounding prose.
--- Valid form: <context_request>["gems","tree"]</context_request>
--- When allowActions is true, any accompanying action block is intentionally
--- discarded while the bridge obtains the requested context and retries.
-- @return string displayText
-- @return table|nil scopes
-- @return string|nil error
function AIBridge:ParseContextRequest(content, allowActions)
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
	local openCount = 0
	for _ in lower:gmatch("<context_request") do
		openCount = openCount + 1
	end
	local closeCount = 0
	for _ in lower:gmatch("</context_request") do
		closeCount = closeCount + 1
	end
	if openCount ~= 1 or closeCount ~= 1 then
		return content, nil, "Context request must contain exactly one block"
	end
	if not allowActions and (lower:find("<actions", 1, true) or lower:find("</actions", 1, true)) then
		return content, nil, "Context request cannot include actions"
	end

	local _, block = content:match(
		"^(.-)<context_request>%s*(.-)%s*</context_request>(.-)$"
	)
	if not block then
		return content, nil, "Malformed context_request block"
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
function AIBridge:BuildQuestionState(build, userMessage, fingerprint, requestedScopes, escalated, contextOverrides)
	local context = self:ClassifyQuestion(userMessage)
	for key, value in pairs(contextOverrides or {}) do
		context[key] = value
	end
	context.treeGoals = self:DeriveTreeGoals(build, userMessage)
	local explicitNodeNames = {}
	local lowerMessage = (userMessage or ""):lower()
	if build and build.spec and build.spec.nodes then
		for _, node in pairs(build.spec.nodes) do
			if (node.type == "Notable" or node.type == "Keystone")
				and type(node.name) == "string" and #node.name >= 3
				and lowerMessage:find(node.name:lower(), 1, true) then
				explicitNodeNames[node.name:lower()] = true
			end
		end
	end
	if next(explicitNodeNames) then
		context.explicitNodeNames = explicitNodeNames
	end
	if context.planningSkill or #context.treeGoals == 0 then
		context.skillProfile = AIPlanning:BuildSkillProfile(build, context.planningSkill)
	end
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

	-- A named notable/keystone is an explicit player decision, not an automatic
	-- recommendation. Preserve that escape hatch while keeping starter plans safe.
	for _, node in ipairs(state.tree.availableNodes or {}) do
		if type(node.name) == "string" and #node.name >= 3
			and lowerMessage:find(node.name:lower(), 1, true) then
			explicitNodeNames[node.name:lower()] = true
		end
	end
	if next(explicitNodeNames) then
		state.tree.explicitNodeNames = explicitNodeNames
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
		targetLevel = context.targetLevel,
		treeGoals = context.treeGoals,
		planningClass = context.planningClass,
		resetTreePlanning = context.resetTreePlanning,
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

--- Derive the smallest safe projection needed to re-evaluate a proposed tree.
function AIBridge:GetTreeActionRecoveryOverrides(actions, state)
	local currentClass = state and state.meta and state.meta.className
	local requestedClass
	local requestsReset = false
	local hasAllocation = false
	for _, action in ipairs(actions or {}) do
		if type(action) == "table" and action.type == "set_class" and type(action.name) == "string" then
			requestedClass = action.name
		elseif type(action) == "table" and action.type == "reset_tree" then
			requestsReset = true
		elseif type(action) == "table" and action.type == "alloc_node" then
			hasAllocation = true
		end
	end

	local overrides = {}
	local changesClass = hasAllocation and requestedClass and type(currentClass) == "string"
		and currentClass:lower() ~= requestedClass:lower()
	if changesClass then
		overrides.planningClass = requestedClass
		overrides.resetTreePlanning = true
	elseif hasAllocation and requestsReset then
		overrides.resetTreePlanning = true
	end
	return overrides
end

--- Ensure an AI allocation refers to the tree data actually provided to it.
--- This catches invented names and forces a fresh projection after a class/reset change.
function AIBridge:ValidateTreeActionReferences(actions, state)
	if type(actions) ~= "table" then
		return true
	end

	local candidateNames = {}
	local treeCandidates = state and state.context and state.context.treeCandidates
	local treeState = state and state.tree or {}
	if treeCandidates and treeState.availableNodes then
		for _, node in ipairs(treeState.availableNodes) do
			if type(node.name) == "string" then
				candidateNames[node.name:lower()] = true
			end
		end
	end

	local currentClass = state and state.meta and state.meta.className
	local requestedClass
	local requestsReset = false
	local hasAllocation = false
	for _, action in ipairs(actions) do
		if type(action) == "table" and action.type == "set_class" and type(action.name) == "string" then
			requestedClass = action.name
		elseif type(action) == "table" and action.type == "reset_tree" then
			requestsReset = true
		elseif type(action) == "table" and action.type == "alloc_node" then
			hasAllocation = true
		end
	end

	local candidateClass = treeState.candidateClass
	local classChanges = hasAllocation and requestedClass and type(currentClass) == "string"
		and currentClass:lower() ~= requestedClass:lower()
	local projectedClassMatches = candidateClass and requestedClass
		and candidateClass:lower() == requestedClass:lower()
	if classChanges and not projectedClassMatches then
		return false, "alloc_node requires candidates projected for set_class " .. requestedClass
	end
	if hasAllocation and requestsReset and not treeState.candidateResetsTree then
		return false, "alloc_node requires candidates projected from reset_tree"
	end

	local plannedNodeNames = {}
	for _, node in ipairs(treeState.recommendedPlan or {}) do
		if type(node.name) == "string" then
			plannedNodeNames[node.name:lower()] = true
		end
	end
	local explicitNodeNames = treeState.explicitNodeNames or {}
	local plannedClassSelected = not candidateClass or (type(currentClass) == "string"
		and currentClass:lower() == candidateClass:lower())
	local resetApplied = not treeState.candidateResetsTree
	for _, action in ipairs(actions) do
		if type(action) == "table" and action.type == "reset_tree" then
			resetApplied = true
		elseif type(action) == "table" and action.type == "set_class"
			and type(action.name) == "string" and candidateClass
			and action.name:lower() == candidateClass:lower() then
			plannedClassSelected = true
		elseif type(action) == "table" and action.type == "alloc_node" then
			if not treeCandidates then
				return false, "alloc_node requires tree context"
			end
			if candidateClass and not plannedClassSelected then
				return false, "alloc_node candidates require set_class " .. candidateClass .. " first"
			end
			if not resetApplied then
				return false, "alloc_node candidates require reset_tree first"
			end
			if type(action.name) ~= "string" or action.name == "" then
				return false, "alloc_node must use a tree candidate name"
			end
			local name = action.name:lower()
			if not candidateNames[name] then
				return false, "alloc_node is not a supplied tree candidate: " .. action.name
			end
			for _, candidate in ipairs(treeState.availableNodes or {}) do
				if type(candidate.name) == "string" and candidate.name:lower() == name then
					if candidate.type == "Keystone" and not explicitNodeNames[name] then
						return false, "Keystone requires explicit player intent: " .. action.name
					end
					if candidate.classification == "manual_only" and not explicitNodeNames[name] then
						return false, "Node requires explicit player intent: " .. action.name
					end
					if candidate.classification == "unknown" and not explicitNodeNames[name] then
						return false, "Node is not compatible with the active skill profile: " .. action.name
					end
					break
				end
			end
			if treeState.candidateResetsTree and next(plannedNodeNames)
				and not plannedNodeNames[name] and not explicitNodeNames[name] then
				return false, "alloc_node is not in the supplied verified tree plan: " .. action.name
			end
		end
	end
	return true
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
	local requestOptionsOk, requestOptionsError = AIConfig:ValidateRequestOptions(config.request_options)
	if not requestOptionsOk then
		callback(false, requestOptionsError)
		return
	end


	local request = applyRequestOptions({
		model = model,
		messages = {
			{ role = "user", content = "Reply with OK." },
		},
		max_tokens = 256,
		temperature = 0,
	}, config.request_options)
	local requestBody, encodeError = dkjson.encode(request, { indent = false })
	if not requestBody then
		callback(false, "Could not encode connection test: " .. tostring(encodeError))
		return
	end

	local header = "Content-Type: application/json\r\n"
		.. "Authorization: Bearer " .. apiKey
	local responseHandled = false
	local function onResponse(response, errMsg)
		responseHandled = true
		local _, responseError = parseChatCompletionResponse(response, errMsg)
		if responseError then
			callback(false, responseError)
			return
		end
		callback(true)
	end
	local submitted, requestId = pcall(
		launch.DownloadPage,
		launch,
		getChatCompletionURL(endpoint),
		onResponse,
		{
			header = header,
			body = requestBody,
			timeout = timeout,
		}
	)
	if (not submitted or not requestId) and not responseHandled then
		callback(false, "Could not start connection test")
	end
end

--- Send build state to LLM and get response
-- @param build The active build object
-- @param callback function(response, errMsg, fingerprint, turn, brief, planningSession)
-- @param history optional array of prior {role, content} messages
-- @param supersedesUnappliedActions whether this request replaces a proposal that was not applied
-- @param conversationSession optional local AIConversation session
-- @param planningSession optional local AIPlanning session
function AIBridge:Ask(build, userMessage, callback, history, supersedesUnappliedActions, conversationSession, planningSession)
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
	local sessionError
	conversationSession, sessionError = AIConversation:BeginRequest(conversationSession, requestFingerprint)
	if not conversationSession then
		callback(nil, sessionError)
		return
	end
	planningSession = planningSession or AIPlanning:NewSession()
	local initialContextOverrides
	if planningSession.state == "brief_confirmed" then
		local targetLv = planningSession.confirmedBrief and planningSession.confirmedBrief.targetLevel or nil
		initialContextOverrides = {
			includeGemReference = true,
			includeGemShortlist = true,
			targetLevel = targetLv,
		}
	elseif planningSession.state == "tree" or planningSession.state == "tree_pending" then
		if not planningSession.passivePlanApplied then
			initialContextOverrides = {
				includeTreeCandidates = true,
				simulatePassiveShortlist = true,
				planningSkill = planningSession.confirmedBrief and planningSession.confirmedBrief.mainSkill or nil,
				planningPriority = planningSession.confirmedBrief and planningSession.confirmedBrief.priority or "balanced",
				fingerprint = requestFingerprint,
			}
		else
			initialContextOverrides = {
				planningSkill = planningSession.confirmedBrief and planningSession.confirmedBrief.mainSkill or nil,
				planningPriority = planningSession.confirmedBrief and planningSession.confirmedBrief.priority or "balanced",
				fingerprint = requestFingerprint,
			}
		end
	end

	local state, contextOrErr =
		self:BuildQuestionState(build, userMessage, requestFingerprint, nil, false, initialContextOverrides)
	if not state then
		callback(nil, contextOrErr)
		return
	end
	local context = contextOrErr

	self.pending = true
	self.lastError = nil

	local systemPrompt = [[You are an expert Path of Exile 1 build advisor integrated into Path of Building.
You have access to the player's current core build state and selected optional context.
You can propose typed build changes, but PoB validates them and the player explicitly decides whether to apply them.
Give specific, actionable advice with numbers. Reference actual stats from the build.
When suggesting changes, explain the expected impact (e.g. "+15% DPS", "+200 life").
Be concise. Use PoB color codes: ^2=green/good, ^1=red/bad, ^7=white, ^8=gray.
If the user asks "how do I improve", focus on the top 3 highest-impact changes.
Format responses for readability in a game tool UI.
Reply in the language the player typed. Some player messages are fixed English requests sent by UI
buttons (for example "Propose complementary skills for this build"): for those, keep the language of the
player's earlier typed messages, and use English when there are none. Never switch language on your own.

state.context declares which optional sections are included and lists omitted sections in
availableContexts. Missing data does not mean that no candidates exist.
If omitted context is required for a reliable answer and escalationRemaining is 1, respond ONLY
with one valid JSON array inside this exact block:
<context_request>
["gems","tree"]
</context_request>
Allowed scopes are: "gems", "uniques", "tree", and "config". Request only the smallest set needed.
Never include prose with a context request. Do not include actions either: if you do,
the bridge safely discards them, obtains the requested PoB data, and repeats the original
question automatically. If escalationRemaining is 0, do not request more context; answer
from the available evidence and state any limitation.

Every final response after sufficient context MUST include exactly one valid JSON object in this block:
<turn>
{"next":"answer|clarify|proposal","goal":"short semantic goal","reason":"short explanation"}
</turn>
Use answer for read-only advice. Use clarify only when a missing player decision would materially
change the result; do not ask for information already present in the build state or conversation.
A clarify turn MUST include question.id and question.prompt, and may include question.options
as a JSON array of non-empty strings.
Use proposal when presenting a change. Only proposal turns may include an actions block. Clarify
and answer turns MUST NOT include actions. If the player must choose between meaningful tradeoffs,
ask one focused clarification instead of silently assuming a preference.

For an explicit request to create or rebuild a build, use guided planning instead of executable
actions. Ask one clarify turn only when a material decision is missing: the main skill, target
level, league/budget/SSF constraint, offensive/defensive priority, or an otherwise unresolved
class or ascendancy choice. Do not ask a long questionnaire when the player already supplied the
details. Once those decisions are known, respond with concise prose and exactly one non-executable
brief block followed by a proposal turn:
<brief>
{"stage":"brief","mainSkill":"Fireball","class":"Witch","ascendancy":"Elementalist","targetLevel":30,"priority":"balanced","constraints":["league starter"],"assumptions":["no required uniques"]}
</brief>
<turn>
{"next":"proposal","goal":"confirm build direction","reason":"brief is complete"}
</turn>
Use priority values damage, defense, or balanced. If the target level is below 33 (before the
first Labyrinth), set ascendancy to "None" or the planned future ascendancy name (never an empty
string). A brief is only a direction for player review:
it MUST NOT include an actions block, it never changes the PoB build, and it is not confirmed
until the player explicitly uses Confirm direction. For existing-build advisor requests, do not
emit a brief unless the player explicitly asks to create or rebuild a build.

When the guided planning session state is brief_confirmed, propose ONLY the build foundation as a
proposal turn with one actions block. Foundation actions are limited to set_level, set_class,
set_ascendancy, reset_tree, add_skill, and set_main_skill. Do not include alloc_node, gear,
mastery, tattoo, bandit, pantheon, jewel, or configuration actions in the foundation stage.
Use the confirmed brief's class, ascendancy, main skill, and target level. If the confirmed
brief's ascendancy is "None", omit set_ascendancy or pass {"type":"set_ascendancy","name":"None"}.
Emit set_level to the
target level before other foundation actions when it changes the level. When adding the main
skill group with add_skill, send the active skill gem alone. The app then links the best compatible,
level-legal supports the character can afford, up to state.socketBudget.maxMainLinks (3L for Lv 1-12,
4L for Lv 13-38, 5L for Lv 39-67, 6L for Lv 68+). Name
supports yourself only when the player asked for specific ones, and then use only gems from
state.reference.gemNames (already filtered to gems unlocked at the character's level). After adding
the main skill group, emit set_main_skill so PoB calculates the intended skill.

Respect character constraints at all times:
1. Gem Level vs Character Level: NEVER propose a gem whose minimum required level exceeds the character's level (e.g. Spell Echo / Multistrike require Lv 38; Swift Affliction requires Lv 31; CwDT requires Lv 38). Set each gem's level appropriate to the character's level.
2. Socket & Link Budget (state.socketBudget): NEVER exceed state.socketBudget.maxMainLinks per group or state.socketBudget.maxTotalSockets across all groups.
3. Mana & Reservation Budget (stats.Mana, stats.ManaUnreserved, stats.ManaUnreservedPercent, stats.ManaCost): before recommending auras, heralds or other reservation skills, check the unreserved mana. Keep ManaUnreserved at least three times ManaCost so the main skill stays castable, and recommend no reservation at all when the character cannot spare mana for it. Preflight rejects batches that leave negative unreserved mana or a skill the character cannot pay for. Prefer skills that need no reservation when mana is tight.
4. Tree Candidates at Current Moment: tree.availableNodes and tree.recommendedPlan are already simulated and ranked by per-point impact for the character's exact level, class, and configured skill. Use them in order.

When the guided planning session state is tree or tree_pending and passivePlanApplied is not true,
propose ONLY the passive tree plan
as a proposal turn with one actions block containing only alloc_node actions from
tree.recommendedPlan (or tree.availableNodes when compatible/defensive). Do not include set_class,
set_level, skills, items, or configuration actions in the passive tree stage. Present the exact
node names, incremental path cost, cumulative point cost, and semantic reason. Never select a
keystone unless the player explicitly requested it.

Once passivePlanApplied is true (or in advisor mode), the player may ask for:
- Complementary skills (auras, curses/marks, guard skills, movement skills, secondary setups): propose add_skill actions using exact canonical gem names from state.reference.gemNames (request "gems" context if omitted).
- Recommended gear/items: explain best-in-slot starter uniques and rare stat priorities per slot, and propose equip_item actions with valid PoB item raw text (e.g. Rarity: RARE\nName\nBase\nImplicits: 0\n+50 to maximum Life\n+35% to Fire Resistance) when helpful.
- Playstyle & leveling guide: provide skill rotation, single-target vs clear combo, aura/curse usage, defensive layers, and leveling progression.

The simulated uniqueShortlist is a preselected sample, not an exhaustive proof about every
unique in the catalog. If no entry improves both DPS and EHP, say "none among the tested
candidates", never "no unique exists". balancedGainPct is positive only when both metrics improve.
If the build has no configured main skill or has near-zero DPS/EHP, state that upgrade analysis
is not meaningful yet and ask the player to load/configure the intended build before concluding.

When state.context.treeCandidates is true, tree.availableNodes contains reachable notables and
keystones with their real PoB stat lines and allocation cost. Never claim a stat that is absent.
tree.pointsAvailable and tree.ascendancyAvailable are hard caps at the current character level.
When tree.planningLevel exists, it is the requested future level: use planningPointsAvailable
and planningAscendancyAvailable as conservative caps, and emit set_level to that target BEFORE
allocations. Do not allocate an ascendancy node while the relevant ascendancy cap is 0.
If tree.candidateClass exists and differs from meta.className, the listed routes were projected
from that class: emit set_class with tree.candidateClass, then reset_tree, BEFORE every
alloc_node action. If tree.candidateResetsTree is true, emit reset_tree BEFORE every alloc_node
action; those candidates assume a clean tree and must not be mixed with the old route.
tree.goals lists mechanics derived from the actual/mentioned skill and the player's request.
When tree.recommendedPlan is non-empty, it is a deterministic, path-aware plan under the current
point cap: use only its entries, in listed order, for a new or reset build. Each entry includes
its incremental and cumulative allocation cost. Do not substitute a superficially related node.
Keystones are build-defining tradeoffs: never choose one automatically; use one only when the
player explicitly names it.
If tree.availableNodes and tree.recommendedPlan are both empty, no notable fits the available
points (typical below level 10). Say so in one sentence, do not tell the player to reload the build,
and tell them they can press Skip Tree to continue with skills and gear.
For alloc_node, use ONLY an exact name from tree.availableNodes; NEVER invent a node or use a
numeric ID. If treeCandidates is false, request the "tree" context before proposing alloc_node.
If state.context.actionRecovery is present, the previous action batch was rejected because its
tree data did not match the requested class/reset/plan. Replace it with one complete, ordered
batch using the supplied projected candidates and plan.
For existing-build advisor requests only, when enough evidence exists and no material player
decision is missing, propose requested changes with a proposal turn. Do not tell the player to do
work that a valid proposal can do. Never claim the active build changed unless you emit a valid
actions block inside a proposal turn. For guided creation or rebuild requests, emit no actions
until a confirmed brief is consumed by a later planning stage.
For an existing-build advisor action proposal, end the final response with its one turn block, exactly like this:
<actions>
[{"type":"set_level","value":100},{"type":"alloc_node","name":"Resolute Technique"}]
</actions>
<turn>
{"next":"proposal","goal":"improve damage","reason":"validated change proposal"}
</turn>

Supported action types:
- {"type":"set_level","value":<1-100>}  -- change character level
- {"type":"set_class","name":"<class name>"}  -- e.g. "Marauder", "Witch", "Scion"
- {"type":"set_ascendancy","name":"<ascendancy>"}  -- e.g. "Inquisitor", "Necromancer"
- {"type":"set_bandit","value":"None|Oak|Kraityn|Alira"}  -- None = kill all
- {"type":"set_pantheon","major":"<god>","minor":"<god>"}  -- e.g. major="TheBrineKing", minor="Gruthkul"
- {"type":"alloc_node","name":"<exact name from tree.availableNodes>"}
  (only after treeCandidates is true; allocating a distant node also allocates its path)
- {"type":"dealloc_node","name":"..."} or {"type":"dealloc_node","id":...}
- {"type":"reset_tree"}  -- remove all allocated passive and ascendancy nodes, retaining class choices
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
For add_skill and set_main_skill actions, use the exact canonical gem names from
state.reference.gemNames. Never translate, pluralize, abbreviate, or invent a gem name.
If that catalog is omitted and an exact gem name is needed, request the "gems" context instead.

Only include actions you are confident about.]]

	if supersedesUnappliedActions then
		systemPrompt = systemPrompt .. [[

The previous action proposal in this conversation was NOT applied. The current serialized build
state is authoritative. When the player asks for a correction or replacement, emit a fresh
complete <actions> block for the requested change; never assume the previous proposal took effect.]]
	end

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
		AIConversation:AbortRequest(conversationSession)
		self.pending = false
		self.lastError = message
		callback(nil, message)
	end

	local function complete(content, finalState, turn, mentionContent, brief, proposedActions)
		local turnApplied, turnError = AIConversation:ApplyTurn(
			conversationSession,
			turn,
			requestFingerprint
		)
		if not turnApplied then
			fail("Invalid AI dialogue turn: " .. tostring(turnError))
			return
		end
		if brief then
			local storedPlanningSession, planningError = AIPlanning:StoreBrief(
				planningSession,
				brief,
				requestFingerprint
			)
			if not storedPlanningSession then
				fail("Invalid AI build brief: " .. tostring(planningError))
				return
			end
			planningSession = storedPlanningSession
		end
		if proposedActions and planningSession.state == "brief_confirmed" then
			local foundationSession, foundationError = AIPlanning:StoreFoundation(
				planningSession,
				proposedActions,
				requestFingerprint
			)
			if not foundationSession then
				fail("Invalid AI foundation proposal: " .. tostring(foundationError))
				return
			end
			planningSession = foundationSession
		elseif proposedActions and (planningSession.state == "tree" or planningSession.state == "tree_pending")
			and (not planningSession.passivePlanApplied or isPassiveOnlyBatch(proposedActions)) then
			local fittedActions, droppedCount = self:FitPassivePlanToBudget(build, proposedActions)
			if droppedCount > 0 then
				proposedActions = fittedActions
				content = content .. string.format(
					"\n\n^1Note: the last %d allocation(s) of this plan did not fit your passive point budget and were removed. The remaining plan fits.",
					droppedCount
				)
			end
			local passivePlanSession, passivePlanError = AIPlanning:StorePassivePlan(
				planningSession,
				proposedActions,
				requestFingerprint
			)
			if not passivePlanSession then
				fail("Invalid AI passive plan proposal: " .. tostring(passivePlanError))
				return
			end
			planningSession = passivePlanSession
		end
		self.pending = false
		self.lastError = nil
		self.lastResponse = content
		self.lastMentions = self:ExtractMentions(mentionContent or content, finalState)
		self.lastMentionsFingerprint = requestFingerprint
		callback(content, nil, requestFingerprint, turn, brief, planningSession)
	end

	local function buildRequest(currentState, tokenBudget)
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
		local conversationJson, conversationEncodeError = dkjson.encode(
			AIConversation:GetPromptState(conversationSession),
			{ indent = false }
		)
		if not conversationJson then
			return nil, nil, "Could not encode conversation state: " .. tostring(conversationEncodeError)
		end
		userPrompt = userPrompt .. "\n\nConversation session (JSON):\n" .. conversationJson
		local planningJson, planningEncodeError = dkjson.encode(
			AIPlanning:GetPromptState(planningSession),
			{ indent = false }
		)
		if not planningJson then
			return nil, nil, "Could not encode planning state: " .. tostring(planningEncodeError)
		end
		userPrompt = userPrompt .. "\n\nGuided planning session (JSON):\n" .. planningJson

		local messages = {
			{ role = "system", content = systemPrompt },
		}
		for _, msg in ipairs(trimmedHistory) do
			t_insert(messages, msg)
		end
		t_insert(messages, { role = "user", content = userPrompt })

		local model = AIConfig:GetModel()
		local request = applyRequestOptions({
			model = model,
			messages = messages,
			max_tokens = tokenBudget,
			temperature = 0.3,
		}, AIConfig:GetRequestOptions())
		request.max_tokens = tokenBudget
		local requestBody, requestEncodeError = dkjson.encode(request, { indent = false })
		if not requestBody then
			return nil, nil, "Could not encode API request: " .. tostring(requestEncodeError)
		end
		return requestBody, stateJson, nil
	end

	local configuredTokens = math.floor(tonumber(AIConfig:GetRequestOptions().max_tokens) or 0)
	local baseTokenBudget = configuredTokens > 0 and configuredTokens or DEFAULT_MAX_TOKENS

	local sendRequest
	sendRequest = function(currentState, currentContext, expansionsUsed, tokenBudget, afterTruncation)
		tokenBudget = tokenBudget or baseTokenBudget
		local requestBody, stateJson, requestError = buildRequest(currentState, tokenBudget)
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

		local responseHandled = false
		local function handleResponse(response, errMsg)
			local content, responseError, finishReason = parseChatCompletionResponse(response, errMsg)
			if errMsg and not afterTruncation and tokenBudget > MIN_TOKENS_FALLBACK and apiRejectedTokenLimit(response) then
				sendRequest(currentState, currentContext, expansionsUsed, math.max(MIN_TOKENS_FALLBACK, math.floor(tokenBudget / 2)))
				return
			end
			if afterTruncation and not content then
				fail("The reply was cut off by the output token limit and the provider did not accept a larger limit. "
					.. "Set request_options.max_tokens in the AI settings to a value it supports.")
				return
			end
			if finishReason == "length" then
				if tokenBudget < MAX_TOKENS_CEILING then
					sendRequest(currentState, currentContext, expansionsUsed, math.min(tokenBudget * 2, MAX_TOKENS_CEILING), true)
					return
				end
				fail("The model ran out of output tokens before it finished. Raise request_options.max_tokens in the AI settings or pick a model that reasons less.")
				return
			end
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
			local hasActionMarker = lowerContent:find("<actions", 1, true)
				or lowerContent:find("</actions", 1, true)
			if lowerContent:find("<context_request", 1, true)
				and (AIConversation:HasTurnMarker(content) or AIPlanning:HasBriefMarker(content)) then
				fail("AI context request cannot include a turn or brief block")
				return
			end
			local _, requestedScopes, contextRequestError =
				self:ParseContextRequest(content, hasActionMarker)
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
				AIConversation:RecordContextExpansion(conversationSession, missingScopes)

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

				sendRequest(expandedState, expandedContextOrError, expansionsUsed + 1, tokenBudget)
				return
			end

			local turnContent, turn, turnError = AIConversation:ParseTurnOrAnswer(content)
			if turnError then
				fail("Invalid AI dialogue turn: " .. turnError)
				return
			end
			local briefContent, brief, briefError = AIPlanning:ParseBrief(turnContent)
			if briefError then
				fail("Invalid AI build brief: " .. briefError .. ". Ask for a complete build direction.")
				return
			end
			if brief then
				if hasActionMarker then
					fail("AI build brief cannot include executable actions")
					return
				end
				if turn.next ~= "proposal" then
					fail("AI build brief must use a proposal turn")
					return
				end
			end
			local displayText, proposedActions, actionParseError = self:ParseActions(briefContent)
			if proposedActions and turn.next ~= "proposal" then
				fail("AI returned actions outside a proposal turn")
				return
			end
			if actionParseError and turn.next ~= "proposal" then
				fail("AI returned an action block outside a proposal turn")
				return
			end
			if actionParseError then
				local rejectedTurn = {
					next = "answer",
					goal = turn.goal,
					reason = "Action block failed local validation",
				}
				complete(briefContent, currentState, rejectedTurn, displayText)
				return
			end
			if proposedActions and planningSession.state == "brief_confirmed" then
				local foundationValid, foundationError = AIPlanning:ValidateFoundationActions(proposedActions)
				if not foundationValid then
					fail("Invalid AI foundation proposal: " .. tostring(foundationError))
					return
				end
			elseif proposedActions and (planningSession.state == "tree" or planningSession.state == "tree_pending")
				and (not planningSession.passivePlanApplied or isPassiveOnlyBatch(proposedActions)) then
				local passivePlanValid, passivePlanError = AIPlanning:ValidatePassivePlanActions(proposedActions)
				if not passivePlanValid then
					fail("Invalid AI passive plan proposal: " .. tostring(passivePlanError))
					return
				end
			end
			local treeActionsValid, treeActionError =
				self:ValidateTreeActionReferences(proposedActions, currentState)
			if not actionParseError and proposedActions and not treeActionsValid then
				if expansionsUsed >= 1 then
					local rejectedText = displayText .. "\n\n^1Action proposal ignored: " .. treeActionError
					local rejectedTurn = {
						next = "answer",
						goal = turn.goal,
						reason = "Tree action proposal failed local validation",
					}
					complete(rejectedText, currentState, rejectedTurn, rejectedText)
					return
				end

				local recoveryScopes = currentState.context and currentState.context.treeCandidates
					and nil or { "tree" }
				local recoveryOverrides = self:GetTreeActionRecoveryOverrides(proposedActions, currentState)
				local recoveryState, recoveryContextOrError = self:BuildQuestionState(
					build,
					userMessage,
					requestFingerprint,
					recoveryScopes,
					true,
					recoveryOverrides
				)
				if not recoveryState then
					fail("Could not validate AI tree actions: " .. tostring(recoveryContextOrError))
					return
				end
				recoveryState.context.actionRecovery = treeActionError

				local recoveryFingerprint, recoveryFingerprintError = self:GetBuildFingerprint(build)
				if not recoveryFingerprint then
					fail(recoveryFingerprintError)
					return
				end
				if recoveryFingerprint ~= requestFingerprint then
					fail("Build changed while validating AI tree actions")
					return
				end

				sendRequest(recoveryState, recoveryContextOrError, expansionsUsed + 1, tokenBudget)
				return
			end

			complete(briefContent, currentState, turn, displayText, brief, proposedActions)
		end
		local function onResponse(response, errMsg)
			if responseHandled then
				return
			end
			responseHandled = true
			local handled = pcall(handleResponse, response, errMsg)
			if not handled then
				fail("AI response processing failed")
			end
		end
		local submitted, requestId = pcall(
			launch.DownloadPage,
			launch,
			url,
			onResponse,
			{
				header = header,
				body = requestBody,
				timeout = math.min(AIConfig:GetTimeout() * (tokenBudget > baseTokenBudget and 2 or 1), 600),
			}
		)
		if (not submitted or not requestId) and not responseHandled then
			fail("Could not start AI request")
		end
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

local ACTION_OPEN_TAG_PATTERN = "<[Aa][Cc][Tt][Ii][Oo][Nn][Ss]%s*>"
local ACTION_CLOSE_TAG_PATTERN = "</[Aa][Cc][Tt][Ii][Oo][Nn][Ss]%s*>"
local ACTION_BLOCK_PATTERN = ACTION_OPEN_TAG_PATTERN .. "([%s%S]-)" .. ACTION_CLOSE_TAG_PATTERN
local ACTION_STRIP_PATTERN = ACTION_OPEN_TAG_PATTERN .. "[%s%S]-" .. ACTION_CLOSE_TAG_PATTERN

--- Parse an <actions> JSON block out of an AI response.
-- @param content The raw AI response text
-- @return string displayText The response with action blocks removed
-- @return table|nil actions Parsed action array, or nil if no valid block
-- @return string|nil parseError An actionable explanation for a malformed block
function AIBridge:ParseActions(content)
	if not content then
		return content, nil, nil
	end

	local displayText, blockCount = content:gsub(ACTION_STRIP_PATTERN, "")
	displayText = displayText:gsub("%s+$", "")
	if blockCount == 0 then
		local lowerContent = content:lower()
		if lowerContent:find("<actions", 1, true) or lowerContent:find("</actions", 1, true) then
			return content, nil, "AI returned an incomplete action block"
		end
		return content, nil, nil
	end
	if blockCount ~= 1 then
		return displayText, nil, "AI returned multiple action blocks"
	end

	local block = content:match(ACTION_BLOCK_PATTERN)
	local actions, nextPosition, decodeError = dkjson.decode(block, 1, dkjson.null)
	if decodeError or type(actions) ~= "table"
		or type(nextPosition) ~= "number" or block:sub(nextPosition):find("%S") then
		return displayText, nil, "AI returned an invalid action block"
	end
	local actionMeta = getmetatable(actions)
	if not actionMeta or actionMeta.__jsontype ~= "array" then
		return displayText, nil, "Action block must contain a JSON array"
	end

	return displayText, actions, nil
end

local SUPPORTED_ACTION_TYPES = {
	equip_item = true,
	alloc_node = true,
	dealloc_node = true,
	reset_tree = true,
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
		needsWeapon = (dps <= 0 and attackLacksWeapon(build)) or nil,
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
	-- A percentage of a near-zero base (DPS 0.06 -> 378) is meaningless, so show the amount instead.
	if math.abs(beforeValue) >= 1 then
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
	if after.needsWeapon then
		t_insert(lines, "^8This attack deals no damage without a weapon. Equip one (see Recommended Gear) to see its real damage.")
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

	local cloneOk, shadowBuild = pcall(function()
		return new("CompareEntry"):CompareEntry(snapshotXml, "AI action preflight")
	end)
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

	-- Verify that any skill changes do not over-reserve mana or life (negative unreserved pool).
	local hasSkillAction = false
	for _, action in ipairs(actions) do
		if type(action) == "table" and (action.type == "add_skill" or action.type == "set_main_skill") then
			hasSkillAction = true
			break
		end
	end
	if hasSkillAction and shadowBuild.calcsTab and shadowBuild.calcsTab.mainOutput then
		local out = shadowBuild.calcsTab.mainOutput
		local manaUnreserved = tonumber(out.ManaUnreserved)
		local lifeUnreserved = tonumber(out.LifeUnreserved)
		local function resourceFailure(message)
			return {
				ok = false,
				phase = "preflight",
				results = { { ok = false, msg = message } },
			}
		end
		if manaUnreserved and manaUnreserved < 0 then
			return resourceFailure(string.format(
				"Insufficient unreserved mana after adding skills (ManaUnreserved: %d). Remove an aura or add reservation efficiency.",
				math.floor(manaUnreserved)
			))
		end
		if lifeUnreserved and lifeUnreserved <= 0 then
			return resourceFailure(string.format(
				"Insufficient unreserved life after adding skills (LifeUnreserved: %d).",
				math.floor(lifeUnreserved)
			))
		end
		-- A skill the player cannot pay for is not a recommendation. Skills that were already
		-- unaffordable before this batch are not blamed on it.
		local activeOutput = build and build.calcsTab and build.calcsTab.mainOutput
		local before = collectUnaffordableSkills(activeOutput)
		local unaffordable = { }
		if activeOutput then
			for name in pairs(collectUnaffordableSkills(out)) do
				if not before[name] then
					t_insert(unaffordable, name)
				end
			end
		end
		if #unaffordable > 0 then
			table.sort(unaffordable)
			return resourceFailure(string.format(
				"Cannot afford %s: the cost per use is above the unreserved pool (mana %d, life %d). Use a cheaper skill, fewer reservations or cost reduction.",
				table.concat(unaffordable, ", "),
				math.floor(math.max(manaUnreserved or 0, 0)),
				math.floor(math.max(lifeUnreserved or 0, 0))
			))
		end
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

--- Remove the trailing actions of a passive plan that the point budget cannot pay for.
-- The plan is checked on an isolated clone, exactly as applying it would be, so the player
-- only ever sees a plan that can be applied. Other kinds of failure are left for apply time.
-- @param build Active build
-- @param actions Passive plan actions
-- @return table actions that fit, number of removed actions
function AIBridge:FitPassivePlanToBudget(build, actions)
	local snapshotOk, snapshot = pcall(build.SaveDB, build, "AI passive plan fit")
	if not snapshotOk or not isNonEmptyString(snapshot) then
		return actions, 0
	end
	local current = actions
	for _ = 1, #actions do
		local report = self:PreflightActions(build, current, snapshot)
		if report.ok then
			return current, #actions - #current
		end
		local failure = report.results and report.results[1]
		local failedIndex = failure and failure.index
		if not failedIndex or failedIndex <= 1 or not tostring(failure.msg):find("Not enough", 1, true) then
			return actions, 0
		end
		local shorter = { }
		for index = 1, failedIndex - 1 do
			t_insert(shorter, current[index])
		end
		current = shorter
	end
	return actions, 0
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
	elseif actionType == "reset_tree" then
		return self:ActionResetTree(build, action)
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
	local item = new("Item"):Item(raw)
	if not item or not item.baseName then
		local lines = { }
		for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
			t_insert(lines, line)
		end
		local rarity = (lines[1] or ""):match("^Rarity:%s*(%a+)")
		local baseLine = (rarity == "NORMAL" or rarity == "MAGIC") and lines[2] or lines[3]
		return false, string.format(
			"Invalid item data: PoB has no item base named '%s'. Ask for the gear again.",
			tostring(baseLine or lines[1] or ""):sub(1, 60)
		)
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

	local budgetOk, budgetError = self:ValidateNodeAllocationBudget(build, node)
	if not budgetOk then
		return false, budgetError
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

--- Reset every allocated passive and ascendancy node while retaining class choices.
function AIBridge:ActionResetTree(build)
	local spec = build.spec
	if not spec then
		return false, "No passive tree spec"
	end
	if not spec.ResetNodes then
		return false, "Passive tree cannot be reset"
	end

	spec:ResetNodes()
	if spec.BuildAllDependsAndPaths then
		spec:BuildAllDependsAndPaths()
	end
	if spec.AddUndoState then
		spec:AddUndoState()
	end
	if build.treeTab then
		build.treeTab.modFlag = true
	end
	build.buildFlag = true

	return true, "Reset all passive and ascendancy nodes"
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

--- Set the character level (1-100) and clamp existing gem levels to what is legal at that level
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
	local skillsTab = build.skillsTab
	local skillSet = skillsTab and skillsTab.skillSets and skillsTab.skillSets[skillsTab.activeSkillSetId]
	if skillSet and skillSet.socketGroupList then
		for _, group in ipairs(skillSet.socketGroupList) do
			local changedGroup = false
			for _, gem in ipairs(group.gemList or {}) do
				local gemData = gem.gemData or findGemDataByName(build, gem.nameSpec)
				if gemData then
					local maxLegalLevel = self:GetMaxLegalGemLevel(gemData, level)
					if maxLegalLevel and (tonumber(gem.level) or 20) > maxLegalLevel then
						gem.level = maxLegalLevel
						changedGroup = true
					end
				end
			end
			if changedGroup then
				skillsTab:ProcessSocketGroup(group)
			end
		end
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

--- Change the ascendancy class by name (e.g. "Inquisitor", "Necromancer", or "None")
function AIBridge:ActionSetAscendancy(build, action)
	local spec = build.spec
	if not spec then
		return false, "No passive tree spec"
	end
	local name = action.name
	if not name or name == "" or name:lower() == "none" then
		spec:SelectAscendClass(0)
		build.treeTab.modFlag = true
		build.buildFlag = true
		return true, "Cleared ascendancy"
	end
	local curClass = spec.curClass
	if not curClass or not curClass.classes then
		return false, "No class selected"
	end
	local foundId
	for ascId, ascClass in pairs(curClass.classes) do
		if ascId ~= 0 and ascClass.name and ascClass.name:lower() == name:lower() then
			foundId = ascId
			name = ascClass.name
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
-- Gem levels are capped to what the character level allows. An active skill sent without
-- supports gets the best affordable supports that fit the link budget.
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

	local charLevel = math.max(1, math.min(math.floor(tonumber(build.characterLevel) or 100), 100))
	local socketBudget = self:GetSocketBudget(build, charLevel)
	local currentSocketsUsed = countSocketsUsed(skillSet)
	local groupName = action.label or "unnamed"

	local newGroup = { label = action.label or "", enabled = true, gemList = {} }
	local firstActiveGemData
	local supportCount = 0
	local seenSupports = {}
	for _, gem in ipairs(gems) do
		local name, requestedLevel, quality
		if type(gem) == "string" then
			name, requestedLevel, quality = gem, nil, 0
		else
			name = gem.name
			requestedLevel = gem.level
			quality = gem.quality or 0
		end
		if name then
			name = resolveGemAlias(build, name)
			local gemData = findGemDataByName(build, name)
			local maxLegalLevel, minReqLv = self:GetMaxLegalGemLevel(gemData, charLevel)
			if gemData and not maxLegalLevel then
				return false, string.format(
					"Gem '%s' requires character level %d (current build level is %d)",
					gemData.name or name,
					minReqLv or 1,
					charLevel
				)
			end
			local finalLevel = maxLegalLevel or 20
			if requestedLevel and tonumber(requestedLevel) then
				finalLevel = math.max(1, math.min(math.floor(tonumber(requestedLevel)), finalLevel))
			end
			if gemData and gemData.grantedEffect then
				if gemData.grantedEffect.support then
					if seenSupports[gemData.name] then
						return false, string.format("Support '%s' appears twice in the same link", gemData.name)
					end
					seenSupports[gemData.name] = true
					supportCount = supportCount + 1
				elseif not firstActiveGemData then
					firstActiveGemData = gemData
				end
			end
			t_insert(newGroup.gemList, {
				nameSpec = name,
				level = finalLevel,
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

	local notes = {}
	if firstActiveGemData and supportCount == 0 and #newGroup.gemList == 1
		and (currentSocketsUsed == 0 or not hasSupportlessRole(firstActiveGemData.grantedEffect)) then
		local room = socketBudget.maxMainLinks - 1
		if socketBudget.enforceTotal then
			room = math.min(room, socketBudget.maxTotalSockets - currentSocketsUsed - 1)
		end
		if room > 0 then
			local autoSupports, autoError = self:SelectOptimalSupportGems(build, firstActiveGemData, charLevel, room)
			for _, support in ipairs(autoSupports) do
				t_insert(newGroup.gemList, {
					nameSpec = support.name,
					level = support.level,
					quality = support.quality or 0,
					enabled = true,
					count = 1,
					enableGlobal1 = true,
					enableGlobal2 = false,
				})
			end
			if autoError then
				t_insert(notes, "supports not chosen: " .. autoError)
			end
		end
	end

	if #newGroup.gemList > socketBudget.maxMainLinks then
		return false, string.format(
			"Skill group '%s' has %d linked gems, exceeding the %d-link limit for level %d",
			groupName,
			#newGroup.gemList,
			socketBudget.maxMainLinks,
			charLevel
		)
	end
	local socketsAfter = currentSocketsUsed + #newGroup.gemList
	if socketsAfter > socketBudget.maxTotalSockets then
		if socketBudget.enforceTotal then
			return false, string.format(
				"Adding '%s' (%d gem(s)) exceeds the %d sockets a level %d character has (%d would be used)",
				groupName,
				#newGroup.gemList,
				socketBudget.maxTotalSockets,
				charLevel,
				socketsAfter
			)
		end
		t_insert(notes, string.format(
			"uses %d sockets but gear offers %d", socketsAfter, socketBudget.maxTotalSockets
		))
	end

	skillsTab:ProcessSocketGroup(newGroup)
	local described = {}
	for index, gem in ipairs(newGroup.gemList) do
		if not gem.gemData and not gem.grantedEffect then
			return false, string.format(
				"Gem %d is unknown or unsupported: %s",
				index,
				gem.errMsg or gem.nameSpec or "unknown"
			)
		end
		t_insert(described, string.format("%s L%d", gem.nameSpec or "?", tonumber(gem.level) or 0))
	end
	t_insert(skillSet.socketGroupList, newGroup)
	skillsTab.modFlag = true
	build.buildFlag = true

	local message = string.format(
		"Added skill group '%s' with %d gem(s): %s", groupName, #newGroup.gemList, table.concat(described, ", ")
	)
	if #notes > 0 then
		message = message .. " (" .. table.concat(notes, "; ") .. ")"
	end
	return true, message
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
	local item = new("Item"):Item(raw)
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

	if not node.alloc then
		local budgetOk, budgetError = self:ValidateNodeAllocationBudget(build, node)
		if not budgetOk then
			return false, budgetError
		end
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
