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

-- UTF-8 punctuation and symbols that use two or three bytes. Replace these before
-- the Latin-1 fallback, otherwise each byte reaches SimpleGraphic separately.
local UTF8_SYMBOL_TRANSLIT = {
	["\194\177"] = "+/-", -- ±
	["\195\151"] = "x", -- ×
	["\195\183"] = "/", -- ÷
	["\226\128\147"] = "-", -- en dash
	["\226\128\148"] = "--", -- em dash
	["\226\128\152"] = "'", ["\226\128\153"] = "'", -- curly single quotes
	["\226\128\156"] = '"', ["\226\128\157"] = '"', -- curly double quotes
	["\226\128\162"] = "-", -- bullet
	["\226\134\145"] = "^", -- ↑
	["\226\134\146"] = "->", -- →
	["\226\134\147"] = "v", -- ↓
	["\226\137\136"] = "~", -- ≈
	["\226\137\164"] = "<=", -- ≤
	["\226\137\165"] = ">=", -- ≥
}

local function translit(text)
	for sequence, replacement in pairs(UTF8_SYMBOL_TRANSLIT) do
		text = text:gsub(sequence, replacement)
	end
	-- First: UTF-8 multi-byte sequences
	text = text:gsub("\195[\128-\191]", function(seq)
		return UTF8_TRANSLIT[seq] or ""
	end)
	-- Then: Latin-1 single bytes (remaining high bytes)
	text = text:gsub("[\192-\255]", function(b)
		return LATIN1_TRANSLIT[b] or ""
	end)
	-- Drop orphaned UTF-8 continuation bytes instead of rendering [U+FFFD].
	text = text:gsub("[\128-\191]", "")
	-- Finally: [U+XXXX] placeholders (SimpleGraphic converts UTF-8 to these)
	text = text:gsub("%[U%+(%x+)%]", function(hex)
		local code = tonumber(hex, 16)
		-- Map common Latin-1 Supplement codepoints to ASCII
		local map = {
			[0xC0]=65,[0xC1]=65,[0xC2]=65,[0xC3]=65,[0xC4]=65,[0xC5]=65,[0xC6]=65, -- À-Å → A
			[0xC7]=67, -- Ç → C
			[0xC8]=69,[0xC9]=69,[0xCA]=69,[0xCB]=69, -- È-Ë → E
			[0xCC]=73,[0xCD]=73,[0xCE]=73,[0xCF]=73, -- Ì-Ï → I
			[0xD1]=78, -- Ñ → N
			[0xD2]=79,[0xD3]=79,[0xD4]=79,[0xD5]=79,[0xD6]=79,[0xD8]=79, -- Ò-Ö,Ø → O
			[0xD9]=85,[0xDA]=85,[0xDB]=85,[0xDC]=85, -- Ù-Ü → U
			[0xDD]=89, -- Ý → Y
			[0xDF]=115, -- ß → s (approximation)
			[0xE0]=97,[0xE1]=97,[0xE2]=97,[0xE3]=97,[0xE4]=97,[0xE5]=97,[0xE6]=97, -- à-å → a
			[0xE7]=99, -- ç → c
			[0xE8]=101,[0xE9]=101,[0xEA]=101,[0xEB]=101, -- è-ë → e
			[0xEC]=105,[0xED]=105,[0xEE]=105,[0xEF]=105, -- ì-ï → i
			[0xF1]=110, -- ñ → n
			[0xF2]=111,[0xF3]=111,[0xF4]=111,[0xF5]=111,[0xF6]=111,[0xF8]=111, -- ò-ö,ø → o
			[0xF9]=117,[0xFA]=117,[0xFB]=117,[0xFC]=117, -- ù-ü → u
			[0xFD]=121,[0xFF]=121, -- ý,ÿ → y
			-- Common symbols
			[0x2192]="->", -- → arrow
			[0x2265]=">=", -- ≥ greater or equal
			[0x2264]="<=", -- ≤ less or equal
			[0x00D7]="x", -- × multiplication
			[0x00F7]="/", -- ÷ division
			[0x00B1]="+/-", -- ± plus-minus
			[0x2248]="~", -- ≈ approximately
			[0x2191]="^", -- ↑ up arrow
			[0x2193]="v", -- ↓ down arrow
			[0xFFFD]="", -- replacement character (drop it)
		}
		local ascii = map[code]
		if ascii then
			return ascii
		end
		return ""  -- Drop unknown codepoints
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
	self.pendingActions = nil  -- actions parsed from last AI response

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

	-- Apply button (top-right, always visible above chat, hidden until actions available)
	self.controls.applyActions = new("ButtonControl", {"TOPRIGHT",self,"TOPRIGHT"}, {-8, 8, 220, 22}, "^2Apply Suggested Changes", function()
		ConPrintf("[AIChat] Apply button clicked!")
		self:ApplyPendingActions()
	end)
	self.controls.applyActions.shown = false

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

	-- Build conversation history from messages (exclude current user message)
	local history = {}
	for i = 1, #self.messages - 1 do
		local msg = self.messages[i]
		if msg.role == "user" then
			t_insert(history, { role = "user", content = msg.text })
		elseif msg.role == "ai" then
			t_insert(history, { role = "assistant", content = msg.full or msg.text })
		end
		-- Skip "system" messages (errors)
	end

	AIBridge:Ask(self.build, text, function(response, errMsg)
		self.pending = false
		self.controls.quickImprove.enabled = true
		self.controls.quickUpgrade.enabled = true
		self.controls.quickTank.enabled = true

		if errMsg then
			self:AddMessage("system", "Error: " .. errMsg)
			self.controls.status.label = "^1Request failed"
			self.controls.applyActions.shown = false
		else
			-- Parse actions FIRST (before translit to avoid corrupting JSON)
			local displayText, actions = AIBridge:ParseActions(response)
			self.pendingActions = actions
			self.controls.applyActions.shown = (actions ~= nil and #actions > 0)
			ConPrintf("[AIChat] Parsed %d actions, shown=%s", actions and #actions or 0, tostring(self.controls.applyActions.shown))
			-- Transliterate only the display text
			self:StartStream(translit(displayText))
			self.controls.status.label = self.controls.applyActions.shown
				and "^2Ready - actions available below" or "^2Ready"
		end
	end, history)
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

--- Apply the pending actions parsed from the last AI response
function AIChatTabClass:ApplyPendingActions()
	ConPrintf("[AIChat] ApplyPendingActions called")
	ConPrintf("[AIChat] pendingActions: %s", tostring(self.pendingActions))
	ConPrintf("[AIChat] build: %s", tostring(self.build))
	
	if not self.pendingActions or #self.pendingActions == 0 then
		ConPrintf("[AIChat] No pending actions to apply")
		return
	end

	ConPrintf("[AIChat] Executing %d actions", #self.pendingActions)
	local results = AIBridge:ExecuteActions(self.build, self.pendingActions)
	ConPrintf("[AIChat] ExecuteActions returned %d results", #results)

	-- Build a summary of what happened
	local lines = { "^7--- Applied changes ---" }
	local okCount, failCount = 0, 0
	for i, result in ipairs(results) do
		ConPrintf("[AIChat] Action %d: ok=%s msg=%s", i, tostring(result.ok), result.msg or "nil")
		if result.ok then
			okCount = okCount + 1
			t_insert(lines, "^2[OK] " .. result.msg)
		else
			failCount = failCount + 1
			t_insert(lines, "^1[FAIL] " .. result.msg)
		end
	end
	t_insert(lines, string.format("^7%d succeeded, %d failed", okCount, failCount))

	self:AddMessage("system", table.concat(lines, "\n"))

	-- Clear pending actions and hide the button
	self.pendingActions = nil
	self.controls.applyActions.shown = false
	self.controls.status.label = "^2Changes applied"
	ConPrintf("[AIChat] Apply complete: %d ok, %d failed", okCount, failCount)
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
