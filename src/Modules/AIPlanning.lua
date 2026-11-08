-- Path of Building AI Integration
-- AIPlanning: validates and stores a confirmed guided-build direction
-- cspell:ignore Arbalists bitval Elementalist jsontype

local t_insert = table.insert
local m_floor = math.floor
local dkjson = require "dkjson"

local AIPlanning = { }

local BRIEF_OPEN_TAG_PATTERN = "<[Bb][Rr][Ii][Ee][Ff]%s*>"
local BRIEF_CLOSE_TAG_PATTERN = "</[Bb][Rr][Ii][Ee][Ff]%s*>"
local BRIEF_BLOCK_PATTERN = BRIEF_OPEN_TAG_PATTERN .. "([%s%S]-)" .. BRIEF_CLOSE_TAG_PATTERN
local BRIEF_STRIP_PATTERN = BRIEF_OPEN_TAG_PATTERN .. "[%s%S]-" .. BRIEF_CLOSE_TAG_PATTERN

local VALID_PRIORITIES = {
	damage = true,
	defense = true,
	balanced = true,
}
local FOUNDATION_ACTION_TYPES = {
	set_level = true,
	set_class = true,
	set_ascendancy = true,
	reset_tree = true,
	add_skill = true,
	set_main_skill = true,
}
local PASSIVE_PLAN_ACTION_TYPES = {
	alloc_node = true,
}

local band = bit and bit.band or function(a, b)
	local result = 0
	local bitval = 1
	while a > 0 and b > 0 do
		if a % 2 == 1 and b % 2 == 1 then
			result = result + bitval
		end
		bitval = bitval * 2
		a = m_floor(a / 2)
		b = m_floor(b / 2)
	end
	return result
end
local bor = bit and bit.bor or function(a, b)
	local result = 0
	local bitval = 1
	while a > 0 or b > 0 do
		if a % 2 == 1 or b % 2 == 1 then
			result = result + bitval
		end
		bitval = bitval * 2
		a = m_floor(a / 2)
		b = m_floor(b / 2)
	end
	return result
end


local function isNonEmptyString(value)
	return type(value) == "string" and value:find("%S") ~= nil
end

local function validateDenseStringArray(value, label)
	if type(value) ~= "table" then
		return false, label .. " must be an array"
	end
	local meta = getmetatable(value)
	if meta and meta.__jsontype == "object" then
		return false, label .. " must be an array"
	end
	local count = 0
	local highestIndex = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key ~= m_floor(key) then
			return false, label .. " must be a dense array"
		end
		count = count + 1
		highestIndex = math.max(highestIndex, key)
	end
	if count ~= highestIndex then
		return false, label .. " must be a dense array"
	end
	for index, entry in ipairs(value) do
		local entryType = type(entry)
		if entryType ~= "string" and entryType ~= "number" and entryType ~= "boolean" then
			return false, label .. " entry " .. index .. " must be a non-empty string"
		end
		value[index] = tostring(entry)
		if not isNonEmptyString(value[index]) then
			return false, label .. " entry " .. index .. " must be a non-empty string"
		end
	end
	return true
end

local function copyStringArray(values)
	local copy = { }
	for _, value in ipairs(values or { }) do
		t_insert(copy, value)
	end
	return copy
end

local function copyBrief(brief)
	if not brief then
		return nil
	end
	return {
		stage = brief.stage,
		mainSkill = brief.mainSkill,
		class = brief.class,
		ascendancy = brief.ascendancy,
		targetLevel = brief.targetLevel,
		priority = brief.priority,
		constraints = copyStringArray(brief.constraints),
		assumptions = copyStringArray(brief.assumptions),
	}
end

--- Create a local session. The chat UI owns the returned table.
function AIPlanning:NewSession()
	return {
		state = "idle",
	}
end

