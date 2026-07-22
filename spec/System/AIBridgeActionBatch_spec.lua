local function readFile(path)
	local file = assert(io.open(path, "r"))
	local content = file:read("*a")
	file:close()
	return content
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
end)
