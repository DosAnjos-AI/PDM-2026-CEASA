<!-- INICIO DO RELATORIO -->
# Auditoria das colunas de preço — prata CEASA-GO

Data: 2026-10-16. Tabela auditada: `pdm-ceasa.silver.ceasa_go_prata`.
Script executor: `sql/construir_tabelas/silver/ceasa_go/ceasa_go_prata.sql`.
Nenhuma correção foi executada. Tudo marcado [FATO] foi medido nesta sessão,
e a query que produziu o número vem logo abaixo dele.

Alias usado nas queries: `T` = `` `pdm-ceasa.silver.ceasa_go_prata` ``,
`V` = `(preco_comum < preco_minimo OR preco_comum > preco_maximo)`.

---

## 1. Schema e contagem da bronze

[FATO] `bronze.ceasa_go` tem 412.661 linhas, de 2010-01-04 a 2026-08-28, e 17 colunas:
`data DATE, ano/mes/dia INTEGER, grupo, categoria, codigo, produto, embalagem STRING,
qtd_kg FLOAT, classe STRING, preco_comum, preco_maximo, preco_minimo, preco_kg FLOAT,
layout, arquivo STRING`.

```bash
bq show --schema --format=prettyjson pdm-ceasa:bronze.ceasa_go
bq query --use_legacy_sql=false 'SELECT COUNT(*) linhas, MIN(data) de, MAX(data) ate FROM `pdm-ceasa.bronze.ceasa_go`'
```

Observação: `classe` é STRING na bronze de GO (em `bronze.cotacoes` era inteiro). O filtro usa `classe = '1'`.

## 2. Portão de validação

[FATO] O portão **fecha sem divergência**. Contagem por CTE, medida com uma query de
diagnóstico descartável (as mesmas CTEs do script, com `SELECT COUNT(*)` no fim e sem
nada materializado):

| CTE | linhas | produtos | esperado |
|---|---|---|---|
| r1_dedup | 411.488 | 372 | 411.488 |
| r3_normalizado | 411.488 | 372 | 372 produtos |
| r5a_lista | — | 184 | 184 |
| r5b_lista | — | 141 | 141 |
| r5_densidade | 300.147 | 141 | — |
| r6_coerente | 298.826 | 141 | 298.826 |
| r7_sem_outliers | 296.709 | 141 | 296.709 |
| r8_de_para | 296.709 | 141 | 296.709 |
| **prata** | **66.057** | **26** | **66.057 / 26** |
| classes distintas na prata | — | 1 (`'1'`) | só `1` |

```sql
-- tabela gravada
SELECT COUNT(*) linhas, COUNT(DISTINCT produto) produtos, STRING_AGG(DISTINCT classe) classes,
       MIN(data) de, MAX(data) ate
FROM T;
-- 66057 | 26 | 1 | 2010-01-04 | 2026-08-28
```

Nenhum dos três suspeitos se manifestou:
- R7: `PERCENTILE_CONT` e o `quantile()` padrão do pandas usam a mesma interpolação linear.
- R6: os 182 `preco_kg` nulos coincidem com `qtd_kg` inválido, então caem nos dois lados.
- R1: a deduplicação dá 411.488 nos dois.

[FATO] R5 não altera o escopo: os 26 produtos somam 80.629 linhas antes e depois de R5.

Decisões de forma tomadas na prata:
- `produto_bronze` guarda o nome **cru** da bronze (ex.: `BATATA COMUM DIVERSAS`), não o normalizado.
- `layout` e `arquivo` são preservados. [FATO] Em 130 linhas a deduplicação juntou mais de um
  arquivo, e eles ficam concatenados com `,`. Em nenhuma linha juntou mais de um layout.

```sql
SELECT COUNTIF(STRPOS(arquivo, ',')>0), COUNTIF(STRPOS(layout, ',')>0) FROM T;  -- 130 | 0
```

## 3. Números do pandas — reprodução

[FATO] Os 15 números foram reproduzidos exatamente.