--- Validate the non-executable brief contract without changing session state.
function AIPlanning:ValidateBrief(brief)
	if type(brief) ~= "table" then
		return false, "Brief block must contain a JSON object"
	end
	local meta = getmetatable(brief)
	if meta and meta.__jsontype == "array" then
		return false, "Brief block must contain a JSON object"
	end
	if brief.stage ~= "brief" then
		return false, "Brief stage must be brief"
	end
	for _, field in ipairs({ "mainSkill", "class", "ascendancy" }) do
		if not isNonEmptyString(brief[field]) then
			return false, "Brief " .. field .. " must be a non-empty string"
		end
	end
	if type(brief.targetLevel) ~= "number" or brief.targetLevel ~= m_floor(brief.targetLevel)
		or brief.targetLevel < 1 or brief.targetLevel > 100 then
		return false, "Brief targetLevel must be an integer from 1 to 100"
	end
	if type(brief.priority) ~= "string" or not VALID_PRIORITIES[brief.priority] then
		return false, "Brief priority must be damage, defense, or balanced"
	end
	local constraintsValid, constraintsError = validateDenseStringArray(brief.constraints, "Brief constraints")
	if not constraintsValid then
		return false, constraintsError
	end
	local assumptionsValid, assumptionsError = validateDenseStringArray(brief.assumptions, "Brief assumptions")
	if not assumptionsValid then
		return false, assumptionsError
	end
	return true
end

function AIPlanning:HasBriefMarker(content)
	local lower = type(content) == "string" and content:lower() or ""
	return lower:find("<brief", 1, true) ~= nil or lower:find("</brief", 1, true) ~= nil
end

--- Parse at most one <brief> block. No brief is valid for ordinary advisor replies.
function AIPlanning:ParseBrief(content)
	if type(content) ~= "string" then
		return content, nil, "AI response must be text"
	end
	local displayText, blockCount = content:gsub(BRIEF_STRIP_PATTERN, "")
	displayText = displayText:gsub("%s+$", "")
	if blockCount == 0 then
		if self:HasBriefMarker(content) then
			return content, nil, "AI returned an incomplete brief block"
		end
		return content, nil, nil
	end
	if blockCount ~= 1 then
		return displayText, nil, "AI returned multiple brief blocks"
	end

	local block = content:match(BRIEF_BLOCK_PATTERN)
	local brief, nextPosition, decodeError = dkjson.decode(block, 1, dkjson.null)
	if decodeError or type(brief) ~= "table"
		or type(nextPosition) ~= "number" or block:sub(nextPosition):find("%S") then
		return displayText, nil, "AI returned an invalid brief block"
	end
	local valid, validationError = self:ValidateBrief(brief)
	if not valid then
		return displayText, nil, validationError
	end
	return displayText, brief, nil
end

--- Store one validated, unconfirmed brief locally. This never touches the PoB build.
function AIPlanning:StoreBrief(session, brief, fingerprint)
	local valid, validationError = self:ValidateBrief(brief)
	if not valid then
		return nil, validationError
	end
	if not isNonEmptyString(fingerprint) then
		return nil, "Build fingerprint is missing"
	end
	session = session or self:NewSession()
	session.pendingBrief = copyBrief(brief)
	session.confirmedBrief = nil
	session.fingerprint = fingerprint
	session.state = "brief_pending"
	return session
end

--- Confirm the local brief only after checking that the PoB build is unchanged.
function AIPlanning:ConfirmBrief(session, fingerprint)
	if not session or session.state ~= "brief_pending" or not session.pendingBrief then
		return false, "No build direction is awaiting confirmation"
	end
	if session.fingerprint ~= fingerprint then
		return false, "Build changed since this direction was proposed. Ask for a new direction."
	end
	session.confirmedBrief = copyBrief(session.pendingBrief)
	session.pendingBrief = nil
	session.state = "brief_confirmed"
	return true, copyBrief(session.confirmedBrief)
end


--- Validate one foundation action batch without changing session state.
function AIPlanning:ValidateFoundationActions(actions)
	if type(actions) ~= "table" then
		return false, "Foundation batch must be an array"
	end
	local meta = getmetatable(actions)
	if meta and meta.__jsontype == "object" then
		return false, "Foundation batch must be an array"
	end
	local count = 0
	local highestIndex = 0
	for key in pairs(actions) do
		if type(key) ~= "number" or key < 1 or key ~= m_floor(key) then
			return false, "Foundation batch must be a dense array"
		end
		count = count + 1
		highestIndex = math.max(highestIndex, key)
	end
	if count ~= highestIndex then
		return false, "Foundation batch must be a dense array"
	end
	if count == 0 then
		return false, "Foundation batch must contain at least one action"
	end
	for index, action in ipairs(actions) do
		if type(action) ~= "table" or type(action.type) ~= "string" then
			return false, "Foundation action " .. index .. " must be an object with a type"
		end
		if not FOUNDATION_ACTION_TYPES[action.type] then
			return false, "Foundation action " .. index .. " is not allowed in the foundation stage"
		end
	end
	return true
end

