-- Path of Building AI Integration
-- AI configuration panel (API Key, Endpoint, Model)
-- Integrated into PoB UI via popup system
-- cspell:ignore qwen

local AIConfig = LoadModule("Modules/AIConfig")
local AIBridge = LoadModule("Modules/AIBridge")

local AIConfigPanel = {}

-- Opens the AI configuration popup
function AIConfigPanel:OpenPopup()
	local controls = {}

	-- Initialize AIConfig if needed
	if not AIConfig.configPath then
		AIConfig:Init(main.userPath)
	end
	local config = AIConfig.config

	local labelX = 8
	local fieldW = 280

	-- API Key label + field (protected - shows asterisks)
	controls.apiKeyLabel = new("LabelControl", { "TOPLEFT", nil, "TOPLEFT" }, { labelX, 20, 0, 16 }, "^7API Key:")
	controls.apiKey = new("EditControl", { "TOPLEFT", controls.apiKeyLabel, "BOTTOMLEFT" }, { 0, 4, fieldW, 20 }, config.api_key or "", nil, nil, nil, nil)
	controls.apiKey:SetProtected(true)
	controls.apiKey:SetPlaceholder("sk-... or your API key")

	-- Endpoint label + field
	controls.endpointLabel = new("LabelControl", { "TOPLEFT", controls.apiKey, "BOTTOMLEFT" }, { 0, 12, 0, 16 }, "^7Endpoint (OpenAI-compatible):")
	controls.endpoint = new("EditControl", { "TOPLEFT", controls.endpointLabel, "BOTTOMLEFT" }, { 0, 4, fieldW, 20 }, config.api_endpoint or "", nil, nil, nil, nil)
	controls.endpoint:SetPlaceholder("https://api.openai.com/v1")

	-- Model label + field
	controls.modelLabel = new("LabelControl", { "TOPLEFT", controls.endpoint, "BOTTOMLEFT" }, { 0, 12, 0, 16 }, "^7Model:")
	controls.model = new("EditControl", { "TOPLEFT", controls.modelLabel, "BOTTOMLEFT" }, { 0, 4, fieldW, 20 }, config.model or "", nil, nil, nil, nil)
	controls.model:SetPlaceholder("gpt-4o, qwen3.7-max, etc.")

	-- Status label
	controls.status = new("LabelControl", { "TOPLEFT", controls.model, "BOTTOMLEFT" }, { 0, 12, fieldW, 16 }, "")

	-- Buttons row
	controls.test = new("ButtonControl", { "TOPLEFT", controls.status, "BOTTOMLEFT" }, { 0, 8, 90, 24 }, "Test", function()
		self:TestConnection(controls)
	end)
	controls.save = new("ButtonControl", { "LEFT", controls.test, "RIGHT" }, { 8, 0, 90, 24 }, "Save", function()
		self:SaveConfig(controls)
	end)
	controls.cancel = new("ButtonControl", { "LEFT", controls.save, "RIGHT" }, { 8, 0, 90, 24 }, "Cancel", function()
		main:ClosePopup()
	end)

	main:OpenPopup(310, 260, "AI Configuration", controls, "save", "apiKey", "cancel")
end

-- Tests the API connection
function AIConfigPanel:TestConnection(controls)
	local apiKey = controls.apiKey.buf
	local endpoint = controls.endpoint.buf
	local model = controls.model.buf

	if apiKey == "" or #apiKey < 10 then
		controls.status.label = "^1Invalid or empty API Key"
		return
	end
	if endpoint == "" then
		controls.status.label = "^1Endpoint cannot be empty"
		return
	end
	if not endpoint:match("^https://") then
		controls.status.label = "^1Endpoint must use HTTPS"
		return
	end
	if model == "" then
		controls.status.label = "^1Model cannot be empty"
		return
	end

	controls.status.label = "^7Testing connection..."
	controls.test.enabled = false
	controls.save.enabled = false
	AIBridge:TestConnection({
		api_key = apiKey,
		api_endpoint = endpoint,
		model = model,
		timeout = AIConfig:GetTimeout(),
	}, function(ok, errMsg)
		controls.test.enabled = true
		controls.save.enabled = true
		if ok then
			controls.status.label = "^2Connection successful"
		else
			controls.status.label = "^1Connection failed: " .. tostring(errMsg)
		end
	end)
end

-- Saves the configuration
function AIConfigPanel:SaveConfig(controls)
	local apiKey = controls.apiKey.buf
	local endpoint = controls.endpoint.buf
	local model = controls.model.buf

	if apiKey == "" or #apiKey < 10 then
		controls.status.label = "^1Invalid or empty API Key"
		return
	end
	if endpoint == "" then
		controls.status.label = "^1Endpoint cannot be empty"
		return
	end
	if not endpoint:match("^https://") then
		controls.status.label = "^1Endpoint must use HTTPS"
		return
	end
	if model == "" then
		controls.status.label = "^1Model cannot be empty"
		return
	end

	AIConfig:SetAPIKey(apiKey)
	AIConfig:SetEndpoint(endpoint)
	AIConfig:SetModel(model)

	local ok, err = AIConfig:Save()
	if ok then
		controls.status.label = "^2Saved!"
		main:ClosePopup()
	else
		controls.status.label = "^1Error saving: " .. tostring(err)
	end
end

return AIConfigPanel
