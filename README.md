# PDM-2026-CEASA

Trabalho 1 da disciplina **PDM_BIA (Processamento de Dados Massivos)**: pipeline
de dados e previsão de preços de hortifruti a partir das cotações da
CEASA-GO, inteiramente construído sobre o Google Cloud Platform (BigQuery +
BigQuery ML + Cloud Storage).

O objetivo do trabalho não é só treinar um modelo, mas demonstrar o efeito de
cada etapa de tratamento de dado sobre a qualidade da previsão: os mesmos três
tipos de modelo (regressão linear, árvore boosted, série temporal ARIMA) são
treinados três vezes — sobre o dado cru, sobre o dado tratado e sobre o dado
agregado — e comparados lado a lado.

## Arquitetura

Arquitetura em camadas (medallion), com dois conjuntos auxiliares para
comparação:

| Camada/conjunto | O que é | Por que existe |
|---|---|---|
| **Bronze** | Dado carregado como veio do CSV histórico, sem nenhum tratamento | Preserva a fonte original intacta e serve de piso de comparação: mostra o que um modelo aprende sem limpeza nenhuma |
| **Silver** | Dado tratado: deduplicado, normalizado, filtrado por densidade de produto, com preço coerente e sem outlier | É o dado "pronto para uso" no grão diário — a camada onde a maior parte do valor de engenharia de dados foi investida |
| **Gold** | Dado agregado por período (semana ISO e mês), pronto para consumo analítico | Reduz granularidade para uso em relatório/dashboard e para um estilo de previsão diferente (média de período, não preço de um dia) |
| **baseline** | Modelos treinados diretamente sobre a Bronze crua | Ponto de referência: mede quanto do desempenho de um modelo vem só do algoritmo, sem nenhuma limpeza |
| **metricas** | Tabela única que consolida a avaliação dos 12 modelos (bronze, silver e gold) | Permite comparar cru vs. tratado vs. agregado num único SELECT |

## Dados

Cotações da CEASA-GO, **2010-01-04 a 2026-08-28**:

| Camada | Linhas |
|---|---|
| Bronze (`pdm-ceasa.bronze.cotacoes`) | 412.661 |
| Silver (`pdm-ceasa.silver.cotacoes`) | 296.545 |
| Produtos após filtragem de densidade (Silver) | 141 |

O CSV de origem é local (fora deste repositório e do versionamento) e sobe
para o bucket do projeto via `ingestao/upload_historico.sh` antes da carga na
Bronze. As últimas datas do arquivo completo foram separadas antes da
ingestão para um recorte de demonstração, também fora do repositório e do
BigQuery — ver `docs/bronze/bronze.md`.

## Estrutura de pastas

```
sql/
  construir_tabelas/
    bronze/       carga da Bronze (LOAD DATA OVERWRITE a partir do GCS)
    silver/       as 9 regras de tratamento, em ordem numerada
    gold/         agregação semanal/mensal, perfil de produto, tabelas de treino
    metricas/     consolidação das métricas dos 12 modelos numa única tabela
  modelo/
    bronze/       treino e avaliação dos 3 modelos baseline (sobre a Bronze crua)
    silver/       treino dos 3 modelos sobre o dado tratado
    gold/         treino dos 6 modelos sobre o dado agregado (semanal + mensal)
  consultas/
    bronze/       inferência (ML.PREDICT/ML.FORECAST) dos modelos baseline
    silver/       conferência de cada regra da Silver, avaliação e inferência
    gold/         conferência da Gold, avaliação, GLOBAL_EXPLAIN e inferência
    metricas/     previsões para o recorte de demo e conferência da tabela consolidada
ingestao/
  upload_historico.sh   sobe o CSV histórico para o bucket (GCS, não BigQuery)
scripts/
  metricas_demo*.py     calcula o bloco de métricas de demo em Python (lê o recorte local)
docs/
  bronze/, modelos/     documentação técnica de referência
```

