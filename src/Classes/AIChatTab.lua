-- Path of Building AI Integration
-- AI Chat Tab: conversational interface for build advice
-- Follows the NotesTab pattern (ControlHost + Control)

local t_insert = table.insert
local dkjson = require "dkjson"
local AIBridge = LoadModule("Modules/AIBridge")

local AIChatTabClass = newClass("AIChatTab", "ControlHost", "Control", function(self, build)
	self.ControlHost()
	self.Control()

	self.build = build
	self.messages = {}  -- {role="user"|"ai"|"system", text=string}
	self.pending = false

	-- === TOP: header + build summary ===
	self.controls.header = new("LabelControl", {"TOPLEFT",self,"TOPLEFT"}, {8, 8, 0, 16}, "^7AI Build Advisor")
	self.controls.summary = new("LabelControl", {"TOPLEFT",self.controls.header,"BOTTOMLEFT"}, {0, 4, 0, 16}, "")
	self.controls.summary.label = function()
		return "^8" .. AIBridge:GetBuildSummary(self.build)
	end

	-- === BOTTOM: status, input, quick buttons (anchored from bottom) ===
	self.controls.status = new("LabelControl", {"BOTTOMLEFT",self,"BOTTOMLEFT"}, {8, -4, 0, 16}, "")

	self.controls.input = new("EditControl", {"BOTTOMLEFT",self.controls.status,"TOPLEFT"}, {0, -4, 0, 22}, "", nil, nil, nil, function(buf)
		self.controls.send.enabled = #buf > 0
	end)
	self.controls.input.width = function()
		return self.width - 100
	end
	self.controls.input:SetPlaceholder("Ask about your build...")

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

	-- === MIDDLE: chat history fills remaining space ===
	self.controls.history = new("EditControl", {"TOPLEFT",self.controls.summary,"BOTTOMLEFT"}, {0, 8, 0, 0}, "", nil, "^%C\t\n", nil, nil, 16, true)
	self.controls.history.width = function()
		return self.width - 16
	end
	self.controls.history.height = function()
		-- Fill space between summary and quick buttons
		local top = 52  -- header(8+16) + summary(4+16) + gap(8)
		local bottom = 80  -- quick(20+6) + input(22+4) + status(16+4) + gap(8)
		return math.max(self.height - top - bottom, 100)
	end

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
			self:AddMessage("ai", response)
			self.controls.status.label = "^2Ready"
		end
	end)
end

--- Add a message to the chat history display
function AIChatTabClass:AddMessage(role, text)
	t_insert(self.messages, { role = role, text = text })
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
	self.width = viewPort.width
	self.height = viewPort.height
	self:ProcessControlsInput(inputEvents, viewPort)
	self:DrawControls(viewPort)
end

return AIChatTabClass
