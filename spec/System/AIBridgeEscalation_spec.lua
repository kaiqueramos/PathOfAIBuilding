-- cspell:ignore Elementalist Upvalue
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

local function extractState(request)
	local userContent = request.messages[#request.messages].content
	local prefix = "Build state (JSON):\n"
	local marker = "\n\nPlayer question:"
	local markerStart = assert(userContent:find(marker, 1, true))
	return assert(dkjson.decode(userContent:sub(#prefix + 1, markerStart - 1)))
end

local function availableScopeNames(state)
	local names = {}
	for _, entry in ipairs(state.context.availableContexts or {}) do
		table.insert(names, entry.scope)
	end
	return names
end

local function answerTurn(text)
	return text
		.. '\n<turn>{"next":"answer","goal":"answer question","reason":"sufficient PoB context"}</turn>'
end

local function proposalTurn(text)
	return text
		.. '\n<turn>{"next":"proposal","goal":"change the build","reason":"validated proposal"}</turn>'
end

local function withMockedTransport(bridge, responder, run)
	local aiConfig = findUpvalue(bridge.Ask, "AIConfig")
	assert.is_table(aiConfig)
	local originalValidate = aiConfig.Validate
	local originalGetEndpoint = aiConfig.GetEndpoint
	local originalGetAPIKey = aiConfig.GetAPIKey
	local originalGetModel = aiConfig.GetModel
	local originalDownloadPage = launch.DownloadPage
	local requests = {}

	aiConfig.Validate = function() return true end
	aiConfig.GetEndpoint = function() return "https://example.invalid/v1" end
	aiConfig.GetAPIKey = function() return "test-key" end
	aiConfig.GetModel = function() return "test-model" end
	launch.DownloadPage = function(_, _, callback, options)
		local request = assert(dkjson.decode(options.body))
		table.insert(requests, request)
		local content = responder(#requests, request)
		callback({
			body = assert(dkjson.encode({
				choices = { { message = { content = content } } },
			})),
		}, nil)
	end

	local ok, err = pcall(run, requests)
	aiConfig.Validate = originalValidate
	aiConfig.GetEndpoint = originalGetEndpoint
	aiConfig.GetAPIKey = originalGetAPIKey
	aiConfig.GetModel = originalGetModel
	launch.DownloadPage = originalDownloadPage
	assert(ok, err)
end

describe("AI context escalation", function()
	before_each(function()
		loadBuildFromXML(readFile("../spec/TestBuilds/3.13/OccVortex.xml"), "AI escalation regression")
	end)

	it("advertises a compact closed context catalog", function()
		local bridge = LoadModule("Modules/AIBridge")
		local fingerprint = assert(bridge:GetBuildFingerprint(build))
		local state = assert(bridge:BuildQuestionState(build, "Explain this build", fingerprint))

		assert.same({ "compact" }, state.context.intents)
		assert.same({}, state.context.includedContexts)
		assert.same({ "gems", "uniques", "tree", "config" }, availableScopeNames(state))
		assert.are.equal(1, state.context.escalationRemaining)
		assert.is_false(state.context.escalated)
		for _, entry in ipairs(state.context.availableContexts) do
			assert.is_string(entry.provides)
			assert.is_true(#entry.provides > 0)
		end
	end)

	it("parses one allowed context request and ignores surrounding prose", function()
		local bridge = LoadModule("Modules/AIBridge")
		local _, scopes, err = bridge:ParseContextRequest(
			"  \n<context_request>[\"GEMS\",\"tree\",\"gems\"]</context_request>\n"
		)
		assert.is_nil(err)
		assert.same({ "gems", "tree" }, scopes)

		local _, proseScopes, proseErr = bridge:ParseContextRequest(
			"I need a little more data first.\n<context_request>[\"gems\"]</context_request>\nThen I can answer."
		)
		assert.is_nil(proseErr)
		assert.same({ "gems" }, proseScopes)

		local _, unknown, unknownErr = bridge:ParseContextRequest(
			"<context_request>[\"secrets\"]</context_request>"
		)
		local _, withNull, nullErr = bridge:ParseContextRequest(
			"<context_request>[\"gems\",null]</context_request>"
		)
		assert.is_nil(withNull)
		assert.is_truthy(nullErr:find("must be a non-empty string", 1, true))
		assert.is_nil(unknown)
		assert.is_truthy(unknownErr:find("Unknown context scope", 1, true))

		local _, mixed, mixedErr = bridge:ParseContextRequest(
			"<context_request>[\"gems\"]</context_request><actions>[{\"type\":\"set_level\",\"value\":100}]</actions>"
		)
		assert.is_nil(mixed)
		assert.is_truthy(mixedErr:find("cannot include actions", 1, true))

		local _, multiple, multipleErr = bridge:ParseContextRequest(
			"<context_request>[\"gems\"]</context_request><context_request>[\"tree\"]</context_request>"
		)
		assert.is_nil(multiple)
		assert.is_truthy(multipleErr:find("exactly one block", 1, true))

		local _, malformed, malformedErr = bridge:ParseContextRequest(
			"<context_request>[\"gems\"]"
		)
		assert.is_nil(malformed)
		assert.is_truthy(malformedErr:find("Malformed", 1, true))
	end)

	it("calculates only explicitly requested optional blocks", function()
		local bridge = LoadModule("Modules/AIBridge")
		local fingerprint = assert(bridge:GetBuildFingerprint(build))
		local gemCalls = 0
		local uniqueCalls = 0
		bridge.ComputeGemShortlist = function()
			gemCalls = gemCalls + 1
			return { { name = "Efficacy" } }
		end
		bridge.ComputeUniqueShortlist = function()
			uniqueCalls = uniqueCalls + 1
			return { { name = "Ashes of the Stars" } }
		end

		local state = assert(bridge:BuildQuestionState(
			build,
			"Explain this build",
			fingerprint,
			{ "gems" },
			true
		))

		assert.are.equal(1, gemCalls)
		assert.are.equal(0, uniqueCalls)
		assert.are.equal("Efficacy", state.gemShortlist[1].name)
		assert.is_nil(state.uniqueShortlist)
		assert.is_table(state.reference.gemNames)
		assert.is_nil(state.reference.uniqueNames)
		assert.is_nil(state.tree.availableNodes)
		assert.same({ "gems" }, state.context.includedContexts)
		assert.same({ "gems" }, state.context.requestedContexts)
		assert.are.equal(0, state.context.escalationRemaining)
		assert.is_true(state.context.escalated)
	end)

	it("retries once with expanded context and the same bounded history", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackContent
		local callbackError
		local callbackCount = 0
		local history = {
			{ role = "user", content = "Earlier question" },
			{ role = "assistant", content = "Earlier answer" },
		}

		withMockedTransport(bridge, function(attempt)
			if attempt == 1 then
				return '<context_request>["config"]</context_request>'
			end
			return answerTurn("Final answer with real config context")
		end, function(requests)
			bridge:Ask(build, "Explain this build", function(content, err)
				callbackCount = callbackCount + 1
				callbackContent = content
				callbackError = err
			end, history)

			assert.are.equal(2, #requests)
			assert.are.equal(4, #requests[1].messages)
			assert.are.equal(4, #requests[2].messages)
			assert.same(requests[1].messages[2], requests[2].messages[2])
			assert.same(requests[1].messages[3], requests[2].messages[3])
			assert.is_nil(requests[2].messages[4].content:find("<context_request>", 1, true))

			local firstState = extractState(requests[1])
			local expandedState = extractState(requests[2])
			assert.is_false(firstState.context.configReference)
			assert.are.equal(1, firstState.context.escalationRemaining)
			assert.is_true(expandedState.context.configReference)
			assert.same({ "config" }, expandedState.context.requestedContexts)
			assert.same({ "config" }, expandedState.context.includedContexts)
			assert.are.equal(0, expandedState.context.escalationRemaining)
			assert.is_table(expandedState.reference.configKeys)
			assert.is_table(expandedState.config)
			assert.is_not_nil(next(expandedState.config))
			assert.is_nil(expandedState.reference.gemNames)
			assert.is_nil(expandedState.reference.uniqueNames)
		end)

		assert.are.equal(1, callbackCount)
		assert.are.equal("Final answer with real config context", callbackContent)
		assert.is_nil(callbackError)
		assert.is_false(bridge.pending)
	end)

	it("retries when the model wraps an allowed context request in prose", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackContent
		local callbackError

		withMockedTransport(bridge, function(attempt)
			if attempt == 1 then
				return "I need the current configuration before I can answer.\n"
					.. '<context_request>["config"]</context_request>\n'
					.. "Then I will provide the recommendation."
			end
			return answerTurn("Final answer after context recovery")
		end, function(requests)
			bridge:Ask(build, "Explain this build", function(content, err)
				callbackContent = content
				callbackError = err
			end, {})
			assert.are.equal(2, #requests)
			local expandedState = extractState(requests[2])
			assert.same({ "config" }, expandedState.context.requestedContexts)
		end)

		assert.are.equal("Final answer after context recovery", callbackContent)
		assert.is_nil(callbackError)
		assert.is_false(bridge.pending)
	end)

	it("rejects a second context request without a third API call", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackContent
		local callbackError

		withMockedTransport(bridge, function(attempt)
			return attempt == 1
				and '<context_request>["config"]</context_request>'
				or '<context_request>["tree"]</context_request>'
		end, function(requests)
			bridge:Ask(build, "Explain this build", function(content, err)
				callbackContent = content
				callbackError = err
			end, {})
			assert.are.equal(2, #requests)
		end)

		assert.is_nil(callbackContent)
		assert.is_truthy(callbackError:find("more than once", 1, true))
		assert.is_false(bridge.pending)
	end)

	it("discards actions attached to an intermediate context request and retries", function()
		local bridge = LoadModule("Modules/AIBridge")
		local originalLevel = build.characterLevel
		local callbackContent
		local callbackError

		withMockedTransport(bridge, function(attempt)
			if attempt == 1 then
				return '<context_request>["config"]</context_request>\n'
					.. '<actions>[{"type":"set_level","value":100}]</actions>'
			end
			return answerTurn("Final answer after discarding intermediate actions")
		end, function(requests)
			bridge:Ask(build, "Explain this build", function(content, err)
				callbackContent = content
				callbackError = err
			end, {})
			assert.are.equal(2, #requests)
			local expandedState = extractState(requests[2])
			assert.same({ "config" }, expandedState.context.requestedContexts)
		end)

		assert.are.equal(originalLevel, build.characterLevel)
		assert.are.equal("Final answer after discarding intermediate actions", callbackContent)
		assert.is_nil(callbackError)
		assert.is_false(bridge.pending)
	end)

	it("retries with tree candidates before exposing an unsourced allocation", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackContent
		local callbackError

		withMockedTransport(bridge, function(attempt, request)
			if attempt == 1 then
				return proposalTurn("I will allocate the tree.\n"
					.. '<actions>[{"type":"alloc_node","id":21050}]</actions>')
			end
			return answerTurn("Recovered after receiving tree candidates.")
		end, function(requests)
			bridge:Ask(build, "Explain this build", function(content, err)
				callbackContent = content
				callbackError = err
			end, {})

			assert.are.equal(2, #requests)
			local initialState = extractState(requests[1])
			local recoveryState = extractState(requests[2])
			assert.is_false(initialState.context.treeCandidates)
			assert.is_true(recoveryState.context.treeCandidates)
			assert.same({ "tree" }, recoveryState.context.requestedContexts)
			assert.are.equal("alloc_node requires tree context", recoveryState.context.actionRecovery)
		end)

		assert.is_nil(callbackError)
		assert.are.equal("Recovered after receiving tree candidates.", callbackContent)
		assert.is_false(bridge.pending)
	end)

	it("fails safely on an unknown requested scope", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackError

		withMockedTransport(bridge, function()
			return '<context_request>["secrets"]</context_request>'
		end, function(requests)
			bridge:Ask(build, "Explain this build", function(_, err)
				callbackError = err
			end, {})
			assert.are.equal(1, #requests)
		end)

		assert.is_truthy(callbackError:find("Unknown context scope", 1, true))
		assert.is_false(bridge.pending)
	end)

	it("rechecks the fingerprint after calculating requested context", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackError
		bridge.ComputeGemShortlist = function()
			build.characterLevel = build.characterLevel == 100 and 99 or build.characterLevel + 1
			return {}
		end

		withMockedTransport(bridge, function()
			return '<context_request>["gems"]</context_request>'
		end, function(requests)
			bridge:Ask(build, "Explain this build", function(_, err)
				callbackError = err
			end, {})
			assert.are.equal(1, #requests)
		end)

		assert.is_truthy(callbackError:find("changed while preparing additional", 1, true))
		assert.is_false(bridge.pending)
	end)

	it("treats a plain reply without a turn block as a read-only answer", function()
		local bridge = LoadModule("Modules/AIBridge")
		local conversation = LoadModule("Modules/AIConversation")
		local session = conversation:NewSession()
		local callbackContent
		local callbackTurn
		local callbackError

		withMockedTransport(bridge, function()
			return "This response has no turn envelope."
		end, function(requests)
			bridge:Ask(build, "Explain this build", function(content, err, _, turn)
				callbackContent = content
				callbackError = err
				callbackTurn = turn
			end, {}, false, session)
			assert.are.equal(1, #requests)
		end)

		assert.is_nil(callbackError)
		assert.is_truthy(callbackContent:find("no turn envelope", 1, true))
		assert.are.equal("answer", callbackTurn.next)
		assert.are.equal("ready", session.state)
		assert.is_false(bridge.pending)
	end)

	it("still rejects a reply with actions, a brief or a context request but no turn block", function()
		local bridge = LoadModule("Modules/AIBridge")
		local replies = {
			'Do this.\n<actions>[{"type":"set_level","value":100}]</actions>',
			'Direction.\n<brief>{"stage":"brief"}</brief>',
			'<context_request>["gems"]</context_request> and a half-finished turn',
		}
		for _, reply in ipairs(replies) do
			local callbackContent
			local callbackError
			withMockedTransport(bridge, function(count)
				return count == 1 and reply or reply
			end, function()
				bridge:Ask(build, "Explain this build", function(content, err)
					callbackContent = content
					callbackError = err
				end, {})
			end)
			assert.is_nil(callbackContent, reply)
			assert.is_truthy(callbackError, reply)
			assert.is_false(bridge.pending)
		end
	end)

	it("rejects actions attached to an answer turn", function()
		local bridge = LoadModule("Modules/AIBridge")
		local callbackError

		withMockedTransport(bridge, function()
			return "Do this.\n<actions>[{\"type\":\"set_level\",\"value\":100}]</actions>\n"
				.. '<turn>{"next":"answer","goal":"give advice","reason":"enough context"}</turn>'
		end, function()
			bridge:Ask(build, "Explain this build", function(_, err)
				callbackError = err
			end, {})
		end)

		assert.is_truthy(callbackError:find("outside a proposal turn", 1, true))
		assert.is_false(bridge.pending)
	end)


	it("rejects actions attached to a clarification turn", function()
		local bridge = LoadModule("Modules/AIBridge")
		local originalLevel = build.characterLevel
		local callbackContent
		local callbackError

		withMockedTransport(bridge, function()
			return "Choose one.\n<actions>[{\"type\":\"set_level\",\"value\":100}]</actions>\n"
				.. '<turn>{"next":"clarify","goal":"choose priority","reason":"a preference is missing",'
				.. '"question":{"id":"priority","prompt":"Damage or defense?"}}</turn>'
		end, function()
			bridge:Ask(build, "Improve this build", function(content, err)
				callbackContent = content
				callbackError = err
			end, {})
		end)

		assert.is_nil(callbackContent)
		assert.is_truthy(callbackError:find("outside a proposal turn", 1, true))
		assert.are.equal(originalLevel, build.characterLevel)
		assert.is_false(bridge.pending)
	end)

	it("downgrades a malformed proposal action block to read-only advice", function()
		local bridge = LoadModule("Modules/AIBridge")
		local conversation = LoadModule("Modules/AIConversation")
		local session = conversation:NewSession()
		local callbackTurn
		local callbackError

		withMockedTransport(bridge, function()
			return 'Use level 100.\n<actions>{"type":"set_level","value":100}</actions>\n'
				.. '<turn>{"next":"proposal","goal":"raise level","reason":"valid upgrade"}</turn>'
		end, function()
			bridge:Ask(build, "Improve this build", function(_, err, _, turn)
				callbackError = err
				callbackTurn = turn
			end, {}, false, session)
		end)

		assert.is_nil(callbackError)
		assert.are.equal("answer", callbackTurn.next)
		assert.are.equal("ready", session.state)
		assert.is_false(bridge.pending)
	end)
	it("returns a validated clarification turn and keeps its session local", function()
		local bridge = LoadModule("Modules/AIBridge")
		local conversation = LoadModule("Modules/AIConversation")
		local session = conversation:NewSession()
		local callbackContent
		local callbackTurn
		local callbackError

		withMockedTransport(bridge, function()
			return "I need one preference before proposing a change.\n"
				.. '<turn>{"next":"clarify","goal":"choose priority","reason":"damage and defense trade off",'
				.. '"question":{"id":"priority","prompt":"Prioritize damage or defense?",'
				.. '"options":["damage","defense"]}}</turn>'
		end, function()
			bridge:Ask(build, "Improve this build", function(content, err, _, turn)
				callbackContent = content
				callbackError = err
				callbackTurn = turn
			end, {}, false, session)
		end)

		assert.is_nil(callbackError)
		assert.are.equal("I need one preference before proposing a change.", callbackContent)
		assert.are.equal("clarify", callbackTurn.next)
		assert.are.equal("awaiting_user", session.state)
		assert.are.equal("priority", session.pendingQuestion.id)
	end)

	it("stores a validated build brief without mutating PoB", function()
		local bridge = LoadModule("Modules/AIBridge")
		local planning = LoadModule("Modules/AIPlanning")
		local planningSession = planning:NewSession()
		local originalLevel = build.characterLevel
		local callbackContent
		local callbackTurn
		local callbackBrief
		local callbackPlanningSession
		local callbackError

		withMockedTransport(bridge, function()
			return "Review this direction before changing anything.\n"
				.. '<brief>{"stage":"brief","mainSkill":"Fireball","class":"Witch",'
				.. '"ascendancy":"Elementalist","targetLevel":30,"priority":"balanced",'
				.. '"constraints":["league starter"],"assumptions":["no required uniques"]}</brief>\n'
				.. '<turn>{"next":"proposal","goal":"confirm build direction","reason":"brief is complete"}</turn>'
		end, function(requests)
			bridge:Ask(build, "Create a Fireball league starter at level 30", function(content, err, _, turn, brief, session)
				callbackContent = content
				callbackError = err
				callbackTurn = turn
				callbackBrief = brief
				callbackPlanningSession = session
			end, {}, false, nil, planningSession)
			assert.is_truthy(requests[1].messages[#requests[1].messages].content:find(
				"Guided planning session (JSON):", 1, true))
		end)

		assert.is_nil(callbackError)
		assert.are.equal("Review this direction before changing anything.", callbackContent)
		assert.are.equal("proposal", callbackTurn.next)
		assert.are.equal("Fireball", callbackBrief.mainSkill)
		assert.is_true(callbackPlanningSession == planningSession)
		assert.are.equal("brief_pending", planningSession.state)
		assert.are.equal("Fireball", planningSession.pendingBrief.mainSkill)
		assert.are.equal(originalLevel, build.characterLevel)
	end)

	it("rejects an incomplete or executable build brief", function()
		local bridge = LoadModule("Modules/AIBridge")
		local planning = LoadModule("Modules/AIPlanning")
		local planningSession = planning:NewSession()
		local callbackError

		withMockedTransport(bridge, function()
			return '<brief>{"stage":"brief","mainSkill":"Fireball","class":"Witch"}</brief>\n'
				.. '<turn>{"next":"proposal","goal":"confirm build direction","reason":"brief is complete"}</turn>'
		end, function()
			bridge:Ask(build, "Create a build", function(_, err)
				callbackError = err
			end, {}, false, nil, planningSession)
		end)

		assert.is_truthy(callbackError:find("Invalid AI build brief", 1, true))
		assert.are.equal("idle", planningSession.state)
		assert.is_false(bridge.pending)

		callbackError = nil
		withMockedTransport(bridge, function()
			return '<actions>[{"type":"set_level","value":30}]</actions>\n'
				.. '<brief>{"stage":"brief","mainSkill":"Fireball","class":"Witch",'
				.. '"ascendancy":"Elementalist","targetLevel":30,"priority":"balanced",'
				.. '"constraints":[],"assumptions":[]}</brief>\n'
				.. '<turn>{"next":"proposal","goal":"confirm build direction","reason":"brief is complete"}</turn>'
		end, function()
			bridge:Ask(build, "Create a build", function(_, err)
				callbackError = err
			end, {}, false, nil, planningSession)
		end)

		assert.is_truthy(callbackError:find("cannot include executable actions", 1, true))
		assert.are.equal("idle", planningSession.state)
		assert.is_false(bridge.pending)
	end)

	it("stores a foundation proposal only after a confirmed brief", function()
		local bridge = LoadModule("Modules/AIBridge")
		local planning = LoadModule("Modules/AIPlanning")
		local planningSession = planning:NewSession()
		local callbackPlanningSession
		local callbackError

		local brief = {
			stage = "brief",
			mainSkill = "Fireball",
			class = "Witch",
			ascendancy = "Elementalist",
			targetLevel = 30,
			priority = "balanced",
			constraints = { "league starter" },
			assumptions = { "no required uniques" },
		}
		local fingerprint = assert(bridge:GetBuildFingerprint(build))
		planningSession = assert(planning:StoreBrief(planningSession, brief, fingerprint))
		assert(planning:ConfirmBrief(planningSession, fingerprint))

		withMockedTransport(bridge, function()
			return 'Apply this foundation.\n<actions>[{"type":"set_level","value":30}]</actions>\n'
				.. '<turn>{"next":"proposal","goal":"apply foundation","reason":"direction is confirmed"}</turn>'
		end, function()
			bridge:Ask(build, "Apply the foundation", function(_, err, _, _, _, session)
				callbackError = err
				callbackPlanningSession = session
			end, {}, false, nil, planningSession)
		end)

		assert.is_nil(callbackError)
		assert.are.equal("foundation_pending", callbackPlanningSession.state)
		assert.are.equal(1, #callbackPlanningSession.pendingFoundation)
	end)

	it("rejects a foundation proposal with disallowed actions", function()
		local bridge = LoadModule("Modules/AIBridge")
		local planning = LoadModule("Modules/AIPlanning")
		local planningSession = planning:NewSession()
		local callbackError

		local brief = {
			stage = "brief",
			mainSkill = "Fireball",
			class = "Witch",
			ascendancy = "Elementalist",
			targetLevel = 30,
			priority = "balanced",
			constraints = { "league starter" },
			assumptions = { "no required uniques" },
		}
		local fingerprint = assert(bridge:GetBuildFingerprint(build))
		planningSession = assert(planning:StoreBrief(planningSession, brief, fingerprint))
		assert(planning:ConfirmBrief(planningSession, fingerprint))

		withMockedTransport(bridge, function()
			return 'Apply this foundation.\n<actions>[{"type":"alloc_node","name":"Resolute Technique"}]</actions>\n'
				.. '<turn>{"next":"proposal","goal":"apply foundation","reason":"direction is confirmed"}</turn>'
		end, function()
			bridge:Ask(build, "Apply the foundation", function(_, err)
				callbackError = err
			end, {}, false, nil, planningSession)
		end)

		assert.is_truthy(callbackError:find("Invalid AI foundation proposal", 1, true))
		assert.are.equal("brief_confirmed", planningSession.state)
		assert.is_false(bridge.pending)
	end)
end)