## O que faz cada arquivo

### `sql/construir_tabelas/bronze/`

| Arquivo | O que faz |
|---|---|
| `01_bronze.sql` | `LOAD DATA OVERWRITE` de `pdm-ceasa.bronze.cotacoes` a partir de `gs://pdm-ceasa-dados/raw/*.csv`. 17 colunas, todas nullable; `codigo` fica STRING para preservar zero à esquerda; preços e pesos ficam NUMERIC. Sem tolerância a linha inválida. |

### `sql/construir_tabelas/silver/`

| Arquivo | Regra | O que faz |
|---|---|---|
| `01_deduplicacao.sql` | R1+R2 | Remove duplicata idêntica nas 17 colunas da Bronze (R1); depois remove duplicata ignorando `arquivo`/`layout` (R2) |
| `02_normalizacao.sql` | R3+R4 | Descarta `categoria` e `codigo`; normaliza `grupo`/`produto`/`embalagem` (trim, colapsa espaço, remove acento, minúsculo, espaço→`_`); converte peso e preços para FLOAT64 |
| `03_selecao_produtos.sql` | R5 | Filtro de densidade de produto em duas janelas (série 2017+ e série completa), em cadeia |
| `04_coerencia_preco.sql` | R6 | Descarta linha com base de cálculo inválida ou `preco_kg` incoerente com `preco_comum/qtd_kg` |
| `05_outliers.sql` | R7 | Remove outlier de `preco_kg` por (produto, classe, ano) via IQR |
| `06_de_para_produtos.sql` | R8 | Unifica 8 pares de grafia divergente de nome de produto |
| `07_silver_cotacoes.sql` | R9 | Mantém só classe 1 e 2; materializa `pdm-ceasa.silver.cotacoes`, tabela final da camada |
| `08_dados_treino.sql` | — | Monta `silver.dados_treino`: alvo (D+7) e 5 lags (7/14/30/365/730 dias) por (produto, classe), sem vazamento |

### `sql/construir_tabelas/gold/`

| Arquivo | O que faz |
|---|---|
| `01_analitica_semanal.sql` | Agrega a Silver por (produto, classe, semana ISO); interpola vão curto (≤4 semanas), mantém vão médio como buraco real, corta bloco antes de vão longo (>26 semanas) |
| `02_analitica_mensal.sql` | Mesma lógica em base mensal (vão curto ≤2 meses, longo >6 meses) |
| `03_perfil_produto.sql` | Uma linha por (produto, classe): médias, data de início/fim, contagens, reaproveitando o corte de bloco da tabela semanal |
| `04_treino_semanal.sql` | Features e alvo semanais (lags de 1/2/4/52/104 semanas) via self-join por igualdade exata de data — a grade tem buracos, então `LAG`/`LEAD` por posição não serve |
| `05_treino_mensal.sql` | Mesma lógica em base mensal (lags de 1/12/24 meses) |

### `sql/construir_tabelas/metricas/`

| Arquivo | O que faz |
|---|---|
| `01_comparacao_modelos.sql` | Cria o dataset `metricas` e a tabela `comparacao_modelos`; popula as 6 linhas bronze/silver via `ML.EVALUATE` sobre a partição de teste; bloco de demo começa `NULL` |
| `02_amplia_comparacao_modelos_gold.sql` | Adiciona a coluna `granularidade`, marca as 6 linhas originais como `'diario'` e insere as 6 linhas gold (semanal/mensal), totalizando 12 |

### `sql/modelo/bronze/` (baseline — treina sobre a Bronze crua)

