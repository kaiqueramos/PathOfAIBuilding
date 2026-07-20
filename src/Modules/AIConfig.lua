-- Path of Building AI Integration
-- Módulo de configuração segura para chaves de API
-- Armazena configurações no userPath (fora do repositório)

local AIConfig = {
	config = {},
	configPath = nil,
}

-- Inicializa o caminho do config baseado no userPath do PoB
function AIConfig:Init(userPath)
	if not userPath then
		return false, "userPath não fornecido"
	end
	
	self.configPath = userPath .. "ai_config.json"
	return self:Load()
end

-- Carrega configurações do arquivo JSON
function AIConfig:Load()
	if not self.configPath then
		return false, "configPath não inicializado"
	end
	
	local file = io.open(self.configPath, "r")
	if not file then
		-- Arquivo não existe, usa defaults
		self.config = self:GetDefaults()
		return true
	end
	
	local content = file:read("*all")
	file:close()
	
	-- Parse JSON (usando dkjson que já vem no PoB)
	local json = require("dkjson")
	local config, err = json.decode(content)
	
	if not config then
		return false, "Erro ao parsear config: " .. tostring(err)
	end
	
	-- Merge com defaults (para campos faltantes)
	self.config = self:GetDefaults()
	for k, v in pairs(config) do
		self.config[k] = v
	end
	
	return true
end

-- Salva configurações no arquivo JSON
function AIConfig:Save()
	if not self.configPath then
		return false, "configPath não inicializado"
	end
	
	local json = require("dkjson")
	local content = json.encode(self.config, { indent = true })
	
	local file = io.open(self.configPath, "w")
	if not file then
		return false, "Não foi possível abrir arquivo para escrita"
	end
	
	file:write(content)
	file:close()
	
	-- Define permissões restritas (apenas owner pode ler)
	-- Isso é importante para proteger a API key
	os.execute('chmod 600 "' .. self.configPath .. '" 2>/dev/null')
	
	return true
end

-- Retorna configurações padrão
function AIConfig:GetDefaults()
	return {
		-- Endpoint da API de IA (OpenAI-compatible)
		api_endpoint = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
		
		-- API Key (NUNCA commitar isso)
		api_key = "",
		
		-- Modelo a usar
		model = "qwen3.7-max",
		
		-- Timeout para requests (segundos)
		timeout = 120,
		
		-- Habilitar logging de requests (sem keys)
		debug_logging = false,
		
		-- Versão do config (para migrações futuras)
		config_version = 1,
	}
end

-- Valida se a configuração está completa
function AIConfig:Validate()
	if not self.config.api_key or self.config.api_key == "" then
		return false, "API Key não configurada"
	end
	
	if not self.config.api_endpoint or self.config.api_endpoint == "" then
		return false, "API Endpoint não configurado"
	end
	
	if not self.config.model or self.config.model == "" then
		return false, "Modelo não configurado"
	end
	
	return true
end

-- Retorna a API key (para uso em requests)
-- NUNCA logue isso
function AIConfig:GetAPIKey()
	return self.config.api_key or ""
end

-- Retorna o endpoint
function AIConfig:GetEndpoint()
	return self.config.api_endpoint or ""
end

-- Retorna o modelo
function AIConfig:GetModel()
	return self.config.model or ""
end

-- Atualiza a API key
function AIConfig:SetAPIKey(key)
	self.config.api_key = key
	return self:Save()
end

-- Atualiza o endpoint
function AIConfig:SetEndpoint(endpoint)
	self.config.api_endpoint = endpoint
	return self:Save()
end

-- Atualiza o modelo
function AIConfig:SetModel(model)
	self.config.model = model
	return self:Save()
end

-- Limpa a API key (para logout/reset)
function AIConfig:ClearAPIKey()
	self.config.api_key = ""
	return self:Save()
end

-- Retorna config sanitizada (sem a key) para logging/debug
function AIConfig:GetSanitizedConfig()
	local sanitized = {}
	for k, v in pairs(self.config) do
		if k == "api_key" then
			sanitized[k] = v ~= "" and "[CONFIGURADA]" or "[VAZIA]"
		else
			sanitized[k] = v
		end
	end
	return sanitized
end

return AIConfig