```sql
SELECT COUNTIF(preco_minimo > preco_maximo) minimo_maior_maximo,          -- 34
       COUNTIF(preco_minimo > preco_comum)  minimo_maior_comum,           -- 6197
       COUNTIF(preco_comum  > preco_maximo) comum_maior_maximo,           -- 74
       COUNTIF(V)                           comum_fora_faixa,             -- 6265
       COUNTIF(preco_minimo = preco_comum AND preco_comum = preco_maximo) os_tres_iguais, -- 23114
       COUNTIF(qtd_kg IS NULL OR qtd_kg = 0) qtd_kg_invalido,             -- 0
       COUNTIF(ABS(preco_kg - preco_comum/qtd_kg)/(preco_comum/qtd_kg) > 0.01) kg_diverge, -- 0
       COUNTIF(embalagem IS NULL) embalagem_nula,                          -- 1
       COUNT(*) total                                                      -- 66057
FROM T;
```

| coluna | nulos | zeros | negativos | mínimo | máximo | mediana |
|---|---|---|---|---|---|---|
| preco_comum | 0 | 0 | 0 | 0,30 | 440,00 | 40,00 |
| preco_minimo | 0 | 16 | 0 | 0,00 | **1.350,00** | 40,00 |
| preco_maximo | 0 | 16 | 0 | 0,00 | 480,00 | 50,00 |
| preco_kg | 0 | 0 | 0 | 0,08 | 36,667 | 2,333 |
| qtd_kg | 0 | 0 | 0 | 1,0 | 50,0 | 20,0 |

```sql
SELECT c, COUNTIF(v IS NULL), COUNTIF(v=0), COUNTIF(v<0), MIN(v), MAX(v)
FROM T, UNNEST([STRUCT('preco_comum' AS c, preco_comum AS v), ('preco_minimo', preco_minimo),
                ('preco_maximo', preco_maximo), ('preco_kg', preco_kg), ('qtd_kg', qtd_kg)])
GROUP BY c;
-- mediana exata: PERCENTILE_CONT(v, 0.5) OVER (PARTITION BY c) sobre o mesmo UNNEST
```

[FATO] As violações por produto conferem uma a uma com a lista do pandas: tomate_longa_vida 828 …
uva_italia 1, e zero em abobrinha_italiana, berinjela e milho_verde.

```sql
SELECT produto, COUNT(*) linhas, COUNTIF(V) violacoes FROM T GROUP BY produto ORDER BY violacoes DESC;
```

## 4. Hipótese principal

**Veredito: confirmada quanto à rastreabilidade, inconclusiva quanto ao culpado.**
- Rastreabilidade [FATO]: o defeito está num subconjunto de origem identificável.
- Culpado: não foi possível verificar se o erro veio da ingestão ou se já estava na planilha-fonte.

### 4.1 O formato da violação

[FATO] 6.166 das 6.265 violações (98,4%) têm exatamente o formato descrito,
`min = max` com `comum` abaixo dos dois.

| formato | linhas |
|---|---|
| min = max, comum < ambos | 6.166 |
| min = max, comum > ambos | 46 |
| min > max | 34 |
| comum < min (min < max) | 14 |
| comum > max (min < max) | 5 |

```sql
SELECT CASE WHEN preco_minimo = preco_maximo AND preco_comum < preco_minimo THEN 'min=max, comum<ambos'
            WHEN preco_minimo = preco_maximo AND preco_comum > preco_maximo THEN 'min=max, comum>ambos'
            WHEN preco_minimo > preco_maximo THEN 'min>max'
            WHEN preco_comum < preco_minimo THEN 'comum<min (min<max)'
            WHEN preco_comum > preco_maximo THEN 'comum>max (min<max)' END formato, COUNT(*)
FROM T WHERE V GROUP BY formato;
```

### 4.2 Teste decisivo: `layout`

[FATO] O teste por `layout` **não discrimina**. Todas as 6.265 violações estão em `antigo`,
mas `antigo` cobre 2010 a 2026-07 e 99,6% da prata.

| layout | linhas | violações |
|---|---|---|
| antigo | 65.765 | 6.265 |
| novo | 269 | 0 |
| novo-ocr | 23 | 0 |

```sql
SELECT layout, COUNT(*), COUNTIF(V) FROM T GROUP BY layout;
```

### 4.3 Teste decisivo: `arquivo` e `ano`

[FATO] `arquivo` **discrimina**. As linhas de 2010 a 2016 vêm de 15 planilhas `.xlsx`, uma
por produto (ex.: `tomate_lv.xlsx`). Os PDFs diários começam em 2019-01-03.

| extensão | arquivos | de | até | linhas | violações | min = max |
|---|---|---|---|---|---|---|
| xlsx | 15 | 2010-01-04 | 2024-04-11 | 27.979 | 6.227 | 24.664 |
| pdf | 1.490 | 2019-01-03 | 2026-08-28 | 38.078 | 38 | 4.662 |

