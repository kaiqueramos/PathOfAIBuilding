# Path of Building AI Integration - Guia de Segurança e Distribuição

## 🔐 Segurança das Chaves de API

### Para Desenvolvedores (você)

**NUNCA commitar:**
- `ai_config.json` (contém a key real)
- Qualquer arquivo com `.ai_key` ou em `ai_keys/`
- Keys hardcoded no código

**Onde a key fica:**
- Local: `~/.local/share/Path of Building/ai_config.json` (Linux)
- Windows: `%APPDATA%/Path of Building/ai_config.json`
- O PoB usa `GetUserPath()` que aponta para o diretório de dados do usuário

**Permissões:**
O módulo `AIConfig.lua` automaticamente define `chmod 600` no arquivo de config (apenas owner pode ler).

### Para Usuários Finais (distribuição)

Quando você distribuir o binário/fork, os usuários precisam:

1. **Copiar o exemplo:**
   ```bash
   cp ai_config.example.json ~/.local/share/Path\ of\ Building/ai_config.json
   ```

2. **Editar e inserir a própria key:**
   ```json
   {
     "api_endpoint": "https://api.openai.com/v1",
     "api_key": "sk-... (key do usuário)",
     "model": "gpt-4o"
   }
   ```

3. **Ou usar a UI (quando implementada):**
   - Menu → Configurações → IA
   - Inserir key, endpoint, modelo
   - Salvar

## 📦 Distribuição Segura

### Opção 1: Distribuir Código-Fonte (Recomendado)

**Vantagens:**
- Usuários compilam localmente
- Transparência total
- Sem binários assinados

**Como:**
```bash
git clone https://github.com/kaiqueramos/PathOfAIBuilding.git
cd PathOfAIBuilding
# Usuário segue README para compilar/rodar
```

**O que incluir no repo:**
- ✅ `ai_config.example.json` (sem key real)
- ✅ `src/Modules/AIConfig.lua` (módulo de config)
- ✅ `src/Classes/AIConfigPanel.lua` (UI de config)
- ✅ Este guia (`AI_SECURITY.md`)
- ❌ `ai_config.json` (NUNCA)

### Opção 2: Distribuir Binário (Windows via Wine)

**Desafios:**
- Binário não pode conter keys
- Usuário precisa configurar após instalar
- Wine complica paths de config

**Solução:**
1. **Primeiro run:** PoB cria `ai_config.json` vazio no userPath
2. **UI de setup:** Modal obrigatório pedindo a key
3. **Validação:** Testa a key com um request simples antes de salvar

**Script de setup (pós-instalação):**
```bash
#!/bin/bash
# setup-ai.sh - Roda após instalar o PoB

USER_PATH="$HOME/.local/share/Path of Building"
CONFIG="$USER_PATH/ai_config.json"

if [ ! -f "$CONFIG" ]; then
    echo "Configurando IA pela primeira vez..."
    cp ai_config.example.json "$CONFIG"
    chmod 600 "$CONFIG"
    echo "Edite $CONFIG e insira sua API key"
    xdg-open "$CONFIG"
fi
```

### Opção 3: Distribuir via Flatpak/Snap (Linux Nativo)

**Vantagens:**
- Sandbox de segurança
- Config isolada por usuário
- Atualizações automáticas

**Paths de config:**
- Flatpak: `~/.var/app/com.pathofbuilding.PoB/data/ai_config.json`
- Snap: `~/snap/pathofbuilding/current/.config/ai_config.json`

**Manifest Flatpak (exemplo):**
```yaml
finish-args:
  - --share=network  # Necessário para API calls
  - --filesystem=xdg-data/Path of Building  # Acesso ao config
```

## 🛡️ Boas Práticas de Segurança

### 1. Validação de Input
```lua
-- Sempre valida antes de usar
local ok, err = AIConfig:Validate()
if not ok then
    -- Mostra erro, não executa
    return false, err
end
```

### 2. Logging Seguro
```lua
-- NUNCA logue a key completa
local config = AIConfig:GetSanitizedConfig()
-- api_key: "[CONFIGURADA]" ou "[VAZIA]"
print(json.encode(config))
```

### 3. HTTPS Obrigatório
```lua
-- Valida que o endpoint é HTTPS
if not string.match(endpoint, "^https://") then
    return false, "Endpoint deve usar HTTPS"
end
```

### 4. Timeout e Rate Limiting
```lua
-- Evita requests infinitos
AIConfig.config.timeout = 120  -- segundos
-- Implementa retry com backoff
```

### 5. Não Armazenar em Memória Compartilhada
```lua
-- A key fica apenas no objeto AIConfig
-- Não passa por variáveis globais
-- Não serializa em logs de debug
```

## 🔍 Auditoria de Segurança

Antes de distribuir, verifique:

```bash
# 1. Nenhuma key no código
grep -r "sk-" src/
grep -r "api_key.*=.*['\"]" src/

# 2. .gitignore cobre os arquivos sensíveis
cat .gitignore | grep ai_config

# 3. Nenhum config real no repo
find . -name "ai_config.json" -not -path "./.git/*"

# 4. Histórico do git não tem keys (se já commitou por engano)
git log -p | grep "sk-"
# Se encontrar: git filter-branch ou BFG Repo-Cleaner
```

## 🚨 Incidente: Key Vazada

Se uma key for commitada por engano:

1. **Revoga a key imediatamente** (no provider: OpenAI/Anthropic/etc.)
2. **Remove do histórico:**
   ```bash
   # Usando BFG (mais rápido)
   bfg --replace-text passwords.txt  # arquivo com a key
   git reflog expire --expire=now --all
   git gc --prune=now --aggressive
   git push --force
   ```
3. **Notifica usuários** (se a key era compartilhada)
4. **Rotaciona todas as keys** que estavam no mesmo arquivo

## 📝 Checklist de Distribuição

- [ ] `ai_config.json` está no `.gitignore`
- [ ] `ai_config.example.json` existe (sem key real)
- [ ] `AI_SECURITY.md` está no repo
- [ ] Nenhuma key hardcoded no código
- [ ] UI de configuração implementada
- [ ] Validação de HTTPS no endpoint
- [ ] Logging sanitizado (sem keys)
- [ ] Timeout configurado
- [ ] Testado com key inválida (mostra erro amigável)
- [ ] Documentação de setup para usuários

## 🔗 Referências

- [OpenAI API Keys](https://platform.openai.com/api-keys)
- [Anthropic API Keys](https://console.anthropic.com/)
- [Qwen Cloud (Alibaba)](https://dashscope.console.aliyun.com/)
- [Git Secret Scanning](https://docs.github.com/en/code-security/secret-scanning)
- [BFG Repo-Cleaner](https://rtyley.github.io/bfg-repo-cleaner/)
