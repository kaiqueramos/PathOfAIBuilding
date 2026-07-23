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
