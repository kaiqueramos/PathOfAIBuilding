-- Path of Building AI Integration
-- AI Chat Tab: conversational interface for build advice
-- Follows the NotesTab pattern (ControlHost + Control)

local t_insert = table.insert
local dkjson = require "dkjson"
local AIBridge = LoadModule("Modules/AIBridge")

-- Transliterate accented characters to ASCII.
-- Handles both:
-- 1. Latin-1 single-byte (Wine keyboard input: ç=0xE7)
-- 2. UTF-8 multi-byte (API response: ã=0xC3 0xA3)
-- PoB font lacks accented glyphs → shows '?' or '[U+XXXX]'.
-- Map to plain ASCII so text stays clean and readable.

-- UTF-8 multi-byte sequences → ASCII
local UTF8_TRANSLIT = {
	-- à á â ã ä å æ
	["\195\160"] = "a", ["\195\161"] = "a", ["\195\162"] = "a", ["\195\163"] = "a",
	["\195\164"] = "a", ["\195\165"] = "a", ["\195\166"] = "ae",
	-- ç
	["\195\167"] = "c",
	-- è é ê ë
	["\195\168"] = "e", ["\195\169"] = "e", ["\195\170"] = "e", ["\195\171"] = "e",
	-- ì í î ï
	["\195\172"] = "i", ["\195\173"] = "i", ["\195\174"] = "i", ["\195\175"] = "i",
	-- ñ
	["\195\177"] = "n",
	-- ò ó ô õ ö ø
	["\195\178"] = "o", ["\195\179"] = "o", ["\195\180"] = "o", ["\195\181"] = "o",
	["\195\182"] = "o", ["\195\184"] = "o",
	-- ù ú û ü
	["\195\185"] = "u", ["\195\186"] = "u", ["\195\187"] = "u", ["\195\188"] = "u",
	-- ý ÿ
	["\195\189"] = "y", ["\195\191"] = "y",
	-- À Á Â Ã Ä Å Æ
	["\195\128"] = "A", ["\195\129"] = "A", ["\195\130"] = "A", ["\195\131"] = "A",
	["\195\132"] = "A", ["\195\133"] = "A", ["\195\134"] = "AE",
	-- Ç
	["\195\135"] = "C",
	-- È É Ê Ë
	["\195\136"] = "E", ["\195\137"] = "E", ["\195\138"] = "E", ["\195\139"] = "E",
	-- Ì Í Î Ï
	["\195\140"] = "I", ["\195\141"] = "I", ["\195\142"] = "I", ["\195\143"] = "I",
	-- Ñ
	["\195\145"] = "N",
	-- Ò Ó Ô Õ Ö Ø
	["\195\146"] = "O", ["\195\147"] = "O", ["\195\148"] = "O", ["\195\149"] = "O",
	["\195\150"] = "O", ["\195\152"] = "O",
	-- Ù Ú Û Ü
	["\195\153"] = "U", ["\195\154"] = "U", ["\195\155"] = "U", ["\195\156"] = "U",
	-- Ý
	["\195\157"] = "Y",
	-- ß
	["\195\159"] = "ss",
}

-- Latin-1 single-byte → ASCII (Wine keyboard)
local LATIN1_TRANSLIT = {
	["\192"] = "A", ["\193"] = "A", ["\194"] = "A", ["\195"] = "A", ["\196"] = "A", ["\197"] = "A", ["\198"] = "AE",
	["\199"] = "C",
	["\200"] = "E", ["\201"] = "E", ["\202"] = "E", ["\203"] = "E",
	["\204"] = "I", ["\205"] = "I", ["\206"] = "I", ["\207"] = "I",
	["\209"] = "N",
	["\210"] = "O", ["\211"] = "O", ["\212"] = "O", ["\213"] = "O", ["\214"] = "O", ["\216"] = "O",
	["\217"] = "U", ["\218"] = "U", ["\219"] = "U", ["\220"] = "U",
	["\221"] = "Y",
	["\223"] = "ss",
	["\224"] = "a", ["\225"] = "a", ["\226"] = "a", ["\227"] = "a", ["\228"] = "a", ["\229"] = "a", ["\230"] = "ae",
	["\231"] = "c",
	["\232"] = "e", ["\233"] = "e", ["\234"] = "e", ["\235"] = "e",
	["\236"] = "i", ["\237"] = "i", ["\238"] = "i", ["\239"] = "i",
	["\241"] = "n",
	["\242"] = "o", ["\243"] = "o", ["\244"] = "o", ["\245"] = "o", ["\246"] = "o", ["\248"] = "o",
	["\249"] = "u", ["\250"] = "u", ["\251"] = "u", ["\252"] = "u",
	["\253"] = "y", ["\255"] = "y",
}