--- Store one validated, unapplied foundation batch locally.
function AIPlanning:StoreFoundation(session, actions, fingerprint)
	local valid, validationError = self:ValidateFoundationActions(actions)
	if not valid then
		return nil, validationError
	end
	if not isNonEmptyString(fingerprint) then
		return nil, "Build fingerprint is missing"
	end
	if not session or session.state ~= "brief_confirmed" or not session.confirmedBrief then
		return nil, "A confirmed build direction is required before applying a foundation"
	end
	session.pendingFoundation = { }
	for _, action in ipairs(actions) do
		t_insert(session.pendingFoundation, action)
	end
	session.foundationFingerprint = fingerprint
	session.state = "foundation_pending"
	return session
end

--- Advance the local session only after a successful foundation application.
function AIPlanning:CompleteFoundation(session, fingerprint)
	if not session or session.state ~= "foundation_pending" or not session.pendingFoundation then
		return false, "No foundation batch is awaiting application"
	end
	session.pendingFoundation = nil
	session.foundationFingerprint = nil
	session.fingerprint = fingerprint
	session.state = "tree"
	return true
end

--- Validate one passive plan action batch without changing session state.
function AIPlanning:ValidatePassivePlanActions(actions)
	if type(actions) ~= "table" then
		return false, "Passive plan batch must be an array"
	end
	local meta = getmetatable(actions)
	if meta and meta.__jsontype == "object" then
		return false, "Passive plan batch must be an array"
	end
	local count = 0
	local highestIndex = 0
	for key in pairs(actions) do
		if type(key) ~= "number" or key < 1 or key ~= m_floor(key) then
			return false, "Passive plan batch must be a dense array"
		end
		count = count + 1
		highestIndex = math.max(highestIndex, key)
	end
	if count ~= highestIndex then
		return false, "Passive plan batch must be a dense array"
	end
	if count == 0 then
		return false, "Passive plan batch must contain at least one action"
	end
	for index, action in ipairs(actions) do
		if type(action) ~= "table" or type(action.type) ~= "string" then
			return false, "Passive plan action " .. index .. " must be an object with a type"
		end
		if not PASSIVE_PLAN_ACTION_TYPES[action.type] then
			return false, "Passive plan action " .. index .. " is not allowed in the passive tree stage"
		end
		if not isNonEmptyString(action.name) then
			return false, "Passive plan action " .. index .. " must specify an exact node name"
		end
	end
	return true
end

--- Store one validated, unapplied passive plan batch locally.
function AIPlanning:StorePassivePlan(session, actions, fingerprint)
	local valid, validationError = self:ValidatePassivePlanActions(actions)
	if not valid then
		return nil, validationError
	end
	if not isNonEmptyString(fingerprint) then
		return nil, "Build fingerprint is missing"
	end
	if not session or (session.state ~= "tree" and session.state ~= "tree_pending") then
		return nil, "An applied build foundation is required before proposing a passive plan"
	end
	session.pendingPassivePlan = { }
	for _, action in ipairs(actions) do
		t_insert(session.pendingPassivePlan, action)
	end
	session.passivePlanFingerprint = fingerprint
	session.state = "tree_pending"
	return session
end

--- Advance the local session after a successful passive plan application without auto-requesting the next stage.
function AIPlanning:CompletePassivePlan(session, fingerprint)
	if not session or session.state ~= "tree_pending" or not session.pendingPassivePlan then
		return false, "No passive plan is awaiting application"
	end
	session.pendingPassivePlan = nil
	session.passivePlanFingerprint = nil
	session.fingerprint = fingerprint
	session.state = "tree"
	return true
end

local function findGemGrantedEffect(build, skillName)
	local gems = build and build.data and build.data.gems
	if type(gems) ~= "table" or not isNonEmptyString(skillName) then
		return nil
	end
	local target = skillName:lower():gsub("^%s+", ""):gsub("%s+$", "")
	for _, gemData in pairs(gems) do
		if gemData.name and not gemData.unsupported and gemData.name:lower() == target then
			if gemData.grantedEffect and not gemData.grantedEffect.support then
				return gemData.grantedEffect, gemData
			end
		end
	end
	return nil
end

