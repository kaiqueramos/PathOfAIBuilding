-- cspell:ignore Labirinto faca translit Upvalue
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
		local translit = findUpvalue(AIChatTab.SendRequest, "translit")
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

	it("never reads the lead byte of an unmapped UTF-8 sequence as a Latin-1 letter", function()
		local AIChatTab = LoadModule("Classes/AIChatTab")
		local translit = findUpvalue(AIChatTab.SendRequest, "translit")
		assert.is_function(translit)

		-- ordinal indicators, an ellipsis, a no-break space and a minus sign are common in replies
		assert.are.equal("1o Labirinto, 2a vez...", translit("1\194\186 Labirinto, 2\194\170 vez\226\128\166"))
		assert.are.equal("a b", translit("a\194\160b"))
		assert.are.equal("-34% fire", translit("\226\136\146" .. "34% fire"))

		-- symbols with no mapping disappear instead of leaving a stray letter
		assert.are.equal("ok  done", translit("ok \226\156\168 done"))
		assert.are.equal("hi ", translit("hi \240\159\152\128"))

		-- a lone Latin-1 byte from a Wine keyboard is still a letter
		assert.are.equal("faca", translit("fa\231a"))
	end)
end)
