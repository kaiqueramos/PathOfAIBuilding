-- Path of Building AI Integration
-- AI configuration panel (API Key, Endpoint, Model)
-- Integrated into PoB UI via popup system

local AIConfig = LoadModule("Modules/AIConfig")

local AIConfigPanel = {}

-- Opens the AI configuration popup
function AIConfigPanel:OpenPopup()
	local controls = {}
	
	-- Initialize AIConfig if needed
	if not AIConfig.configPath then
		AIConfig:Init(main.userPath)
	end
	local config = AIConfig.config
	
	-- Title
	controls.title = new("LabelControl", nil, {0, 20, 0, 16}, "^7AI Configuration")
	
	-- API Key (protected field - shows asterisks)
	controls.apiKeyLabel = new("LabelControl", nil, {0, 50, 0, 16}, "API Key:")
	controls.apiKey = new("EditControl", nil, {0, 70, 300, 20}, config.api_key or "", nil, nil, nil, function(buf)
		-- Validation on input
	end)
	controls.apiKey:SetProtected(true)  -- Hides key with asterisks
	controls.apiKey:SetPlaceholder("sk-... or your API key")
	
	-- Endpoint
	controls.endpointLabel = new("LabelControl", nil, {0, 100, 0, 16}, "Endpoint (OpenAI-compatible):")
	controls.endpoint = new("EditControl", nil, {0, 120, 300, 20}, config.api_endpoint or "", nil, nil, nil, nil)
	controls.endpoint:SetPlaceholder("https://api.openai.com/v1")
	
	-- Model
	controls.modelLabel = new("LabelControl", nil, {0, 150, 0, 16}, "Model:")
	controls.model = new("EditControl", nil, {0, 170, 300, 20}, config.model or "", nil, nil, nil, nil)
	controls.model:SetPlaceholder("gpt-4o, qwen3.7-max, etc.")
	
	-- Test Connection button
	controls.test = new("ButtonControl", nil, {0, 200, 140, 24}, "Test Connection", function()
		self:TestConnection(controls)
	end)
	
	-- Save button
	controls.save = new("ButtonControl", nil, {0, 230, 140, 24}, "Save", function()
		self:SaveConfig(controls)
	end)
	
	-- Cancel button
	controls.cancel = new("ButtonControl", nil, {150, 230, 140, 24}, "Cancel", function()
		main:ClosePopup()
	end)
	
	-- Status
	controls.status = new("LabelControl", nil, {0, 260, 0, 16}, "")
	
	-- Open popup
	main:OpenPopup(320, 290, "AI Configuration", controls, "save", "apiKey", "cancel")
end

-- Tests the API connection
function AIConfigPanel:TestConnection(controls)
	local apiKey = controls.apiKey.buf
	local endpoint = controls.endpoint.buf
	local model = controls.model.buf
	
	-- Basic validations
	if apiKey == "" or #apiKey < 10 then
		controls.status.label = "^1Invalid or empty API Key"
		return
	end
	
	if endpoint == "" then
		controls.status.label = "^1Endpoint cannot be empty"
		return
	end
	
	if not string.match(endpoint, "^https://") then
		controls.status.label = "^1Endpoint must use HTTPS"
		return
	end
	
	if model == "" then
		controls.status.label = "^1Model cannot be empty"
		return
	end
	
	controls.status.label = "^7Testing connection..."
	
	-- Here we would make a real request to /v1/models
	-- For now, just validates the format
	controls.status.label = "^2Valid format! (Real connection test will be implemented with AIBridge)"
end

-- Saves the configuration
function AIConfigPanel:SaveConfig(controls)
	local apiKey = controls.apiKey.buf
	local endpoint = controls.endpoint.buf
	local model = controls.model.buf
	
	-- Validations
	if apiKey == "" or #apiKey < 10 then
		controls.status.label = "^1Invalid or empty API Key"
		return
	end
	
	if endpoint == "" then
		controls.status.label = "^1Endpoint cannot be empty"
		return
	end
	
	if not string.match(endpoint, "^https://") then
		controls.status.label = "^1Endpoint must use HTTPS"
		return
	end
	
	if model == "" then
		controls.status.label = "^1Model cannot be empty"
		return
	end
	
	-- Save
	AIConfig:SetAPIKey(apiKey)
	AIConfig:SetEndpoint(endpoint)
	AIConfig:SetModel(model)
	
	local ok, err = AIConfig:Save()
	if ok then
		controls.status.label = "^2Configuration saved successfully!"
		main:ClosePopup()
	else
		controls.status.label = "^1Error saving: " .. tostring(err)
	end
end

return AIConfigPanel