```sql
SELECT REGEXP_EXTRACT(arquivo, r'\.(\w+)$') ext, COUNT(DISTINCT arquivo), MIN(data), MAX(data),
       COUNT(*), COUNTIF(V), COUNTIF(preco_minimo=preco_maximo)
FROM T GROUP BY ext;
```

[FATO] Dentro dos xlsx há uma fronteira de data exata, entre **2016-07-21** e **2016-08-02**
(não houve pregão entre essas datas):

| trecho | linhas | min = max | violações |
|---|---|---|---|
| **A**: xlsx, data < 2016-08-01 | 19.795 | **19.795 (100%)** | **6.207** |
| B: xlsx, data ≥ 2016-08-01 | 8.184 | 4.869 | 20 |

```sql
SELECT IF(data < '2016-08-01','A','B') trecho, COUNT(*), COUNTIF(preco_minimo=preco_maximo), COUNTIF(V)
FROM T WHERE ENDS_WITH(arquivo,'.xlsx') GROUP BY trecho;

-- fronteira, pregão a pregão
SELECT data, COUNT(*), COUNTIF(preco_minimo=preco_maximo), COUNTIF(V)
FROM T WHERE data BETWEEN '2016-07-20' AND '2016-08-10' GROUP BY data ORDER BY data;
-- 2016-07-21: 15 linhas, 15 min=max, 8 violações | 2016-08-02: 12 linhas, 2 min=max, 0 violações
```

[FATO] **O trecho A concentra 6.207 das 6.265 violações (99,07%)** e cobre todos os 15 arquivos xlsx.
No trecho A, `preco_minimo` nunca difere de `preco_maximo`.

[FATO] A taxa de violação por ano segue a mesma fronteira:

| ano | violações | % do ano |
|---|---|---|
| 2010 a 2016 | 733 a 1.309 por ano | 16% a 44% |
| 2017 a 2026 | 1 a 15 por ano | ≤ 0,37% |

```sql
SELECT ano, COUNT(*), COUNTIF(V), ROUND(100*COUNTIF(V)/COUNT(*),2) FROM T GROUP BY ano ORDER BY ano;
```

### 4.4 O valor duplicado é um máximo, não um mínimo

[FATO] No trecho A, o valor gravado nas duas colunas fica:
- **abaixo** de `preco_comum` em só 25 de 19.779 linhas;
- **acima** de `preco_comum` em 6.166 linhas.

Isso é comportamento de máximo. No trecho B, onde min e max divergem de verdade, o mínimo fica
abaixo do comum em 1.605 linhas. Conclusão: no trecho A, **`preco_minimo` contém uma cópia do
máximo**.

```sql
SELECT IF(data<'2016-08-01','A','B') trecho, COUNT(*),
       COUNTIF(preco_minimo<preco_comum) min_abaixo_comum, COUNTIF(preco_maximo>preco_comum) max_acima_comum
FROM T WHERE ENDS_WITH(arquivo,'.xlsx') AND preco_maximo>0 GROUP BY trecho;
-- A: 19779 | 25 | 6166      B: 8184 | 1605 | 2182
```

### 4.5 A bimodalidade por produto é efeito de período

[FATO] A bimodalidade por produto se explica pelo período coberto:

| grupo | produtos | início da série | linhas por produto | violações |
|---|---|---|---|---|
| alto | 15 | 2010-01 | ~3.300 | ≥ 159 |
| baixo | 11 | 2019-01-03 | ~1.450 | 0 a 5 |

Os 11 do grupo baixo não têm linha no trecho A.

```sql
SELECT produto, MIN(data) inicio, COUNT(*), COUNTIF(V), MAX(IF(V, data, NULL)) FROM T GROUP BY produto ORDER BY inicio;
```

### 4.6 O que fica sem resposta

[HIPÓTESE] Não se sabe se o erro foi introduzido na ingestão (uma coluna-fonte lida para
`min` e `max`) ou se a própria planilha já trazia uma coluna só. Teste que resolveria: abrir
um dos 15 xlsx originais (ex.: `tomate_lv.xlsx`) e ver se há coluna de mínimo distinta antes
de ago/2016. Os xlsx e o código de ingestão de `bronze.ceasa_go` não estão no repositório nem
nas pastas locais `historico/` e `recorte/`.