local function resolveActiveMainSkillData(build, skillNameOverride)
	if isNonEmptyString(skillNameOverride) then
		local ge, gemData = findGemGrantedEffect(build, skillNameOverride)
		if ge then
			return ge.name or skillNameOverride, copyTable(ge.skillTypes or { }), copyTable(ge.baseFlags or { }), copyTable(ge.minionSkillTypes or { })
		end
	end

	local envSkill = build and build.calcsTab and build.calcsTab.mainEnv
		and build.calcsTab.mainEnv.player and build.calcsTab.mainEnv.player.mainSkill
	if envSkill and envSkill.activeEffect and envSkill.activeEffect.grantedEffect then
		local ge = envSkill.activeEffect.grantedEffect
		return ge.name or "Main Skill",
			copyTable(envSkill.skillTypes or ge.skillTypes or { }),
			copyTable(envSkill.skillFlags or ge.baseFlags or { }),
			copyTable(envSkill.minionSkillTypes or ge.minionSkillTypes or { })
	end

	local skillsTab = build and build.skillsTab
	local activeSet = skillsTab and skillsTab.skillSets and skillsTab.skillSets[skillsTab.activeSkillSetId]
	local group = activeSet and activeSet.socketGroupList and activeSet.socketGroupList[build.mainSocketGroup or 1]
	if group and group.gemList then
		for _, gem in ipairs(group.gemList) do
			local ge = (gem.gemData and gem.gemData.grantedEffect) or gem.grantedEffect
			if ge and not ge.support then
				return ge.name or gem.nameSpec or "Main Skill",
					copyTable(ge.skillTypes or { }),
					copyTable(ge.baseFlags or { }),
					copyTable(ge.minionSkillTypes or { })
			end
			if isNonEmptyString(gem.nameSpec) then
				local foundGe = findGemGrantedEffect(build, gem.nameSpec)
				if foundGe then
					return foundGe.name or gem.nameSpec,
						copyTable(foundGe.skillTypes or { }),
						copyTable(foundGe.baseFlags or { }),
						copyTable(foundGe.minionSkillTypes or { })
				end
			end
		end
	end
	return nil
end