| Arquivo | O que faz |
|---|---|
| `01_baseline_dados_treino.sql` | Monta `baseline.dados_treino`: alvo D+7 por (produto, classe), features = só produto/classe/mês/dia da semana, sem nenhum preço |
| `02_baseline_treino_linear.sql` | `CREATE OR REPLACE MODEL baseline.modelo_regressao_linear` (LINEAR_REG) |
| `03_baseline_treino_arvore.sql` | `CREATE OR REPLACE MODEL baseline.modelo_regressao_arvore` (BOOSTED_TREE_REGRESSOR), mesmo vetor da linear |
| `04_baseline_treino_arima.sql` | `CREATE OR REPLACE MODEL baseline.modelo_serie_arima` (ARIMA_PLUS, horizon=4 pregões, sem split) |
| `05_baseline_avaliacao.sql` | Avalia linear e árvore via `ML.EVALUATE` na partição de teste; grava ARIMA como `sem_particao_teste` |

### `sql/modelo/silver/` (treina sobre o dado tratado)

| Arquivo | O que faz |
|---|---|
| `01_modelo_regressao_linear.sql` | `CREATE OR REPLACE MODEL silver.modelo_regressao_linear` (LINEAR_REG elastic net, L1=L2=1.0), vetor com 5 lags |
| `02_modelo_regressao_arvore.sql` | `CREATE OR REPLACE MODEL silver.modelo_regressao_arvore` (BOOSTED_TREE_REGRESSOR), vetor idêntico ao linear |
| `03_modelo_serie_arima.sql` | `CREATE OR REPLACE MODEL silver.modelo_serie_arima` (ARIMA_PLUS, horizon=60 pregões, `AUTO_FREQUENCY`, feriado BR) |

### `sql/modelo/gold/` (treina sobre o dado agregado)

| Arquivo | O que faz |
|---|---|
| `01_modelo_regressao_linear_semanal.sql` | LINEAR_REG elastic net sobre `gold.treino_semanal` |
| `02_modelo_regressao_linear_mensal.sql` | LINEAR_REG elastic net sobre `gold.treino_mensal` |
| `03_modelo_regressao_arvore_semanal.sql` | BOOSTED_TREE_REGRESSOR, vetor semanal idêntico ao linear |
| `04_modelo_regressao_arvore_mensal.sql` | BOOSTED_TREE_REGRESSOR, vetor mensal idêntico ao linear |
| `05_modelo_serie_arima_semanal.sql` | ARIMA_PLUS sobre `gold.analitica_semanal`, horizon=90 semanas |
| `06_modelo_serie_arima_mensal.sql` | ARIMA_PLUS sobre `gold.analitica_mensal`, horizon=24 meses |

### `sql/consultas/bronze/`

| Arquivo | O que faz |
|---|---|
| `01_bronze_check.sql` | Contagem total, faixa de data, produtos/classes distintos, amostra de 5 linhas |
| `02_inferencia_regressao_linear.sql` | `ML.PREDICT` do modelo baseline linear para um (produto, classe, data) parametrizável |
| `03_inferencia_regressao_arvore.sql` | Idem para o modelo baseline de árvore |
| `04_inferencia_serie_arima.sql` | `ML.FORECAST` do ARIMA baseline (horizon=4, replicado explicitamente) |

### `sql/consultas/silver/`

