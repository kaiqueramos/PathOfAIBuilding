-- Path of Building AI Integration
-- AIConversation: validates semantic dialogue turns and owns local conversation state
-- cspell:ignore jsontype

local t_insert = table.insert
local dkjson = require "dkjson"

local AIConversation = { }

local TURN_OPEN_TAG_PATTERN = "<[Tt][Uu][Rr][Nn]%s*>"
local TURN_CLOSE_TAG_PATTERN = "</[Tt][Uu][Rr][Nn]%s*>"
local TURN_BLOCK_PATTERN = TURN_OPEN_TAG_PATTERN .. "([%s%S]-)" .. TURN_CLOSE_TAG_PATTERN
local TURN_STRIP_PATTERN = TURN_OPEN_TAG_PATTERN .. "[%s%S]-" .. TURN_CLOSE_TAG_PATTERN

local NEXT_TURN = {
	answer = true,
	clarify = true,
	proposal = true,
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
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
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

local function copyQuestion(question)
	if not question then
		return nil
	end
	local copy = {
		id = question.id,
		prompt = question.prompt,
	}
	if question.options then
		copy.options = { }
		for _, option in ipairs(question.options) do
			t_insert(copy.options, option)
		end
	end
	return copy
end

--- Create a local session. The UI owns the returned table.
function AIConversation:NewSession()
	return {
		state = "idle",
		constraints = { },
		loadedContexts = { },
		contextAttempts = 0,
	}
end

--- Start a request against one immutable build fingerprint.
function AIConversation:BeginRequest(session, fingerprint)
	session = session or self:NewSession()
	if session.fingerprint and session.fingerprint ~= fingerprint then
		if session.clarificationFingerprint or session.state == "awaiting_user" then
			return nil, "Build changed while waiting for clarification"
		end
		session.constraints = { }
		session.pendingQuestion = nil
	end
	if session.state == "awaiting_user" then
		return nil, "Clarification requires a player answer"
	end
	session.loadedContexts = { }
	session.contextAttempts = 0
	session.clarificationFingerprint = nil
	session.fingerprint = fingerprint
	session.state = "understanding"
	return session
end

--- Store a player's answer to the one pending clarification.
function AIConversation:SubmitAnswer(session, answer)
	if not session or session.state ~= "awaiting_user" or not session.pendingQuestion then
		return false, "No clarification is waiting for an answer"
	end
	if not isNonEmptyString(answer) then
		return false, "Clarification answer cannot be empty"
	end
	local questionId = session.pendingQuestion.id
	session.clarificationFingerprint = session.fingerprint
	session.constraints[questionId] = answer
	session.pendingQuestion = nil
	session.state = "understanding"
	return true
end

--- Record local context gathered during this request without exposing an extra user turn.
function AIConversation:RecordContextExpansion(session, scopes)
	if not session then
		return
	end
	session.contextAttempts = session.contextAttempts + 1
	local seen = { }
	for _, scope in ipairs(session.loadedContexts) do
		seen[scope] = true
	end
	for _, scope in ipairs(scopes or { }) do
		if not seen[scope] then
			seen[scope] = true
			t_insert(session.loadedContexts, scope)
		end
	end
	session.state = "gathering_context"
end

--- Return only the state that may help the model continue a clarification.
function AIConversation:GetPromptState(session)
	if not session then
		return { state = "new" }
	end
	local state = {
		state = session.state,
		constraints = session.constraints,
		loadedContexts = session.loadedContexts,
		contextAttempts = session.contextAttempts,
	}
	if session.pendingQuestion then
		state.pendingQuestion = copyQuestion(session.pendingQuestion)
	end
	return state
end

function AIConversation:HasTurnMarker(content)
	local lower = type(content) == "string" and content:lower() or ""
	return lower:find("<turn", 1, true) ~= nil or lower:find("</turn", 1, true) ~= nil
end

--- Validate a decoded turn envelope without changing session state.
function AIConversation:ValidateTurn(turn)
	if type(turn) ~= "table" then
		return false, "Turn block must contain a JSON object"
	end
	local meta = getmetatable(turn)
	if meta and meta.__jsontype == "array" then
		return false, "Turn block must contain a JSON object"
	end
	if not isNonEmptyString(turn.next) or not NEXT_TURN[turn.next] then
		return false, "Turn next must be answer, clarify, or proposal"
	end
	if not isNonEmptyString(turn.goal) then
		return false, "Turn goal must be a non-empty string"
	end
	if not isNonEmptyString(turn.reason) then
		return false, "Turn reason must be a non-empty string"
	end
	if turn.requiredContexts ~= nil then
		local validContexts, contextError = validateDenseStringArray(turn.requiredContexts, "Turn requiredContexts")
		if not validContexts then
			return false, contextError
		end
	end
	if turn.next == "clarify" then
		local question = turn.question
		if type(question) ~= "table" or not isNonEmptyString(question.id)
			or not isNonEmptyString(question.prompt) then
			return false, "Clarify turn requires a question id and prompt"
		end
		if question.options ~= nil then
			local validOptions, optionsError = validateDenseStringArray(question.options, "Clarify question options")
			if not validOptions then
				return false, optionsError
			end
		end
	elseif turn.question ~= nil then
		return false, "Only clarify turns may include a question"
	end
	return true
end

--- Parse exactly one structured <turn> block and return prose without it.
function AIConversation:ParseTurn(content)
	if type(content) ~= "string" then
		return content, nil, "AI response must be text"
	end
	local displayText, blockCount = content:gsub(TURN_STRIP_PATTERN, "")
	displayText = displayText:gsub("%s+$", "")
	if blockCount == 0 then
		if self:HasTurnMarker(content) then
			return content, nil, "AI returned an incomplete turn block"
		end
		return content, nil, "AI response is missing a turn block"
	end
	if blockCount ~= 1 then
		return displayText, nil, "AI returned multiple turn blocks"
	end

	local block = content:match(TURN_BLOCK_PATTERN)
	local turn, nextPosition, decodeError = dkjson.decode(block, 1, dkjson.null)
	if decodeError or type(turn) ~= "table"
		or type(nextPosition) ~= "number" or block:sub(nextPosition):find("%S") then
		return displayText, nil, "AI returned an invalid turn block"
	end
	local valid, validationError = self:ValidateTurn(turn)
	if not valid then
		return displayText, nil, validationError
	end
	return displayText, turn, nil
end

--- Apply one validated final turn to the session after fingerprint verification.
function AIConversation:ApplyTurn(session, turn, fingerprint)
	if not session then
		return false, "Conversation session is missing"
	end
	if session.fingerprint ~= fingerprint then
		return false, "Build changed while preparing the AI response"
	end
	local valid, validationError = self:ValidateTurn(turn)
	if not valid then
		return false, validationError
	end
	session.lastTurn = turn
	if turn.next == "clarify" then
		session.pendingQuestion = copyQuestion(turn.question)
		session.clarificationFingerprint = fingerprint
		session.state = "awaiting_user"
	elseif turn.next == "proposal" then
		session.pendingQuestion = nil
		session.clarificationFingerprint = nil
		session.state = "awaiting_confirmation"
	else
		session.pendingQuestion = nil
		session.clarificationFingerprint = nil
		session.state = "ready"
	end
	return true
end

function AIConversation:AbortRequest(session)
	if session and session.state ~= "awaiting_user" then
		session.state = "idle"
	end
end

return AIConversation
