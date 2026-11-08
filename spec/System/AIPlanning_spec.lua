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

	it("builds a semantic skill profile and classifies representative passive fixtures (US-004)", function()
		local planning = LoadModule("Modules/AIPlanning")
		local nodeByName = {}
		for _, node in pairs(build.spec.nodes) do
			if node.name and (node.type == "Notable" or node.type == "Keystone") then
				nodeByName[node.name] = node
			end
		end

		-- 1. Fireball hit
		local fireball = assert(planning:BuildSkillProfile(build, "Fireball"))
		assert.is_true(fireball.isSpell)
		assert.is_true(fireball.isHit)
		assert.is_true(fireball.elements.Fire)
		local cls, reason = planning:ClassifyPassiveNode(nodeByName["Heart of Flame"], fireball)
		assert.are.equal("compatible", cls)
		assert.is_truthy(reason:find("fire", 1, true))
		cls, reason = planning:ClassifyPassiveNode(nodeByName["Lord of the Dead"], fireball)
		assert.are.equal("unknown", cls)
		assert.is_truthy(reason:find("minion", 1, true))

		-- 2. Righteous Fire / fire DoT
		local rf = assert(planning:BuildSkillProfile(build, "Righteous Fire"))
		assert.is_true(rf.isDoT)
		assert.is_false(rf.isHit)
		cls, reason = planning:ClassifyPassiveNode(nodeByName["Heart of Flame"], rf)
		assert.are.equal("compatible", cls)

		-- 3. Toxic Rain
		local tr = assert(planning:BuildSkillProfile(build, "Toxic Rain"))
		assert.is_true(tr.isAttack)
		assert.is_true(tr.isProjectile)
		assert.is_true(tr.elements.Chaos)
		cls, reason = planning:ClassifyPassiveNode(nodeByName["Fatal Toxins"], tr)
		assert.are.equal("compatible", cls)
		assert.is_truthy(reason:find("damage over time", 1, true))

		-- 4. Melee attack (Heavy Strike)
		local melee = assert(planning:BuildSkillProfile(build, "Heavy Strike"))
		assert.is_true(melee.isAttack)
		assert.is_true(melee.isMelee)
		cls, reason = planning:ClassifyPassiveNode(nodeByName["Master of the Arena"], melee)
		assert.are.equal("compatible", cls)
		assert.is_truthy(reason:find("melee", 1, true))

		-- 5. Raise Zombie (minion)
		local zombie = assert(planning:BuildSkillProfile(build, "Raise Zombie"))
		assert.is_true(zombie.isMinion)
		assert.is_false(zombie.isSpell)
		cls, reason = planning:ClassifyPassiveNode(nodeByName["Lord of the Dead"], zombie)
		assert.are.equal("compatible", cls)
		assert.is_truthy(reason:find("minion", 1, true))
		cls, reason = planning:ClassifyPassiveNode(nodeByName["Heart of Flame"], zombie)
		assert.are.equal("unknown", cls)
		assert.is_truthy(reason:find("minion", 1, true))

		-- 6. Explosive Trap (trap)
		local trap = assert(planning:BuildSkillProfile(build, "Explosive Trap"))
		assert.is_true(trap.isTrap)
		cls, reason = planning:ClassifyPassiveNode(nodeByName["Saboteur"], trap)
		assert.are.equal("compatible", cls)
		assert.is_truthy(reason:find("trap", 1, true))

		-- Defensive & Keystones
		cls, reason = planning:ClassifyPassiveNode(nodeByName["Constitution"], fireball)
		assert.are.equal("defensive", cls)
		assert.is_truthy(reason:find("life", 1, true))
		cls, reason = planning:ClassifyPassiveNode(nodeByName["Resolute Technique"], melee)
		assert.are.equal("manual_only", cls)
		assert.is_truthy(reason:find("keystone", 1, true))
		cls, reason = planning:ClassifyPassiveNode(nodeByName["Resolute Technique"], melee, { ["resolute technique"] = true })
		assert.are.equal("compatible", cls)
	end)

	it("stores and completes only alloc_node actions in the passive plan stage (US-005)", function()
		local planning = LoadModule("Modules/AIPlanning")
		local _, brief = planning:ParseBrief(validBriefBlock())
		local session = assert(planning:StoreBrief(nil, brief, "fingerprint"))
		assert(planning:ConfirmBrief(session, "fingerprint"))
		session = assert(planning:StoreFoundation(session, { { type = "set_level", value = 30 } }, "fingerprint"))
		assert.is_true(planning:CompleteFoundation(session, "fingerprint-2"))
		assert.are.equal("tree", session.state)

		local invalidPlan = {
			{ type = "set_class", name = "Witch" },
			{ type = "alloc_node", name = "Heart of Flame" },
		}
		local badSession, badErr = planning:StorePassivePlan(session, invalidPlan, "fingerprint-2")
		assert.is_nil(badSession)
		assert.is_truthy(badErr:find("not allowed", 1, true))

		local validPlan = {
			{ type = "alloc_node", name = "Heart of Flame" },
		}
		session = assert(planning:StorePassivePlan(session, validPlan, "fingerprint-2"))
		assert.are.equal("tree_pending", session.state)
		assert.are.equal(1, #session.pendingPassivePlan)

		local completed, completeErr = planning:CompletePassivePlan(session, "fingerprint-3")
		assert.is_true(completed)
		assert.is_nil(completeErr)
		assert.are.equal("tree", session.state)
		assert.is_nil(session.pendingPassivePlan)
	end)

	it("ranks a bounded semantic passive shortlist by isolated PoB simulation and caches by fingerprint (US-006)", function()
		local planning = LoadModule("Modules/AIPlanning")
		local bridge = LoadModule("Modules/AIBridge")

		build.characterLevel = 30
		build.characterLevelAutoMode = false
		build.spec:ResetNodes()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Witch))
		build.spec:BuildAllDependsAndPaths()
		local okSkill = bridge:ActionAddSkill(build, {
			label = "Main",
			gems = { { name = "Fireball", level = 8, quality = 0 } },
		})
		assert.is_true(okSkill)
		assert.is_true((bridge:ActionSetMainSkill(build, { name = "Fireball" })))
		assert.is_true((bridge:RebuildBuild(build)))

		local profile = assert(planning:BuildSkillProfile(build, "Fireball"))
		local mainLimit, ascLimit = bridge:GetPassivePointLimits(build)
		local used, ascUsed = build.spec:CountAllocNodes()
		local candidates = bridge:CollectTreeCandidates(
			build.spec,
			math.max(mainLimit - used, 0),
			math.max(ascLimit - ascUsed, 0),
			{},
			profile
		)
		assert.is_true(#candidates > 0)

		-- Inject one unreachable candidate to verify safe exclusion with a reason
		table.insert(candidates, 1, {
			name = "NonExistentSimulationNode",
			type = "Notable",
			stats = {},
			pathLength = 2,
			mainPointCost = 2,
			ascendancyPointCost = 0,
			goalScore = 200,
			classification = "compatible",
		})

		local fp = assert(bridge:GetBuildFingerprint(build))
		local rankedDamage, excluded = bridge:RankPassiveCandidatesBySimulation(
			build,
			candidates,
			profile,
			"damage",
			fp,
			6
		)
		assert.are.equal(1, #excluded)
		assert.are.equal("NonExistentSimulationNode", excluded[1].name)
		assert.is_truthy(excluded[1].reason:find("not reachable", 1, true))

		local simulatedCount = 0
		for _, c in ipairs(rankedDamage) do
			if c.simulationStatus == "simulated" then
				simulatedCount = simulatedCount + 1
				assert.is_table(c.simulatedDelta)
				assert.are.equal("damage", c.simulatedDelta.priority)
			end
		end
		assert.is_true(simulatedCount > 0 and simulatedCount <= 6)
		assert.are.equal(fp, bridge.treeSimulationFingerprint)
	end)
end)
