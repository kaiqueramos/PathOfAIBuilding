local dkjson = require "dkjson"

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

local function validConfig(overrides)
	local config = {
		api_endpoint = "https://example.invalid/v1",
		api_key = "test-api-key",
		model = "test-model",
		timeout = 120,
	}
	for key, value in pairs(overrides or {}) do
		config[key] = value
	end
	return config
end

describe("AI connection", function()
	it("tests unsaved configuration through a minimal chat completion", function()
		local bridge = LoadModule("Modules/AIBridge")
		local originalDownloadPage = launch.DownloadPage
		local capturedUrl
		local capturedOptions
		local callbackOk
		local callbackError

		launch.DownloadPage = function(_, url, callback, options)
			capturedUrl = url
			capturedOptions = options
			callback({
				body = '{"choices":[{"message":{"content":"OK"}}]}',
			}, nil)
		end

		local ok, err = pcall(function()
			bridge:TestConnection(validConfig({
				api_endpoint = "https://example.invalid/v1/",
				timeout = 37,
			}), function(success, connectionError)
				callbackOk = success
				callbackError = connectionError
			end)
		end)
		launch.DownloadPage = originalDownloadPage
		assert(ok, err)

		assert.is_true(callbackOk)
		assert.is_nil(callbackError)
		assert.are.equal("https://example.invalid/v1/chat/completions", capturedUrl)
		assert.are.equal(37, capturedOptions.timeout)
		assert.is_truthy(capturedOptions.header:find("Authorization: Bearer test-api-key", 1, true))
		local request = assert(dkjson.decode(capturedOptions.body))
		assert.are.equal("test-model", request.model)
		assert.are.equal("Reply with OK.", request.messages[1].content)
	end)

	it("reports provider failures without accepting the configuration", function()
		local bridge = LoadModule("Modules/AIBridge")
		local originalDownloadPage = launch.DownloadPage
		local callbackOk
		local callbackError

		launch.DownloadPage = function(_, _, callback)
			callback(nil, "Response code: 401")
		end
		local ok, err = pcall(function()
			bridge:TestConnection(validConfig(), function(success, connectionError)
				callbackOk = success
				callbackError = connectionError
			end)
		end)
		launch.DownloadPage = originalDownloadPage
		assert(ok, err)

		assert.is_false(callbackOk)
		assert.are.equal("API request failed: Response code: 401", callbackError)
	end)

	it("rejects insecure endpoints before sending the API key", function()
		local bridge = LoadModule("Modules/AIBridge")
		local originalDownloadPage = launch.DownloadPage
		local transportCalled = false
		local callbackOk
		local callbackError

		launch.DownloadPage = function()
			transportCalled = true
		end
		local ok, err = pcall(function()
			bridge:TestConnection(validConfig({ api_endpoint = "http://example.invalid/v1" }), function(success, connectionError)
				callbackOk = success
				callbackError = connectionError
			end)
		end)
		launch.DownloadPage = originalDownloadPage
		assert(ok, err)

		assert.is_false(transportCalled)
		assert.is_false(callbackOk)
		assert.are.equal("Endpoint must use HTTPS", callbackError)
	end)

	it("updates the configuration popup after the asynchronous result", function()
		local panel = LoadModule("Classes/AIConfigPanel")
		local bridge = assert(findUpvalue(panel.TestConnection, "AIBridge"))
		local originalTestConnection = bridge.TestConnection
		local controls = {
			apiKey = { buf = "test-api-key" },
			endpoint = { buf = "https://example.invalid/v1" },
			model = { buf = "test-model" },
			status = { label = "" },
			test = { enabled = true },
			save = { enabled = true },
		}
		local disabledDuringRequest = false

		bridge.TestConnection = function(_, _, callback)
			disabledDuringRequest = not controls.test.enabled and not controls.save.enabled
			callback(true)
		end
		local ok, err = pcall(panel.TestConnection, panel, controls)
		bridge.TestConnection = originalTestConnection
		assert(ok, err)

		assert.is_true(disabledDuringRequest)
		assert.is_true(controls.test.enabled)
		assert.is_true(controls.save.enabled)
		assert.are.equal("^2Connection successful", controls.status.label)
	end)
end)