--- Build a semantic skill profile from PoB's real skillTypes, baseFlags, and calculated state (US-004).
function AIPlanning:BuildSkillProfile(build, skillNameOverride)
	local skillName, skillTypes, baseFlags, minionSkillTypes = resolveActiveMainSkillData(build, skillNameOverride)
	if not skillName or type(SkillType) ~= "table" then
		return nil, "No calculable active main skill is configured"
	end

	local isMinion = (skillTypes[SkillType.Minion] or skillTypes[SkillType.CreatesMinion] or baseFlags.minion) and true or false
	local isTotem = (skillTypes[SkillType.SummonsTotem] or skillTypes[SkillType.Totem] or baseFlags.totem) and true or false
	local isTrap = (skillTypes[SkillType.Trapped] or skillTypes[SkillType.Trap] or baseFlags.trap) and true or false
	local isMine = (skillTypes[SkillType.RemoteMined] or skillTypes[SkillType.Mine] or baseFlags.mine) and true or false
	local isAttack = (not isMinion) and ((skillTypes[SkillType.Attack] or baseFlags.attack) and true or false)
	local isSpell = (not isMinion) and ((skillTypes[SkillType.Spell] or baseFlags.spell) and true or false)
	local isMelee = (not isMinion) and ((skillTypes[SkillType.Melee] or skillTypes[SkillType.MeleeSingleTarget] or baseFlags.melee) and true or false)
	local isProjectile = (not isMinion) and ((skillTypes[SkillType.Projectile] or skillTypes[SkillType.RangedAttack] or skillTypes[SkillType.ProjectileNumber] or baseFlags.projectile) and true or false)
	local isArea = (not isMinion) and ((skillTypes[SkillType.Area] or skillTypes[SkillType.AreaSpell] or baseFlags.area) and true or false)
	local isDoT = (skillTypes[SkillType.DamageOverTime] or skillTypes[SkillType.CausesBurning] or skillTypes[SkillType.DegenOnlySpellDamage] or baseFlags.dot) and true or false
	local isHit = (not isMinion) and ((isAttack or skillTypes[SkillType.Damage] or isProjectile or baseFlags.hit) and not skillTypes[SkillType.DegenOnlySpellDamage]) and true or false
	if skillName == "Righteous Fire" then
		isHit = false
	end

	local elements = {
		Physical = (skillTypes[SkillType.Physical] or isAttack) and true or false,
		Fire = (skillTypes[SkillType.Fire] or skillTypes[SkillType.CausesBurning]) and true or false,
		Cold = skillTypes[SkillType.Cold] and true or false,
		Lightning = skillTypes[SkillType.Lightning] and true or false,
		Chaos = skillTypes[SkillType.Chaos] and true or false,
	}

	local modFlags = 0
	local keywordFlags = 0
	if type(ModFlag) == "table" and type(KeywordFlag) == "table" then
		if isHit then
			modFlags = bor(modFlags, ModFlag.Hit)
			keywordFlags = bor(keywordFlags, KeywordFlag.Hit)
		end
		if isDoT then
			modFlags = bor(modFlags, ModFlag.Dot)
		end
		if isAttack then
			modFlags = bor(modFlags, bor(ModFlag.Attack, ModFlag.Weapon))
			keywordFlags = bor(keywordFlags, KeywordFlag.Attack)
		elseif isSpell then
			modFlags = bor(modFlags, bor(ModFlag.Spell, ModFlag.Cast))
			keywordFlags = bor(keywordFlags, KeywordFlag.Spell)
		end
		if isMelee then
			modFlags = bor(modFlags, bor(ModFlag.Melee, ModFlag.WeaponMelee))
		end
		if isProjectile then
			modFlags = bor(modFlags, bor(ModFlag.Projectile, ModFlag.WeaponRanged))
			if isAttack then
				modFlags = bor(modFlags, ModFlag.Bow)
				keywordFlags = bor(keywordFlags, bor(KeywordFlag.Bow, KeywordFlag.Arrow))
			end
		end
		if isArea then
			modFlags = bor(modFlags, ModFlag.Area)
		end
		if isMinion then
			keywordFlags = bor(keywordFlags, KeywordFlag.Minion)
		end
		if isTotem then
			keywordFlags = bor(keywordFlags, KeywordFlag.Totem)
		end
		if isTrap then
			keywordFlags = bor(keywordFlags, KeywordFlag.Trap)
		end
		if isMine then
			keywordFlags = bor(keywordFlags, KeywordFlag.Mine)
		end
		if elements.Physical then
			keywordFlags = bor(keywordFlags, KeywordFlag.Physical)
			if isDoT then
				keywordFlags = bor(keywordFlags, bor(KeywordFlag.Bleed, KeywordFlag.PhysicalDot))
			end
		end
		if elements.Fire then
			keywordFlags = bor(keywordFlags, KeywordFlag.Fire)
			if isDoT or isHit then
				keywordFlags = bor(keywordFlags, bor(KeywordFlag.Ignite, KeywordFlag.FireDot))
			end
		end
		if elements.Cold then
			keywordFlags = bor(keywordFlags, KeywordFlag.Cold)
			if isDoT then
				keywordFlags = bor(keywordFlags, KeywordFlag.ColdDot)
			end
		end
		if elements.Lightning then
			keywordFlags = bor(keywordFlags, KeywordFlag.Lightning)
			if isDoT then
				keywordFlags = bor(keywordFlags, KeywordFlag.LightningDot)
			end
		end
		if elements.Chaos then
			keywordFlags = bor(keywordFlags, KeywordFlag.Chaos)
			if isDoT or isHit then
				keywordFlags = bor(keywordFlags, bor(KeywordFlag.Poison, KeywordFlag.ChaosDot))
			end
		end
	end

	local categories = { }
	if isMinion then t_insert(categories, "minion") end
	if isTotem then t_insert(categories, "totem") end
	if isTrap then t_insert(categories, "trap") end
	if isMine then t_insert(categories, "mine") end
	if isAttack then t_insert(categories, "attack") end
	if isSpell then t_insert(categories, "spell") end
	if isMelee then t_insert(categories, "melee") end
	if isProjectile then t_insert(categories, "projectile") end
	if isArea then t_insert(categories, "area") end
	if isDoT then t_insert(categories, "damage_over_time") end
	if isHit then t_insert(categories, "hit") end
	if elements.Fire then t_insert(categories, "fire") end
	if elements.Cold then t_insert(categories, "cold") end
	if elements.Lightning then t_insert(categories, "lightning") end
	if elements.Chaos then t_insert(categories, "chaos") end
	if elements.Physical then t_insert(categories, "physical") end

	return {
		skillName = skillName,
		isMinion = isMinion,
		isTotem = isTotem,
		isTrap = isTrap,
		isMine = isMine,
		isAttack = isAttack,
		isSpell = isSpell,
		isMelee = isMelee,
		isProjectile = isProjectile,
		isArea = isArea,
		isDoT = isDoT,
		isHit = isHit,
		elements = elements,
		skillTypes = skillTypes,
		minionSkillTypes = minionSkillTypes,
		modFlags = modFlags,
		keywordFlags = keywordFlags,
		categories = categories,
	}
end

