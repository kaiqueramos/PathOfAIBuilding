-- Path of Building AI Integration
-- AI Chat Tab: conversational interface for build advice
-- Follows the NotesTab pattern (ControlHost + Control)
-- cspell:ignore translit

local t_insert = table.insert
local dkjson = require "dkjson"
local AIBridge = LoadModule("Modules/AIBridge")
local AIConversation = LoadModule("Modules/AIConversation")
local AIPlanning = LoadModule("Modules/AIPlanning")

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
	["\194\160"] = " ", -- no-break space
	["\194\170"] = "a", -- feminine ordinal indicator
	["\194\171"] = '"', ["\194\187"] = '"', -- double angle quotation marks
	["\194\176"] = "deg", -- degree sign
	["\194\181"] = "u", -- micro sign
	["\194\183"] = "-", -- middle dot
	["\194\186"] = "o", -- masculine ordinal indicator
	["\226\128\137"] = " ", ["\226\128\175"] = " ", -- thin and narrow no-break spaces
	["\226\128\139"] = "", -- zero width space
	["\226\128\145"] = "-", ["\226\128\146"] = "-", -- non-breaking hyphen, figure dash
	["\226\128\149"] = "--", -- horizontal bar
	["\226\128\166"] = "...", -- ellipsis
	["\226\134\144"] = "<-", -- left arrow
	["\226\134\148"] = "<->", -- left right arrow
	["\226\135\146"] = "=>", -- double right arrow
	["\226\136\146"] = "-", -- minus sign
	["\226\137\160"] = "!=", -- not equal
	["\226\156\147"] = "ok", ["\226\156\148"] = "ok", -- check marks
	["\226\156\151"] = "x", ["\226\156\152"] = "x", -- cross marks
	["\226\152\133"] = "*", -- black star
}

local function translit(text)
	for sequence, replacement in pairs(UTF8_SYMBOL_TRANSLIT) do
		text = text:gsub(sequence, replacement)
	end
	-- First: UTF-8 multi-byte sequences
	text = text:gsub("\195[\128-\191]", function(seq)
		return UTF8_TRANSLIT[seq] or ""
	end)
	-- Any other well-formed UTF-8 sequence is a symbol the font cannot draw. Left alone, its lead
	-- byte would be read as a Latin-1 letter below (the ordinal indicator after a number became "A").
	text = text:gsub("[\194-\223][\128-\191]", "")
	text = text:gsub("[\224-\239][\128-\191][\128-\191]", "")
	text = text:gsub("[\240-\247][\128-\191][\128-\191][\128-\191]", "")
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

-- What a click on the "AI Decides" chip answers.
local AI_DECIDES_ANSWER = "Choose the best option for me"

local AIChatTabClass = newClass("AIChatTab", "ControlHost", "Control")

