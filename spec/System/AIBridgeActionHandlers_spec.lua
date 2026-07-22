local function newFakeBuild()
	local allocatedNode = { id = 1, name = "Allocated Node", type = "Normal", alloc = true, path = {}, linkedId = { 2 } }
	local reachableNode = { id = 2, name = "Reachable Node", type = "Normal", alloc = false, path = {}, linkedId = { 1 } }
	local socketNode = { id = 3, name = "Jewel Socket", type = "Socket", alloc = true, path = {}, linkedId = {} }
	local masteryNode = {
		id = 4,
		name = "Test Mastery",
		type = "Mastery",
		alloc = false,
		path = {},
		linkedId = {},
		masteryEffects = { { effect = 101 } },
	}

	local originalNodes = {
		[1] = allocatedNode,
		[2] = reachableNode,
		[3] = socketNode,
		[4] = masteryNode,
	}
	local tree = {
		nodes = originalNodes,
		classNameMap = { Witch = 3 },
		alternate_ascendancies = { [2] = { name = "Warden" } },
		masteryEffects = { [101] = { id = 101, sd = { "+10 to Intelligence" } } },
		tattoo = {
			nodes = {
				[201] = { id = 201, dn = "Test Tattoo", sd = { "+10 to Strength" }, stats = {} },
			},
		},
	}
	function tree:ProcessStats(node)
		node.processed = true
	end

	local spec = {
		tree = tree,
		nodes = {
			[1] = allocatedNode,
			[2] = reachableNode,
			[3] = socketNode,
			[4] = masteryNode,
		},
		allocNodes = { [1] = allocatedNode, [3] = socketNode },
		jewels = {},
		hashOverrides = {},
		masterySelections = {},
		curClassName = "Witch",
		curClass = { classes = { [1] = { name = "Occultist" } } },
	}
	function spec:AllocNode(node)
		node.alloc = true
		self.allocNodes[node.id] = node
	end
	function spec:DeallocNode(node)
		node.alloc = false
		self.allocNodes[node.id] = nil
	end
	function spec:SelectClass(classId)
		self.selectedClassId = classId
	end
	function spec:SelectAscendClass(ascendancyId)
		self.selectedAscendancyId = ascendancyId
	end
	function spec:SelectSecondaryAscendClass(ascendancyId)
		self.selectedSecondaryAscendancyId = ascendancyId
	end
	function spec:BuildClusterJewelGraphs()
		self.clusterGraphsBuilt = true
	end
	function spec:ReplaceNode(oldNode, newNode)
		self.nodes[oldNode.id] = newNode
		if oldNode.alloc then
			newNode.alloc = true
			self.allocNodes[oldNode.id] = newNode
		end
	end
	function spec:BuildAllDependsAndPaths()
		self.pathsRebuilt = true
	end
	function spec:AddUndoState()
		self.undoAdded = true
	end

	local itemsTab = {
		added = {},
		nextId = 1,
		slots = {
			["Ring 1"] = {
				SetSelItemId = function(slot, itemId)
					slot.selItemId = itemId
				end,
			},
		},
	}
	function itemsTab:AddItem(item)
		item.id = self.nextId
		self.nextId = self.nextId + 1
		table.insert(self.added, item)
	end
	function itemsTab:PopulateSlots()
		self.slotsPopulated = true
	end
	function itemsTab:AddUndoState()
		self.undoAdded = true
	end

	local mainGroup = {
		label = "Main",
		enabled = true,
		gemList = { { nameSpec = "Fireball", gemData = { grantedEffect = {} } } },
		displaySkillList = { { name = "Fireball" }, { name = "Vaal Fireball" } },
		mainActiveSkill = 1,
	}
	local skillSet = { socketGroupList = { mainGroup } }
	local skillsTab = {
		activeSkillSetId = 1,
		skillSets = { [1] = skillSet },
		modFlag = false,
	}
	function skillsTab:ProcessSocketGroup(group)
		self.processedGroup = group
		for _, gem in ipairs(group.gemList or {}) do
			if gem.nameSpec == "Fireball" or gem.nameSpec == "Combustion" then
				gem.gemData = gem.gemData or { grantedEffect = {} }
				gem.errMsg = nil
			else
				gem.gemData = nil
				gem.grantedEffect = nil
				gem.errMsg = "Unknown gem: " .. tostring(gem.nameSpec)
			end
		end
	end

	local configTab = {
		input = {
			testFlag = false,
			bandit = "None",
			pantheonMajorGod = "None",
			pantheonMinorGod = "None",
		},
		modFlag = false,
	}
	function configTab:BuildModList()
		self.modListBuilt = true
	end

	local levelControl = {}
	function levelControl:SetText(value)
		self.value = value
	end

	return {
		characterLevel = 90,
		characterLevelAutoMode = true,
		mainSocketGroup = 99,
		buildFlag = false,
		spec = spec,
		treeTab = { modFlag = false },
		itemsTab = itemsTab,
		skillsTab = skillsTab,
		configTab = configTab,
		controls = { characterLevel = levelControl },
		data = {
			pantheons = {
				TheBrineKing = { isMajorGod = true },
				Gruthkul = { isMajorGod = false },
			},
		},
	}