describe("AI request timeout", function()
	it("rejects invalid timeout and insecure persisted configuration", function()
		local configModule = LoadModule("Modules/AIConfig")
		local originalConfig = configModule.config

		configModule.config = validConfig({ timeout = 0 })
		local timeoutOk, timeoutError = configModule:Validate()
		configModule.config = validConfig({ api_endpoint = "http://example.invalid/v1" })
		local endpointOk, endpointError = configModule:Validate()
		configModule.config = originalConfig

		assert.is_false(timeoutOk)
		assert.are.equal("Timeout must be between 1 and 600 seconds", timeoutError)
		assert.is_false(endpointOk)
		assert.are.equal("API Endpoint must use HTTPS", endpointError)
	end)

	it("configures total and connection timeouts in the lcurl subprocess", function()
		local originalLaunchSubScript = _G.LaunchSubScript
		local originalSubScripts = launch.subScripts
		local captured
		launch.subScripts = {}
		_G.LaunchSubScript = function(script, _, _, url, header, body, protocol, proxy, noSSL, timeout)
			captured = {
				script = script,
				url = url,
				header = header,
				body = body,
				protocol = protocol,
				proxy = proxy,
				noSSL = noSSL,
				timeout = timeout,
			}
			return 42
		end

		local ok, err = pcall(function()
			launch:DownloadPage("https://example.invalid", function() end, { timeout = 120 })
		end)
		_G.LaunchSubScript = originalLaunchSubScript
		launch.subScripts = originalSubScripts
		assert(ok, err)
		assert.are.equal(120, captured.timeout)

		local options = {}
		local writeFunction
		local fakeCurl = {
			OPT_HTTPHEADER = "HTTPHEADER",
			OPT_USERAGENT = "USERAGENT",
			OPT_ACCEPT_ENCODING = "ACCEPT_ENCODING",
			OPT_FOLLOWLOCATION = "FOLLOWLOCATION",
			OPT_TIMEOUT = "TIMEOUT",
			OPT_CONNECTTIMEOUT = "CONNECTTIMEOUT",
			OPT_POST = "POST",
			OPT_POSTFIELDS = "POSTFIELDS",
			OPT_IPRESOLVE = "IPRESOLVE",
			OPT_PROXY = "PROXY",
			OPT_SSL_VERIFYPEER = "SSL_VERIFYPEER",
			OPT_SSL_VERIFYHOST = "SSL_VERIFYHOST",
			INFO_RESPONSE_CODE = "RESPONSE_CODE",
		}
		local easy = {}
		function easy:setopt(option, value)
			options[option] = value
		end
		function easy:setopt_url(value)
			options.url = value
		end
		function easy:setopt_headerfunction() end
		function easy:setopt_writefunction(callback)
			writeFunction = callback
		end
		function easy:perform()
			writeFunction("{}")
			return true, nil
		end
		function easy:getinfo()
			return 200
		end
		function easy:close() end
		fakeCurl.easy = function()
			return easy
		end

		local chunk, loadError = loadstring(captured.script)
		assert(chunk, loadError)
		setfenv(chunk, setmetatable({
			require = function(name)
				assert.are.equal("lcurl.safe", name)
				return fakeCurl
			end,
			ConPrintf = function() end,
		}, { __index = _G }))
		chunk(
			captured.url,
			captured.header,
			captured.body,
			captured.protocol,
			captured.proxy,
			captured.noSSL,
			captured.timeout
		)

		assert.are.equal(120, options.TIMEOUT)
		assert.are.equal(10, options.CONNECTTIMEOUT)
	end)
end)
