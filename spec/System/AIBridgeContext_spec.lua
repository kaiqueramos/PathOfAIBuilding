-- cspell:ignore Upvalue arvore alocar devo gemas habilidade melhoram minha nodos suporte
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

describe("AI question context", function()
	it("classifies compact and specialized questions deterministically", function()
		local bridge = LoadModule("Modules/AIBridge")

		local defense = bridge:ClassifyQuestion("Can I tank this boss? Check my EHP and max hit.")
		assert.same({ "defense" }, defense.intents)
		assert.is_false(defense.includeGemShortlist)
		assert.is_false(defense.includeUniqueShortlist)
		assert.is_false(defense.includeTreeCandidates)

		local gems = bridge:ClassifyQuestion("Quais gemas de suporte melhoram minha habilidade?")
		assert.same({ "gems" }, gems.intents)
		assert.is_true(gems.includeGemShortlist)
		assert.is_true(gems.includeGemReference)
		assert.is_false(gems.includeUniqueShortlist)

		local minionStarter = bridge:ClassifyQuestion("Build a minion starter to level 30; which skills should I use?")
		assert.same({ "gems" }, minionStarter.intents)
		assert.is_true(minionStarter.includeGemShortlist)
		assert.is_true(minionStarter.includeGemReference)


		local requestedBuild = bridge:ClassifyQuestion("Cria uma build de minion ate nivel 30 pra mim")
		assert.same({ "gems" }, requestedBuild.intents)
		assert.is_true(requestedBuild.includeGemReference)
		assert.is_true(requestedBuild.includeTreeCandidates)
		assert.is_true(requestedBuild.resetTreePlanning)

		local minionTree = bridge:ClassifyQuestion(
			"Create a minion starter to level 30 and allocate its passive tree"
		)
		assert.same({ "gems", "tree" }, minionTree.intents)
		assert.is_true(minionTree.includeGemReference)
		assert.is_true(minionTree.includeTreeCandidates)

		local items = bridge:ClassifyQuestion("Which unique amulet is best for this build?")
		assert.same({ "items" }, items.intents)
		assert.is_true(items.includeUniqueShortlist)
		assert.is_true(items.includeUniqueReference)
		assert.is_true(items.includeItemBases)
		assert.is_false(items.includeGemShortlist)

		local tree = bridge:ClassifyQuestion("Quais nodos da arvore devo alocar?")
		assert.same({ "tree" }, tree.intents)
		assert.is_true(tree.includeTreeCandidates)
		assert.is_false(tree.includeGemShortlist)
		assert.is_false(tree.includeUniqueShortlist)

		local improve = bridge:ClassifyQuestion("How do I improve this build? Give me the top 3 changes.")
		assert.same({ "improve" }, improve.intents)
		assert.is_true(improve.includeGemShortlist)
		assert.is_true(improve.includeUniqueShortlist)
		assert.is_true(improve.includeTreeCandidates)
		assert.is_false(improve.includeGemReference)
		assert.is_false(improve.includeUniqueReference)

		local broadImprove = bridge:ClassifyQuestion("What should I upgrade first?")
		assert.same({ "improve" }, broadImprove.intents)
		assert.is_true(broadImprove.includeGemShortlist)
		assert.is_true(broadImprove.includeUniqueShortlist)

		local itemUpgrade = bridge:ClassifyQuestion("Quais uniques sao upgrades para mim?")
		assert.same({ "items" }, itemUpgrade.intents)
		assert.is_true(itemUpgrade.includeUniqueShortlist)
		assert.is_false(itemUpgrade.includeGemShortlist)

		local config = bridge:ClassifyQuestion("Set the boss configuration and enemy condition")
		assert.same({ "config" }, config.intents)
		assert.is_true(config.includeConfigReference)

		local compact = bridge:ClassifyQuestion("Explain ignite proliferation")
		assert.same({ "compact" }, compact.intents)
	end)

	it("keeps only the newest contiguous history within budget", function()
		local bridge = LoadModule("Modules/AIBridge")
		local history = {
			{ role = "user", content = "aaaaaa" },
			{ role = "assistant", content = "bbbbbb" },
			{ role = "user", content = "cccccc" },
		}

		local trimmed, used, dropped = bridge:TrimHistory(history, 12)
		assert.are.equal(12, used)
		assert.are.equal(1, dropped)
		assert.are.equal(2, #trimmed)
		assert.are.equal("bbbbbb", trimmed[1].content)
		assert.are.equal("cccccc", trimmed[2].content)

		local oversized = string.rep("x", 100)
		local truncated, truncatedUsed, truncatedDropped = bridge:TrimHistory({
			{ role = "assistant", content = oversized },
		}, 50)
		assert.are.equal(50, truncatedUsed)
		assert.are.equal(0, truncatedDropped)
		assert.are.equal(1, #truncated)
		assert.are.equal(50, #truncated[1].content)
		assert.is_truthy(truncated[1].content:find("truncated", 1, true))
	end)
end)

describe("AI selective build serialization", function()
	before_each(function()
		loadBuildFromXML(readFile("../spec/TestBuilds/3.13/OccVortex.xml"), "AI context regression")
	end)

	it("omits optional catalogs while preserving core build state", function()
		local bridge = LoadModule("Modules/AIBridge")
		local compact = assert(bridge:SerializeBuild(build, {}))
		local full = assert(bridge:SerializeBuild(build))

		assert.is_nil(compact.reference)
		assert.is_nil(compact.tree.availableNodes)
		assert.is_number(compact.stats.TotalEHP)
		assert.is_truthy(next(compact.items))
		assert.is_true(#compact.skills > 0)
		assert.is_truthy(full.reference.gemNames)
		assert.is_truthy(full.reference.uniqueNames)
		assert.is_truthy(full.reference.configKeys)
		assert.is_truthy(full.reference.itemBases)
		assert.is_truthy(full.tree.availableNodes)
		assert.is_true(#dkjson.encode(compact) < #dkjson.encode(full))

		local gemContext = assert(bridge:SerializeBuild(build, { includeGemReference = true }))
		assert.is_truthy(gemContext.reference.gemNames)
		assert.is_nil(gemContext.reference.uniqueNames)
		assert.is_nil(gemContext.reference.configKeys)
		assert.is_nil(gemContext.reference.itemBases)

		local itemContext = assert(bridge:SerializeBuild(build, {
			includeUniqueReference = true,
			includeItemBases = true,
		}))
		assert.is_truthy(itemContext.reference.uniqueNames)
		assert.is_truthy(itemContext.reference.itemBases)
		assert.is_nil(itemContext.reference.gemNames)
		assert.is_nil(itemContext.reference.configKeys)

		local treeContext = assert(bridge:SerializeBuild(build, { includeTreeCandidates = true }))
		assert.is_truthy(treeContext.tree.availableNodes)
		assert.is_nil(treeContext.reference)
	end)

	it("caps tree candidates and point totals at the current level", function()
		local bridge = LoadModule("Modules/AIBridge")
		build.characterLevel = 30
		build.characterLevelAutoMode = false
		build.configTab.input.bandit = "None"
		build.configTab:BuildModList()
		build.spec:ResetNodes()
		build.spec:BuildAllDependsAndPaths()

		local state = assert(bridge:SerializeBuild(build, { includeTreeCandidates = true }))
		assert.are.equal(34, state.tree.pointsTotal)
		assert.are.equal(34, state.tree.pointsAvailable)
		assert.are.equal(0, state.tree.ascendancyTotal)
		assert.are.equal(0, state.tree.ascendancyAvailable)
		for _, candidate in ipairs(state.tree.availableNodes) do
			assert.is_true(candidate.mainPointCost <= state.tree.pointsAvailable)
			assert.are.equal(0, candidate.ascendancyPointCost)
		end
	end)

	it("provides conservative tree candidates for an explicitly requested future level", function()
		local bridge = LoadModule("Modules/AIBridge")
		build.characterLevel = 1
		build.characterLevelAutoMode = false
		build.configTab.input.bandit = "None"
		build.configTab:BuildModList()
		build.spec:ResetNodes()
		build.spec:BuildAllDependsAndPaths()

		local context = bridge:ClassifyQuestion("Cria uma build de minion ate nivel 30 pra mim")
		local state = assert(bridge:SerializeBuild(build, context))
		assert.are.equal(30, context.targetLevel)
		assert.are.equal(1, state.meta.level)
		assert.are.equal(0, state.tree.pointsAvailable)
		assert.are.equal(30, state.tree.planningLevel)
		assert.are.equal(33, state.tree.planningPointsAvailable)
		assert.are.equal(0, state.tree.planningAscendancyAvailable)
		assert.is_true(#state.tree.availableNodes > 0)
		for _, candidate in ipairs(state.tree.availableNodes) do
			assert.is_true(candidate.mainPointCost <= state.tree.planningPointsAvailable)
			assert.are.equal(0, candidate.ascendancyPointCost)
		end
	end)

	it("projects a mechanic-matched plan from an explicitly requested class", function()
		local bridge = LoadModule("Modules/AIBridge")
		build.spec:ResetNodes()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Scion))
		build.characterLevel = 1
		build.characterLevelAutoMode = false

		local context = bridge:ClassifyQuestion("Cria uma build Witch de minions ate nivel 30 starter league")
		local state = assert(bridge:SerializeBuild(build, context))
		assert.are.equal("Witch", context.planningClass)
		assert.is_true(table.concat(context.treeGoals, ","):find("minion", 1, true) ~= nil)
		assert.are.equal("Scion", state.meta.className)
		assert.are.equal("Witch", state.tree.candidateClass)
		assert.is_true(state.tree.candidateResetsTree)
		assert.is_true(#state.tree.recommendedPlan > 0)

		local lordOfTheDead
		for _, candidate in ipairs(state.tree.availableNodes) do
			assert.is_table(candidate.stats)
			assert.is_nil(candidate.id)
			if candidate.name == "Lord of the Dead" then
				lordOfTheDead = candidate
			end
		end
		local hasLordOfTheDead = false
		for _, candidate in ipairs(state.tree.recommendedPlan) do
			assert.are_not.equal("Keystone", candidate.type)
			assert.are_not.equal("Totemic Zeal", candidate.name)
			local text = (candidate.name .. " " .. table.concat(candidate.stats, " ")):lower()
			assert.is_truthy(text:find("minion", 1, true) or text:find("maximum life", 1, true))
			hasLordOfTheDead = hasLordOfTheDead or candidate.name == "Lord of the Dead"
		end
		assert.is_true(hasLordOfTheDead)
		assert.is_table(lordOfTheDead)
		assert.is_truthy(table.concat(lordOfTheDead.stats, " "):find("Raised Zombies", 1, true))

		local planNames = {}
		for _, candidate in ipairs(state.tree.recommendedPlan) do
			planNames[candidate.name] = true
		end
		local outsidePlan
		for _, candidate in ipairs(state.tree.availableNodes) do
			if candidate.type == "Notable" and not planNames[candidate.name] then
				outsidePlan = candidate
				break
			end
		end
		assert.is_table(outsidePlan)

		local validationState = {
			context = { treeCandidates = true },
			meta = state.meta,
			tree = state.tree,
		}
		local valid, validationError = bridge:ValidateTreeActionReferences({
			{ type = "alloc_node", name = lordOfTheDead.name },
		}, validationState)
		assert.is_false(valid)
		assert.is_truthy(validationError:find("set_class Witch first", 1, true))

		valid, validationError = bridge:ValidateTreeActionReferences({
			{ type = "set_class", name = "Witch" },
			{ type = "alloc_node", name = lordOfTheDead.name },
		}, validationState)
		assert.is_false(valid)
		assert.is_truthy(validationError:find("reset_tree first", 1, true))

		valid, validationError = bridge:ValidateTreeActionReferences({
			{ type = "set_class", name = "Witch" },
			{ type = "reset_tree" },
			{ type = "alloc_node", name = lordOfTheDead.name },
		}, validationState)
		assert.is_true(valid, validationError)

		valid, validationError = bridge:ValidateTreeActionReferences({
			{ type = "set_class", name = "Witch" },
			{ type = "reset_tree" },
			{ type = "alloc_node", name = outsidePlan.name },
		}, validationState)
		assert.is_false(valid)
		assert.is_truthy(validationError:find("verified tree plan", 1, true))

		local preflight = bridge:PreflightActions(build, {
			{ type = "set_level", value = 30 },
			{ type = "set_class", name = "Witch" },
			{ type = "reset_tree" },
			{ type = "alloc_node", name = lordOfTheDead.name },
		}, assert(build:SaveDB()))
		assert.is_true(preflight.ok, preflight.results[1] and preflight.results[1].msg)
	end)

	it("requires reset_tree before applying candidates projected from a clean tree", function()
		local bridge = LoadModule("Modules/AIBridge")
		local context = bridge:ClassifyQuestion("Refaz a arvore de minions focando em Raise Zombie")
		local state = assert(bridge:SerializeBuild(build, context))
		assert.is_true(context.resetTreePlanning)
		assert.is_true(state.tree.candidateResetsTree)

		local candidate = assert(state.tree.recommendedPlan[1])
		local validationState = {
			context = { treeCandidates = true },
			meta = state.meta,
			tree = state.tree,
		}
		local valid, validationError = bridge:ValidateTreeActionReferences({
			{ type = "alloc_node", name = candidate.name },
		}, validationState)
		assert.is_false(valid)
		assert.is_truthy(validationError:find("reset_tree first", 1, true))

		valid, validationError = bridge:ValidateTreeActionReferences({
			{ type = "reset_tree" },
			{ type = "alloc_node", name = candidate.name },
		}, validationState)
		assert.is_true(valid, validationError)
	end)

	it("recovers any class-changing tree proposal with projected candidates", function()
		local bridge = LoadModule("Modules/AIBridge")
		build.spec:ResetNodes()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Scion))
		build.characterLevel = 1
		build.characterLevelAutoMode = false

		local message = "Cria uma build Fireball starter ate nivel 30"
		local state = assert(bridge:BuildQuestionState(build, message, "fingerprint"))
		assert.is_nil(state.tree.candidateClass)
		assert.is_true(table.concat(state.context.treeGoals, ","):find("fire", 1, true) ~= nil)
		assert.is_true(table.concat(state.context.treeGoals, ","):find("spell", 1, true) ~= nil)

		local actions = {
			{ type = "set_class", name = "Witch" },
			{ type = "reset_tree" },
			{ type = "alloc_node", name = "Not a Scion candidate" },
		}
		local valid, validationError = bridge:ValidateTreeActionReferences(actions, state)
		assert.is_false(valid)
		assert.is_truthy(validationError:find("projected for set_class Witch", 1, true))

		local overrides = bridge:GetTreeActionRecoveryOverrides(actions, state)
		assert.are.equal("Witch", overrides.planningClass)
		assert.is_true(overrides.resetTreePlanning)
		local projectedState = assert(bridge:BuildQuestionState(
			build,
			message,
			"fingerprint",
			nil,
			true,
			overrides
		))
		for _, plannedNode in ipairs(projectedState.tree.recommendedPlan) do
			assert.is_truthy(
				plannedNode.goalReason:find("spell", 1, true)
					or plannedNode.goalReason:find("fire", 1, true)
					or plannedNode.goalReason:find("life", 1, true)
			)
		end
		assert.are.equal("Witch", projectedState.tree.candidateClass)
		assert.is_true(projectedState.tree.candidateResetsTree)
		local candidate = assert(projectedState.tree.recommendedPlan[1])
		assert.are_not.equal("Keystone", candidate.type)

		valid, validationError = bridge:ValidateTreeActionReferences({
			{ type = "set_class", name = "Witch" },
			{ type = "reset_tree" },
			{ type = "alloc_node", name = candidate.name },
		}, projectedState)
		assert.is_true(valid, validationError)
	end)

	it("supplies canonical gem names for minion starter questions", function()
		local bridge = LoadModule("Modules/AIBridge")
		local context = bridge:ClassifyQuestion("Build a minion starter to level 30; which skills should I use?")
		local state = assert(bridge:SerializeBuild(build, context))
		local hasRagingSpirit = false
		for _, name in ipairs(state.reference.gemNames) do
			if name == "Summon Raging Spirit" then
				hasRagingSpirit = true
				break
			end
		end
		assert.is_true(hasRagingSpirit)
	end)

	it("runs only the simulations selected for the question", function()
		local bridge = LoadModule("Modules/AIBridge")
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

		local defense = assert(bridge:BuildQuestionState(build, "Can I tank?", "fingerprint"))
		assert.are.equal(0, gemCalls)
		assert.are.equal(0, uniqueCalls)
		assert.is_nil(defense.gemShortlist)
		assert.is_nil(defense.uniqueShortlist)
		assert.is_false(defense.context.treeCandidates)

		local gems = assert(bridge:BuildQuestionState(build, "Which support gem should I use?", "fingerprint"))
		assert.are.equal(1, gemCalls)
		assert.are.equal(0, uniqueCalls)
		assert.are.equal("Efficacy", gems.gemShortlist[1].name)
		assert.is_nil(gems.uniqueShortlist)

		local improve = assert(bridge:BuildQuestionState(build, "How do I improve this build?", "fingerprint"))
		assert.are.equal(2, gemCalls)
		assert.are.equal(1, uniqueCalls)
		assert.are.equal("Efficacy", improve.gemShortlist[1].name)
		assert.are.equal("Ashes of the Stars", improve.uniqueShortlist[1].name)
		assert.is_true(improve.context.treeCandidates)

		local mentions = bridge:ExtractMentions(
			"Use Efficacy with Ashes of the Stars.",
			improve
		)
		assert.are.equal(2, #mentions)
		assert.are.equal("gem", mentions[1].type)
		assert.are.equal("unique", mentions[2].type)
	end)

	it("sends a compact bounded request with an unapplied-action correction contract", function()
		local bridge = LoadModule("Modules/AIBridge")
		local aiConfig = findUpvalue(bridge.Ask, "AIConfig")
		assert.is_table(aiConfig)

		local originalValidate = aiConfig.Validate
		local originalGetEndpoint = aiConfig.GetEndpoint
		local originalGetAPIKey = aiConfig.GetAPIKey
		local originalGetModel = aiConfig.GetModel
		local originalGetTimeout = aiConfig.GetTimeout
		local originalDownloadPage = launch.DownloadPage
		local capturedOptions
		local responseContent
		local responseError

		aiConfig.Validate = function() return true end
		aiConfig.GetEndpoint = function() return "https://example.invalid/v1" end
		aiConfig.GetAPIKey = function() return "test-key" end
		aiConfig.GetModel = function() return "test-model" end
		aiConfig.GetTimeout = function() return 73 end
		launch.DownloadPage = function(_, _, callback, options)
			capturedOptions = options
			callback({
				body = '{"choices":[{"message":{"content":"Selective context OK"}}]}',
			}, nil)
		end

		local history = {}
		for index = 1, 6 do
			table.insert(history, {
				role = index % 2 == 0 and "assistant" or "user",
				content = string.rep(tostring(index), 3000),
			})
		end

		local ok, err = pcall(function()
			bridge:Ask(build, "Can I tank this boss?", function(content, callbackError)
				responseContent = content
				responseError = callbackError
			end, history, true)
		end)

		aiConfig.Validate = originalValidate
		aiConfig.GetEndpoint = originalGetEndpoint
		aiConfig.GetAPIKey = originalGetAPIKey
		aiConfig.GetModel = originalGetModel
		aiConfig.GetTimeout = originalGetTimeout
		launch.DownloadPage = originalDownloadPage
		assert(ok, err)
		assert.are.equal("Selective context OK", responseContent)
		assert.is_nil(responseError)
		assert.is_table(capturedOptions)

		assert.are.equal(73, capturedOptions.timeout)
		local request = assert(dkjson.decode(capturedOptions.body))
		assert.is_truthy(request.messages[1].content:find("previous action proposal", 1, true))
		assert.is_truthy(request.messages[1].content:find("NOT applied", 1, true))
		assert.is_truthy(request.messages[1].content:find("exact canonical gem names", 1, true))

		assert.are.equal(6, #request.messages)
		local historyChars = 0
		for index = 2, #request.messages - 1 do
			historyChars = historyChars + #request.messages[index].content
		end
		assert.is_true(historyChars <= bridge.HISTORY_CHAR_BUDGET)

		local userContent = request.messages[#request.messages].content
		local prefix = "Build state (JSON):\n"
		local marker = "\n\nPlayer question:"
		local markerStart = assert(userContent:find(marker, 1, true))
		local stateJson = userContent:sub(#prefix + 1, markerStart - 1)
		local state = assert(dkjson.decode(stateJson))
		assert.same({ "defense" }, state.context.intents)
		assert.is_nil(state.reference)
		assert.is_nil(state.tree.availableNodes)
		assert.is_nil(state.gemShortlist)
		assert.is_nil(state.uniqueShortlist)
	end)

	it("unblocks the bridge after an AI request cannot start", function()
		local bridge = LoadModule("Modules/AIBridge")
		local aiConfig = findUpvalue(bridge.Ask, "AIConfig")
		local originalValidate = aiConfig.Validate
		local originalGetEndpoint = aiConfig.GetEndpoint
		local originalGetAPIKey = aiConfig.GetAPIKey
		local originalGetModel = aiConfig.GetModel
		local originalGetTimeout = aiConfig.GetTimeout
		local originalDownloadPage = launch.DownloadPage
		local firstContent
		local firstError
		local secondContent
		local secondError

		aiConfig.Validate = function() return true end
		aiConfig.GetEndpoint = function() return "https://example.invalid/v1" end
		aiConfig.GetAPIKey = function() return "test-key" end
		aiConfig.GetModel = function() return "test-model" end
		aiConfig.GetTimeout = function() return 73 end
		launch.DownloadPage = function()
			return nil
		end
		bridge:Ask(build, "Can I tank this boss?", function(content, callbackError)
			firstContent = content
			firstError = callbackError
		end, {})

		launch.DownloadPage = function(_, _, callback)
			callback({
				body = '{"choices":[{"message":{"content":"Recovered"}}]}',
			}, nil)
			return 1
		end
		bridge:Ask(build, "Can I tank this boss?", function(content, callbackError)
			secondContent = content
			secondError = callbackError
		end, {})

		aiConfig.Validate = originalValidate
		aiConfig.GetEndpoint = originalGetEndpoint
		aiConfig.GetAPIKey = originalGetAPIKey
		aiConfig.GetModel = originalGetModel
		aiConfig.GetTimeout = originalGetTimeout
		launch.DownloadPage = originalDownloadPage

		assert.is_nil(firstContent)
		assert.are.equal("Could not start AI request", firstError)
		assert.are.equal("Recovered", secondContent)
		assert.is_nil(secondError)
		assert.is_false(bridge.pending)
	end)

	it("recovers when response processing raises after submission", function()
		local bridge = LoadModule("Modules/AIBridge")
		local aiConfig = findUpvalue(bridge.Ask, "AIConfig")
		local originalValidate = aiConfig.Validate
		local originalGetEndpoint = aiConfig.GetEndpoint
		local originalGetAPIKey = aiConfig.GetAPIKey
		local originalGetModel = aiConfig.GetModel
		local originalGetTimeout = aiConfig.GetTimeout
		local originalGetBuildFingerprint = bridge.GetBuildFingerprint
		local originalDownloadPage = launch.DownloadPage
		local fingerprintCalls = 0
		local responseContent
		local responseError

		aiConfig.Validate = function() return true end
		aiConfig.GetEndpoint = function() return "https://example.invalid/v1" end
		aiConfig.GetAPIKey = function() return "test-key" end
		aiConfig.GetModel = function() return "test-model" end
		aiConfig.GetTimeout = function() return 73 end
		bridge.GetBuildFingerprint = function()
			fingerprintCalls = fingerprintCalls + 1
			if fingerprintCalls == 1 then
				return "fingerprint"
			end
			error("fingerprint unavailable")
		end
		launch.DownloadPage = function(_, _, callback)
			callback({
				body = '{"choices":[{"message":{"content":"Response"}}]}',
			}, nil)
			return 1
		end
		bridge:Ask(build, "Can I tank this boss?", function(content, callbackError)
			responseContent = content
			responseError = callbackError
		end, {})

		aiConfig.Validate = originalValidate
		aiConfig.GetEndpoint = originalGetEndpoint
		aiConfig.GetAPIKey = originalGetAPIKey
		aiConfig.GetModel = originalGetModel
		aiConfig.GetTimeout = originalGetTimeout
		bridge.GetBuildFingerprint = originalGetBuildFingerprint
		launch.DownloadPage = originalDownloadPage

		assert.is_nil(responseContent)
		assert.are.equal("AI response processing failed", responseError)
		assert.is_false(bridge.pending)
	end)

	it("includes configured provider options in full build requests", function()
		local bridge = LoadModule("Modules/AIBridge")
		local aiConfig = findUpvalue(bridge.Ask, "AIConfig")
		assert.is_table(aiConfig)

		local originalValidate = aiConfig.Validate
		local originalGetEndpoint = aiConfig.GetEndpoint
		local originalGetAPIKey = aiConfig.GetAPIKey
		local originalGetModel = aiConfig.GetModel
		local originalGetRequestOptions = aiConfig.GetRequestOptions
		local originalGetTimeout = aiConfig.GetTimeout
		local originalDownloadPage = launch.DownloadPage
		local capturedOptions
		local responseContent
		local responseError

		aiConfig.Validate = function() return true end
		aiConfig.GetEndpoint = function() return "https://example.invalid/v1" end
		aiConfig.GetAPIKey = function() return "test-key" end
		aiConfig.GetModel = function() return "test-model" end
		aiConfig.GetRequestOptions = function()
			return {
				thinking = { type = "disabled" },
				service_tier = "priority",
			}
		end
		aiConfig.GetTimeout = function() return 73 end
		launch.DownloadPage = function(_, _, callback, options)
			capturedOptions = options
			callback({
				body = '{"choices":[{"message":{"content":"Direct answer"}}]}',
			}, nil)
		end

		local ok, err = pcall(function()
			bridge:Ask(build, "Can I tank this boss?", function(content, callbackError)
				responseContent = content
				responseError = callbackError
			end, {})
		end)

		aiConfig.Validate = originalValidate
		aiConfig.GetEndpoint = originalGetEndpoint
		aiConfig.GetAPIKey = originalGetAPIKey
		aiConfig.GetModel = originalGetModel
		aiConfig.GetRequestOptions = originalGetRequestOptions
		aiConfig.GetTimeout = originalGetTimeout
		launch.DownloadPage = originalDownloadPage
		assert(ok, err)
		assert.are.equal("Direct answer", responseContent)
		assert.is_nil(responseError)
		local request = assert(dkjson.decode(capturedOptions.body))
		assert.same({
			thinking = { type = "disabled" },
			service_tier = "priority",
		}, {
			thinking = request.thinking,
			service_tier = request.service_tier,
		})
	end)
end)