## 5. Tabela de problemas

% sobre 66.057 linhas.

| problema | linhas | % | evidência | gravidade |
|---|---|---|---|---|
| `preco_minimo` = cópia do máximo no trecho A (xlsx até 2016-07-21) | 19.795 | 29,97 | §4.3, §4.4 | **alta**: min inválido em 30% da base; gera 6.207 violações |
| `comum` fora de `[min, max]`, total | 6.265 | 9,48 | §3 | sintoma; 99,07% explicado pelo item acima |
| min e max zerados (as mesmas 16 linhas, todas no trecho A) | 16 | 0,024 | §6.1 | média |
| `min > max` fora do trecho A (2017–2025, xlsx e pdf) | 34 | 0,051 | §7 | média; há razões ~8× em 2020 e 2023 (escala) |
| violações residuais fora do trecho A | 58 | 0,088 | §4.3 | baixa |
| `preco_minimo` = 1.350,00 (provável zero a mais) | 1 | 0,002 | §6.2 | baixa, mas distorce o máximo da coluna |
| `preco_comum` = 2,00 / `preco_kg` = 0,08 em repolho, 2012-07-30 (provável escala ÷10) | 1 | 0,002 | §6.4 | baixa; R7 não pegou |
| `embalagem` nula | 1 | 0,002 | §6.3 | baixa |

```sql
-- linhas do trecho A
SELECT COUNT(*) FROM T WHERE ENDS_WITH(arquivo,'.xlsx') AND data < '2016-08-01';  -- 19795
-- violações fora do trecho A
SELECT COUNTIF(V) FROM T WHERE NOT (ENDS_WITH(arquivo,'.xlsx') AND data < '2016-08-01');  -- 58
```

## 6. Casos pontuais

### 6.1 Zeros em min e max

[FATO] São as mesmas 16 linhas: `preco_minimo = 0` e `preco_maximo = 0` ao mesmo tempo.

```sql
SELECT COUNTIF(preco_minimo=0), COUNTIF(preco_maximo=0), COUNTIF(preco_minimo=0 AND preco_maximo=0) FROM T;  -- 16 | 16 | 16
SELECT data, produto, produto_bronze, embalagem, qtd_kg, preco_minimo, preco_comum, preco_maximo, preco_kg, layout, arquivo
FROM T WHERE preco_minimo=0 OR preco_maximo=0 ORDER BY data;
```

| data | produto | comum | qtd_kg | arquivo |
|---|---|---|---|---|
| 2013-04-16 | 12 produtos (banana_maca, repolho_verde, quiabo, melancia, chuchu, cenoura, maracuja_azedo, beterraba, maca_fuji, mamao_formosa, laranja_pera, batata_lisa) | 0,80 a 150,00 | — | o xlsx de cada produto |
| 2014-07-01 | tomate_longa_vida | 50,00 | 22 | tomate_lv.xlsx |
| 2014-08-08 | tomate_longa_vida | 60,00 | 22 | tomate_lv.xlsx |
| 2015-11-13 | pimentao_verde | 20,00 | 10 | pimentao.xlsx |
| 2015-12-01 | quiabo | 20,00 | 14 | quiabo.xlsx |

Todas as 16 estão no trecho A, com layout `antigo`. Em 2013-04-16 o pregão inteiro dos 12
produtos veio sem min/max. `preco_comum` e `preco_kg` são coerentes nas 16 linhas.

### 6.2 `preco_minimo` = 1.350,00

[FATO] A linha:
`2023-12-15 | batata_inglesa | BATATA COMUM DIVERSAS | sc | qtd_kg 50 | min 1350,00 | comum 140,00 | max 170,00 | kg 2,80 | antigo | 2023/12/2023-12-15.pdf`.

Os vizinhos (11 a 22/12) têm min entre 65 e 160.

```sql
SELECT * FROM T WHERE preco_minimo = 1350;
-- vizinhança: mesmo produto, ±7 dias
```

[HIPÓTESE] Zero a mais (135,00), mas mesmo assim 135 < comum 140 não fecharia com a ordem
esperada. Teste: abrir `2023/12/2023-12-15.pdf`.

### 6.3 `embalagem` nula

[FATO] A linha:
`2026-08-06 | laranja_lima | LARANJA LIMA | grupo fn | qtd_kg 25 | min 100 | comum 120 | max 130 | kg 4,80 | novo-ocr | 2026/08/2026-08-06.pdf`.