| Arquivo | O que faz |
|---|---|
| `01_deduplicacao_check.sql` | Contagem antes/depois de R1 e R2 |
| `02_normalizacao_check.sql` | Distintos por coluna normalizada e checagem de nulo novo introduzido pelo CAST |
| `03_selecao_produtos_check.sql` | Contagem de produtos em cada corte da cadeia de densidade |
| `04_coerencia_preco_check.sql` | Decomposição do motivo de descarte da R6 |
| `05_outliers_check.sql` | Total antes/depois da R7 |
| `06_de_para_check.sql` | Total antes/depois da R8 e ausência de conflito de chave |
| `07_silver_check.sql` | Conferência obrigatória da camada: contagens, classes, faixa de data, chaves duplicadas, preço inválido |
| `08_dados_treino_check.sql` | Recalcula alvo e lags de forma independente para provar `silver.dados_treino` |
| `09_avaliacao_regressao_linear.sql` | `ML.EVALUATE` do modelo linear na partição de teste + comparação com o baseline |
| `10_erro_por_produto.sql` | MAE e erro percentual médio por produto (linear) |
| `11_avaliacao_regressao_arvore.sql` | `ML.EVALUATE` da árvore + `ML.GLOBAL_EXPLAIN` |
| `12_erro_por_produto_arvore.sql` | MAE e erro percentual médio por produto (árvore) |
| `13_avaliacao_serie_arima.sql` | `ML.ARIMA_EVALUATE`: ordem (p,d,q), AIC e sazonalidade por série |
| `14_forecast_serie_arima.sql` | `ML.FORECAST` (horizon=60) e cobertura real por série até 2026-09-04 |
| `15_inferencia_regressao_linear.sql` | `ML.PREDICT` parametrizável (produto/classe/data) do modelo linear |
| `16_inferencia_regressao_arvore.sql` | Idem para a árvore |
| `17_inferencia_serie_arima.sql` | `ML.FORECAST` parametrizável do ARIMA da Silver |

### `sql/consultas/gold/`

| Arquivo | O que faz |
|---|---|
| `01_analitica_semanal_check.sql` | Linhas totais/interpoladas, distribuição de `n_pregoes`, maior vão interpolado, prova de que não há interpolação nas pontas |
| `02_analitica_mensal_check.sql` | Mesma conferência em base mensal |
| `03_perfil_produto_check.sql` | Contagem (210), faixa de datas, pares que sofreram corte de bloco |
| `04_treino_semanal_check.sql` | Recontagem independente + prova formal de não vazamento (`lag_1s`) |
| `05_treino_mensal_check.sql` | Mesma prova em base mensal (`lag_1m`) |
| `06_avaliacao_regressao_linear_gold.sql` | `ML.EVALUATE` do linear semanal e mensal |
| `07_erro_por_produto_regressao_linear_gold.sql` | MAE por produto, semanal e mensal (linear) |
| `08_avaliacao_regressao_arvore_gold.sql` | `ML.EVALUATE` da árvore semanal e mensal |
| `09_erro_por_produto_regressao_arvore_gold.sql` | MAE por produto, semanal e mensal (árvore) |
| `10_global_explain_gold.sql` | `ML.GLOBAL_EXPLAIN` dos 4 modelos parametricos (linear/árvore × semanal/mensal) |
| `11_avaliacao_serie_arima_gold.sql` | `ML.ARIMA_EVALUATE` dos dois ARIMA gold, séries avaliadas vs. na fonte |
| `12_forecast_serie_arima_gold.sql` | Data final de previsão por série e cobertura de 2026-09-04 |
| `13_inferencia_regressao_linear.sql` | `ML.PREDICT` parametrizável (semanal e mensal) do linear gold |
| `14_inferencia_regressao_arvore.sql` | Idem para a árvore gold |
| `15_inferencia_serie_arima.sql` | `ML.FORECAST` parametrizável dos dois ARIMA gold |

### `sql/consultas/metricas/`

| Arquivo | O que faz |
|---|---|
| `01_comparacao_modelos_check.sql` | Confere dataset, contagem (6) e conteúdo de `comparacao_modelos` |
| `02_previsoes_demo.sql` | Previsões dos 6 modelos bronze/silver para as 3 datas de demo, formato comum para casamento em Python |
| `03_previsoes_demo_gold.sql` | Mesma lógica para os 6 modelos gold, com granularidade |
| `04_comparacao_modelos_check_gold.sql` | Confere contagem (12) e conteúdo final de `comparacao_modelos` |

### `ingestao/` e `scripts/`

