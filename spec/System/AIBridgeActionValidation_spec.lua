local CASES = {
	{
		name = "equip_item", handler = "ActionEquipItem",
		valid = { type = "equip_item", raw = "Rarity: Normal\nCoral Ring", slot = "Ring 1" },
		invalid = { type = "equip_item", raw = "" }, error = "non-empty raw item string",
	},
	{
		name = "alloc_node", handler = "ActionAllocNode",
		valid = { type = "alloc_node", id = 1 },
		invalid = { type = "alloc_node" }, error = "numeric id or node name",
	},
	{
		name = "dealloc_node", handler = "ActionDeallocNode",
		valid = { type = "dealloc_node", name = "Test Node" },
		invalid = { type = "dealloc_node", id = 1.5 }, error = "numeric id or node name",
	},
	{
		name = "set_config", handler = "ActionSetConfig",
		valid = { type = "set_config", key = "condition", value = true },
		invalid = { type = "set_config", key = "condition", value = "true" }, error = "boolean or number",
	},
	{
		name = "set_level", handler = "ActionSetLevel",
		valid = { type = "set_level", value = 100 },
		invalid = { type = "set_level", value = 0 }, error = "integer between 1 and 100",
	},
	{
		name = "set_class", handler = "ActionSetClass",
		valid = { type = "set_class", name = "Witch" },
		invalid = { type = "set_class", name = "" }, error = "requires a name",
	},
	{
		name = "set_ascendancy", handler = "ActionSetAscendancy",
		valid = { type = "set_ascendancy", name = "Occultist" },
		invalid = { type = "set_ascendancy" }, error = "requires a name",
	},
	{
		name = "set_bandit", handler = "ActionSetBandit",
		valid = { type = "set_bandit", value = "None" },
		invalid = { type = "set_bandit" }, error = "requires a value",
	},
	{
		name = "set_pantheon", handler = "ActionSetPantheon",
		valid = { type = "set_pantheon", major = "None" },
		invalid = { type = "set_pantheon" }, error = "requires major or minor",
	},
	{
		name = "add_skill", handler = "ActionAddSkill",
		valid = {
			type = "add_skill", label = "Main",
			gems = { "Fireball", { name = "Combustion", level = 20, quality = 0 } },
		},
		invalid = { type = "add_skill", gems = {} }, error = "non-empty dense array",
	},
	{
		name = "remove_skill", handler = "ActionRemoveSkill",
		valid = { type = "remove_skill", label = "Main" },
		invalid = { type = "remove_skill" }, error = "label or gem name",
	},
	{
		name = "equip_jewel", handler = "ActionEquipJewel",
		valid = { type = "equip_jewel", raw = "Rarity: Normal\nCrimson Jewel", nodeId = 1 },
		invalid = { type = "equip_jewel", raw = "Rarity: Normal\nCrimson Jewel", nodeId = 1.5 },
		error = "nodeId must be an integer",
	},
	{
		name = "apply_tattoo", handler = "ActionApplyTattoo",
		valid = { type = "apply_tattoo", id = 1, tattoo = "Test Tattoo" },
		invalid = { type = "apply_tattoo", id = 1 }, error = "requires a tattoo name",
	},
	{
		name = "remove_tattoo", handler = "ActionRemoveTattoo",
		valid = { type = "remove_tattoo", id = 1 },
		invalid = { type = "remove_tattoo" }, error = "numeric id or node name",
	},
	{
		name = "set_mastery", handler = "ActionSetMastery",
		valid = { type = "set_mastery", id = 1, effect = 1 },
		invalid = { type = "set_mastery", id = 1, effect = 0 }, error = "positive integer",
	},
	{
		name = "set_main_skill", handler = "ActionSetMainSkill",
		valid = { type = "set_main_skill", label = "Main", skillIndex = 1 },
		invalid = { type = "set_main_skill", label = "Main", skillIndex = 0 }, error = "positive integer",
	},
	{
		name = "set_secondary_ascendancy", handler = "ActionSetSecondaryAscendancy",
		valid = { type = "set_secondary_ascendancy", name = "Warden" },
		invalid = { type = "set_secondary_ascendancy" }, error = "requires a name",
	},
	{
		name = "set_skill_part", handler = "ActionSetSkillPart",
		valid = { type = "set_skill_part", name = "Fireball", part = 1 },
		invalid = { type = "set_skill_part", name = "Fireball", part = 0 }, error = "positive integer",
	},
}

describe("AI action structural contracts", function()
	for _, case in ipairs(CASES) do
		it("accepts and dispatches " .. case.name, function()
			local bridge = LoadModule("Modules/AIBridge")
			local valid, validationError = bridge:ValidateActionShape(case.valid)
			assert.is_true(valid, validationError)
			assert.is_nil(validationError)

			local target = {}
			local routedBuild
			local routedAction
			local originalHandler = bridge[case.handler]
			bridge[case.handler] = function(_, actionBuild, action)
				routedBuild = actionBuild
				routedAction = action
				return true, "routed"
			end
			local callOk, actionOk, actionMessage = pcall(bridge.ExecuteAction, bridge, target, case.valid)
			bridge[case.handler] = originalHandler

			assert.is_true(callOk, actionOk)
			assert.is_true(actionOk)
			assert.are.equal("routed", actionMessage)
			assert.are.equal(target, routedBuild)
			assert.are.equal(case.valid, routedAction)
		end)

		it("rejects malformed " .. case.name, function()
			local bridge = LoadModule("Modules/AIBridge")
			local valid, validationError = bridge:ValidateActionShape(case.invalid)
			assert.is_false(valid)
			assert.is_truthy(validationError:find(case.error, 1, true))
		end)
	end

	it("rejects missing and unknown action types", function()
		local bridge = LoadModule("Modules/AIBridge")
		local valid, validationError = bridge:ValidateActionShape("set_level")
		assert.is_false(valid)
		assert.are.equal("Action must be an object", validationError)

		valid, validationError = bridge:ValidateActionShape({})
		assert.is_false(valid)
		assert.are.equal("Action type is required", validationError)

		valid, validationError = bridge:ValidateActionShape({ type = "delete_build" })
		assert.is_false(valid)
		assert.are.equal("Unknown action type: delete_build", validationError)
	end)

	it("rejects sparse gem and action arrays", function()
		local bridge = LoadModule("Modules/AIBridge")
		local valid, validationError = bridge:ValidateActionShape({
			type = "add_skill",
			gems = { [1] = "Fireball", [3] = "Combustion" },
		})
		assert.is_false(valid)
		assert.is_truthy(validationError:find("dense array", 1, true))

		local preflight = bridge:PreflightActions({}, {
			[1] = { type = "set_level", value = 90 },
			[3] = { type = "set_level", value = 91 },
		}, "snapshot")
		assert.is_false(preflight.ok)
		assert.are.equal("validation", preflight.phase)
		assert.is_truthy(preflight.results[1].msg:find("dense array", 1, true))
	end)

	it("preserves explicit nulls for validation", function()
		local bridge = LoadModule("Modules/AIBridge")
		local _, actions = bridge:ParseActions([[
<actions>
[{"type":"set_level","value":90},null]
</actions>
]])
		assert.is_table(actions)
		assert.are.equal(2, #actions)

		local preflight = bridge:PreflightActions({}, actions, "snapshot")
		assert.is_false(preflight.ok)
		assert.are.equal("validation", preflight.phase)
		assert.is_truthy(preflight.results[1].msg:find("Action 2 invalid", 1, true))
	end)
end)
