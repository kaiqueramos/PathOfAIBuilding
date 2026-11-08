describe("AI build brief", function()
	local function validBriefBlock()
		return '<brief>{"stage":"brief","mainSkill":"Fireball","class":"Witch",'
			.. '"ascendancy":"Elementalist","targetLevel":30,"priority":"balanced",'
			.. '"constraints":["league starter"],"assumptions":["no required uniques"]}</brief>'
	end

	it("parses and strips one validated non-executable brief", function()
		local planning = LoadModule("Modules/AIPlanning")
		local displayText, brief, err = planning:ParseBrief("This is the proposed direction.\n" .. validBriefBlock())

		assert.is_nil(err)
		assert.are.equal("This is the proposed direction.", displayText)
		assert.are.equal("brief", brief.stage)
		assert.are.equal("Fireball", brief.mainSkill)
		assert.are.equal(30, brief.targetLevel)
		assert.same({ "league starter" }, brief.constraints)
	end)

	it("rejects malformed and incomplete brief blocks", function()
		local planning = LoadModule("Modules/AIPlanning")
		local _, incompleteBrief, incompleteError = planning:ParseBrief(
			'<brief>{"stage":"brief","mainSkill":"Fireball"}</brief>'
		)
		assert.is_nil(incompleteBrief)
		assert.is_truthy(incompleteError:find("class", 1, true))

		local _, malformedBrief, malformedError = planning:ParseBrief("<brief>{bad json}</brief>")
		assert.is_nil(malformedBrief)
		assert.is_truthy(malformedError:find("invalid", 1, true))

		local _, objectArrayBrief, objectArrayError = planning:ParseBrief(
			'<brief>{"stage":"brief","mainSkill":"Fireball","class":"Witch",'
				.. '"ascendancy":"Elementalist","targetLevel":30,"priority":"balanced",'
				.. '"constraints":{},"assumptions":[]}</brief>'
		)
		assert.is_nil(objectArrayBrief)
		assert.is_truthy(objectArrayError:find("constraints", 1, true))
	end)

	it("normalizes numeric brief array entries into strings", function()
		local planning = LoadModule("Modules/AIPlanning")
		local _, brief, err = planning:ParseBrief(
			'<brief>{"stage":"brief","mainSkill":"Fireball","class":"Witch",'
				.. '"ascendancy":"Elementalist","targetLevel":30,"priority":"balanced",'
				.. '"constraints":[1,2],"assumptions":[3]}</brief>'
		)
		assert.is_nil(err)
		assert.same({ "1", "2" }, brief.constraints)
		assert.same({ "3" }, brief.assumptions)
	end)

	it("stores, revises, and confirms only local planning state", function()
		local planning = LoadModule("Modules/AIPlanning")
		local _, brief = planning:ParseBrief(validBriefBlock())
		local session = assert(planning:StoreBrief(nil, brief, "fingerprint"))
		assert.are.equal("brief_pending", session.state)
		assert.are.equal("Fireball", session.pendingBrief.mainSkill)

		assert.is_true(planning:ReviseBrief(session))
		assert.are.equal("brief_revising", session.state)
		assert.is_nil(session.pendingBrief)

		session = assert(planning:StoreBrief(session, brief, "fingerprint"))
		local confirmed, confirmedBrief = planning:ConfirmBrief(session, "fingerprint")
		assert.is_true(confirmed)
		assert.are.equal("brief_confirmed", session.state)
		assert.is_nil(session.pendingBrief)
		assert.are.equal("Fireball", confirmedBrief.mainSkill)
	end)

	it("does not confirm a direction against a changed build fingerprint", function()
		local planning = LoadModule("Modules/AIPlanning")
		local _, brief = planning:ParseBrief(validBriefBlock())
		local session = assert(planning:StoreBrief(nil, brief, "first"))
		local confirmed, err = planning:ConfirmBrief(session, "second")

		assert.is_false(confirmed)
		assert.is_truthy(err:find("Build changed", 1, true))
		assert.are.equal("brief_pending", session.state)
	end)

	it("stores and completes only allowed foundation actions", function()
		local planning = LoadModule("Modules/AIPlanning")
		local _, brief = planning:ParseBrief(validBriefBlock())
		local session = assert(planning:StoreBrief(nil, brief, "fingerprint"))
		assert(planning:ConfirmBrief(session, "fingerprint"))

		local foundation = {
			{ type = "set_level", value = 30 },
			{ type = "set_class", name = "Witch" },
			{ type = "set_ascendancy", name = "Elementalist" },
			{ type = "reset_tree" },
			{ type = "add_skill", label = "Main", gems = { { name = "Fireball", level = 5 } } },
			{ type = "set_main_skill", name = "Fireball" },
		}
		session = assert(planning:StoreFoundation(session, foundation, "fingerprint"))
		assert.are.equal("foundation_pending", session.state)
		assert.are.equal(6, #session.pendingFoundation)

		local completed, completeError = planning:CompleteFoundation(session, "fingerprint")
		assert.is_true(completed)
		assert.is_nil(completeError)
		assert.are.equal("tree", session.state)
		assert.is_nil(session.pendingFoundation)
	end)

	it("rejects foundation batches with disallowed actions", function()
		local planning = LoadModule("Modules/AIPlanning")
		local _, brief = planning:ParseBrief(validBriefBlock())
		local session = assert(planning:StoreBrief(nil, brief, "fingerprint"))
		assert(planning:ConfirmBrief(session, "fingerprint"))

		local invalidFoundation = {
			{ type = "set_level", value = 30 },
			{ type = "alloc_node", name = "Resolute Technique" },
		}
		local storedSession, storeError = planning:StoreFoundation(session, invalidFoundation, "fingerprint")
		assert.is_nil(storedSession)
		assert.is_truthy(storeError:find("not allowed", 1, true))
		assert.are.equal("brief_confirmed", session.state)
	end)
end)