local DEFENSIVE_MOD_REASONS = {
	Life = "maximum life",
	LifeRegen = "life regeneration",
	LifeRegenPercent = "life regeneration",
	EnergyShield = "energy shield",
	EnergyShieldRegen = "energy shield regeneration",
	EnergyShieldRecharge = "energy shield recharge",
	Armour = "armour",
	ArmourDefense = "armour",
	Evasion = "evasion",
	ArmourAndEvasion = "armour and evasion",
	Defences = "defences",
	ElementalResist = "elemental resistances",
	FireResist = "fire resistance",
	ColdResist = "cold resistance",
	LightningResist = "lightning resistance",
	ChaosResist = "chaos resistance",
	ElementalResistMax = "maximum elemental resistances",
	FireResistMax = "maximum fire resistance",
	ColdResistMax = "maximum cold resistance",
	LightningResistMax = "maximum lightning resistance",
	ChaosResistMax = "maximum chaos resistance",
	SpellSuppressionChance = "spell suppression",
	BlockChance = "block chance",
	SpellBlockChance = "spell block chance",
	DamageTaken = "reduced damage taken",
	PhysicalDamageReduction = "physical damage reduction",
	Mana = "maximum mana",
	ManaRegen = "mana regeneration",
	ManaReservationEfficiency = "reservation efficiency",
	ReservationEfficiency = "reservation efficiency",
}

local ELEMENT_FOR_MOD_NAME = {
	FireDamage = "Fire",
	FirePenetration = "Fire",
	FireDotMultiplier = "Fire",
	EnemyIgniteChance = "Fire",
	ColdDamage = "Cold",
	ColdPenetration = "Cold",
	ColdDotMultiplier = "Cold",
	EnemyFreezeChance = "Cold",
	LightningDamage = "Lightning",
	LightningPenetration = "Lightning",
	EnemyShockChance = "Lightning",
	ChaosDamage = "Chaos",
	ChaosPenetration = "Chaos",
	ChaosDotMultiplier = "Chaos",
	PhysicalDamage = "Physical",
	PhysicalDotMultiplier = "Physical",
}

local function checkModFlagsCompatible(profile, mod)
	local mFlags = tonumber(mod.flags) or 0
	local kFlags = tonumber(mod.keywordFlags) or 0
	if mFlags ~= 0 and band(profile.modFlags, mFlags) ~= mFlags then
		return false
	end
	if kFlags ~= 0 then
		if type(MatchKeywordFlags) == "function" then
			if not MatchKeywordFlags(profile.keywordFlags, kFlags) then
				return false
			end
		elseif band(profile.keywordFlags, kFlags) == 0 then
			return false
		end
	end
	for _, tag in ipairs(mod) do
		if type(tag) == "table" and tag.type == "SkillType" and tag.skillType then
			if tag.neg then
				if profile.skillTypes[tag.skillType] then
					return false
				end
			elseif not profile.skillTypes[tag.skillType] then
				return false
			end
		end
	end
	return true
end

local MINION_LIMIT_MODS = {
	ActiveZombieLimit = true,
	ActiveSkeletonLimit = true,
	ActiveSpectreLimit = true,
	ActiveGolemLimit = true,
	ActiveRagingSpiritLimit = true,
	ActiveReaperLimit = true,
	ActiveSpiderLimit = true,
	ActiveArbalistsLimit = true,
	ActiveSentinelOfPurityLimit = true,
	ActiveHolyRelicLimit = true,
	ActivePhantasmLimit = true,
}

