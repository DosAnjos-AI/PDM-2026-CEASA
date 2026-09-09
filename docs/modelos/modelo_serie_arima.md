# `modelo_serie_arima` — `pdm-ceasa.baseline.modelo_serie_arima`

Script: `sql/modelo/bronze/04_baseline_treino_arima.sql` (treino),
`sql/modelo/bronze/05_baseline_avaliacao.sql` (marca a métrica como não
aplicável). Retreinado no Bloco 11 (versão do
Bloco 10 tinha split; esta versão não tem — ver seção Split).

## Objetivo

Projetar a série de `preco_comum` de cada (`produto`, `classe`) alguns
passos (pregões) à frente do fim da série treinada. Entrada é a própria
série histórica por (`produto`, `classe`) — não uma linha com features, como
nos dois modelos de regressão.

## Dados

- Origem: `pdm-ceasa.bronze.cotacoes` diretamente, sem tratamento e sem
  passar pela tabela `dados_treino` (o ARIMA consome série, não linha com
  alvo pré-calculado).
- Colunas selecionadas: `data` (timestamp da série), `preco_comum` (valor da
  série), `serie_id = CONCAT(produto, '|', CAST(classe AS STRING))`
  (identificador da série — BQML exige coluna única para `time_series_id_col`).
- Período: toda a Bronze, sem filtro de data — `2010-01-04` a `2026-08-28`
  (data máxima confirmada na execução do Bloco 11).
- Linhas de entrada: 412.661 (toda a Bronze).
- Séries possíveis (pares produto/classe distintos em toda a Bronze): 508.

## Alvo

Não há alvo tabular pré-calculado como nos modelos de regressão — o próprio
ARIMA projeta os próximos valores da série via `horizon`. Não há, portanto,
a regra de "pregão mais próximo seguinte a D+7" aplicada aqui; o alcance em
dias corridos da projeção depende da frequência de pregões inferida pelo
modelo (ver seção Hiperparâmetros).

## Split

**Sem partição de teste — decisão registrada no Bloco 11.** O ARIMA vale
pela previsão ao vivo na apresentação, comparada contra o recorte de 4 datas
reservado para a demo (`docs/bronze/bronze.md`), não por métrica de teste
sobre dado histórico. Por isso o script treina com a série completa
disponível na Bronze, sem filtro de data — ao contrário dos dois modelos de
regressão, que continuam com split temporal (`treino <= 2025-12-31`,
`teste >= 2026-01-01`) e não foram alterados no Bloco 11.

Consequência: a tabela `pdm-ceasa.baseline.metricas` traz, para
`modelo_serie_arima`, uma única linha com `metrica = 'sem_particao_teste'` e
`valor = NULL` — não uma métrica de erro. Nenhuma métrica de teste foi
inventada para preencher essa lacuna.

## Colunas usadas

| Coluna | Papel |
|---|---|
| `data` | `time_series_timestamp_col` — eixo temporal da série |
| `preco_comum` | `time_series_data_col` — valor previsto |
| `serie_id` | `time_series_id_col` — identifica cada série (`PRODUTO\|CLASSE`), permite treinar todas em um único `CREATE MODEL` |

## Colunas rejeitadas

Não se aplica no mesmo sentido dos modelos de regressão — o ARIMA não recebe
uma linha de features, só a série (`data`, `preco_comum`) por identificador.
`preco_maximo`, `preco_minimo` e `preco_kg` não entram porque o `ARIMA_PLUS`
projeta uma única série univariada por `time_series_id`; nenhum deles é
usado como variável auxiliar.

## Hiperparâmetros

```sql
OPTIONS (
  model_type = 'ARIMA_PLUS',
  time_series_timestamp_col = 'data',
  time_series_data_col = 'preco_comum',
  time_series_id_col = 'serie_id',
  horizon = 4,
  auto_arima = TRUE
)
```
- `model_type = 'ARIMA_PLUS'`: modelo de série temporal do BQML.
- `time_series_timestamp_col = 'data'`, `time_series_data_col = 'preco_comum'`:
  definem o eixo temporal e o valor da série.
- `time_series_id_col = 'serie_id'`: treina todas as 508 séries possíveis em
  um único modelo, uma por valor distinto de `serie_id`.
