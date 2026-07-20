-- Path of Building AI Integration
-- Painel de configuração de IA (API Key, Endpoint, Modelo)
-- Integrado na UI do PoB via sistema de controles existente

local AIConfig = require("Modules/AIConfig")

local AIConfigPanel = {
	controls = {},
	shown = false,
}

-- Cria os controles do painel
function AIConfigPanel:Create(parent)
	local controls = self.controls
	
	-- Título
	controls.title = new("LabelControl", { "TOPLEFT", parent, "TOPLEFT" }, { 8, 8, 0, 16 }, "^7Configuração de IA")
	controls.title.width = 300
	
	-- API Key
	controls.apiKeyLabel = new("LabelControl", { "TOPLEFT", controls.title, "BOTTOMLEFT" }, { 0, 12, 0, 16 }, "API Key:")
	controls.apiKey = new("EditControl", { "TOPLEFT", controls.apiKeyLabel, "BOTTOMLEFT" }, { 0, 4, 300, 20 }, "", nil, "^8", nil, function(buf)
		-- Validação ao digitar
		if #buf > 0 and #buf < 10 then
			controls.apiKey:SetPlaceholder("Muito curta")
		end
	end)
	controls.apiKey:SetPlaceholder("sk-... ou sua chave de API")
	
	-- Endpoint
	controls.endpointLabel = new("LabelControl", { "TOPLEFT", controls.apiKey, "BOTTOMLEFT" }, { 0, 12, 0, 16 }, "Endpoint (OpenAI-compatible):")
	controls.endpoint = new("EditControl", { "TOPLEFT", controls.endpointLabel, "BOTTOMLEFT" }, { 0, 4, 300, 20 }, "", nil, "^8", nil, nil)
	controls.endpoint:SetPlaceholder("https://api.openai.com/v1")
	
	-- Modelo
	controls.modelLabel = new("LabelControl", { "TOPLEFT", controls.endpoint, "BOTTOMLEFT" }, { 0, 12, 0, 16 }, "Modelo:")
	controls.model = new("EditControl", { "TOPLEFT", controls.modelLabel, "BOTTOMLEFT" }, { 0, 4, 300, 20 }, "", nil, "^8", nil, nil)
	controls.model:SetPlaceholder("gpt-4o, qwen3.7-max, etc.")
	
	-- Botão Salvar
	controls.save = new("ButtonControl", { "TOPLEFT", controls.model, "BOTTOMLEFT" }, { 0, 16, 140, 24 }, "Salvar", function()
		self:SaveConfig()
	end)
	
	-- Botão Cancelar
	controls.cancel = new("ButtonControl", { "LEFT", controls.save, "RIGHT" }, { 8, 0, 140, 24 }, "Cancelar", function()
		self:Hide()
	end)
	
	-- Status
	controls.status = new("LabelControl", { "TOPLEFT", controls.save, "BOTTOMLEFT" }, { 0, 8, 0, 16 }, "")
	controls.status.width = 300
	
	-- Carrega config atual
	self:LoadConfigToUI()
end

-- Carrega config atual para os campos
function AIConfigPanel:LoadConfigToUI()
	local config = AIConfig.config
	
	if config.api_key and config.api_key ~= "" then
		-- Mostra apenas os últimos 4 caracteres por segurança
		local masked = string.rep("•", 20) .. string.sub(config.api_key, -4)
		self.controls.apiKey:SetText(masked)
		self.controls.apiKey.buf = config.api_key  -- Mantém o valor real no buffer
	else
		self.controls.apiKey:SetText("")
	end
	
	self.controls.endpoint:SetText(config.api_endpoint or "")
	self.controls.model:SetText(config.model or "")
end

-- Salva configuração da UI
function AIConfigPanel:SaveConfig()
	local controls = self.controls
	
	-- Valida API Key
	local apiKey = controls.apiKey.buf
	if apiKey == "" or #apiKey < 10 then
		controls.status:SetText("^1API Key inválida ou vazia")
		return
	end
	
	-- Valida Endpoint
	local endpoint = controls.endpoint.buf
	if endpoint == "" then
		controls.status:SetText("^1Endpoint não pode ser vazio")
		return
	end
	
	-- Valida Modelo
	local model = controls.model.buf
	if model == "" then
		controls.status:SetText("^1Modelo não pode ser vazio")
		return
	end
	
	-- Salva
	AIConfig:SetAPIKey(apiKey)
	AIConfig:SetEndpoint(endpoint)
	AIConfig:SetModel(model)
	
	local ok, err = AIConfig:Save()
	if ok then
		controls.status:SetText("^2Configuração salva com sucesso!")
	else
		controls.status:SetText("^1Erro ao salvar: " .. tostring(err))
	end
end

-- Mostra o painel
function AIConfigPanel:Show()
	self.shown = true
	-- Aqui você integraria com o sistema de modais/popups do PoB
	-- Por exemplo: main:OpenPopup(self.controls, "AIConfig")
end

-- Esconde o painel
function AIConfigPanel:Hide()
	self.shown = false
	-- main:ClosePopup()
end

return AIConfigPanel
