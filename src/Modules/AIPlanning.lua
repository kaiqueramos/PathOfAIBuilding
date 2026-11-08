-- Path of Building AI Integration
-- AIPlanning: validates and stores a confirmed guided-build direction

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
