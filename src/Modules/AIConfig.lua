-- Path of Building AI Integration
-- Secure API key configuration module
-- Stores config in userPath (outside the repository)
-- Singleton: all LoadModule calls share the same instance
-- cspell:ignore qwen

local dkjson = require "dkjson"

local RESERVED_REQUEST_OPTION_FIELDS = {
	model = true,
	messages = true,
	stream = true,
}

-- Singleton guard: return cached instance if already loaded
if _G._AIConfigInstance then
	return _G._AIConfigInstance
end

local AIConfig = {
	config = {},
	configPath = nil,
}

-- Initialize config path based on PoB's userPath
function AIConfig:Init(userPath)
	if not userPath then
		return false, "userPath not provided"
	end

	self.configPath = userPath .. "ai_config.json"
	return self:Load()
end

-- Load configuration from JSON file
function AIConfig:Load()
	if not self.configPath then
		return false, "configPath not initialized"
	end

	local file = io.open(self.configPath, "r")
	if not file then
		-- File doesn't exist, use defaults
		self.config = self:GetDefaults()
		return true
	end

	local content = file:read("*all")
	file:close()

	local config, err = dkjson.decode(content)
	if not config then
		return false, "Error parsing config: " .. tostring(err)
	end

	-- Merge with defaults (for missing fields)
	self.config = self:GetDefaults()
	for k, v in pairs(config) do
		self.config[k] = v
	end

	return true
end

-- Save configuration to JSON file
function AIConfig:Save()
	if not self.configPath then
		return false, "configPath not initialized"
	end

	local content = dkjson.encode(self.config, { indent = true })

	local file = io.open(self.configPath, "w")
	if not file then
		return false, "Cannot open file for writing"
	end

	file:write(content)
	file:close()

	-- Restrict permissions (owner read/write only)
	os.execute('chmod 600 "' .. self.configPath .. '" 2>/dev/null')

	return true
end

-- Returns default configuration
function AIConfig:GetDefaults()
	return {
		api_endpoint = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
		api_key = "",
		model = "qwen3.7-max",
		timeout = 120,
		debug_logging = false,
		request_options = {},
		config_version = 1,
	}
end

-- Validate optional provider-specific JSON fields while preserving the bridge contract.
function AIConfig:ValidateRequestOptions(options)
	if options == nil then
		return true
	end
	if type(options) ~= "table" then
		return false, "Request options must be a JSON object"
	end
	for key in pairs(options) do
		if type(key) ~= "string" then
			return false, "Request option keys must be strings"
		end
		if RESERVED_REQUEST_OPTION_FIELDS[key] then
			return false, "Request option '" .. key .. "' is managed by the app"
		end
	end
	return true
end

-- Validate that configuration is complete
function AIConfig:Validate()
	if not self.config.api_key or self.config.api_key == "" then
		return false, "API Key not configured"
	end

	if not self.config.api_endpoint or self.config.api_endpoint == "" then
		return false, "API Endpoint not configured"
	end

	if not self.config.api_endpoint:match("^https://") then
		return false, "API Endpoint must use HTTPS"
	end

	if not self.config.model or self.config.model == "" then
		return false, "Model not configured"
	end

	local timeout = tonumber(self.config.timeout)
	if not timeout or timeout < 1 or timeout > 600 then
		return false, "Timeout must be between 1 and 600 seconds"
	end

	return self:ValidateRequestOptions(self.config.request_options)
end

-- Returns the API key (for use in requests)
-- NEVER log this
function AIConfig:GetAPIKey()
	return self.config.api_key or ""
end

-- Returns the endpoint
function AIConfig:GetEndpoint()
	return self.config.api_endpoint or ""
end

-- Returns the model
function AIConfig:GetModel()
	return self.config.model or ""
end

-- Returns the request timeout in seconds
function AIConfig:GetTimeout()
	return tonumber(self.config.timeout) or self:GetDefaults().timeout
end

-- Returns provider-specific OpenAI-compatible request fields.
function AIConfig:GetRequestOptions()
	return self.config.request_options or {}
end

-- Updates the API key
function AIConfig:SetAPIKey(key)
	self.config.api_key = key
	return self:Save()
end

-- Updates the endpoint
function AIConfig:SetEndpoint(endpoint)
	self.config.api_endpoint = endpoint
	return self:Save()
end

-- Updates the model
function AIConfig:SetModel(model)
	self.config.model = model
	return self:Save()
end

-- Updates provider-specific OpenAI-compatible request fields.
function AIConfig:SetRequestOptions(options)
	local ok, err = self:ValidateRequestOptions(options)
	if not ok then
		return false, err
	end
	self.config.request_options = options or {}
	return self:Save()
end

-- Clears the API key (for logout/reset)
function AIConfig:ClearAPIKey()
	self.config.api_key = ""
	return self:Save()
end

-- Returns sanitized config (no key) for logging/debug
function AIConfig:GetSanitizedConfig()
	local sanitized = {}
	for k, v in pairs(self.config) do
		if k == "api_key" then
			sanitized[k] = v ~= "" and "[SET]" or "[EMPTY]"
		else
			sanitized[k] = v
		end
	end
	return sanitized
end

-- Cache singleton globally
_G._AIConfigInstance = AIConfig

return AIConfig
