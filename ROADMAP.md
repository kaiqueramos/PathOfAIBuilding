# PathOfAIBuilding — Roadmap de Integração IA

> Arquivo local, NÃO versionado. Guia de desenvolvimento da camada de IA dentro do PoB.

## Visão

O PoB já é o motor de cálculo mais completo de PoE1. A IA não substitui isso — ela é a
**interface conversacional** e o **orquestrador de automação** que transforma o PoB de
"planilha glorificada" em "consultor de build que pensa".

O jogador abre o PoB, digita numa caixa de texto, e a IA + scripts de automação fazem
o trabalho pesado: calcular, comparar, buscar no trade, sugerir upgrades.

---

## Estado atual — 2026-07-22

- [x] Bridge Lua, configuração local, chat integrado e 18 ações aplicáveis
- [x] Serialização do build com DPS, EHP, max hits e defesas calculadas pelo PoB
- [x] Shortlists de gems e uniques simulados sem mutar o build
- [x] Fingerprint do build para invalidar caches e respostas obsoletas
- [x] Roteamento local por intenção, contexto seletivo e histórico limitado a 12.000 caracteres
- [x] Lotes de ações pré-validados em clone, rebuild completo e diff real após Apply
- [ ] Escalonamento: permitir que a IA solicite contexto adicional antes de responder
- [ ] Trade real com preço e orçamento
- [ ] Otimização de árvore
- [ ] Geração completa de build

## Fase 1 — Ponte IA ↔ PoB (fundação)

**Objetivo:** A IA consegue ler o estado completo do build e executar ações.

### 1.1 AIBridge.lua (serialização do build)
- Serializar estado atual do build → JSON estruturado:
  - Classe, ascendência, nível, bandits, pantheon
  - Skills (gems + links + qualidade + nível)
  - Itens equipados (por slot, com mods)
  - Tree (nós alocados, keystones, masteries)
  - Config (boss, distância, condições)
- Usar APIs internas do PoB:
  - `build.calcsTab.mainOutput` → DPS, EHP, resistências, etc.
  - `build.itemsTab` → itens equipados
  - `build.treeTab` → árvore passiva
  - `build.skillsTab` → gems/skills
- Formato: núcleo JSON compacto; catálogos e candidatos volumosos entram somente sob demanda

### 1.2 AIBridge.lua (execução de ações)
- Receber lista de ações da IA e executar no PoB
- Validar estrutura e fingerprint antes de qualquer mutação
- Executar o lote primeiro em um `CompareEntry` isolado, incluindo dependências entre ações
- Se o preflight falhar, manter o build original intacto
- Aplicar o lote válido no build real e parar diante de falha inesperada
- Disparar um rebuild síncrono completo ao final
- Mostrar diff real de DPS, EHP, max hits e pontos antes/depois

### 1.3 Comunicação HTTP
- PoB (Lua) → POST JSON → Server Hono (Node.js, fora do Wine)
- Server → LLM (Qwen/OpenAI-compatible) → resposta estruturada
- Server → POST ações → PoB executa
- Alternativa: PoB chama LLM direto via lcurl (já existe no runtime)
  - Mais simples, sem server intermediário
  - Mas menos controle (retry, cache, rate limit)

---

## Fase 2 — Chat na UI (interface conversacional)

**Objetivo:** Jogador digita perguntas e recebe respostas acionáveis.

### 2.1 Painel de chat
- Nova aba ou painel lateral na UI do PoB
- Histórico de mensagens (TextListControl)
- Input de texto (EditControl) + botão enviar
- Streaming de resposta (SSE ou polling)
- Formatação rica: cores do PoB (^2 verde, ^1 vermelho, ^7 branco)

### 2.2 Perguntas que a IA responde (com dados reais do PoB)
| Pergunta do jogador | O que a IA faz |
|---|---|
| "Como melhoro essa build?" | Analisa DPS/EHP/resists, identifica gargalo, sugere top 3 mudanças com impacto numérico |
| "Qual meu próximo upgrade?" | Compara itens atuais vs trade, ordena por custo-benefício |
| "Por que meu DPS tá baixo?" | Explica mecânicas: less/more, pen, exposição, impale, etc. |
| "E se eu trocar X por Y?" | Simula a troca (ação no PoB), mostra diff de stats |
| "Minha build tanka o que?" | Analisa EHP, resists, ailment avoidance, recovery |
| "O que falta pra endgame?" | Checklist: resists cap, life, damage floor, utility |

### 2.3 Contexto automático
- A IA sempre recebe o núcleo atual do build: meta, stats, itens equipados, skills e tree alocada
- Um roteador local e determinístico classifica a pergunta antes de montar o contexto
- Catálogos de gems, uniques, configs, bases e nós candidatos entram somente quando relevantes
- Shortlists caros são calculados somente para intenção de gems, itens ou melhoria geral
- Histórico enviado ao modelo preserva apenas as mensagens mais recentes dentro de 12.000 caracteres
- Cada resposta, shortlist e lote de ações fica vinculado ao fingerprint exato do build
- Pendente: permitir que a própria IA peça blocos omitidos e refazer a chamada uma única vez

