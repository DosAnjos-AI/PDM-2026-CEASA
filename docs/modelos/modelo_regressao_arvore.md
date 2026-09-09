# `modelo_regressao_arvore` — `pdm-ceasa.baseline.modelo_regressao_arvore`

Script: `sql/modelo/bronze/03_baseline_treino_arvore.sql` (treino),
`sql/modelo/bronze/01_baseline_dados_treino.sql` (tabela de origem),
`sql/modelo/bronze/05_baseline_avaliacao.sql` (avaliação).

## Objetivo

Prever `preco_comum` de um (`produto`, `classe`) 7 dias após uma data dada,
a partir apenas de identificação do produto e da data — sem nenhum preço de
entrada. Mesma entrada e mesmo comportamento esperado do
`modelo_regressao_linear`: recebe `produto`, `classe` e uma data (decomposta
em `mes` e `dia_semana`) e devolve o preço estimado ~7 dias depois.

## Dados

- Origem: `pdm-ceasa.baseline.dados_treino`, idêntica à do modelo linear —
  construída sobre `pdm-ceasa.bronze.cotacoes` sem tratamento.
- Período coberto pela tabela de origem: toda a Bronze, `2010-01-04` a
  `2026-08-28`.
- Linhas na tabela de origem (com alvo calculado): 411.226, de 412.661 na
  Bronze — 1.435 linhas ficaram sem alvo e saíram da tabela.
- Produtos/séries na tabela de origem: 347 produtos distintos, 432 pares
  (produto, classe) distintos.

## Alvo

Idêntico ao `modelo_regressao_linear`: `preco_comum` do mesmo (`produto`,
`classe`) no pregão mais próximo seguinte a `data + 7 dias`. Pregão exato em
D+7 tem prioridade; senão, usa o primeiro pregão seguinte disponível na
série. Linha sem pregão futuro que satisfaça essa condição sai da tabela.

## Split

Temporal, nunca aleatório: treino usa `data <= 2025-12-31`, teste usa
`data >= 2026-01-01`. Mesmo motivo do modelo linear: split aleatório vazaria
informação futura para o treino em um problema de previsão temporal.

- Linhas de treino: 380.850
- Linhas de teste: 30.376
- Faixa de datas da partição de teste: `2026-01-05` a `2026-08-21`.

## Colunas usadas

| Coluna | Papel |
|---|---|
| `produto` | Categórica, identifica a série |
| `classe` | Categórica, identifica a série junto com `produto` |
| `mes` | Derivado direto de `data`, captura sazonalidade |
| `dia_semana` | Derivado direto de `data` |
| `alvo` | Rótulo (`input_label_cols`), não é entrada |

## Colunas rejeitadas

| Coluna | Motivo |
|---|---|
| `preco_comum`, `preco_maximo`, `preco_minimo`, `preco_kg` (da própria linha) | Não disponíveis no momento da previsão — vazamento |
| Defasagens (rejeitadas no descarte do baseline anterior, Bloco 10) | Exigem histórico de preço como entrada, proibido pelo desenho |
| `data` bruta | Só entram os derivados diretos (`mes`, `dia_semana`) |

## Hiperparâmetros

```sql
OPTIONS (
  model_type = 'BOOSTED_TREE_REGRESSOR',
  input_label_cols = ['alvo']
)
```
- `model_type = 'BOOSTED_TREE_REGRESSOR'`: árvore de decisão com boosting do
  BQML (XGBoost por trás).
- `input_label_cols = ['alvo']`: mesma função do modelo linear. Nenhum outro
  hiperparâmetro foi setado (número de árvores, profundidade máxima,
  learning rate etc. ficam no default do BQML).

## Métricas

Obtidas via `ML.EVALUATE` na mesma partição de teste do modelo linear
(`data >= 2026-01-01`), sem maquiagem:

| Métrica | Valor |
|---|---|
| `mean_absolute_error` | 38,29 |
| `mean_squared_error` | 2731,13 |
| `r2_score` | 0,3253 |
| `explained_variance` | 0,4114 |

## Previsão de exemplo

Mesma linha de entrada usada no modelo linear, para comparação direta:
`produto = "FRANBOESA"`, `classe = 1`, `mes = 1`, `dia_semana = 2` (data real
`2026-01-05`).

Saída: `preco_previsto = 116,77`.
Valor real (`preco_comum` do alvo nessa linha): `240,00`.

## Limitações

- **R² de 0,3253** — positivo e muito mais estável que o do modelo linear.
  Árvore de decisão não extrapola linearmente fora do intervalo visto no
  treino (ao contrário da regressão linear), por isso não produz os valores
  absurdamente distantes que o modelo linear produziu na mesma partição de
  teste — mas ainda explica só cerca de um terço da variância do alvo.
- Mesmas limitações estruturais do modelo linear quanto à entrada: sem
  informação de preço passado, não captura choques nem tendência real de
  curto prazo, só padrões por produto/classe/mês/dia da semana observados no
  treino.
- Resultado é o piso de comparação do Bloco 10, não ajustado para melhorar a
  métrica.
