-- Path of Building AI Integration
-- Painel de configuração de IA (API Key, Endpoint, Modelo)
-- Integrado na UI do PoB via sistema de popup

local AIConfig = LoadModule("Modules/AIConfig")

local AIConfigPanel = {}

-- Abre o popup de configuração de IA
function AIConfigPanel:OpenPopup()
	local controls = {}
	
	-- Inicializa AIConfig se necessário
	if not AIConfig.configPath then
		AIConfig:Init(main.userPath)
	end
	local config = AIConfig.config
	
	-- Título
	controls.title = new("LabelControl", nil, {0, 20, 0, 16}, "^7Configuração de IA")
	
	-- API Key (campo protegido - mostra asteriscos)
	controls.apiKeyLabel = new("LabelControl", nil, {0, 50, 0, 16}, "API Key:")
	controls.apiKey = new("EditControl", nil, {0, 70, 300, 20}, config.api_key or "", nil, nil, nil, function(buf)
		-- Validação ao digitar
	end)
	controls.apiKey:SetProtected(true)  -- Esconde a key com asteriscos
	controls.apiKey:SetPlaceholder("sk-... ou sua chave de API")
	
	-- Endpoint
	controls.endpointLabel = new("LabelControl", nil, {0, 100, 0, 16}, "Endpoint (OpenAI-compatible):")
	controls.endpoint = new("EditControl", nil, {0, 120, 300, 20}, config.api_endpoint or "", nil, nil, nil, nil)
	controls.endpoint:SetPlaceholder("https://api.openai.com/v1")
	
	-- Modelo
	controls.modelLabel = new("LabelControl", nil, {0, 150, 0, 16}, "Modelo:")
	controls.model = new("EditControl", nil, {0, 170, 300, 20}, config.model or "", nil, nil, nil, nil)
	controls.model:SetPlaceholder("gpt-4o, qwen3.7-max, etc.")
	
	-- Botão Testar Conexão
	controls.test = new("ButtonControl", nil, {0, 200, 140, 24}, "Testar Conexão", function()
		self:TestConnection(controls)
	end)
	
	-- Botão Salvar
	controls.save = new("ButtonControl", nil, {0, 230, 140, 24}, "Salvar", function()
		self:SaveConfig(controls)
	end)
	
	-- Botão Cancelar
	controls.cancel = new("ButtonControl", nil, {150, 230, 140, 24}, "Cancelar", function()
		main:ClosePopup()
	end)
	
	-- Status
	controls.status = new("LabelControl", nil, {0, 260, 0, 16}, "")
	
	-- Abre o popup
	main:OpenPopup(320, 290, "Configuração de IA", controls, "save", "apiKey", "cancel")
end

-- Testa a conexão com a API
function AIConfigPanel:TestConnection(controls)
	local apiKey = controls.apiKey.buf
	local endpoint = controls.endpoint.buf
	local model = controls.model.buf
	
	-- Validações básicas
	if apiKey == "" or #apiKey < 10 then
		controls.status.label = "^1API Key inválida ou vazia"
		return
	end
	
	if endpoint == "" then
		controls.status.label = "^1Endpoint não pode ser vazio"
		return
	end
	
	if not string.match(endpoint, "^https://") then
		controls.status.label = "^1Endpoint deve usar HTTPS"
		return
	end
	
	if model == "" then
		controls.status.label = "^1Modelo não pode ser vazio"
		return
	end
	
	controls.status.label = "^7Testando conexão..."
	
	-- Aqui faríamos um request real para /v1/models
	-- Por enquanto, apenas valida o formato
	controls.status.label = "^2Formato válido! (Teste de conexão real será implementado com o AIBridge)"
end

-- Salva a configuração
function AIConfigPanel:SaveConfig(controls)
	local apiKey = controls.apiKey.buf
	local endpoint = controls.endpoint.buf
	local model = controls.model.buf
	
	-- Validações
	if apiKey == "" or #apiKey < 10 then
		controls.status.label = "^1API Key inválida ou vazia"
		return
	end
	
	if endpoint == "" then
		controls.status.label = "^1Endpoint não pode ser vazio"
		return
	end
	
	if not string.match(endpoint, "^https://") then
		controls.status.label = "^1Endpoint deve usar HTTPS"
		return
	end
	
	if model == "" then
		controls.status.label = "^1Modelo não pode ser vazio"
		return
	end
	
	-- Salva
	AIConfig:SetAPIKey(apiKey)
	AIConfig:SetEndpoint(endpoint)
	AIConfig:SetModel(model)
	
	local ok, err = AIConfig:Save()
	if ok then
		controls.status.label = "^2Configuração salva com sucesso!"
		main:ClosePopup()
	else
		controls.status.label = "^1Erro ao salvar: " .. tostring(err)
	end
end

return AIConfigPanel