| Arquivo | O que faz |
|---|---|
| `ingestao/upload_historico.sh` | Sobe o CSV histórico local para `gs://pdm-ceasa-dados/raw/`; idempotente; caminho de origem via `ARQUIVO_ORIGEM` (env) com default relativo ao repositório |
| `scripts/metricas_demo.py` | Roda `02_previsoes_demo.sql`, lê o recorte local, casa previsão×observado, calcula MAE/MSE/RMSE e grava via `UPDATE` nas 6 linhas bronze/silver de `comparacao_modelos` |
| `scripts/metricas_demo_gold.py` | Mesma lógica para as 6 linhas gold, casando pela convenção de período (semana/mês contém a data) |

## Como executar

Todo `.sql` roda via CLI a partir da raiz do repositório:

```bash
bq query --use_legacy_sql=false < caminho/do/arquivo.sql
```

Ordem de execução do pipeline:

1. `ingestao/upload_historico.sh` — sobe o CSV para o bucket
2. `sql/construir_tabelas/bronze/01_bronze.sql`
3. `sql/construir_tabelas/silver/01_*.sql` a `08_*.sql`, em ordem numérica
4. `sql/construir_tabelas/gold/01_*.sql` a `05_*.sql`, em ordem numérica
5. `sql/modelo/bronze/01_*.sql` a `05_*.sql`, em ordem
6. `sql/modelo/silver/01_*.sql` a `03_*.sql`, em ordem
7. `sql/modelo/gold/01_*.sql` a `06_*.sql`, em ordem
8. `sql/construir_tabelas/metricas/01_*.sql`, depois `02_*.sql`
9. `scripts/metricas_demo.py`, depois `scripts/metricas_demo_gold.py`

Os arquivos de `sql/consultas/` (conferência, avaliação, inferência) podem
rodar a qualquer momento depois que a tabela ou modelo correspondente existir.

**Não reexecutar por rotina** — tudo em `sql/modelo/`: cada arquivo contém
`CREATE OR REPLACE MODEL` e **retreina** ao rodar. Reexecutar sem mudança de
desenho não reproduz a métrica exata (`LINEAR_REG` tem inicialização
estocástica) e já custou tempo/crédito desnecessário numa reorganização
anterior. Para validar sintaxe sem treinar:

```bash
bq query --dry_run --use_legacy_sql=false < sql/modelo/<camada>/<arquivo>.sql
```

Retreino só acontece com intenção explícita de mudar desenho, dado de entrada
ou hiperparâmetro.

## Regras de tratamento da Silver

| Regra | Efeito |
|---|---|
| **R1** — dedup total (17 colunas da Bronze) | 0 linhas removidas (412.661 → 412.661) |
| **R2** — dedup ignorando `arquivo`/`layout` | 1.173 linhas removidas (→ 411.488) |
| **R3** — descarte de `categoria` e `codigo` | Sem efeito em linhas; remove colunas com prefixo ambíguo ou já sem uso |
| **R4** — normalização de texto e tipo | Sem efeito em linhas; padroniza `grupo`/`produto`/`embalagem` e converte preço/peso para FLOAT64 |
| **R5** — seleção de produto por densidade (2 janelas) | 372 → 274 → 224 → 184 → 141 produtos |
| **R6** — coerência de `preco_kg` | 1.321 linhas removidas (16 por incoerência + 1.305 por base de cálculo inválida) |
| **R7** — outlier de `preco_kg` por (produto, classe, ano) via IQR | 2.117 linhas removidas (298.826 → 296.709) |
| **R8** — de-para de grafia de produto (8 pares) | 0 linhas removidas, 141 produtos mantidos |
| **R9** — corte de classe (mantém 1 e 2) + materialização final | 164 linhas removidas (296.709 → 296.545) |

## Modelos

12 modelos, três algoritmos (regressão linear elastic net, árvore boosted,
ARIMA_PLUS) em quatro combinações de camada/granularidade:

