-- cspell:ignore Upvalue
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

local function changedLevel(level)
	return level == 100 and 99 or level + 1
end

describe("AI safe action batch", function()
	before_each(function()
		loadBuildFromXML(readFile("../spec/TestBuilds/3.13/OccVortex.xml"), "AI action batch regression")
	end)

	it("rejects a structurally invalid batch before touching the build", function()
		local bridge = LoadModule("Modules/AIBridge")
		bridge:InvalidateBuildContext()
		local originalLevel = build.characterLevel
		local fingerprint = assert(bridge:GetBuildFingerprint(build))

		local report = bridge:ApplyActionBatch(build, {
			{ type = "set_level", value = changedLevel(originalLevel) },
			{ type = "unknown_action" },
		}, fingerprint)

		assert.is_false(report.ok)
		assert.is_false(report.applied)
		assert.are.equal("validation", report.phase)
		assert.are.equal(originalLevel, build.characterLevel)
		assert.are.equal(fingerprint, assert(bridge:GetBuildFingerprint(build)))
		assert.is_truthy(report.results[1].msg:find("Action 2 invalid", 1, true))
	end)

	it("rejects a semantic failure after dependent preflight mutations without partial application", function()
		local bridge = LoadModule("Modules/AIBridge")
		bridge:InvalidateBuildContext()
		local originalLevel = build.characterLevel
		local fingerprint = assert(bridge:GetBuildFingerprint(build))

		local report = bridge:ApplyActionBatch(build, {
			{ type = "set_level", value = changedLevel(originalLevel) },
			{ type = "alloc_node", id = 987654321 },
		}, fingerprint)

		assert.is_false(report.ok)
		assert.is_false(report.applied)
		assert.are.equal("preflight", report.phase)
		assert.are.equal(originalLevel, build.characterLevel)
		assert.are.equal(fingerprint, assert(bridge:GetBuildFingerprint(build)))
		assert.is_truthy(report.results[1].msg:find("Action 2 failed preflight", 1, true))
	end)

	it("applies a valid batch, fully rebuilds, and captures calculated metrics", function()
		local bridge = LoadModule("Modules/AIBridge")
		bridge:InvalidateBuildContext()
		local originalLevel = build.characterLevel
		local targetLevel = changedLevel(originalLevel)
		local fingerprint = assert(bridge:GetBuildFingerprint(build))

		local report = bridge:ApplyActionBatch(build, {
			{ type = "set_level", value = targetLevel },
		}, fingerprint)

		assert.is_true(report.ok)
		assert.is_true(report.applied)
		assert.is_false(report.partial)
		assert.are.equal(1, report.appliedCount)
		assert.are.equal(targetLevel, build.characterLevel)
		assert.is_false(build.buildFlag)
		assert.is_number(report.before.dps)
		assert.is_number(report.before.ehp)
		assert.is_number(report.after.dps)
		assert.is_number(report.after.ehp)
		assert.is_number(report.after.maxHits.physical)
		assert.not_equal(fingerprint, assert(bridge:GetBuildFingerprint(build)))

		local diff = table.concat(bridge:FormatMetricDiff(report.before, report.after), "\n")
		assert.is_truthy(diff:find("Real PoB diff", 1, true))
		assert.is_truthy(diff:find("DPS:", 1, true))
		assert.is_truthy(diff:find("EHP:", 1, true))
		assert.is_truthy(diff:find("Passive points used:", 1, true))
	end)

	it("shows the real calculated diff after applying from the chat UI", function()
		local bridge = LoadModule("Modules/AIBridge")
		local chat = build.aiChatTab
		local targetLevel = changedLevel(build.characterLevel)
		chat.pendingActions = { { type = "set_level", value = targetLevel } }
		chat.pendingActionsFingerprint = assert(bridge:GetBuildFingerprint(build))
		chat.controls.applyActions.shown = true

		chat:ApplyPendingActions()

		assert.are.equal(targetLevel, build.characterLevel)
		assert.is_nil(chat.pendingActions)
		assert.is_nil(chat.pendingActionsFingerprint)
		assert.is_false(chat.controls.applyActions.shown)
		assert.are.equal("^2Changes applied", chat.controls.status.label)
		local message = chat.messages[#chat.messages].text
		assert.is_truthy(message:find("Real PoB diff", 1, true))
		assert.is_truthy(message:find("DPS:", 1, true))
		assert.is_truthy(message:find("EHP:", 1, true))
	end)

	it("replaces an unapplied proposal with a fresh actionable correction", function()
		local chat = build.aiChatTab
		local bridge = assert(findUpvalue(chat.SendRequest, "AIBridge"))
		local originalAsk = bridge.Ask
		local originalLevel = build.characterLevel
		local supersedesUnappliedActions
		chat.pendingActions = { { type = "set_level", value = 98 } }
		chat.pendingActionsFingerprint = assert(bridge:GetBuildFingerprint(build))
		chat.controls.applyActions.shown = true

		bridge.Ask = function(_, _, _, callback, _, supersedes, _, planningSession)
			supersedesUnappliedActions = supersedes
			callback([[
Use level 97 instead.
<actions>
[{"type":"set_level","value":97}]
</actions>]], nil, assert(bridge:GetBuildFingerprint(build)), {
				next = "proposal",
				goal = "correct the level",
				reason = "player requested a correction",
			}, nil, planningSession)
		end

		local ok, err = pcall(function()
			chat:SendMessage("Correct the previous suggestion: use level 97 instead.")
		end)
		bridge.Ask = originalAsk

		assert(ok, err)
		assert.is_true(supersedesUnappliedActions)
		assert.same({ { type = "set_level", value = 97 } }, chat.pendingActions)
		assert.is_true(chat.controls.applyActions.shown)
		assert.are.equal(originalLevel, build.characterLevel)
	end)

	it("makes a malformed replacement proposal visible without keeping stale actions", function()
		local chat = build.aiChatTab
		local bridge = assert(findUpvalue(chat.SendRequest, "AIBridge"))
		local originalAsk = bridge.Ask
		local originalLevel = build.characterLevel
		chat.pendingActions = { { type = "set_level", value = 98 } }
		chat.pendingActionsFingerprint = assert(bridge:GetBuildFingerprint(build))
		chat.controls.applyActions.shown = true

		bridge.Ask = function(_, _, _, callback, _, _, _, planningSession)
			callback('Use level 97 instead.\n<actions>{"type":"set_level","value":97}</actions>', nil,
				assert(bridge:GetBuildFingerprint(build)), {
					next = "proposal",
					goal = "correct the level",
					reason = "player requested a correction",
				}, nil, planningSession)
		end
		local ok, err = pcall(function()
			chat:SendMessage("Correct the previous suggestion.")
		end)
		bridge.Ask = originalAsk

		assert(ok, err)
		assert.is_nil(chat.pendingActions)
		assert.is_false(chat.controls.applyActions.shown)
		assert.are.equal("^1Action proposal ignored - ask again", chat.controls.status.label)
		assert.is_truthy(chat.messages[#chat.messages].text:find("Action proposal ignored", 1, true))
		assert.are.equal(originalLevel, build.characterLevel)
	end)

	it("clears an unapplied proposal and recovers after a follow-up request fails", function()
		local chat = build.aiChatTab
		local bridge = assert(findUpvalue(chat.SendRequest, "AIBridge"))
		local originalAsk = bridge.Ask
		local originalLevel = build.characterLevel
		chat.pendingActions = { { type = "set_level", value = 98 } }
		chat.pendingActionsFingerprint = assert(bridge:GetBuildFingerprint(build))
		chat.controls.applyActions.shown = true

		bridge.Ask = function(_, _, _, callback)
			callback(nil, "Connection lost")
		end
		local ok, err = pcall(function()
			chat:SendMessage("Correct the previous suggestion.")
		end)
		bridge.Ask = originalAsk

		assert(ok, err)
		assert.is_false(chat.pending)
		assert.is_nil(chat.pendingActions)
		assert.is_nil(chat.pendingActionsFingerprint)
		assert.is_false(chat.controls.applyActions.shown)
		assert.are.equal("^1Request failed", chat.controls.status.label)
		assert.is_truthy(chat.messages[#chat.messages].text:find("Connection lost", 1, true))
		assert.are.equal(originalLevel, build.characterLevel)
	end)

	it("completes a streaming reply before a fast follow-up replaces it", function()
		local chat = build.aiChatTab
		local bridge = assert(findUpvalue(chat.SendRequest, "AIBridge"))
		local originalAsk = bridge.Ask
		local requestCount = 0

		bridge.Ask = function(_, _, _, callback, _, _, _, planningSession)
			requestCount = requestCount + 1
			callback(requestCount == 1 and "First complete reply." or "Second complete reply.", nil, nil, {
				next = "answer",
				goal = "answer question",
				reason = "sufficient PoB context",
			}, nil, planningSession)
		end
		local ok, err = pcall(function()
			chat:SendMessage("First question.")
			chat:SendMessage("Immediate follow-up.")
		end)
		bridge.Ask = originalAsk

		assert(ok, err)
		assert.are.equal(2, requestCount)
		assert.are.equal("First complete reply.", chat.messages[2].full)
		assert.are.equal(chat.messages[2].full, chat.messages[2].text)
		assert.is_true(chat.streaming)
	end)

	it("recovers the chat when the bridge throws before starting a request", function()
		local chat = build.aiChatTab
		local bridge = assert(findUpvalue(chat.SendRequest, "AIBridge"))
		local originalAsk = bridge.Ask

		bridge.Ask = function(self)
			self.pending = true
			error("serialization failed")
		end
		local ok, err = pcall(function()
			chat:SendMessage("Can I tank this boss?")
		end)
		bridge.Ask = originalAsk

		assert(ok, err)
		assert.is_false(chat.pending)
		assert.is_false(bridge.pending)
		assert.are.equal("^1Request failed", chat.controls.status.label)
		assert.is_truthy(chat.messages[#chat.messages].text:find("AI request crashed", 1, true))
	end)

	it("keeps a clarification answer in the same local conversation session", function()
		local chat = build.aiChatTab
		local bridge = assert(findUpvalue(chat.SendRequest, "AIBridge"))
		local conversation = LoadModule("Modules/AIConversation")
		local originalAsk = bridge.Ask
		local requestCount = 0
		local firstSession

		bridge.Ask = function(_, _, _, callback, _, _, session, planningSession)
			requestCount = requestCount + 1
			local fingerprint = assert(bridge:GetBuildFingerprint(build))
			assert(conversation:BeginRequest(session, fingerprint))
			if requestCount == 1 then
				firstSession = session
				local turn = {
					next = "clarify",
					goal = "choose priority",
					reason = "damage and defense trade off",
					question = {
						id = "priority",
						prompt = "Prioritize damage or defense?",
						options = { "damage", "defense" },
					},
				}
				assert.is_true(conversation:ApplyTurn(session, turn, fingerprint))
				callback("I need one preference.", nil, fingerprint, turn, nil, planningSession)
				return
			end

			assert.are.equal(firstSession, session)
			assert.are.equal("defense", session.constraints.priority)
			local turn = {
				next = "answer",
				goal = "recommend next upgrade",
				reason = "priority is now known",
			}
			assert.is_true(conversation:ApplyTurn(session, turn, fingerprint))
			callback("Prioritize defensive upgrades first.", nil, fingerprint, turn, nil, planningSession)
		end

		local ok, err = pcall(function()
			chat:SendMessage("How should I improve this build?")
			chat:FinishStream()
			chat:SendMessage("defense")
			chat:FinishStream()
		end)
		bridge.Ask = originalAsk

		assert(ok, err)
		assert.are.equal(2, requestCount)
		assert.are.equal("ready", firstSession.state)
		assert.are.equal("^2Ready", chat.controls.status.label)
		assert.is_truthy(chat.messages[2].full:find("Prioritize damage or defense?", 1, true))
		assert.are.equal("Prioritize defensive upgrades first.", chat.messages[#chat.messages].full)
	end)

	it("requests the foundation automatically after confirming a build direction", function()
		local chat = build.aiChatTab
		local bridge = assert(findUpvalue(chat.SendRequest, "AIBridge"))
		local conversation = LoadModule("Modules/AIConversation")
		local planning = LoadModule("Modules/AIPlanning")
		local originalAsk = bridge.Ask
		local originalLevel = build.characterLevel
		local targetLevel = changedLevel(originalLevel)
		local requestCount = 0
		local secondUserMessage

		bridge.Ask = function(_, _, userMessage, callback, _, _, session, planningSession)
			requestCount = requestCount + 1
			local fingerprint = assert(bridge:GetBuildFingerprint(build))
			assert(conversation:BeginRequest(session, fingerprint))
			if requestCount == 1 then
				local turn = {
					next = "proposal",
					goal = "confirm build direction",
					reason = "brief is complete",
				}
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
				assert.is_true(conversation:ApplyTurn(session, turn, fingerprint))
				local storedSession = assert(planning:StoreBrief(planningSession, brief, fingerprint))
				callback("Review this direction.", nil, fingerprint, turn, brief, storedSession)
				return
			end

			secondUserMessage = userMessage
			assert.are.equal("brief_confirmed", planningSession.state)
			local turn = {
				next = "proposal",
				goal = "apply foundation",
				reason = "direction is confirmed",
			}
			local actions = { { type = "set_level", value = targetLevel } }
			assert.is_true(conversation:ApplyTurn(session, turn, fingerprint))
			local storedSession = assert(planning:StoreFoundation(planningSession, actions, fingerprint))
			callback("Apply this foundation.", nil, fingerprint, turn, nil, storedSession)
		end

		local ok, err = pcall(function()
			chat:SendMessage("Create a Fireball league starter at level 30.")
			chat:FinishStream()
			chat:ConfirmBrief()
			chat:FinishStream()
		end)
		bridge.Ask = originalAsk

		assert(ok, err)
		assert.are.equal(2, requestCount)
		assert.is_truthy(secondUserMessage:find("confirmed", 1, true))
		assert.are.equal("foundation_pending", chat.planningSession.state)
		assert.is_true(chat.controls.applyFoundation.shown)
		assert.is_false(chat.controls.confirmBrief.shown)
		assert.is_false(chat.controls.reviseBrief.shown)
		assert.are.equal("^7Review build foundation", chat.controls.status.label)
		assert.are.equal(originalLevel, build.characterLevel)
	end)

	it("revises an unconfirmed brief without losing the conversation", function()
		local chat = build.aiChatTab
		local bridge = assert(findUpvalue(chat.SendRequest, "AIBridge"))
		local conversation = LoadModule("Modules/AIConversation")
		local planning = LoadModule("Modules/AIPlanning")
		local originalAsk = bridge.Ask
		local originalLevel = build.characterLevel
		local requestCount = 0
		local firstPlanningSession
		local secondHistory

		bridge.Ask = function(_, _, _, callback, history, _, session, planningSession)
			requestCount = requestCount + 1
			local fingerprint = assert(bridge:GetBuildFingerprint(build))
			assert(conversation:BeginRequest(session, fingerprint))
			if requestCount == 1 then
				firstPlanningSession = planningSession
				local turn = {
					next = "proposal",
					goal = "confirm build direction",
					reason = "brief is complete",
				}
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
				assert.is_true(conversation:ApplyTurn(session, turn, fingerprint))
				local storedSession = assert(planning:StoreBrief(planningSession, brief, fingerprint))
				callback("Review this direction.", nil, fingerprint, turn, brief, storedSession)
				return
			end

			secondHistory = history
			assert.is_true(planningSession == firstPlanningSession)
			assert.are.equal("brief_revising", planningSession.state)
			local turn = {
				next = "answer",
				goal = "acknowledge revision",
				reason = "revision was received",
			}
			assert.is_true(conversation:ApplyTurn(session, turn, fingerprint))
			callback("I will revise the direction.", nil, fingerprint, turn, nil, planningSession)
		end

		local ok, err = pcall(function()
			chat:SendMessage("Create a Fireball league starter at level 30.")
			chat:FinishStream()
			chat:ReviseBrief()
			chat:SendMessage("Make it defense-first.")
			chat:FinishStream()
		end)
		bridge.Ask = originalAsk

		assert(ok, err)
		assert.are.equal(2, requestCount)
		assert.are.equal("brief_revising", chat.planningSession.state)
		assert.is_nil(chat.planningSession.pendingBrief)
		assert.is_false(chat.controls.confirmBrief.shown)
		assert.is_false(chat.controls.reviseBrief.shown)
		assert.are.equal("Create a Fireball league starter at level 30.", secondHistory[1].content)
		assert.is_truthy(secondHistory[2].content:find("Build direction", 1, true))
		assert.are.equal(originalLevel, build.characterLevel)
	end)

	it("applies a confirmed foundation and advances the planning session", function()
		local chat = build.aiChatTab
		local bridge = assert(findUpvalue(chat.SendRequest, "AIBridge"))
		local conversation = LoadModule("Modules/AIConversation")
		local planning = LoadModule("Modules/AIPlanning")
		local originalAsk = bridge.Ask
		local originalLevel = build.characterLevel
		local targetLevel = changedLevel(originalLevel)
		local requestCount = 0

		bridge.Ask = function(_, _, _, callback, _, _, session, planningSession)
			requestCount = requestCount + 1
			local fingerprint = assert(bridge:GetBuildFingerprint(build))
			assert(conversation:BeginRequest(session, fingerprint))
			if requestCount == 1 then
				local turn = {
					next = "proposal",
					goal = "confirm build direction",
					reason = "brief is complete",
				}
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
				assert.is_true(conversation:ApplyTurn(session, turn, fingerprint))
				local storedSession = assert(planning:StoreBrief(planningSession, brief, fingerprint))
				callback("Review this direction.", nil, fingerprint, turn, brief, storedSession)
				return
			end

			assert.are.equal("brief_confirmed", planningSession.state)
			local turn = {
				next = "proposal",
				goal = "apply foundation",
				reason = "direction is confirmed",
			}
			local actions = { { type = "set_level", value = targetLevel } }
			assert.is_true(conversation:ApplyTurn(session, turn, fingerprint))
			local storedSession = assert(planning:StoreFoundation(planningSession, actions, fingerprint))
			callback("Apply this foundation.", nil, fingerprint, turn, nil, storedSession)
		end

		local ok, err = pcall(function()
			chat:SendMessage("Create a Fireball league starter at level 30.")
			chat:FinishStream()
			chat:ConfirmBrief()
			chat:FinishStream()
			chat:ApplyFoundation()
		end)
		bridge.Ask = originalAsk

		assert(ok, err)
		assert.are.equal(2, requestCount)
		assert.are.equal("tree", chat.planningSession.state)
		assert.is_nil(chat.planningSession.pendingFoundation)
		assert.is_false(chat.controls.applyFoundation.shown)
		assert.are.equal(targetLevel, build.characterLevel)
		assert.are.equal("^2Foundation applied - tree stage ready", chat.controls.status.label)
	end)

	it("proposes and applies a safe passive plan without auto-requesting the next stage (US-005)", function()
		local chat = build.aiChatTab
		local bridge = assert(findUpvalue(chat.SendRequest, "AIBridge"))
		local conversation = LoadModule("Modules/AIConversation")
		local planning = LoadModule("Modules/AIPlanning")
		local originalAsk = bridge.Ask
		local requestCount = 0

		build.characterLevel = 30
		build.characterLevelAutoMode = false
		build.spec:ResetNodes()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Witch))
		build.spec:BuildAllDependsAndPaths()

		local state = assert(bridge:SerializeBuild(build, {
			includeTreeCandidates = true,
			skillProfile = assert(planning:BuildSkillProfile(build, "Fireball")),
		}))
		local plannedNode = assert(state.tree.recommendedPlan[1])

		local fingerprint = assert(bridge:GetBuildFingerprint(build))
		chat.planningSession = {
			state = "tree",
			fingerprint = fingerprint,
			confirmedBrief = {
				stage = "brief",
				mainSkill = "Fireball",
				class = "Witch",
				ascendancy = "Elementalist",
				targetLevel = 30,
				priority = "balanced",
				constraints = { "league starter" },
				assumptions = { "no required uniques" },
			},
		}

		bridge.Ask = function(_, _, _, callback, _, _, session, planningSession)
			requestCount = requestCount + 1
			local fp = assert(bridge:GetBuildFingerprint(build))
			assert(conversation:BeginRequest(session, fp))
			assert.are.equal("tree", planningSession.state)
			local turn = {
				next = "proposal",
				goal = "propose passive plan",
				reason = "foundation is applied",
			}
			local actions = { { type = "alloc_node", name = plannedNode.name } }
			assert.is_true(conversation:ApplyTurn(session, turn, fp))
			local storedSession = assert(planning:StorePassivePlan(planningSession, actions, fp))
			callback("Review this passive plan.", nil, fp, turn, nil, storedSession)
		end

		local ok, err = pcall(function()
			chat:SendMessage("Propose my passive tree plan.")
			chat:FinishStream()
		end)
		assert(ok, err)
		assert.are.equal(1, requestCount)
		assert.are.equal("tree_pending", chat.planningSession.state)
		assert.is_true(chat.controls.applyPassivePlan.shown)
		assert.is_false(chat.controls.applyActions.shown)
		assert.are.equal("^7Review passive plan", chat.controls.status.label)

		local okApply, errApply = pcall(function()
			chat:ApplyPassivePlan()
		end)
		bridge.Ask = originalAsk

		assert(okApply, errApply)
		assert.are.equal(1, requestCount)
		assert.are.equal("tree", chat.planningSession.state)
		assert.is_nil(chat.planningSession.pendingPassivePlan)
		assert.is_false(chat.controls.applyPassivePlan.shown)
		assert.are.equal("^2Passive plan applied", chat.controls.status.label)
	end)
end)