- `horizon = 4`: número de passos (pregões) projetados à frente do fim da
  série, não dias corridos. **`horizon` conta pregões, não dias.** Medido
  sobre toda a Bronze, o gap médio entre pregões é de ~1,76 dia (~4 pregões
  por semana); a equivalência adotada foi 4 pregões ≈ 7 dias corridos — mas é
  aproximada, não exata (pregões não caem em intervalos regulares). Na
  prova de execução do Bloco 11, a série `TOMATE SALADETE|1` teve passo
  diário, então os 4 passos cobriram só 4 dias corridos (`2026-08-29` a
  `2026-09-01`), não 7 — **o alcance real em dias corridos varia por série**
  e não é garantido pelo parâmetro único e global.
- `auto_arima = TRUE`: BQML escolhe automaticamente a ordem (p, d, q) e
  sazonalidade de cada série.

**Particularidade de uso a registrar:** `ML.FORECAST(MODEL ...)` chamado
sem `STRUCT` explícito usa o horizonte default da própria função (**3**),
não o `horizon = 4` definido no treino. Qualquer consulta ao modelo — na
demo inclusive — precisa passar `STRUCT(4 AS horizon)` explicitamente para
obter os 4 passos treinados; confirmado por execução no Bloco 11 (chamada
sem `STRUCT` devolveu 3 linhas para `TOMATE SALADETE|1`; com
`STRUCT(4 AS horizon)`, devolveu 4).

## Métricas

Não aplicável — sem partição de teste, por decisão registrada (ver seção
Split). A tabela `pdm-ceasa.baseline.metricas` traz `valor = NULL` para essa
linha, em vez de uma métrica de erro.

## Séries descartadas nativamente pelo BQML

De 508 pares (produto, classe) possíveis em toda a Bronze:

- **419 séries** entram no modelo (aparecem em `ML.ARIMA_EVALUATE`).
- **4 delas falham** com o erro `"The input time series has a data
  frequency longer than the two year maximum"`: `BETERRABA|3`,
  `CAJAMANGA|2`, `LIMAO TAHITI (SP)|2`, `TOMATE CEREJA BDJ|2`. Provável
  causa: gaps entre pregões grandes demais para o `ARIMA_PLUS` estabelecer
  uma frequência.
- **89 séries** ficam totalmente fora do modelo (nem aparecem em
  `ML.ARIMA_EVALUATE`), descarte silencioso e nativo do BQML. Verificado por
  execução: todas as 89 têm **1 ou 2 pontos** em toda a Bronze — histórico
  insuficiente para qualquer ajuste ARIMA.

Nenhuma dessas exclusões foi feita manualmente; é comportamento nativo do
`ARIMA_PLUS` diante de séries curtas ou irregulares demais.

## Previsão de exemplo

Série `TOMATE SALADETE|1`, `ML.FORECAST(MODEL ..., STRUCT(4 AS horizon))`:

| `forecast_timestamp` | `forecast_value` | Valor real (recorte de demo, fora da Bronze) |
|---|---|---|
| 2026-08-29 | 104,30 | lacuna — data não está no recorte de demo |
| 2026-08-30 | 109,46 | lacuna — data não está no recorte de demo |
| 2026-08-31 | 113,03 | 120,00 |
| 2026-09-01 | 107,76 | 160,00 |

Valores reais lidos de `recorte/cotacoes_recorte_demo.csv` (fora da Bronze e
do BigQuery — arquivo local separado antes da ingestão, ver
`docs/bronze/bronze.md`), não de uma consulta ao banco.

## Limitações

- Sem partição de teste: não há métrica de erro para comparar contra os
  modelos de regressão nesta tabela — a validação real é a comparação ao
  vivo contra o recorte de demo, fora do escopo deste bloco.
- `horizon` conta pregões, não dias corridos, e o alcance real em dias varia
  por série conforme a frequência de pregões observada em cada uma — não há
  garantia de que "4 passos" signifique "7 dias corridos" para um produto
  específico.
- 89 séries (17,5% dos 508 pares possíveis) não têm modelo algum, por
  histórico insuficiente (1-2 pontos); mais 4 séries falham por frequência
  irregular. Para essas, `ML.FORECAST` não retorna previsão.
- `ML.FORECAST` sem `STRUCT(4 AS horizon)` explícito devolve só 3 passos
  (default da função), não os 4 treinados — armadilha de uso a evitar na
  consulta ao vivo da demo.