| Modelo | Camada | Tipo | Alvo | Granularidade |
|---|---|---|---|---|
| `baseline.modelo_regressao_linear` | Bronze | LINEAR_REG | `preco_comum` em D+7 | Diária |
| `baseline.modelo_regressao_arvore` | Bronze | BOOSTED_TREE_REGRESSOR | `preco_comum` em D+7 | Diária |
| `baseline.modelo_serie_arima` | Bronze | ARIMA_PLUS (horizon=4) | Série de `preco_comum` | Diária |
| `silver.modelo_regressao_linear` | Silver | LINEAR_REG elastic net | `preco_comum` em D+7 | Diária |
| `silver.modelo_regressao_arvore` | Silver | BOOSTED_TREE_REGRESSOR | `preco_comum` em D+7 | Diária |
| `silver.modelo_serie_arima` | Silver | ARIMA_PLUS (horizon=60) | Série de `preco_comum` | Diária |
| `gold.modelo_regressao_linear_semanal` | Gold | LINEAR_REG elastic net | Média de `preco_comum` da semana seguinte | Semanal |
| `gold.modelo_regressao_arvore_semanal` | Gold | BOOSTED_TREE_REGRESSOR | Idem | Semanal |
| `gold.modelo_serie_arima_semanal` | Gold | ARIMA_PLUS (horizon=90) | Série de média semanal | Semanal |
| `gold.modelo_regressao_linear_mensal` | Gold | LINEAR_REG elastic net | Média de `preco_comum` do mês seguinte | Mensal |
| `gold.modelo_regressao_arvore_mensal` | Gold | BOOSTED_TREE_REGRESSOR | Idem | Mensal |
| `gold.modelo_serie_arima_mensal` | Gold | ARIMA_PLUS (horizon=24) | Série de média mensal | Mensal |

Os modelos de regressão nunca recebem preço da própria linha ou de linhas
futuras como feature — a Silver e a Gold acrescentam lags de preço passado
(5 lags diários na Silver; 5 lags semanais e 3 mensais na Gold), sempre
ancorados na data/período da própria observação.

## Resultados

Conteúdo vigente de `pdm-ceasa.metricas.comparacao_modelos` (12 linhas),
obtido via `SELECT * FROM pdm-ceasa.metricas.comparacao_modelos ORDER BY
camada, granularidade, modelo` em 2026-09-10. Os valores mudam a cada
retreino — esta é uma fotografia, não uma constante do repositório.

**Bloco formal** — `ML.EVALUATE` na partição de teste nunca vista no treino
(`data >= 2026-01-01` para Bronze/Silver; período equivalente de 2026 para a
Gold). ARIMA não tem partição de teste, por isso as três células ficam vazias:

| Camada | Granularidade | Modelo | R² | MAE | MSE | RMSE |
|---|---|---|---|---|---|---|
| Bronze | diária | regressao_linear | -1.535.674,71 (instável entre execuções) | 7.828,49 | 6,216 × 10⁹ | 78.843,86 |
| Bronze | diária | regressao_arvore | 0,3253 | 38,29 | 2.731,13 | 52,26 |
| Bronze | diária | serie_arima | — | — | — | — |
| Silver | diária | regressao_linear | 0,9513 | 8,64 | 192,53 | 13,88 |
| Silver | diária | regressao_arvore | 0,9605 | 6,83 | 156,03 | 12,49 |
| Silver | diária | serie_arima | — | — | — | — |
| Gold | semanal | regressao_linear | 0,9622 | 7,46 | 147,60 | 12,15 |
| Gold | semanal | regressao_arvore | 0,9700 | 5,95 | 117,33 | 10,83 |
| Gold | semanal | serie_arima | — | — | — | — |
| Gold | mensal | regressao_linear | 0,9236 | 11,42 | 298,25 | 17,27 |
| Gold | mensal | regressao_arvore | 0,9347 | 9,59 | 254,67 | 15,96 |
| Gold | mensal | serie_arima | — | — | — | — |

**Bloco demo** — erro calculado por fora, comparando `ML.PREDICT`/`ML.FORECAST`
com o `preco_comum` observado no recorte de demo (2026-09-01, 03 e 04, nunca
vistas em nenhum treino). É o único bloco com número para os três ARIMA,
porque não depende de partição de teste:

| Camada | Granularidade | Modelo | MAE demo | RMSE demo | n obs |
|---|---|---|---|---|---|
| Bronze | diária | regressao_linear | 103.898,65 | 287.567,26 | 659 |
| Bronze | diária | regressao_arvore | 38,85 | 53,69 | 659 |
| Bronze | diária | serie_arima | 4,84 | 9,70 | 266 |
| Silver | diária | regressao_linear | 8,94 | 16,73 | 426 |
| Silver | diária | regressao_arvore | 7,01 | 15,42 | 426 |
| Silver | diária | serie_arima | 7,71 | 16,34 | 225 |
| Gold | semanal | regressao_linear | 8,90 | 16,88 | 426 |
| Gold | semanal | regressao_arvore | 6,93 | 15,50 | 426 |
| Gold | semanal | serie_arima | 7,14 | 14,92 | 426 |
| Gold | mensal | regressao_linear | 12,73 | 19,46 | 426 |
| Gold | mensal | regressao_arvore | 10,37 | 18,97 | 426 |
| Gold | mensal | serie_arima | 9,35 | 18,23 | 426 |

**Ressalvas obrigatórias:**

- A diferença entre Bronze e Silver **não isola o efeito da limpeza**: a
  Silver tem limpeza de dado *e* engenharia de features (os 5 lags de preço
  passado) que a Bronze não tem. A diferença mede os dois efeitos somados —
  por isso o salto de R² de 0,3253 (melhor caso Bronze) para 0,96+ (Silver)
  não pode ser atribuído só à limpeza.
- O alvo da Gold é **média de preço do período** (semana ou mês seguinte),
  não o preço de um dia como em Bronze/Silver. O erro absoluto menor da Gold
  (MAE de 5,95 a 11,42, contra 6,83 a 8,64 na Silver) é esperado por
  construção da métrica — a média suaviza variação — e não é comparável em
  escala com as camadas diárias.

Achado adicional registrado na `observacao` da tabela, não corrigido: no
`gold.modelo_serie_arima_semanal`, a série `banana_maca` classe 2 teve
`AUTO_FREQUENCY` inferindo passo de ~105 dias (183 das 184 séries avaliadas
inferiram o passo semanal esperado de 7 dias), estendendo sua previsão até
2049-09-27 — mesmo padrão de extrapolação anômala já visto na Silver.

## Limitações conhecidas

- **`preco_minimo`/`preco_maximo` incoerentes**: cerca de 11.700 linhas têm
  `preco_comum` fora do intervalo `[preco_minimo, preco_maximo]` da própria
  linha; 96% concentradas antes de 2017. Não corrigido em nenhuma camada.
- **348 semanas com cotação em 7 dias**, incluindo domingo — a CEASA
  tipicamente não opera aos domingos; achado não investigado a fundo.
- **Séries ARIMA com extrapolação anômala**: quando `AUTO_FREQUENCY` infere
  passo irregular (produto com poucas cotações espaçadas), o horizonte pode
  projetar dezenas de anos à frente (ex.: uma série chegou a prever até
  2072). Comportamento nativo do `ARIMA_PLUS`, não filtrado.
- **5 produtos com classe 1 mais cara que classe 2 invertida** — ou seja,
  classe 1 (nominalmente superior) aparece mais barata que classe 2 em pelo
  menos 5 produtos. Não corrigido; classe é tratada como vier da fonte.
- **89 séries (17,5% dos 508 pares produto/classe da Bronze) não têm modelo
  ARIMA algum**, por histórico insuficiente (1-2 pontos); mais algumas falham
  por frequência irregular demais para o `ARIMA_PLUS` estabelecer um passo.
- **26 dos 210 pares produto/classe da Gold estão descontinuados** (última
  cotação real antes de 2025) e não alcançam as datas recentes com nenhum
  horizonte razoável de `ML.FORECAST`.
