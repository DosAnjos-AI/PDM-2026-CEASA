# Coleta — do site da CEASA-GO ao CSV histórico

Etapa anterior à Bronze: os dois scripts de `ingestao/` produzem o CSV que
`ingestao/upload_historico.sh` envia para `gs://pdm-ceasa-dados/raw/`.

| Script | O que faz |
|---|---|
| `ingestao/ceasa_scraper.py` | Baixa os PDFs de cotação diária de <https://goias.gov.br/ceasa/cotacoes-diarias/> |
| `ingestao/ceasa_extrair.py` | Converte os PDFs numa tabela única (`cotacoes.csv`) |

Estado da última execução completa: **1.509 PDFs** (2019-01-03 a 2026-09-04)
→ **349.827 linhas**. O CSV histórico carregado na Bronze cobre 2010-01-04 a
2026-08-28; o trecho anterior a 2019 vem de outra origem, não coberta por
estes scripts.

## Dependências

```bash
pip install requests beautifulsoup4
sudo apt install poppler-utils                      # pdftotext, pdftoppm
sudo apt install tesseract-ocr tesseract-ocr-por    # so para os PDFs de imagem
```

O scraper não depende de binário externo. O extrator chama `pdftotext`,
`pdftoppm` e `tesseract` pelo nome: desenvolvido e testado em Linux, roda em
Windows se esses binários estiverem no PATH.

## Uso

```bash
python3 ingestao/ceasa_scraper.py --start-year 2019     # baixa tudo -> ./cotacoes
python3 ingestao/ceasa_extrair.py --ocr --resumo        # extrai tudo -> ./cotacoes.csv
```

Os dois são idempotentes: reexecutar só processa o que é novo, o que permite
usá-los como atualização diária em cron.

Opções do scraper: `--start-year`, `--end-year`, `-o/--out`, `--delay`,
`--workers`, `--dry-run`.
Opções do extrator: `-e/--entrada`, `-s/--saida`, `--ocr`, `--dpi`,
`--workers`, `--resumo`, `--falhas`.

## Saída

```
cotacoes/2024/01/2024-01-02.pdf      PDFs, por ano/mes
cotacoes/manifesto.csv               o que foi baixado
cotacoes.csv                         a tabela
cotacoes_falhas.csv                  PDFs que nao viraram dados
```

Nenhum desses arquivos é versionado: `.gitignore` ignora `*.csv` e a pasta
`cotacoes/`.

Colunas de `cotacoes.csv`, na ordem em que entram na Bronze: `data, ano, mes,
dia, grupo, categoria, codigo, produto, embalagem, qtd_kg, classe,
preco_comum, preco_maximo, preco_minimo, preco_kg, layout, arquivo`.

## Cuidados ao analisar

- **Usar `grupo`, não `categoria`.** O número do grupo mudou entre os layouts
  (raízes é `03-` no antigo e `01-` no novo), então `categoria` não é
  comparável ao longo do tempo. `grupo` (sigla: HFFH, HF, RTB, FN, FI, AO,
  PD, CE) é estável. A Silver descarta `categoria` pela regra R3.
- **`codigo` é vazio até meados de 2022** — não existia coluna de código no
  PDF. Para série histórica longa, a junção é por `produto`.
- **`embalagem`, `qtd_kg` e `preco_kg` são vazios nas 1.690 linhas de
  `layout=cupom-ocr`**: esse layout não traz essas colunas.
- `classe` é o "Class"/"Tipo" do PDF (1 = padrão, 2 = inferior). O CEASA
  publica esporadicamente valores fora disso (`3`, `10`, `20`, `80`), que são
  reproduzidos como estão; a regra R9 da Silver mantém só 1 e 2.
- `preco_comum` é a moda do dia ("+Comum"), não a média.

## Os cinco layouts de PDF

| # | Layout | Período | Arqs | Particularidade |
|---|---|---|---|---|
| 1 | antigo sem código | 2019-01 → 2022 (meados) | 634 | a linha começa no nome do produto |
| 2 | antigo com código | 2022 (meados) → 2026-08-06 | 847 | `10 ACELGA  CX  15  1 ...`; classes extras herdam o produto anterior, inclusive atravessando quebra de página |
| 3 | antigo, código em coluna própria | 3 dias avulsos | 3 | 9 campos; um usa "COTAÇÃO DO DIA" no lugar de `Periodo` |
| 4 | novo ("Grupo BIOS") | 2026-08-07 → | 18 | nome quebra em várias linhas, `EMBALAGEM` pode vir vazia |
| 5 | cupom (só imagem, via OCR) | 2026-07-23 → 2026-08-04 | 8 | 3 colunas na ordem MÍNIMO COMUM MÁXIMO, invertida em relação aos demais; classe no nome como "(TIPO 1)" |