É o único arquivo do layout `novo-ocr`, o que aponta para falha de OCR.

```sql
SELECT *, grupo FROM T WHERE embalagem IS NULL;
```

### 6.4 `preco_comum` 0,30 e `preco_kg` 0,08

```sql
SELECT * FROM T WHERE preco_comum = 0.3 OR preco_kg = 0.08;
-- vizinhança de cada uma por produto e ±10 dias
```

- [FATO] `preco_comum` 0,30: melancia, 2010-07-27, kg, `melancia.xlsx`. Os vizinhos estão em
  0,35 a 0,40/kg. **Plausível.**
- [FATO] `preco_kg` 0,08: repolho_verde, 2012-07-30, comum 2,00 em embalagem de 25 kg,
  `repolho_verde.xlsx`. Os vizinhos estão em comum 15 a 30 (0,60 a 1,20/kg).
  [HIPÓTESE] **Erro de escala** (20,00 gravado como 2,00): os três preços estão em 2,00, o
  que é coerente internamente mas 10× abaixo dos vizinhos. R7 não pegou porque o limite
  inferior Q1 − 3×IQR do ano fica abaixo de 0,08.

## 7. Achados adicionais (uma linha cada, sem aprofundar)

- [FATO] A nota sobre R8 do prompt não vale para GO: a grafia `MACA NACIONAL GALA (CART.) T150` não existe na bronze de GO, então R8 é no-op e pular R8 não perde linha. Query: `SELECT produto, classe, COUNT(*) FROM bronze.ceasa_go WHERE UPPER(produto) LIKE '%GALA%' GROUP BY 1,2`.
- [FATO] Existe `MACA NACIONAL GALA (SOLTA)`, com 2.620 linhas em classe 1 desde 2010-01-04, fora do escopo; a `maca_gala` do escopo só começa em 2019-01-03 (mesma query acima).
- [FATO] Os xlsx continuam até 2024-04-11 e se sobrepõem aos PDFs desde 2019, mas a prata não tem chave `(produto, data)` duplicada (query: `GROUP BY produto, data HAVING COUNT(*)>1` → 0 grupos).
- [FATO] Dos 23.114 `min = comum = max`, 14.164 estão em 2010–2016, onde `min = max` é estrutural (trecho A). Ali essa igualdade não é evidência de pouca oferta (query: `estrutura_min_max` por período).
- [FATO] As 34 linhas com `min > max` estão espalhadas entre 2017 e 2025, em xlsx e pdf. A mediana da razão min/max fica em ~1,25, mas chega a ~8× em 2020 e 2023, o que sugere erro de escala (query: `WHERE preco_minimo>preco_maximo GROUP BY ano, ext`).
- [FATO] Existe uma `silver.ceasa_go` vazia, que não foi tocada.

## 8. Propostas de correção (não executadas)

### 8.1 Trecho A: 19.795 linhas, xlsx até 2016-07-21

| opção | o que faz | custo | risco |
|---|---|---|---|
| A1 | `preco_minimo = NULL` no trecho A; `preco_maximo` mantido | 1 `CASE` no script | baixo; assume que o valor é o máximo (sustentado por §4.4) |
| A2 | `preco_minimo` e `preco_maximo` = NULL no trecho A | 1 `CASE` | mínimo; perde a faixa de 2010–2016 inteira |
| A3 | coluna `faixa_confiavel BOOL` (FALSE no trecho A), sem mexer nos valores | 1 coluna | baixo, mas empurra a decisão para quem consome |
| A4 | descartar o trecho A | 1 filtro | **alto**: as 15 séries longas passam a começar em 2016-08, perdendo 30% das linhas e 6,5 anos |
| A5 | recuperar o mínimo nos xlsx originais | desconhecido; exige os arquivos | só funciona se a planilha tiver a coluna (§4.6) |

Recomendação: **A1 + A3**, que mantém o máximo, anula o mínimo sabidamente inválido e deixa o
trecho marcado. Os 16 zeros (§6.1) ficam cobertos se a regra também anular `preco_maximo = 0`.

### 8.2 Casos fora do trecho A