local function translit(text)
	-- First: UTF-8 multi-byte sequences
	text = text:gsub("\195[\128-\191]", function(seq)
		return UTF8_TRANSLIT[seq] or ""
	end)
	-- Then: Latin-1 single bytes (remaining high bytes)
	text = text:gsub("[\192-\255]", function(b)
		return LATIN1_TRANSLIT[b] or ""
	end)
	return text
end

local AIChatTabClass = newClass("AIChatTab", "ControlHost", "Control", function(self, build)
	self.ControlHost()
	self.Control()

	self.build = build
	self.messages = {}  -- {role="user"|"ai"|"system", text=string, full=string}
	self.pending = false
	self.streaming = false
	self.streamMsgIndex = nil
	self.streamPos = 0

	-- === TOP: header + build summary ===
	self.controls.header = new("LabelControl", {"TOPLEFT",self,"TOPLEFT"}, {8, 8, 0, 16}, "^7AI Build Advisor")
	self.controls.summary = new("LabelControl", {"TOPLEFT",self.controls.header,"BOTTOMLEFT"}, {0, 4, 0, 16}, "")
	self.controls.summary.label = function()
		return "^8" .. AIBridge:GetBuildSummary(self.build)
	end

	-- === BOTTOM: status, input, quick buttons (anchored from bottom) ===
	self.controls.status = new("LabelControl", {"BOTTOMLEFT",self,"BOTTOMLEFT"}, {8, -4, 0, 16}, "")

	self.controls.input = new("EditControl", {"BOTTOMLEFT",self.controls.status,"TOPLEFT"}, {0, -4, 0, 22}, "", nil, "^%C\t\n", nil, function(buf)
		self.controls.send.enabled = #buf > 0
	end)
	self.controls.input.width = function()
		return self.width - 100
	end
	self.controls.input:SetPlaceholder("Ask about your build...")
	-- Transliterate accented chars to ASCII on input (Wine Latin-1 keyboard)
	local origInsert = self.controls.input.Insert
	self.controls.input.Insert = function(ctrl, text)
		return origInsert(ctrl, translit(text))
	end
	-- Enter to send
	self.controls.input.enterFunc = function(buf)
		if buf and #buf > 0 then
			self:SendMessage(buf)
		end
	end

	self.controls.send = new("ButtonControl", {"LEFT",self.controls.input,"RIGHT"}, {6, 0, 76, 22}, "Send", function()
		local msg = self.controls.input.buf
		if msg and #msg > 0 then
			self:SendMessage(msg)
		end
	end)
	self.controls.send.enabled = false

	self.controls.quickImprove = new("ButtonControl", {"BOTTOMLEFT",self.controls.input,"TOPLEFT"}, {0, -6, 150, 20}, "How do I improve?", function()
		self:SendMessage("How do I improve this build? Give me the top 3 highest-impact changes.")
	end)
	self.controls.quickUpgrade = new("ButtonControl", {"LEFT",self.controls.quickImprove,"RIGHT"}, {6, 0, 150, 20}, "Next upgrade?", function()
		self:SendMessage("What is my best next upgrade considering cost vs impact?")
	end)
	self.controls.quickTank = new("ButtonControl", {"LEFT",self.controls.quickUpgrade,"RIGHT"}, {6, 0, 150, 20}, "Can I tank?", function()
		self:SendMessage("Analyze my defenses. What can I tank and what will kill me?")
	end)

	-- === MIDDLE: chat history fills remaining space (READ-ONLY) ===
	self.controls.history = new("EditControl", {"TOPLEFT",self.controls.summary,"BOTTOMLEFT"}, {0, 8, 0, 0}, "", nil, "^%C\t\n", nil, nil, 16, true)
	self.controls.history.width = function()
		return self.width - 16
	end
	self.controls.history.height = function()
		local top = 52
		local bottom = 80
		return math.max(self.height - top - bottom, 100)
	end
	-- Make history read-only: block all text input
	self.controls.history.OnChar = function() end
	self.controls.history.Insert = function() end
	self.controls.history.ReplaceSel = function() end

	self:SelectControl(self.controls.input)
end)