Nos layouts 1–4 as colunas são separadas por runs de 2+ espaços no texto com
layout preservado (`pdftotext -layout`), o que dá uma divisão exata. **Não** se
usa vocabulário de embalagem para dividir, porque há produtos cujo nome contém
"CX" e "KG" (ex.: `CAQUI CX C/9 KG`).

## OCR

9 PDFs (23/07 a 06/08/2026) não têm camada de texto — são desenho vetorial
puro (`pdffonts` não lista fonte alguma, não há operadores `Tj/TJ`), então
`--ocr` rasteriza a 300 DPI e passa no tesseract.

Oito deles são o layout cupom, que o OCR lê bem. O nono (`2026-08-06`) é o
layout novo rasterizado: como o OCR não preserva as colunas, os campos são
recuperados da direita para a esquerda (4 preços, classe, quantidade) e a
fronteira nome/embalagem é resolvida com o dicionário de produtos montado a
partir dos PDFs com texto.

O OCR erra códigos com frequência (`11` → `1`, `77` → `7`) e nomes raramente,
então **o nome tem prioridade**: quando o nome é conhecido, o código é derivado
dele. Na última execução: 135 nomes corrigidos, 11 códigos recuperados, 4
linhas sinalizadas e deixadas como o OCR leu.

## Conferência da última execução

- **Completude**: nos 1.498 PDFs com texto, o número de linhas de preço no
  texto bruto é igual ao número de linhas no CSV. Divergência: 0.
- **Alinhamento de colunas**: `preco_kg == preco_comum / qtd_kg` em 99,995%
  das linhas; as 16 exceções são inconsistências do próprio PDF.
- **Qualidade do OCR**: 0 de 1.915 linhas violam `mínimo <= comum <= máximo`
  (nos PDFs com texto, 0,07% violam, por erro de digitação da fonte). O dia
  lido por OCR (06/08) tem 149 de 176 produtos com preço idêntico ao dia
  seguinte, e as 27 diferenças são variações plausíveis.
- Nenhuma linha sem data, grupo ou produto.

## Limitações — da fonte, não dos scripts

- **2 PDFs não são cotação diária** (`2022-04-08`, `2023-12-05`): são um
  boletim semanal comparativo, com uma coluna por data e coluna "SITUAÇÃO".
  Schema incompatível; ficam listados em `cotacoes_falhas.csv`.
- **22 PDFs têm data interna diferente do nome do arquivo**: o site publicou o
  documento sob o link do dia errado. O CSV usa a data interna do documento,
  que é a correta. O extrator lista todos ao rodar.
- **5 datas aparecem em dois PDFs** (consequência do item acima), e os dias
  correspondentes ficam sem cotação. Ex.: o PDF de 03/06/2024 foi publicado
  também sob o link de 31/05/2024, então 31/05 não existe.
- **20/02/2024 está truncado** na origem (2 páginas em vez de 6): 94 linhas.
- **23/07/2026 é um relatório reduzido**: só 3 dos 8 grupos (99 linhas).
- 252 linhas (0,07%) têm `minimo > comum` ou `comum > maximo`, e há linhas com
  preço `0,00`. Conferido contra o PDF: está assim no original. Um exemplo
  visível é ALCACHOFRA em 06/08/2026, com máximo `353,00` entre comum `35,00`
  e mínimo `30,00`.

---

# Outras CEASAs — SP, MS, MG e ES

Fontes que não publicam PDF e, por isso, não passam pelo extrator do GO. Cada
coletor faz as duas etapas (coleta do bruto + extração para CSV) e é
idempotente: reexecutar só baixa o que é novo e regera o mesmo CSV.

| Script | Fonte | Formato na origem | Histórico no site |
|---|---|---|---|
| `ingestao/ceagesp_sp.py` | CEAGESP — Entreposto da Capital | Tabela HTML devolvida por POST (categoria + data) | meados de 2022 → |
| `ingestao/ceasa_ms.py` | CEASA-MS — Campo Grande | Uma planilha `.xls` por mês, uma aba por dia | 2021 → |
| `ingestao/ceasa_mg_es.py` | CEASA-MG (7 mercados) e CEASA-ES (3 mercados) | Boletim HTML do sistema Scriptcase | MG out/2021 →, ES nov/2021 → |
| `ingestao/coleta_comum.py` | — | Cliente HTTP, esquema do CSV e conferência, compartilhados | — |

## Dependências

```bash
pip install requests beautifulsoup4 xlrd openpyxl
pip install msoffcrypto-tool    # opcional: 1 planilha do MS (2021/04) tem protecao contra gravacao
```

Nenhum binário externo: rodam igual em Linux e Windows.

## Uso

```bash
python3 ingestao/ceagesp_sp.py                  # -> cotacoes_sp/ e cotacoes_sp.csv
python3 ingestao/ceasa_ms.py                    # -> cotacoes_ms/ e cotacoes_ms.csv
python3 ingestao/ceasa_mg_es.py                 # -> cotacoes_mg/, cotacoes_es/ e os dois CSVs
python3 ingestao/ceasa_mg_es.py --estado mg --mercados 214,218 --inicio 2026-01-01
python3 ingestao/<script>.py --so-extrair       # refaz o CSV sem acessar o site
```

