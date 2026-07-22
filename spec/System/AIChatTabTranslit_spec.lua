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

describe("AI chat transliteration", function()
	it("converts UTF-8 symbols before the Latin-1 fallback", function()
		local AIChatTab = LoadModule("Classes/AIChatTab")
		local translit = findUpvalue(AIChatTab.SendMessage, "translit")
		assert.is_function(translit)

		local input = table.concat({
			"at\195\169", -- ate with an accented e
			"\226\134\146", -- right arrow
			"\226\137\165", -- greater than or equal
			"\226\137\164", -- less than or equal
			"\226\137\136", -- approximately
			"\194\177", -- plus-minus
			"\195\151", -- multiplication
			"\195\183", -- division
		}, " ")

		assert.are.equal("ate -> >= <= ~ +/- x /", translit(input))
		assert.are.equal("->", translit("[U+2192][U+FFFD]"))
		assert.are.equal("safe", translit("safe\134\146"))
	end)
end)