| caso | opção | custo | risco |
|---|---|---|---|
| 34 `min > max` | NULL nos dois | baixo | baixo; não tentar trocar, porque há casos de escala |
| 1.350,00 | NULL em `preco_minimo` dessa linha, ou regra genérica `min > 3× max` → NULL | baixo | baixo |
| repolho 2012-07-30 | descartar a linha, ou regra de razão contra a mediana móvel do produto | linha: trivial; regra: média | regra nova pode pegar variação real de preço |
| 58 violações residuais | manter e marcar; volume desprezível | nenhum | nenhum |
| `embalagem` nula | preencher com a embalagem dominante do produto | baixo | baixo; a dominante ainda precisa ser medida |

## 9. Não verificado e o que seria preciso

| item | o que falta |
|---|---|
| culpado do trecho A (ingestão ou planilha) | os 15 xlsx originais e o código que gerou `bronze.ceasa_go`, ausentes do repositório |
| 1.350,00 e repolho 2012-07-30 | o PDF de 2023-12-15 e o `repolho_verde.xlsx` |
| embalagem dominante de `laranja_lima` | não medida (query simples sobre `T`) |
| validade dos 8.955 `min = max` de 2017+ | segundo o Mestre, repetição é comum; não há teste que separe repetição legítima de cópia |
| trecho A nos outros CEASAs | fora do escopo desta sessão |
<!-- FIM DO RELATORIO -->

---

## Log de lapidação

Cada entrada registra uma decisão do Mestre sobre `silver.ceasa_go_prata`: o problema, o
comando, as linhas afetadas e o estado antes e depois. A partir da entrada 2, as correções
são aplicadas direto na tabela e espelhadas no script `ceasa_go_prata.sql`, sem rodá-lo.

| # | data | problema | comando | linhas afetadas | antes | depois |
|---|---|---|---|---|---|---|
| 1 | 2026-10-16 | trecho xlsx até 2016-07-21 com `preco_minimo` = cópia do máximo | CTE `corte_2017` (`WHERE data >= '2017-01-01'`) + recriação da prata pelo script | 21.094 removidas | 66.057 linhas, 26 produtos | 44.963 linhas, 26 produtos, 2017-01-02 a 2026-08-28 |
| 2 | 2026-10-16 | problema 1 da lista remanescente: `min = max` desproporcional nos xlsx | nenhum: fechado como não-problema (efeito de período, não de fonte) | 0 | 44.963 | 44.963 |
| 3 | 2026-10-17 | problema 2: `preco_minimo > preco_maximo` | `UPDATE ... FROM (cálculo p2) WHERE guarda`; espelhado nas CTEs `p2_base`, `p2_vizinhos`, `p2_calculo` e `p2_inversao` | 31 alteradas: P1 6, P2 1, P3 17, P4 7. Comum alterado: 0. Rejeitadas pela guarda: 3 | min > max 34; fora da faixa 58 | min > max 3; fora da faixa 27; soma de `preco_comum` e de `preco_kg` inalteradas |

Detalhe da entrada 3:

- Regra: P1 e P4 recebem a média dos pregões válidos vizinhos no mínimo; P2 e P4, no máximo; P3 troca mínimo e máximo. Vizinho válido é o pregão com `min ≤ comum ≤ max`. As médias são arredondadas a 3 casas.
- Ensaio: 0 linhas sem vizinho e 0 com um só vizinho.
- Rejeitadas pela guarda, mantidas como estavam por ambiguidade entre comum e ponta:
  - cenoura 2017-05-22 (P2): o máximo interpolado ficaria 17,5, abaixo do comum 20.
  - quiabo 2018-04-24 (P1): o mínimo interpolado ficaria 42,5, acima do comum 40.
  - quiabo 2023-06-08 (P4): o máximo interpolado ficaria 110, abaixo do comum 120.
- Exemplos (mínimo / comum / máximo):
  - #7 batata 2023-12-15: 1350 / 140 / 170 → 102,5 / 140 / 170.
  - #8 cenoura 2017-05-22: rejeitada, sem alteração.
  - #10 pimentão 2023-12-05: 80 / 50 / 40 → 40 / 50 / 80.
  - #33 maca_fuji 2025-02-14: 175 / 180 / 140 → 140 / 180 / 180.

Anotações, sem ação:

- A interpolação depende do pregão posterior. Isso importa para o streaming, que não é foco agora.
- `preco_kg` parece ser calculado a partir de `preco_comum`: coincide em 99,69% das linhas. Se for confirmado, o teste da R6 é quase tautológico. Não investigado.