---

## Fase 3 — Trade Integration (BiS com orçamento)

**Objetivo:** "Tenho 5 divines, qual o melhor upgrade?" → lista de itens reais do trade.

### 3.1 Busca no trade
- Usar `TradeQueryGenerator.lua` (já existe) pra gerar queries
- `TradeQueryRequests.lua` (já existe) pra fazer fetch
- IA define os pesos de stats baseado no build atual
- Filtra por: preço máximo, league, tipo de item

### 3.2 Análise de custo-benefício
- Pra cada item encontrado: simula equipar no PoB → calcula DPS/EHP gain
- Ordena por: gain por divine gasto
- Mostra: "Item X (+15% DPS, 2.3 div) vs Item Y (+8% DPS, 0.8 div)"
- Sugere ordem de compra: "Compre Y primeiro (melhor ratio), depois X"

### 3.3 Budget planner
- Jogador diz: "Tenho 10 divines pra gear"
- IA distribui o budget entre slots otimizando DPS/EHP total
- Considera sinergias (ex: +1 to all skills no amuleto + gems no body)
- Gera lista de compra ordenada com links do trade

---

## Fase 4 — Build Generation (do zero)

**Objetivo:** "Quero jogar Righteous Fire Inquisitor" → build completa e funcional.

### 4.1 Geração guiada
- Jogador descreve: archetype, budget, playstyle
- IA gera: tree path, skills, gear mínimo, level plan
- Valida TUDO no motor do PoB (não é "achismo" — é cálculo real)
- Itera: se DPS < threshold ou EHP < threshold, ajusta

### 4.2 Leveling plan
- Act-by-act: que gems usar, que uniques comprar, que labs fazer
- Transição pra endgame: quando trocar gems, que maps evitar
- Budget: quanto custa cada fase (em chaos/divines)

### 4.3 Validação contínua
- A cada mudança sugerida, o PoB recalcula
- IA verifica: resists cap? Life suficiente? Damage floor ok?
- Se algo quebra, IA explica o porquê e sugere alternativa

---

## Fase 5 — Automação Avançada

**Objetivo:** IA como "co-piloto" que age proativamente.

### 5.1 Import de personagem
- Importar char real da API do PoE (account name + char name)
- Comparar com o plano: "Você tá 15% abaixo do DPS planejado porque..."
- Sugerir próximos passos baseados no estado real

### 5.2 Price check integrado
- Hover num item → IA mostra: preço estimado, upgrades disponíveis, vale a pena?
- "Esse item é 20% melhor que o seu atual e custa 1.2 div"

### 5.3 Otimização de tree
- "Maximiza meu DPS mantendo 5k+ life" → IA realoca nós
- Usa o motor do PoB pra validar cada swap
- Mostra o caminho de realocação (ordem de alocação/dealocação)

### 5.4 Comparação de builds
- "RF Inquis vs RF Necro — qual é melhor pro meu budget?"
- IA gera ambas, calcula, compara lado a lado
- Mostra tradeoffs: DPS, EHP, custo, dificuldade de pilotagem

---

## Decisões de Arquitetura

### Onde roda a IA?
- **Opção A:** Server Hono externo (Node.js nativo, fora do Wine)
  - Pro: controle total, retry, cache, múltiplos modelos
  - Contra: precisa rodar 2 processos
- **Opção B:** PoB chama LLM direto via lcurl
  - Pro: single process, mais simples pro usuário final
  - Contra: Lua HTTP é limitado, sem streaming fácil
- **Decisão:** Começar com B (simples), migrar pra A se precisar de mais controle

### Formato de comunicação
- Build state → JSON seletivo: núcleo compacto + blocos opcionais por intenção
- Ações → JSON array de operações
- Respostas → Markdown com cores do PoB

### Segurança
- API key NUNCA no código (ai_config.json no userPath, chmod 600)
- HTTPS obrigatório
- Logging sanitizado (sem keys)
- Distribuição: usuário insere própria key

---

## Prioridades (ordem de implementação)

1. **AIBridge.lua** — serializar build + executar ações (Fase 1.1 + 1.2)
2. **Chat panel** — UI de conversa (Fase 2.1)
3. **"Como melhoro?"** — primeira pergunta funcional (Fase 2.2)
4. **Trade search** — buscar itens reais (Fase 3.1)
5. **Budget planner** — otimizar compras (Fase 3.2 + 3.3)
6. **Build generation** — do zero (Fase 4)
7. **Automação** — import, price check, tree opt (Fase 5)

---

## O que NÃO fazer

- ❌ Substituir o motor de cálculo do PoB (ele é a fonte da verdade)
- ❌ Gerar builds "de cabeça" sem validar no PoB
- ❌ Mostrar números que não vieram do cálculo real
- ❌ Complexidade desnecessária na UI (chat simples > dashboard complexo)
- ❌ Depender de APIs externas instáveis (poe.ninja pode cair, trade tem rate limit)
- ❌ Commitar keys, tokens, ou dados sensíveis