function AIChatTabClass:AIChatTab(build)
	self:ControlHost()
	self:Control()

	self.build = build
	self.messages = {}  -- {role="user"|"ai"|"system", text=string, full=string}
	self.pending = false
	self.streaming = false
	self.streamMsgIndex = nil
	self.streamPos = 0
	self.pendingActions = nil  -- actions parsed from last AI response
	self.pendingActionsFingerprint = nil
	self.conversationSession = nil
	self.planningSession = nil

	-- === TOP: header + stage badge + build summary ===
	self.controls.header = new("LabelControl"):LabelControl({"TOPLEFT",self,"TOPLEFT"}, {10, 8, 0, 18}, "^x5CF0BBAI Build Advisor")
	self.controls.stageBadge = new("LabelControl"):LabelControl({"LEFT",self.controls.header,"RIGHT"}, {12, 0, 0, 16}, "")
	self.controls.stageBadge.label = function()
		return self:GetStageBadgeText()
	end
	self.controls.summary = new("LabelControl"):LabelControl({"TOPLEFT",self.controls.header,"BOTTOMLEFT"}, {0, 4, 0, 16}, "")
	self.controls.summary.label = function()
		return "^8" .. AIBridge:GetBuildSummary(self.build)
	end

	-- === BOTTOM: status, input, quick buttons (anchored from bottom) ===
	self.controls.status = new("LabelControl"):LabelControl({"BOTTOMLEFT",self,"BOTTOMLEFT"}, {10, -4, 0, 16}, "^2Ready")

	self.controls.input = new("EditControl"):EditControl({"BOTTOMLEFT",self.controls.status,"TOPLEFT"}, {0, -4, 0, 24}, "", nil, "^%C\t\n", nil, function(buf)
		self.controls.send.enabled = #buf > 0 and not self.pending
	end)
	self.controls.input.width = function()
		return self.width - 178
	end
	self.controls.input:SetPlaceholder("Ask about your build or type 'Create a build...'")
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

	self.controls.send = new("ButtonControl"):ButtonControl({"LEFT",self.controls.input,"RIGHT"}, {6, 0, 82, 24}, "^2Send", function()
		local msg = self.controls.input.buf
		if msg and #msg > 0 then
			self:SendMessage(msg)
		end
	end)
	self.controls.send.enabled = false

	self.controls.clearChat = new("ButtonControl"):ButtonControl({"LEFT",self.controls.send,"RIGHT"}, {6, 0, 68, 24}, "^8Reset", function()
		self:ResetChat()
	end)

	self.controls.quickImprove = new("ButtonControl"):ButtonControl({"BOTTOMLEFT",self.controls.input,"TOPLEFT"}, {0, -6, 132, 22}, "How do I improve?", function()
		self:SendMessage("How do I improve this build? Give me the top 3 highest-impact changes.")
	end)
	self.controls.quickUpgrade = new("ButtonControl"):ButtonControl({"LEFT",self.controls.quickImprove,"RIGHT"}, {5, 0, 118, 22}, "Next upgrade?", function()
		self:SendMessage("What is my best next upgrade considering cost vs impact?")
	end)
	self.controls.quickTank = new("ButtonControl"):ButtonControl({"LEFT",self.controls.quickUpgrade,"RIGHT"}, {5, 0, 102, 22}, "Can I tank?", function()
		self:SendMessage("Analyze my defenses. What can I tank and what will kill me?")
	end)
	self.controls.quickSkills = new("ButtonControl"):ButtonControl({"LEFT",self.controls.quickTank,"RIGHT"}, {5, 0, 148, 22}, "Complementary Skills", function()
		self:SendMessage("Propose complementary skills for this build (auras, curses/marks, guard skill, and movement skill) and add them with add_skill actions.")
	end)
	self.controls.quickGear = new("ButtonControl"):ButtonControl({"LEFT",self.controls.quickSkills,"RIGHT"}, {5, 0, 142, 22}, "Recommended Gear", function()
		self:SendMessage("Recommend the best starter/upgrade items for each slot (uniques and rare stat priorities) and propose equip_item actions for key slots.")
	end)
	self.controls.quickGuide = new("ButtonControl"):ButtonControl({"LEFT",self.controls.quickGear,"RIGHT"}, {5, 0, 128, 22}, "Playstyle Guide", function()
		self:SendMessage("Write a complete playstyle, skill rotation, leveling progression, and defensive mechanics guide for this build.", { saveGuideToNotes = true })
	end)
	self.controls.quickNewBuild = new("ButtonControl"):ButtonControl({"LEFT",self.controls.quickGuide,"RIGHT"}, {5, 0, 145, 22}, "^x5CF0BB+ New Guided Build", function()
		self.controls.input:SetText("Create a league starter build at level 30: ")
		self.controls.send.enabled = true
		self:SelectControl(self.controls.input)
	end)
	self.controls.quickTreePlan = new("ButtonControl"):ButtonControl({"LEFT",self.controls.quickNewBuild,"RIGHT"}, {5, 0, 155, 22}, "^2Plan Passive Tree ->", function()
		self:SendMessage("Propose my passive tree plan for this foundation.")
	end)
	self.controls.quickTreePlan.shown = function()
		return self.planningSession ~= nil and self.planningSession.state == "tree" and not self.pending
			and not self.planningSession.passivePlanApplied
	end
	self.controls.quickSkipTree = new("ButtonControl"):ButtonControl({"LEFT",self.controls.quickTreePlan,"RIGHT"}, {5, 0, 100, 22}, "^8Skip Tree", function()
		self:SkipTreeStage()
	end)

	-- Option chips (shown when AI asks a clarification question with options)
	self.optionButtons = {}
	for idx = 1, 5 do
		local anchor = idx == 1
			and {"BOTTOMLEFT",self.controls.quickImprove,"TOPLEFT"}
			or {"LEFT",self.optionButtons[idx - 1],"RIGHT"}
		local offsetX = idx == 1 and 0 or 6
		local offsetY = idx == 1 and -6 or 0
		local btn = new("ButtonControl"):ButtonControl(anchor, {offsetX, offsetY, 170, 22}, "", function()
			local choice = self.optionValues and self.optionValues[idx]
			if choice and not self.pending then
				self:SendMessage(choice)
			end
		end)
		btn.shown = false
		self.optionButtons[idx] = btn
		self.controls["option" .. idx] = btn
	end
	self.optionValues = {}

	-- Action buttons (top-right, always visible above chat, hidden until actions available)
	self.controls.applyActions = new("ButtonControl"):ButtonControl({"TOPRIGHT",self,"TOPRIGHT"}, {-10, 8, 220, 24}, "^2Apply Suggested Changes", function()
		ConPrintf("[AIChat] Apply button clicked!")
		self:ApplyPendingActions()
	end)
	self.controls.applyActions.shown = false

	self.controls.confirmBrief = new("ButtonControl"):ButtonControl({"TOPRIGHT",self,"TOPRIGHT"}, {-10, 8, 160, 24}, "^2Confirm Direction", function()
		self:ConfirmBrief()
	end)
	self.controls.confirmBrief.shown = false
	self.controls.reviseBrief = new("ButtonControl"):ButtonControl({"RIGHT",self.controls.confirmBrief,"LEFT"}, {-6, 0, 145, 24}, "^8Revise Direction", function()
		self:ReviseBrief()
	end)
	self.controls.reviseBrief.shown = false

	self.controls.applyFoundation = new("ButtonControl"):ButtonControl({"TOPRIGHT",self,"TOPRIGHT"}, {-10, 8, 170, 24}, "^2Apply Foundation", function()
		self:ApplyFoundation()
	end)
	self.controls.applyFoundation.shown = false

	self.controls.applyPassivePlan = new("ButtonControl"):ButtonControl({"TOPRIGHT",self,"TOPRIGHT"}, {-10, 8, 180, 24}, "^2Apply Passive Plan", function()
		self:ApplyPassivePlan()
	end)
	self.controls.applyPassivePlan.shown = false

	-- === MIDDLE: chat history fills remaining space (READ-ONLY) ===
	self.controls.history = new("EditControl"):EditControl({"TOPLEFT",self.controls.summary,"BOTTOMLEFT"}, {0, 8, 0, 0}, "", nil, "^%C\t\n", nil, nil, 17, true)
	self.controls.history.width = function()
		return self.width - 20
	end
	self.controls.history.height = function()
		local top = 54
		local hasOptions = self.optionButtons[1] and self.optionButtons[1].shown
		local bottom = hasOptions and 112 or 84
		return math.max(self.height - top - bottom, 100)
	end
	-- Make history read-only: block all text input
	self.controls.history.OnChar = function() end
	self.controls.history.Insert = function() end
	self.controls.history.ReplaceSel = function() end

	self:RefreshHistory()
	self:SelectControl(self.controls.input)
	return self