Saídas vão para a raiz do repositório, ou para a pasta em `CEASA_DADOS` se a
variável estiver definida. Nada disso é versionado (`.gitignore`: `*.csv`,
`cotacoes_*/`).

Volume de uma carga completa, com o padrão `--delay 0.5`: SP ~9 mil
requisições (calendário × 7 categorias), MG ~4,5 mil, ES ~3 mil, MS ~70.
Consultas sem dado ficam em `<bruto>/vazios.txt` e não são repetidas, exceto
as dos últimos `--revisar-dias` (padrão 7), porque o site pode publicar com
atraso.

## Esquema do CSV (igual para as quatro fontes)

`data, ano, mes, dia, fonte, mercado, grupo, produto, classificacao,
embalagem, qtd_kg, preco_minimo, preco_comum, preco_maximo, situacao, arquivo`

| Coluna | SP | MS | MG / ES |
|---|---|---|---|
| `grupo` | categoria do formulário (FRUTAS, LEGUMES…) | seção da aba (FRUTAS, HORTALIÇAS…) | vazio — a fonte não agrupa |
| `classificacao` | "Classificação" (A, TIPO 6, BOCA 08 A 11…) | vazio | vazio |
| `embalagem` | "Uni/Peso" (KG, CX, ENG…) | "Embalagem" (cx 23 kg…) | "Embalagem" |
| `qtd_kg` | "Quilo" — peso da embalagem | vazio | vazio |
| `preco_comum` | "Comum" | "P. M. Comum" | "Preço Mais Comum" |
| `situacao` | vazio | FRA/EST/FIR/AUS… | ME/MFR/MFI… |
| `arquivo` | tabela bruta de origem | `AAAA/MM.xls#aba` | boletim bruto de origem |

## Cuidados — verificados na fonte

- **MG: boletim sempre sem cookie.** Com cookie de sessão, o servidor mantém
  o cabeçalho (data) do primeiro boletim da sessão, enquanto as linhas
  acompanham a data pedida, o que rotularia dados com a data errada. O
  coletor usa um cliente sem cookies e confere a data impressa contra a pedida.
- **MG/ES: a data do `nmgp_parms` é MM/DD/AAAA**, ao contrário da tela.
- **MS repete dias.** As 31 abas de cada mês vêm preenchidas, inclusive fim de
  semana e dias sem pregão, que repetem a aba anterior (em ago/2026, 20 das 31
  abas eram cópia da anterior). O CSV reproduz a fonte; descartar repetição é
  regra da Silver.
- **MS: abas com data errada ficam fora do CSV e são listadas.** Template do
  ano anterior não atualizado (ex.: set/2026 só tem os dias 1–2 preenchidos;
  as demais abas dizem 01/09/2025), abas "31" em mês de 30 dias e um ano
  digitado como 2219. Na última execução: 48 abas.
- **MS: 2 links quebrados no próprio site** — nov/2023 (404) e "Março" de
  2025, que aponta para `ABRIL.xls` (404). Esses meses não existem.
- **MS: preço 0,00 com situação `AUS`** = produto ausente no dia. Também há
  linhas com mínimo > comum (erro de digitação da origem) e 23 células de
  preço ilegíveis (`'2,220,00'`), deixadas vazias.
- **MG traz itens que não são hortifruti** (`COMBUSTIVEL ALCOOL`, flores), e
  há boletins parciais (ex.: Uberlândia em 25/09/2026, 3 linhas). Filtrar é
  papel da Silver.
- **SP**: o formulário só lista as ~2 semanas mais recentes; o histórico é
  obtido consultando dia a dia, o que explica o volume de requisições.

## Conferência da última execução

| Fonte | Recorte testado | Linhas | Datas | Sem data/produto | min ≤ comum ≤ max violado |
|---|---|---|---|---|---|
| SP | 21–30/09/2026 | 2.778 | 5 | 0 | 0 |
| MG | 24–30/09/2026 (6 mercados) | 1.821 | 5 | 0 | 0 |
| ES | 24–30/09/2026 | 765 | 5 | 0 | 0 |
| MS | histórico completo, 2021-01 → 2026-09 | 332.844 | 1.991 | 0 | 1.551 (amostra conferida: está assim na planilha) |

- SP: as 5 datas coincidem com a lista que o próprio site publica; ABACATE
  AVOCADO em 30/09/2026 = 9,76 / 11,07 / 12,4, igual ao site.
- MG: contagem por boletim igual à de consultas isoladas (BH 25/09 = 241,
  28/09 = 223).
- Reexecução sobre os mesmos brutos gera CSV idêntico (`cmp`) em SP, MG e MS.
- A carga histórica completa de SP, MG e ES ainda não foi executada.