local function classifySingleMod(profile, mod)
	if type(mod) ~= "table" or type(mod.name) ~= "string" then
		return nil
	end

	-- Minion-routed modifiers
	if mod.name == "MinionModifier" or mod.name == "ExtraMinionSkill"
		or MINION_LIMIT_MODS[mod.name] then
		if profile.isMinion then
			local innerName = type(mod.value) == "table" and mod.value.mod and mod.value.mod.name or mod.name
			return "compatible", "minion scaling (" .. tostring(innerName) .. ")", 130
		end
		return "incompatible", "minion-only modifier"
	end
	if mod.name == "MinionDamageAppliesToPlayer" or mod.name == "MinionAttackSpeedAppliesToPlayer" then
		if not profile.isMinion then
			return "compatible", "spiritual aid conversion", 70
		end
		return "compatible", "minion hybrid scaling", 90
	end

	-- Totem / Trap / Mine limit or specific mods
	if mod.name == "ActiveTotemLimit" or mod.name:find("^Totem") then
		if profile.isTotem then
			return "compatible", "totem scaling", 125
		end
		return "incompatible", "totem-only modifier"
	end
	if mod.name == "ActiveTrapLimit" or mod.name:find("^Trap") then
		if profile.isTrap then
			return "compatible", "trap scaling", 125
		end
		return "incompatible", "trap-only modifier"
	end
	if mod.name == "ActiveMineLimit" or mod.name:find("^Mine") then
		if profile.isMine then
			return "compatible", "mine scaling", 125
		end
		return "incompatible", "mine-only modifier"
	end

	-- Defensive modifiers apply to the character regardless of main skill
	local defenseReason = DEFENSIVE_MOD_REASONS[mod.name]
	if defenseReason then
		local numVal = tonumber(mod.value)
		if not numVal or numVal > 0 or (mod.name == "DamageTaken" and numVal < 0) then
			local weight = (mod.name == "Life" or mod.name == "SpellSuppressionChance" or mod.name == "ElementalResistMax") and 45 or 30
			return "defensive", defenseReason, weight
		end
	end

	-- For minion builds, non-minion offensive mods on the caster do not scale minions
	if profile.isMinion then
		if mod.name == "AuraEffect" or mod.name == "ExtraAura" then
			return "compatible", "aura scaling for minions", 65
		end
		return "incompatible", "caster/player offensive modifier does not scale minions"
	end

	-- Check flags and keywordFlags against profile
	if not checkModFlagsCompatible(profile, mod) then
		return "incompatible", "modifier flags do not match skill mechanics"
	end

	-- Element-specific offensive mods
	local reqElem = ELEMENT_FOR_MOD_NAME[mod.name]
	if reqElem then
		if not profile.elements[reqElem] then
			return "incompatible", reqElem:lower() .. " modifier does not match skill element"
		end
		if mod.name:find("DotMultiplier", 1, true) and not (profile.isDoT or reqElem == "Fire" or reqElem == "Chaos" or reqElem == "Physical") then
			return "incompatible", "damage over time modifier on non-DoT skill"
		end
		if mod.name:find("Penetration", 1, true) and not profile.isHit then
			return "incompatible", "penetration requires a hitting skill"
		end
		return "compatible", reqElem:lower() .. " damage scaling", 95
	end

	if mod.name == "ElementalDamage" or mod.name == "ElementalPenetration" then
		if not (profile.elements.Fire or profile.elements.Cold or profile.elements.Lightning) then
			return "incompatible", "elemental modifier on non-elemental skill"
		end
		if mod.name == "ElementalPenetration" and not profile.isHit then
			return "incompatible", "penetration requires a hitting skill"
		end
		return "compatible", "elemental damage scaling", 85
	end

	if mod.name == "DotMultiplier" then
		if not (profile.isDoT or profile.elements.Chaos or profile.elements.Fire) then
			return "incompatible", "damage over time multiplier on non-DoT skill"
		end
		return "compatible", "damage over time scaling", 100
	end

	if mod.name == "Damage" then
		return "compatible", "direct damage scaling", 90
	end

	if mod.name == "Speed" then
		if profile.isDoT and not profile.isHit and not profile.isAttack then
			return nil
		end
		return "compatible", (profile.isAttack and "attack speed" or "cast speed"), 75
	end

	if mod.name == "CritChance" or mod.name == "CritMultiplier" then
		if not profile.isHit then
			return "incompatible", "critical strike modifier requires a hitting skill"
		end
		return "compatible", "critical strike scaling", 55
	end

	if mod.name == "Accuracy" then
		if not profile.isAttack then
			return "incompatible", "accuracy only applies to attacks"
		end
		return "compatible", "attack accuracy", 50
	end

	if mod.name == "MeleeWeaponRangeMetre" or mod.name == "UnarmedRangeMetre" or mod.name == "ImpaleEffect" then
		if not profile.isMelee then
			return "incompatible", "melee-only modifier"
		end
		return "compatible", "melee scaling", 65
	end

	if mod.name == "ProjectileSpeed" or mod.name == " PierceCount" then
		if not profile.isProjectile then
			return "incompatible", "projectile-only modifier"
		end
		return "compatible", "projectile scaling", 60
	end

	if mod.name == "AreaOfEffect" then
		if not profile.isArea then
			return "incompatible", "area-only modifier"
		end
		return "compatible", "area of effect scaling", 60
	end

	if mod.name == "Duration" then
		if not (profile.skillTypes and SkillType and profile.skillTypes[SkillType.Duration]) then
			return nil
		end
		return "compatible", "skill duration scaling", 55
	end

	return nil