end

--- Return a visual stage badge for the top bar based on current planning session state.
function AIChatTabClass:GetStageBadgeText()
	local state = self.planningSession and self.planningSession.state or "idle"
	if state == "brief_pending" then
		return "^xFFFF77[Stage 1/3: Review Direction]"
	elseif state == "brief_revising" then
		return "^xFF9922[Stage 1/3: Revising Direction]"
	elseif state == "brief_confirmed" then
		return "^x5CF0BB[Stage 2/3: Preparing Foundation]"
	elseif state == "foundation_pending" then
		return "^x33FF77[Stage 2/3: Apply Foundation ->]"
	elseif state == "tree" then
		return "^x5CF0BB[Stage 3/3: Passive Tree Ready]"
	elseif state == "tree_pending" then
		return "^x33FF77[Stage 3/3: Apply Passive Plan ->]"
	end
	return "^8[Advisor Mode]"
end

--- Populate clickable option buttons when the AI asks a clarification question.
function AIChatTabClass:SetClarificationOptions(options)
	-- Option text becomes the player's answer and is shown in the history, so it is
	-- transliterated once here instead of at every use.
	local cleaned = {}
	for _, opt in ipairs(options or {}) do
		local rawOpt = translit(tostring(opt))
		local cleanOpt = rawOpt:match("^%s*(.-)%s*%(") or rawOpt
		if #cleanOpt == 0 then
			cleanOpt = rawOpt
		end
		cleanOpt = cleanOpt:gsub("^%s+", ""):gsub("%s+$", "")
		if #cleanOpt > 0 then
			t_insert(cleaned, cleanOpt)
		end
		if #cleaned == 4 then
			break
		end
	end

	self.optionValues = {}
	self.optionCount = #cleaned
	self.optionAutoIndex = #cleaned > 0 and (#cleaned + 1) or nil
	for idx = 1, 4 do
		local btn = self.optionButtons and self.optionButtons[idx]
		local text = cleaned[idx]
		if btn then
			if text then
				self.optionValues[idx] = text
				local shortLabel = text
				if #shortLabel > 24 then
					shortLabel = shortLabel:sub(1, 22) .. ".."
				end
				btn.label = "^x5CF0BB[" .. idx .. "] ^7" .. shortLabel
				btn.width = math.max(110, math.min(220, #shortLabel * 7 + 32))
				btn.shown = true
			else
				btn.shown = false
			end
		end
	end
	local autoBtn = self.optionButtons and self.optionButtons[5]
	if autoBtn then
		if #cleaned > 0 then
			self.optionValues[5] = AI_DECIDES_ANSWER
			autoBtn.label = "^2[" .. self.optionAutoIndex .. "] AI Decides (Recommended)"
			autoBtn.width = 205
			-- It follows the last visible option. Anchored to the fourth chip it would stay
			-- hidden whenever the question has fewer than four options.
			autoBtn:SetAnchor("LEFT", self.optionButtons[#cleaned], "RIGHT", 6, 0)
			autoBtn.shown = true
		else
			autoBtn.shown = false
		end
	end
end

--- Re-create the buttons, chips and prompts that a loaded planning state implies.
-- Only the saved sessions survive a save, so the screen is rebuilt from them.
function AIChatTabClass:RestoreUiFromState()
	local controls = self.controls
	local state = self.planningSession and self.planningSession.state or "idle"
	local conversation = self.conversationSession
	controls.applyActions.shown = false
	controls.confirmBrief.shown = state == "brief_pending"
	controls.reviseBrief.shown = state == "brief_pending"
	controls.applyFoundation.shown = state == "foundation_pending"
	controls.applyPassivePlan.shown = state == "tree_pending"
	if conversation and conversation.state == "awaiting_user" and conversation.pendingQuestion then
		self:SetClarificationOptions(conversation.pendingQuestion.options)
		controls.input:SetPlaceholder("Answer: " .. translit(tostring(conversation.pendingQuestion.prompt)))
		controls.status.label = "^7Clarification needed"
		return
	end
	self:SetClarificationOptions(nil)
	if state == "brief_pending" then
		controls.input:SetPlaceholder("Use Confirm direction or describe a revision...")
		controls.status.label = "^7Review build direction"
	elseif state == "foundation_pending" then
		controls.input:SetPlaceholder("Use Apply Foundation or describe a revision...")
		controls.status.label = "^7Review build foundation"
	elseif state == "tree_pending" then
		controls.input:SetPlaceholder("Use Apply Passive Plan or describe a revision...")
		controls.status.label = "^7Review passive plan"
	elseif state == "tree" then
		local planDone = self.planningSession.passivePlanApplied
		controls.input:SetPlaceholder(planDone
			and "Use Complementary Skills, Recommended Gear, or Playstyle Guide below..."
			or "Ask for the passive tree plan...")
		controls.status.label = "^2Ready"
	end
end

--- A reloaded build is a new object whose saved form differs in defaults PoB fills in, so the
-- fingerprints stored with the chat can never match it. The first use after loading binds the
-- restored sessions to the build as it is now. Preflight still checks every action on apply.
function AIChatTabClass:RebindRestoredSessions()
	if not self.restoredSessions then
		return
	end
	local fingerprint = AIBridge:GetBuildFingerprint(self.build)
	if not fingerprint then
		return
	end
	self.restoredSessions = false
	AIPlanning:Rebind(self.planningSession, fingerprint)
	AIConversation:Rebind(self.conversationSession, fingerprint)
end

--- Reset the conversation and guided planning state.
function AIChatTabClass:ResetChat()
	if self.pending then
		return
	end
	self:FinishStream()
	self.messages = {}
	self.pendingActions = nil
	self.pendingActionsFingerprint = nil
	self.conversationSession = nil
	self.planningSession = nil
	self.controls.applyActions.shown = false
	self.controls.confirmBrief.shown = false
	self.controls.reviseBrief.shown = false
	self.controls.applyFoundation.shown = false
	self.controls.applyPassivePlan.shown = false
	self:SetClarificationOptions(nil)
	self.controls.input:SetPlaceholder("Ask about your build or type 'Create a build...'")
	self.controls.status.label = "^2Ready"
	self:RefreshHistory()
	self:SelectControl(self.controls.input)
end

--- Send a message to the AI and display the response
function AIChatTabClass:SendMessage(text, requestOptions)
	if self.pending then
		return
	end
	self:RebindRestoredSessions()
	local awaitingClarification = self.conversationSession
		and self.conversationSession.state == "awaiting_user"
	if awaitingClarification then
		-- A bare digit picks the chip with that number, the last number being "AI Decides".
		local numChoice = tonumber(text:match("^%s*(%d)%s*$"))
		if numChoice then
			if numChoice >= 1 and numChoice <= (self.optionCount or 0) then
				text = self.optionValues[numChoice]
			elseif numChoice == self.optionAutoIndex then
				text = self.optionValues[5]
			end
		end
		local accepted, answerError = AIConversation:SubmitAnswer(self.conversationSession, text)
		if not accepted then
			self:AddMessage("system", "Error: " .. answerError)
			self.controls.status.label = "^1Clarification could not be recorded"
			return
		end
	else
		self.conversationSession = AIConversation:NewSession()
	end
	self:SetClarificationOptions(nil)
	self.planningSession = self.planningSession or AIPlanning:NewSession()
	if self.planningSession.state == "foundation_pending" then
		self.planningSession.pendingFoundation = nil
		self.planningSession.foundationFingerprint = nil
		self.planningSession.state = "brief_confirmed"
		self.controls.applyFoundation.shown = false
	end
	if self.planningSession.state == "tree_pending" then
		self.planningSession.pendingPassivePlan = nil
		self.planningSession.passivePlanFingerprint = nil
		self.planningSession.state = "tree"
		self.controls.applyPassivePlan.shown = false
	end
	if self.planningSession.state == "brief_pending" then
		AIPlanning:ReviseBrief(self.planningSession)
		self.controls.confirmBrief.shown = false
		self.controls.reviseBrief.shown = false
	end

	self:AddMessage("user", text)
	self.controls.input:SetText("")
	self.controls.send.enabled = false
	self:SendRequest(text, requestOptions)
end

--- Remove protocol tags the model left outside a parsed block, such as a second </turn>.
local function stripStrayProtocolTags(text)
	text = text:gsub("</?[Tt][Uu][Rr][Nn]%s*>", "")
		:gsub("</?[Bb][Rr][Ii][Ee][Ff]%s*>", "")
		:gsub("</?[Aa][Cc][Tt][Ii][Oo][Nn][Ss]%s*>", "")
		:gsub("</?[Cc][Oo][Nn][Tt][Ee][Xx][Tt]_[Rr][Ee][Qq][Uu][Ee][Ss][Tt]%s*>", "")
		:gsub("\n\n\n+", "\n\n")
		:gsub("^%s+", "")
		:gsub("%s+$", "")
	return text
end

--- Run one AI request using the current local conversation and planning sessions.
-- @param requestOptions optional { saveGuideToNotes = true } for the Playstyle Guide button
function AIChatTabClass:SendRequest(text, requestOptions)
	if self.pending then
		return
	end

	self.pending = true
	self.controls.status.label = "^7Thinking..."
	local supersedesUnappliedActions = self.pendingActions and #self.pendingActions > 0
	-- A new request supersedes any unapplied actions from the previous response.
	self.pendingActions = nil
	self.pendingActionsFingerprint = nil
	self.controls.applyActions.shown = false

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

	local responseHandled = false
	local function resetRequestState()
		self.pending = false
		self.controls.quickImprove.enabled = true
		self.controls.quickUpgrade.enabled = true
		self.controls.quickTank.enabled = true
	end
	local function showRequestFailure(message)
		AIConversation:AbortRequest(self.conversationSession)
		self.controls.applyFoundation.shown = false
		self.controls.applyPassivePlan.shown = false
		resetRequestState()
		self.pendingActions = nil
		self.pendingActionsFingerprint = nil
		self.controls.applyActions.shown = false
		self:AddMessage("system", "Error: " .. message)
		self.controls.status.label = "^1Request failed"
	end
	local function handleResponse(response, errMsg, responseFingerprint, turn, brief, returnedPlanningSession)
		if responseHandled then
			return
		end
		responseHandled = true
		local handled, handlerError = pcall(function()
			if errMsg then
				showRequestFailure(errMsg)
				return
			end
			if not turn then
				showRequestFailure("AI response is missing a validated dialogue turn")
				return
			end
			if returnedPlanningSession then
				self.planningSession = returnedPlanningSession
			end

			resetRequestState()
			-- Parse actions FIRST (before translit to avoid corrupting JSON).
			local displayText, actions, actionError = AIBridge:ParseActions(response)
			displayText = stripStrayProtocolTags(displayText)
			if brief and ((actions and #actions > 0) or actionError) then
				showRequestFailure("AI build brief cannot include executable actions")
				return
			end
			if brief and not returnedPlanningSession then
				local storedPlanningSession, planningError = AIPlanning:StoreBrief(
					self.planningSession,
					brief,
					responseFingerprint
				)
				if not storedPlanningSession then
					showRequestFailure("Invalid AI build brief: " .. planningError)
					return
				end
				self.planningSession = storedPlanningSession
			end
			local planningState = self.planningSession and self.planningSession.state or "idle"
			-- Offer only what this build can use: no items above its level, no skills its mana cannot carry.
			local proposalNotes
			if actions and #actions > 0 and not brief
				and planningState ~= "foundation_pending" and planningState ~= "tree_pending" then
				local fitted, notes = AIBridge:FitProposalToBuild(self.build, actions)
				actions = #fitted > 0 and fitted or nil
				if #notes > 0 then
					proposalNotes = table.concat(notes, "\n")
				end
			end
			self.pendingActions = actions
			self.pendingActionsFingerprint = actions and #actions > 0 and responseFingerprint or nil
			self.controls.applyActions.shown = (actions ~= nil and #actions > 0)
			ConPrintf("[AIChat] Parsed %d actions, shown=%s", actions and #actions or 0, tostring(self.controls.applyActions.shown))
			if planningState == "foundation_pending" then
				self.pendingActions = nil
				self.pendingActionsFingerprint = nil
				self.controls.applyActions.shown = false
				self.controls.applyPassivePlan.shown = false
				self.controls.applyFoundation.shown = true
				self.controls.input:SetPlaceholder("Use Apply Foundation or describe a revision...")
				self.controls.status.label = "^7Review build foundation"
				self:StartStream(translit(displayText))
				return
			end
			self.controls.applyFoundation.shown = false
			if planningState == "tree_pending" then
				self.pendingActions = nil
				self.pendingActionsFingerprint = nil
				self.controls.applyActions.shown = false
				self.controls.applyPassivePlan.shown = true
				self.controls.input:SetPlaceholder("Use Apply Passive Plan or describe a revision...")
				self.controls.status.label = "^7Review passive plan"
				self:StartStream(translit(displayText))
				return
			end
			self.controls.applyPassivePlan.shown = false

			if brief then
				self.pendingActions = nil
				self.pendingActionsFingerprint = nil
				self.controls.applyActions.shown = false
				local summary = AIPlanning:FormatBrief(brief)
				displayText = #displayText > 0 and displayText .. "\n\n" .. summary or summary
				self.controls.confirmBrief.shown = true
				self.controls.reviseBrief.shown = true
				self.controls.input:SetPlaceholder("Use Confirm direction or describe a revision...")
			elseif turn.next == "clarify" then
				local question = turn.question
				local lines = { displayText }
				if #lines[1] == 0 then
					lines[1] = "^7" .. question.prompt
				else
					t_insert(lines, "^7" .. question.prompt)
				end
				if question.options and #question.options > 0 then
					t_insert(lines, "^8Options (click a button below or type your answer): " .. table.concat(question.options, " / "))
					self:SetClarificationOptions(question.options)
				end
				displayText = table.concat(lines, "\n\n")
				self.controls.input:SetPlaceholder("Answer: " .. translit(question.prompt))
			else
				self.controls.input:SetPlaceholder("Ask about your build...")
			end

			-- Transliterate only the display text.
			local cleanDisplay = translit(displayText)
			self:StartStream(cleanDisplay)
			if proposalNotes then
				self:AddMessage("system", "^7" .. translit(proposalNotes))
			end
			if requestOptions and requestOptions.saveGuideToNotes then
				if self.build and self.build.notesTab and self.build.notesTab.controls and self.build.notesTab.controls.edit then
					local existingNotes = self.build.notesTab.controls.edit.buf or ""
					local guideHeader = "^x5CF0BB=== AI Playstyle & Leveling Guide ===\n^7"
					self.build.notesTab.controls.edit:SetText(
						(#existingNotes > 0 and (existingNotes .. "\n\n") or "") .. guideHeader .. cleanDisplay
					)
					self.build.notesTab.modFlag = true
					self:AddMessage("system", "^2Playstyle guide also saved to the 'Notes' tab.")
				end
			end
			if actionError then
				self:AddMessage("system", "Action proposal ignored: " .. actionError)
				self.controls.status.label = "^1Action proposal ignored - ask again"
			elseif brief then
				self.controls.status.label = "^7Review build direction"
			elseif turn.next == "clarify" then
				self.controls.status.label = "^7Clarification needed"
			else
				self.controls.status.label = self.controls.applyActions.shown
					and "^2Ready - actions available below" or "^2Ready"
			end
		end)
		if not handled then
			AIBridge.pending = false
			showRequestFailure("AI response processing failed: " .. tostring(handlerError))
		end
	end
	local started, requestError = pcall(
		AIBridge.Ask,
		AIBridge,
		self.build,
		text,
		handleResponse,
		history,
		supersedesUnappliedActions,
		self.conversationSession,
		self.planningSession
	)
	if not started and not responseHandled then
		AIBridge.pending = false
		showRequestFailure("AI request crashed: " .. tostring(requestError))
	end
end

--- Leave the passive tree stage without a plan, for characters whose points reach no notable.
-- The tree stays as it is and the later steps (skills, gear, guide) become available.
function AIChatTabClass:SkipTreeStage()
	if self.pending then
		return
	end
	local session = self.planningSession
	if not session or session.state ~= "tree" or session.passivePlanApplied then
		return
	end
	session.passivePlanApplied = true
	session.treeSkipped = true
	self:AddMessage("system", "^7Passive tree stage skipped. The tree is unchanged.\n^8Ask for skills, gear or the guide whenever you want.")
	self.controls.status.label = "^2Tree stage skipped"
	self.controls.input:SetPlaceholder("Use Complementary Skills, Recommended Gear, or Playstyle Guide below...")
end

--- Confirm a non-executable build direction without mutating the active PoB build.
function AIChatTabClass:ConfirmBrief()
	if self.pending then
		return
	end
	self:RebindRestoredSessions()
	local fingerprint, fingerprintError = AIBridge:GetBuildFingerprint(self.build)
	if not fingerprint then
		self:AddMessage("system", "Error: " .. tostring(fingerprintError))
		self.controls.status.label = "^1Could not confirm direction"
		return
	end
	local confirmed, confirmationOrError = AIPlanning:ConfirmBrief(self.planningSession, fingerprint)
	if not confirmed then
		self:AddMessage("system", "Error: " .. confirmationOrError)
		self.controls.status.label = "^1Could not confirm direction"
		return
	end
	self:FinishStream()
	self.controls.confirmBrief.shown = false
	self.controls.reviseBrief.shown = false
	self.controls.applyActions.shown = false
	self.controls.status.label = "^2Direction confirmed"
	self.controls.input:SetPlaceholder("Preparing build foundation...")
	self:AddMessage("system", "^2Build direction confirmed.\n^8PoB build remains unchanged.")
	self:SelectControl(self.controls.input)
	self:SendRequest("The build direction is confirmed. Propose the build foundation now.")
end

--- Discard the unconfirmed brief while retaining the chat history for a revision request.
function AIChatTabClass:ReviseBrief()
	if self.pending then
		return
	end
	local revised, revisionError = AIPlanning:ReviseBrief(self.planningSession)
	if not revised then
		self:AddMessage("system", "Error: " .. revisionError)
		self.controls.status.label = "^1Could not revise direction"
		return
	end
	self:FinishStream()
	self.controls.confirmBrief.shown = false
	self.controls.reviseBrief.shown = false
	self.controls.status.label = "^7Direction needs revision"
	self.controls.input:SetPlaceholder("Describe what to revise...")
	self:AddMessage("system", "^7Direction needs revision. Describe what to change.")
	self:SelectControl(self.controls.input)
end

--- Finish a progressive reply before another reply replaces the stream cursor.
function AIChatTabClass:FinishStream()
	if not self.streaming then
		return
	end
	local msg = self.messages[self.streamMsgIndex]
	if msg then
		msg.text = msg.full
		self:RefreshHistory()
	end
	self.streaming = false
	self.streamPos = 0
end

--- Start streaming a response (progressive reveal)
function AIChatTabClass:StartStream(fullText)
	self:FinishStream()
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
	if #self.messages == 0 then
		self.controls.history:SetText(
			"^x5CF0BBAI Build Advisor - Ready\n"
			.. "^8Ask about your active build (DPS, EHP, gems, items, passive tree) or start a guided build from scratch.\n"
			.. "^8Quick actions below: 'How do I improve?', 'Next upgrade?', 'Can I tank?', or '+ New Guided Build'."
		)
		self.controls.history.caret = 1
		return
	end
	local lines = {}
	for _, msg in ipairs(self.messages) do
		local prefix
		local contPrefix = "  "
		if msg.role == "user" then
			prefix = "^x5CF0BBYou: ^7"
			contPrefix = "     ^7"
		elseif msg.role == "ai" then
			prefix = "^2AI: ^7"
			contPrefix = "    ^7"
		else
			local isError = msg.text:find("^Error:") or msg.text:find("^%^1") or msg.text:find("ignored:")
			prefix = isError and "^1[!] " or "^x5CF0BB[*] ^7"
			contPrefix = "    "
		end
		for line in (msg.text .. "\n"):gmatch("([^\n]*)\n") do
			t_insert(lines, prefix .. line)
			prefix = contPrefix
		end
		t_insert(lines, "")
	end
	self.controls.history:SetText(table.concat(lines, "\n"))
	self.controls.history.caret = #self.controls.history.buf
	self.controls.history:ScrollCaretIntoView()
end

--- Run one action batch through PoB preflight, fingerprint checks, and metric diff.
function AIChatTabClass:RunActionBatch(actions, fingerprint, labels)
	ConPrintf("[AIChat] RunActionBatch: %d actions", actions and #actions or 0)
	local callOk, report = pcall(
		AIBridge.ApplyActionBatch,
		AIBridge,
		self.build,
		actions,
		fingerprint
	)
	if not callOk then
		report = {
			ok = false,
			applied = false,
			results = { { ok = false, msg = "Action pipeline error: " .. tostring(report) } },
		}
	end

	local lines
	if report.ok then
		lines = { "^7--- " .. labels.okHeader .. " ---" }
	elseif report.partial then
		lines = { "^1--- Partial application error ---" }
	else
		lines = { "^1--- " .. labels.failHeader .. " ---" }
	end

	local okCount, failCount = 0, 0
	for index, result in ipairs(report.results or {}) do
		ConPrintf("[AIChat] Action result %d: ok=%s msg=%s",
			index, tostring(result.ok), result.msg or "nil")
		if result.ok then
			okCount = okCount + 1
			t_insert(lines, "^2[OK] " .. result.msg)
		else
			failCount = failCount + 1
			t_insert(lines, "^1[FAIL] " .. result.msg)
		end
	end

	if report.before and report.after then
		t_insert(lines, "")
		for _, line in ipairs(AIBridge:FormatMetricDiff(report.before, report.after)) do
			t_insert(lines, line)
		end
	end

	if report.ok then
		t_insert(lines, string.format("^7%d applied, %d failed", okCount, failCount))
		self.controls.status.label = labels.okStatus
	elseif report.partial then
		t_insert(lines, string.format("^1%d applied before failure; review the build", okCount))
		self.controls.status.label = "^1Partial changes - review build"
	else
		t_insert(lines, labels.failLine)
		self.controls.status.label = labels.failStatus
	end
	self:AddMessage("system", table.concat(lines, "\n"))
	ConPrintf("[AIChat] Apply complete: ok=%s applied=%s",
		tostring(report.ok), tostring(report.applied))
	return report
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

	self.controls.applyActions.enabled = false
	ConPrintf("[AIChat] Preflighting %d actions", #self.pendingActions)
	self:RunActionBatch(self.pendingActions, self.pendingActionsFingerprint, {
		okHeader = "Applied changes",
		failHeader = "Changes not applied",
		okStatus = "^2Changes applied",
		failLine = "^1No changes were applied",
		failStatus = "^1No changes applied",
	})

	self.pendingActions = nil
	self.pendingActionsFingerprint = nil
	self.conversationSession = nil
	self.controls.applyActions.shown = false
	self.controls.applyActions.enabled = true
end

--- Apply the confirmed foundation batch and advance the local planning session.
function AIChatTabClass:ApplyFoundation()
	if self.pending then
		return
	end
	if not self.planningSession or self.planningSession.state ~= "foundation_pending"
		or not self.planningSession.pendingFoundation then
		self:AddMessage("system", "Error: No foundation batch is awaiting application")
		self.controls.status.label = "^1No foundation to apply"
		return
	end

	local fingerprint, fingerprintError = AIBridge:GetBuildFingerprint(self.build)
	if not fingerprint then
		self:AddMessage("system", "Error: " .. tostring(fingerprintError))
		self.controls.status.label = "^1Could not apply foundation"
		return
	end

	self.controls.applyFoundation.enabled = false
	local report = self:RunActionBatch(
		self.planningSession.pendingFoundation,
		fingerprint,
		{
			okHeader = "Applied foundation",
			failHeader = "Foundation not applied",
			okStatus = "^2Foundation applied",
			failLine = "^1No foundation changes were applied",
			failStatus = "^1Foundation not applied",
		}
	)

	if report.ok then
		local newFingerprint, newFingerprintError = AIBridge:GetBuildFingerprint(self.build)
		if not newFingerprint then
			self:AddMessage("system", "Error: " .. tostring(newFingerprintError))
			self.controls.status.label = "^1Foundation applied but could not advance"
		else
			local advanced, advanceError = AIPlanning:CompleteFoundation(self.planningSession, newFingerprint)
			if not advanced then
				self:AddMessage("system", "Error: " .. advanceError)
				self.controls.status.label = "^1Foundation applied but could not advance"
			else
				self.controls.status.label = "^2Foundation applied - tree stage ready"
				self.controls.input:SetPlaceholder("Ask for the passive tree plan...")
			end
		end
	end

	-- A rejected proposal stays pending, so its button stays until the player revises it.
	self.controls.applyFoundation.shown = self.planningSession.state == "foundation_pending"
	self.controls.applyFoundation.enabled = true
end

--- Apply the proposed passive tree plan without automatically requesting the next stage.
function AIChatTabClass:ApplyPassivePlan()
	if self.pending then
		return
	end
	if not self.planningSession or self.planningSession.state ~= "tree_pending"
		or not self.planningSession.pendingPassivePlan then
		self:AddMessage("system", "Error: No passive plan is awaiting application")
		self.controls.status.label = "^1No passive plan to apply"
		return
	end

	local fingerprint, fingerprintError = AIBridge:GetBuildFingerprint(self.build)
	if not fingerprint then
		self:AddMessage("system", "Error: " .. tostring(fingerprintError))
		self.controls.status.label = "^1Could not apply passive plan"
		return
	end

	self.controls.applyPassivePlan.enabled = false
	local report = self:RunActionBatch(
		self.planningSession.pendingPassivePlan,
		fingerprint,
		{
			okHeader = "Applied passive plan",
			failHeader = "Passive plan not applied",
			okStatus = "^2Passive plan applied",
			failLine = "^1No passive plan changes were applied",
			failStatus = "^1Passive plan not applied",
		}
	)

	if report.ok then
		local newFingerprint, newFingerprintError = AIBridge:GetBuildFingerprint(self.build)
		if not newFingerprint then
			self:AddMessage("system", "Error: " .. tostring(newFingerprintError))
			self.controls.status.label = "^1Passive plan applied but could not update state"
		else
			local completed, completeError = AIPlanning:CompletePassivePlan(self.planningSession, newFingerprint)
			if completed then
				self.controls.status.label = "^2Passive plan applied"
				self.controls.input:SetPlaceholder("Use Complementary Skills, Recommended Gear, or Playstyle Guide below...")
				if self.build and self.build.notesTab and self.build.notesTab.controls and self.build.notesTab.controls.edit then
					local brief = self.planningSession and self.planningSession.confirmedBrief
					if brief then
						local existingNotes = self.build.notesTab.controls.edit.buf or ""
						local summaryBlock = string.format(
							"^x5CF0BB=== AI Guided Build: %s (%s / %s, Lv %d) ===\n^7Priority: ^2%s\n^7Passive tree stage applied (%d action(s)).\n",
							tostring(brief.mainSkill),
							tostring(brief.class),
							tostring(brief.ascendancy),
							tonumber(brief.targetLevel) or 1,
							tostring(brief.priority),
							#(report.results or {})
						)
						if not existingNotes:find("AI Guided Build:", 1, true) then
							self.build.notesTab.controls.edit:SetText(
								(#existingNotes > 0 and (existingNotes .. "\n\n") or "") .. summaryBlock
							)
							self.build.notesTab.modFlag = true
						end
					end
				end
			else
				self:AddMessage("system", "Error: " .. completeError)
				self.controls.status.label = "^1Passive plan applied but could not update state"
			end
		end
	end

	self.controls.applyPassivePlan.shown = self.planningSession.state == "tree_pending"
	self.controls.applyPassivePlan.enabled = true
end

--- Load/Save chat history and local planning state in the build XML (<AIChat> section)
function AIChatTabClass:Load(xml, dbFileName)
	self.messages = {}
	self.conversationSession = nil
	self.planningSession = nil
	for _, node in ipairs(xml or {}) do
		if type(node) == "table" then
			if node.elem == "Message" and node.attrib and node.attrib.role then
				local text = node[1] or node.attrib.text or ""
				t_insert(self.messages, {
					role = node.attrib.role,
					text = text,
					full = text,
				})
			elseif node.elem == "Session" and type(node[1]) == "string" then
				local decoded = dkjson.decode(node[1])
				if type(decoded) == "table" then
					if type(decoded.conversation) == "table" then
						self.conversationSession = decoded.conversation
					end
					if type(decoded.planning) == "table" then
						self.planningSession = decoded.planning
					end
				end
			end
		end
	end
	self.restoredSessions = self.conversationSession ~= nil or self.planningSession ~= nil
	self:RestoreUiFromState()
	self:RefreshHistory()
	self.modFlag = false
	return false
end

function AIChatTabClass:Save(xml)
	if not xml then
		return
	end
	for _, msg in ipairs(self.messages or {}) do
		local content = msg.full or msg.text or ""
		if content ~= "" then
			t_insert(xml, {
				elem = "Message",
				attrib = { role = msg.role or "system" },
				[1] = content,
			})
		end
	end
	if self.conversationSession or self.planningSession then
		local sessionJson = dkjson.encode({
			conversation = self.conversationSession,
			planning = self.planningSession,
		}, { indent = false })
		if sessionJson then
			t_insert(xml, {
				elem = "Session",
				[1] = sessionJson,
			})
		end
	end
	self.modFlag = false
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

	-- Draw subtle header bar and chat panel frame
	SetDrawLayer(nil, -5)
	SetDrawColor(0.08, 0.09, 0.12, 0.92)
	DrawImage(nil, self.x + 4, self.y + 4, self.width - 8, 44)
	SetDrawColor(0.22, 0.28, 0.34, 0.85)
	DrawImage(nil, self.x + 4, self.y + 48, self.width - 8, 1)

	local histX, histY = self.controls.history:GetPos()
	local histW, histH = self.controls.history:GetSize()
	SetDrawColor(0.18, 0.22, 0.27, 0.7)
	DrawImage(nil, histX - 2, histY - 2, histW + 4, histH + 4)
	SetDrawColor(0.05, 0.06, 0.08, 0.95)
	DrawImage(nil, histX, histY, histW, histH)
	SetDrawLayer(nil, 0)

	self:DrawControls(viewPort)
end

return AIChatTabClass
