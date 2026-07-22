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

describe("AI build fingerprint", function()
	before_each(function()
		loadBuildFromXML(readFile("../spec/TestBuilds/3.13/OccVortex.xml"), "AI fingerprint regression")
	end)

	it("is stable and changes with manual build edits", function()
		local bridge = LoadModule("Modules/AIBridge")
		bridge:InvalidateBuildContext()

		local originalLevel = build.characterLevel
		local changedLevel = originalLevel == 100 and 99 or originalLevel + 1
		local initial = assert(bridge:GetBuildFingerprint(build))
		assert.are.equal(initial, assert(bridge:GetBuildFingerprint(build)))

		build.characterLevel = changedLevel
		local changed = assert(bridge:GetBuildFingerprint(build))
		assert.not_equal(initial, changed)

		build.characterLevel = originalLevel
		assert.are.equal(initial, assert(bridge:GetBuildFingerprint(build)))
	end)

	it("invalidates cached advice when the fingerprint changes", function()
		local bridge = LoadModule("Modules/AIBridge")
		bridge:InvalidateBuildContext()
		local initial = assert(bridge:GetBuildFingerprint(build))
		assert.is_true(bridge:SyncBuildFingerprint(initial))

		local gemCache = { marker = "gems" }
		local uniqueCache = { marker = "uniques" }
		bridge.gemShortlistCache = gemCache
		bridge.gemShortlistFingerprint = initial
		bridge.uniqueShortlistCache = uniqueCache
		bridge.uniqueShortlistFingerprint = initial
		bridge.lastMentions = { { type = "unique", name = "Test" } }
		bridge.lastMentionsFingerprint = initial

		assert.is_false(bridge:SyncBuildFingerprint(initial))
		assert.are.equal(gemCache, bridge.gemShortlistCache)
		assert.are.equal(uniqueCache, bridge.uniqueShortlistCache)

		build.characterLevel = build.characterLevel == 100 and 99 or build.characterLevel + 1
		local changed = assert(bridge:GetBuildFingerprint(build))
		assert.is_true(bridge:SyncBuildFingerprint(changed))
		assert.are.equal(changed, bridge.activeBuildFingerprint)
		assert.is_nil(bridge.gemShortlistCache)
		assert.is_nil(bridge.gemShortlistFingerprint)
		assert.is_nil(bridge.uniqueShortlistCache)
		assert.is_nil(bridge.uniqueShortlistFingerprint)
		assert.is_nil(bridge.lastMentions)
		assert.is_nil(bridge.lastMentionsFingerprint)
	end)

	it("refuses stale actions and accepts actions for the current state", function()
		local chat = build.aiChatTab
		local bridge = findUpvalue(chat.SendMessage, "AIBridge")
		assert.is_table(bridge)
		bridge:InvalidateBuildContext()

		local originalLevel = build.characterLevel
		local manualLevel = originalLevel == 100 and 99 or originalLevel + 1
		local suggestedLevel = manualLevel == 100 and 98 or manualLevel + 1
		local responseFingerprint = assert(bridge:GetBuildFingerprint(build))

		chat.pendingActions = { { type = "set_level", value = suggestedLevel } }
		chat.pendingActionsFingerprint = responseFingerprint
		chat.controls.applyActions.shown = true
		build.characterLevel = manualLevel
		chat:ApplyPendingActions()

		assert.are.equal(manualLevel, build.characterLevel)
		assert.is_nil(chat.pendingActions)
		assert.is_nil(chat.pendingActionsFingerprint)
		assert.is_false(chat.controls.applyActions.shown)
		assert.is_truthy(chat.messages[#chat.messages].text:find("Build changed since this suggestion", 1, true))

		local currentFingerprint = assert(bridge:GetBuildFingerprint(build))
		chat.pendingActions = { { type = "set_level", value = suggestedLevel } }
		chat.pendingActionsFingerprint = currentFingerprint
		chat.controls.applyActions.shown = true
		chat:ApplyPendingActions()
		assert.are.equal(suggestedLevel, build.characterLevel)
		assert.is_nil(chat.pendingActionsFingerprint)
	end)
end)
