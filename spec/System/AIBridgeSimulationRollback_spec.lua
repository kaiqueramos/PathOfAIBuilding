local function readFile(path)
	local file = assert(io.open(path, "r"))
	local content = file:read("*a")
	file:close()
	return content
end

local function mainGroup(activeBuild)
	local skillsTab = assert(activeBuild.skillsTab)
	local skillSet = assert(skillsTab.skillSets[skillsTab.activeSkillSetId])
	return assert(skillSet.socketGroupList[activeBuild.mainSocketGroup or 1])
end

describe("AI shortlist simulation rollback", function()
	before_each(function()
		loadBuildFromXML(readFile("../spec/TestBuilds/3.13/OccVortex.xml"), "AI simulation rollback")
	end)

	it("restores the socket group when gem processing throws", function()
		local bridge = LoadModule("Modules/AIBridge")
		bridge:InvalidateBuildContext()
		local group = mainGroup(build)
		local originalCount = #group.gemList
		local originalFingerprint = assert(bridge:GetBuildFingerprint(build))
		local originalProcess = build.skillsTab.ProcessSocketGroup
		local processCalls = 0
		local injected = false
		build.skillsTab.ProcessSocketGroup = function(self, socketGroup)
			processCalls = processCalls + 1
			if not injected and #socketGroup.gemList > originalCount then
				injected = true
				error("injected gem processing failure")
			end
			return originalProcess(self, socketGroup)
		end

		local ok, err = pcall(bridge.ComputeGemShortlist, bridge, build, 10, true, originalFingerprint)
		build.skillsTab.ProcessSocketGroup = originalProcess

		assert.is_false(ok)
		assert.is_truthy(tostring(err):find("injected gem processing failure", 1, true))
		assert.is_true(injected)
		assert.are.equal(originalCount, #group.gemList)
		assert.are.equal(originalFingerprint, assert(bridge:GetBuildFingerprint(build)))
	end)

	it("restores the socket group when calculation throws", function()
		local bridge = LoadModule("Modules/AIBridge")
		bridge:InvalidateBuildContext()
		local group = mainGroup(build)
		local originalCount = #group.gemList
		local originalFingerprint = assert(bridge:GetBuildFingerprint(build))
		local originalBuildOutput = build.calcsTab.BuildOutput
		local calculationCalls = 0
		build.calcsTab.BuildOutput = function(self)
			calculationCalls = calculationCalls + 1
			if calculationCalls == 2 then
				error("injected gem calculation failure")
			end
			return originalBuildOutput(self)
		end

		local ok, err = pcall(bridge.ComputeGemShortlist, bridge, build, 10, true, originalFingerprint)
		build.calcsTab.BuildOutput = originalBuildOutput

		assert.is_false(ok)
		assert.is_truthy(tostring(err):find("injected gem calculation failure", 1, true))
		assert.is_true(calculationCalls >= 2)
		assert.are.equal(originalCount, #group.gemList)
		assert.are.equal(originalFingerprint, assert(bridge:GetBuildFingerprint(build)))
	end)

	it("preserves the active build after a successful gem shortlist", function()
		local bridge = LoadModule("Modules/AIBridge")
		bridge:InvalidateBuildContext()
		local group = mainGroup(build)
		local originalCount = #group.gemList
		local originalFingerprint = assert(bridge:GetBuildFingerprint(build))

		local results = bridge:ComputeGemShortlist(build, 3, true, originalFingerprint)

		assert.is_table(results)
		assert.is_true(#results > 0)
		assert.is_true(#results <= 3)
		assert.are.equal(originalCount, #group.gemList)
		assert.are.equal(originalFingerprint, assert(bridge:GetBuildFingerprint(build)))
	end)
end)