--- Send a message to the AI and display the response
function AIChatTabClass:SendMessage(text)
	if self.pending then
		return
	end

	self:AddMessage("user", text)
	self.controls.input:SetText("")
	self.controls.send.enabled = false
	self.pending = true
	self.controls.status.label = "^7Thinking..."

	self.controls.quickImprove.enabled = false
	self.controls.quickUpgrade.enabled = false
	self.controls.quickTank.enabled = false

	AIBridge:Ask(self.build, text, function(response, errMsg)
		self.pending = false
		self.controls.quickImprove.enabled = true
		self.controls.quickUpgrade.enabled = true
		self.controls.quickTank.enabled = true

		if errMsg then
			self:AddMessage("system", "Error: " .. errMsg)
			self.controls.status.label = "^1Request failed"
		else
			-- Start streaming the response (transliterate accented chars)
			self:StartStream(translit(response))
			self.controls.status.label = "^2Ready"
		end
	end)
end

--- Start streaming a response (progressive reveal)
function AIChatTabClass:StartStream(fullText)
	t_insert(self.messages, { role = "ai", text = "", full = fullText })
	self.streamMsgIndex = #self.messages
	self.streamPos = 0
	self.streaming = true
end

--- Update streaming progress (called every frame from Draw)
function AIChatTabClass:UpdateStream()
	if not self.streaming then return end

	local msg = self.messages[self.streamMsgIndex]
	if not msg then
		self.streaming = false
		return
	end

	-- Reveal ~40 chars per frame, snap past ^ color codes
	self.streamPos = self.streamPos + 40
	local full = msg.full
	if self.streamPos >= #full then
		self.streamPos = #full
		self.streaming = false
	else
		-- Don't split a ^X color code
		if full:sub(self.streamPos, self.streamPos) == "^" then
			self.streamPos = self.streamPos + 1
		end
	end

	msg.text = full:sub(1, self.streamPos)
	self:RefreshHistory()
end

--- Add a message to the chat history display
function AIChatTabClass:AddMessage(role, text)
	t_insert(self.messages, { role = role, text = text, full = text })
	self:RefreshHistory()
end

--- Refresh the history display
function AIChatTabClass:RefreshHistory()
	local lines = {}
	for _, msg in ipairs(self.messages) do
		local prefix
		if msg.role == "user" then
			prefix = "^7> "
		elseif msg.role == "ai" then
			prefix = "^2AI: "
		else
			prefix = "^1[!] "
		end
		for line in (msg.text .. "\n"):gmatch("([^\n]*)\n") do
			t_insert(lines, prefix .. line)
			prefix = "  "
		end
		t_insert(lines, "")
	end
	self.controls.history:SetText(table.concat(lines, "\n"))
	self.controls.history.caret = #self.controls.history.buf
	self.controls.history:ScrollCaretIntoView()
end

--- Load/Save (no persistence for chat history - session only)
function AIChatTabClass:Load(xml, dbFileName)
	return false
end

function AIChatTabClass:Save(xml)
end

function AIChatTabClass:Draw(viewPort, inputEvents)
	self.x = viewPort.x
	self.y = viewPort.y
	self.width = viewPort.width
	self.height = viewPort.height

	-- Update streaming animation
	self:UpdateStream()

	self:ProcessControlsInput(inputEvents, viewPort)
	main:DrawBackground(viewPort)
	self:DrawControls(viewPort)
end

return AIChatTabClass