end

local CASES = {
	{
		name = "equip_item",
		action = {
			type = "equip_item", slot = "Ring 1",
			raw = "Rarity: Rare\nAI Test Ring\nCoral Ring\nImplicits: 0\n+10 to maximum Life",
		},
		verify = function(fake)
			assert.are.equal(1, #fake.itemsTab.added)
			assert.are.equal(fake.itemsTab.added[1].id, fake.itemsTab.slots["Ring 1"].selItemId)
		end,
	},
	{
		name = "alloc_node", action = { type = "alloc_node", id = 2 },
		verify = function(fake) assert.is_true(fake.spec.nodes[2].alloc) end,
	},
	{
		name = "dealloc_node", action = { type = "dealloc_node", id = 1 },
		verify = function(fake) assert.is_false(fake.spec.nodes[1].alloc) end,
	},
	{
		name = "set_config", action = { type = "set_config", key = "testFlag", value = true },
		verify = function(fake) assert.is_true(fake.configTab.input.testFlag) end,
	},
	{
		name = "set_level", action = { type = "set_level", value = 98 },
		verify = function(fake)
			assert.are.equal(98, fake.characterLevel)
			assert.is_false(fake.characterLevelAutoMode)
			assert.are.equal(98, fake.controls.characterLevel.value)
		end,
	},
	{
		name = "set_class", action = { type = "set_class", name = "Witch" },
		verify = function(fake) assert.are.equal(3, fake.spec.selectedClassId) end,
	},
	{
		name = "set_ascendancy", action = { type = "set_ascendancy", name = "Occultist" },
		verify = function(fake) assert.are.equal(1, fake.spec.selectedAscendancyId) end,
	},
	{
		name = "set_bandit", action = { type = "set_bandit", value = "Alira" },
		verify = function(fake) assert.are.equal("Alira", fake.configTab.input.bandit) end,
	},
	{
		name = "set_pantheon", action = { type = "set_pantheon", major = "TheBrineKing", minor = "Gruthkul" },
		verify = function(fake)
			assert.are.equal("TheBrineKing", fake.configTab.input.pantheonMajorGod)
			assert.are.equal("Gruthkul", fake.configTab.input.pantheonMinorGod)
		end,
	},
	{
		name = "add_skill", action = { type = "add_skill", label = "Added", gems = { "Fireball", "Combustion" } },
		verify = function(fake)
			local groups = fake.skillsTab.skillSets[1].socketGroupList
			assert.are.equal(2, #groups)
			assert.are.equal("Added", groups[2].label)
			assert.is_table(groups[2].gemList[1].gemData)
		end,
	},
	{
		name = "remove_skill", action = { type = "remove_skill", label = "Main" },
		verify = function(fake) assert.are.equal(0, #fake.skillsTab.skillSets[1].socketGroupList) end,
	},
	{
		name = "equip_jewel",
		action = {
			type = "equip_jewel", nodeId = 3,
			raw = "Rarity: Rare\nAI Test Jewel\nCrimson Jewel\nImplicits: 0\n+10 to Strength",
		},
		verify = function(fake)
			assert.are.equal(1, #fake.itemsTab.added)
			assert.are.equal(fake.itemsTab.added[1].id, fake.spec.jewels[3])
		end,
	},
	{
		name = "apply_tattoo", action = { type = "apply_tattoo", id = 1, tattoo = "Test Tattoo" },
		verify = function(fake)
			assert.is_table(fake.spec.hashOverrides[1])
			assert.are.equal(1, fake.spec.hashOverrides[1].id)
			assert.is_true(fake.spec.pathsRebuilt)
		end,
	},
	{
		name = "remove_tattoo", action = { type = "remove_tattoo", id = 1 },
		prepare = function(fake)
			local tattooed = { id = 1, name = "Tattooed Node", type = "Normal", alloc = true, path = {} }
			fake.spec.nodes[1] = tattooed
			fake.spec.allocNodes[1] = tattooed
			fake.spec.hashOverrides[1] = tattooed
		end,
		verify = function(fake)
			assert.is_nil(fake.spec.hashOverrides[1])
			assert.are.equal(fake.spec.tree.nodes[1], fake.spec.nodes[1])
		end,
	},
	{
		name = "set_mastery", action = { type = "set_mastery", id = 4, effect = 1 },
		verify = function(fake)
			assert.are.equal(101, fake.spec.masterySelections[4])
			assert.is_true(fake.spec.nodes[4].alloc)
			assert.is_true(fake.spec.nodes[4].processed)
		end,
	},
	{
		name = "set_main_skill", action = { type = "set_main_skill", label = "Main", skillIndex = 2 },
		verify = function(fake)
			assert.are.equal(1, fake.mainSocketGroup)
			assert.are.equal(2, fake.skillsTab.skillSets[1].socketGroupList[1].mainActiveSkill)
		end,
	},
	{
		name = "set_secondary_ascendancy", action = { type = "set_secondary_ascendancy", name = "Warden" },
		verify = function(fake) assert.are.equal(2, fake.spec.selectedSecondaryAscendancyId) end,
	},
	{
		name = "set_skill_part", action = { type = "set_skill_part", name = "Fireball", part = 2 },
		verify = function(fake)
			local gem = fake.skillsTab.skillSets[1].socketGroupList[1].gemList[1]
			assert.are.equal(2, gem.skillPart)
		end,
	},
}

describe("AI action semantic handlers", function()
	for _, case in ipairs(CASES) do
		it("applies " .. case.name .. " with its observable effect", function()
			local bridge = LoadModule("Modules/AIBridge")
			local fake = newFakeBuild()
			if case.prepare then
				case.prepare(fake)
			end
			local ok, message = bridge:ExecuteAction(fake, case.action)
			assert.is_true(ok, message)
			assert.is_string(message)
			case.verify(fake)
		end)
	end

	it("does not add an item when the jewel socket is invalid", function()
		local bridge = LoadModule("Modules/AIBridge")
		local fake = newFakeBuild()
		local ok, message = bridge:ExecuteAction(fake, {
			type = "equip_jewel",
			nodeId = 999,
			raw = "Rarity: Rare\nInvalid Socket Jewel\nCrimson Jewel\nImplicits: 0\n+10 to Strength",
		})
		assert.is_false(ok)
		assert.is_truthy(message:find("not a jewel socket", 1, true))
		assert.are.equal(0, #fake.itemsTab.added)
	end)

	it("does not append unknown gems or change the selected main skill", function()
		local bridge = LoadModule("Modules/AIBridge")
		local fake = newFakeBuild()
		local groups = fake.skillsTab.skillSets[1].socketGroupList
		local ok = bridge:ExecuteAction(fake, {
			type = "add_skill",
			gems = { "Definitely Not A Gem" },
		})
		assert.is_false(ok)
		assert.are.equal(1, #groups)

		ok = bridge:ExecuteAction(fake, {
			type = "set_main_skill",
			label = "Main",
			skillIndex = 999,
		})
		assert.is_false(ok)
		assert.are.equal(99, fake.mainSocketGroup)
		assert.are.equal(1, groups[1].mainActiveSkill)
	end)
end)
