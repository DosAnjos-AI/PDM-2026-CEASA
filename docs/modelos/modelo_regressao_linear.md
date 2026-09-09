# `modelo_regressao_linear` — `pdm-ceasa.baseline.modelo_regressao_linear`

Script: `sql/modelo/bronze/02_baseline_treino_linear.sql` (treino),
`sql/modelo/bronze/01_baseline_dados_treino.sql` (tabela de origem),
`sql/modelo/bronze/05_baseline_avaliacao.sql` (avaliação).

## Objetivo

Prever `preco_comum` de um (`produto`, `classe`) 7 dias após uma data dada,
a partir apenas de identificação do produto e da data — sem nenhum preço de
entrada. Recebe `produto`, `classe` e uma data (decomposta em `mes` e
`dia_semana`) e devolve o preço estimado para o pregão ~7 dias depois.

## Dados

- Origem: `pdm-ceasa.baseline.dados_treino`, construída sobre
  `pdm-ceasa.bronze.cotacoes` sem tratamento (sem deduplicar, sem filtrar
  produto por volume, sem corrigir preço).
- Período coberto pela tabela de origem: toda a Bronze, `2010-01-04` a
  `2026-08-28`.
- Linhas na tabela de origem (com alvo calculado): 411.226, de 412.661 na
  Bronze — 1.435 linhas ficaram sem alvo (sem pregão seguinte disponível a
  partir de D+7 na mesma série) e saíram da tabela.
- Produtos/séries na tabela de origem: 347 produtos distintos, 432 pares
  (produto, classe) distintos.

## Alvo

`preco_comum` do mesmo (`produto`, `classe`) no pregão mais próximo seguinte
a `data + 7 dias`. Se existir pregão exatamente em D+7, esse é o valor usado;
senão, o primeiro pregão seguinte disponível na série (busca por
`data >= DATE_ADD(data, INTERVAL 7 DAY)`, pega o de menor data). Linha sem
pregão futuro que satisfaça essa condição fica sem alvo e sai da tabela —
tratado como borda de série, não como defeito de dado a corrigir.

## Split

Temporal, nunca aleatório: treino usa `data <= 2025-12-31`, teste usa
`data >= 2026-01-01`. Split temporal porque o problema é previsão no tempo —
um split aleatório vazaria informação futura para o treino (linhas de datas
posteriores ajudando a prever linhas de datas anteriores), inflando a métrica
de forma artificial.

- Linhas de treino: 380.850
- Linhas de teste: 30.376
- Faixa de datas da partição de teste: `2026-01-05` a `2026-08-21` (mínimo
  confirmado `>= 2026-01-01`).

## Colunas usadas

| Coluna | Papel |
|---|---|
| `produto` | Categórica, identifica a série (BQML codifica automaticamente) |
| `classe` | Categórica, identifica a série junto com `produto` |
| `mes` | Derivado direto de `data` (`EXTRACT(MONTH FROM data)`), captura sazonalidade |
| `dia_semana` | Derivado direto de `data` (`EXTRACT(DAYOFWEEK FROM data)`) |
| `alvo` | Rótulo (`input_label_cols`), não é entrada |

## Colunas rejeitadas

| Coluna | Motivo |
|---|---|
| `preco_comum`, `preco_maximo`, `preco_minimo`, `preco_kg` (da própria linha) | Não disponíveis no momento da previsão — o objetivo é responder para qualquer data futura sem dispor de cotação; usar preço contemporâneo seria vazamento |
| Defasagens (`lag_1`...`lag_5`, usadas no baseline anterior, descartado no Bloco 10) | Rejeitadas por serem tratamento: exigem histórico de preço como entrada, o que o desenho atual proíbe |
| `data` bruta (timestamp) | Não usada diretamente como feature contínua — só seus derivados diretos (`mes`, `dia_semana`) entram, para não acoplar o modelo a um intervalo de datas específico |

## Hiperparâmetros

```sql
OPTIONS (
  model_type = 'LINEAR_REG',
  input_label_cols = ['alvo']
)
```
- `model_type = 'LINEAR_REG'`: regressão linear do BQML.
- `input_label_cols = ['alvo']`: define `alvo` como rótulo; todas as demais
  colunas selecionadas (`produto`, `classe`, `mes`, `dia_semana`) entram como
  features. Nenhum outro hiperparâmetro foi setado — valores default do BQML
  para o resto (regularização, otimizador etc.).

## Métricas

Obtidas via `ML.EVALUATE` na partição de teste (`data >= 2026-01-01`), sem
maquiagem:

| Métrica | Valor |
|---|---|
| `mean_absolute_error` | 2694,84 |
| `mean_squared_error` | 7,297 × 10⁸ |
| `r2_score` | **-180271,21** |
| `explained_variance` | -178485,74 |

## Previsão de exemplo

Entrada: `produto = "FRANBOESA"`, `classe = 1`, `mes = 1`, `dia_semana = 2`
(linha da partição de teste, data real `2026-01-05`).

Saída: `preco_previsto = 367,63`.
Valor real (`preco_comum` do alvo nessa linha): `240,00`.

## Limitações

- **R² fortemente negativo, com aviso de overfitting emitido pelo próprio
  BQML** durante o treino ("evaluation loss ... significantly larger than
  training loss"). Com features só categóricas (`produto`, `classe`) e
  derivados de data (`mes`, `dia_semana`) — nenhuma delas contínua no eixo do
  tempo de forma monotônica —, o modelo linear tende a extrapolar uma
  tendência temporal que não existe de fato na série, produzindo previsões
  distantes do valor real na partição de teste.
- Não usa nenhuma informação de preço passado: não consegue capturar
  choques, sazonalidade fina ou tendência real de curto prazo — só padrões
  médios por produto/classe/mês/dia da semana.
- Resultado é o piso de comparação do Bloco 10: não foi ajustado para
  melhorar a métrica, por decisão de desenho (medir o efeito do tratamento
  na Silver depois, contra este piso).