end

--- Classify a passive tree node semantically against a skill profile (US-004).
--- Returns classification ("compatible"|"defensive"|"manual_only"|"unknown"), reason, and semantic score.
function AIPlanning:ClassifyPassiveNode(node, profile, explicitNodeNames)
	if type(node) ~= "table" or not node.name then
		return "unknown", "missing passive node data", 0
	end
	local lowerName = node.name:lower()
	local isExplicit = explicitNodeNames and explicitNodeNames[lowerName] or false

	if node.type == "Keystone" then
		if isExplicit then
			return "compatible", "explicitly requested keystone", 120
		end
		return "manual_only", "keystone requires explicit player intent", -1000
	end

	if not profile then
		return "unknown", "no active skill profile", 0
	end

	local modList = node.modList
	if type(modList) ~= "table" or #modList == 0 then
		return "unknown", "no parsed passive modifiers", 0
	end

	local compatibleReasons = { }
	local compatibleSeen = { }
	local defensiveReasons = { }
	local defensiveSeen = { }
	local incompatibleReason
	local compatibleScore = 0
	local defensiveScore = 0

	for _, mod in ipairs(modList) do
		local kind, reason, weight = classifySingleMod(profile, mod)
		if kind == "compatible" then
			compatibleScore = compatibleScore + (weight or 60)
			if reason and not compatibleSeen[reason] then
				compatibleSeen[reason] = true
				t_insert(compatibleReasons, reason)
			end
		elseif kind == "defensive" then
			defensiveScore = defensiveScore + (weight or 30)
			if reason and not defensiveSeen[reason] then
				defensiveSeen[reason] = true
				t_insert(defensiveReasons, reason)
			end
		elseif kind == "incompatible" and not incompatibleReason then
			incompatibleReason = reason
		end
	end

	if compatibleScore > 0 then
		local reasons = { table.concat(compatibleReasons, ", ") }
		if #defensiveReasons > 0 then
			t_insert(reasons, table.concat(defensiveReasons, ", "))
		end
		return "compatible", table.concat(reasons, " + "), compatibleScore + m_floor(defensiveScore * 0.5)
	end

	if defensiveScore > 0 then
		return "defensive", table.concat(defensiveReasons, ", "), defensiveScore
	end

	return "unknown", incompatibleReason or "no matching offensive or defensive modifiers for skill profile", 0
end

--- Discard only an unconfirmed brief while retaining the chat history and session constraints.
function AIPlanning:ReviseBrief(session)
	if not session or session.state ~= "brief_pending" or not session.pendingBrief then
		return false, "No unconfirmed build direction is available to revise"
	end
	session.pendingBrief = nil
	session.state = "brief_revising"
	return true
end

--- Return compact local planning state for the next guided planning request.
function AIPlanning:GetPromptState(session)
	if not session then
		return { state = "idle" }
	end
	local state = {
		state = session.state,
	}
	if session.pendingBrief then
		state.pendingBrief = copyBrief(session.pendingBrief)
	end
	if session.confirmedBrief then
		state.confirmedBrief = copyBrief(session.confirmedBrief)
	end
	if session.pendingFoundation then
		state.pendingFoundation = { }
		for _, action in ipairs(session.pendingFoundation) do
			t_insert(state.pendingFoundation, action)
		end
	end
	if session.pendingPassivePlan then
		state.pendingPassivePlan = { }
		for _, action in ipairs(session.pendingPassivePlan) do
			t_insert(state.pendingPassivePlan, action)
		end
	end
	return state
end

function AIPlanning:FormatBrief(brief)
	local valid = self:ValidateBrief(brief)
	if not valid then
		return "^1Invalid build direction"
	end
	local lines = {
		"^7--- Build direction ---",
		"^2Class: " .. brief.class .. " / " .. brief.ascendancy,
		"^2Main skill: " .. brief.mainSkill,
		"^2Target level: " .. brief.targetLevel,
		"^2Priority: " .. brief.priority,
	}
	if #brief.constraints > 0 then
		t_insert(lines, "^8Constraints: " .. table.concat(brief.constraints, ", "))
	end
	if #brief.assumptions > 0 then
		t_insert(lines, "^8Assumptions: " .. table.concat(brief.assumptions, ", "))
	end
	t_insert(lines, "^8Confirm or revise this direction. PoB build is unchanged.")
	return table.concat(lines, "\n")
end

return AIPlanning
