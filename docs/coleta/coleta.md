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

# Outras CEASAs — `ingestao/scraping/`

Um coletor por sede. Cada um faz as duas etapas (coleta do bruto + extração
para CSV) e é idempotente: reexecutar só baixa o que é novo e regera o mesmo
CSV. O coletor da CEASA-GO continua em `ingestao/ceasa_scraper.py` +
`ingestao/ceasa_extrair.py`, porque é o que roda no ciclo diário do Cloud Run
(`entrypoint.sh`).

| Script | Sede | Formato na origem | Histórico no site |
|---|---|---|---|
| `ceasa_ms.py` | CEASA-MS — Campo Grande | Uma planilha `.xls` por mês, uma aba por dia | 2021 → |
| `ceasa_mg.py` | CEASA-MG — 7 mercados | Boletim HTML do sistema Scriptcase | out/2021 → (Barbacena tem também um bloco de 2006) |
| `ceasa_es.py` | CEASA-ES — 3 mercados | Boletim HTML do sistema Scriptcase | 2010 → (varia por mercado) |
| `ceasa_sc.py` | CEASA-SC — São José | Um PDF por dia | 2020 → |

Módulos de apoio, que não rodam sozinhos:

| Módulo | O que tem |
|---|---|
| `comum.py` | Cliente HTTP (retry + intervalo entre requisições), esquema do CSV, conferência da saída |
| `scriptcase.py` | Coleta e extração compartilhadas por MG e ES; cada sede só passa a própria configuração |

## Dependências

```bash
pip install requests beautifulsoup4 xlrd openpyxl
sudo apt install poppler-utils      # pdftotext, so para o SC (o mesmo do extrator do GO)
pip install msoffcrypto-tool        # opcional: 1 planilha do MS (2021/04) tem protecao contra gravacao
```

Rodam igual em Linux e Windows (no Windows, o `pdftotext` precisa estar no PATH para o SC).

## Uso

```bash
python3 ingestao/scraping/ceasa_ms.py                # -> cotacoes_ms/ e cotacoes_ms.csv
python3 ingestao/scraping/ceasa_mg.py                # -> cotacoes_mg/ e cotacoes_mg.csv
python3 ingestao/scraping/ceasa_es.py                # -> cotacoes_es/ e cotacoes_es.csv
python3 ingestao/scraping/ceasa_sc.py                # -> cotacoes_sc/ e cotacoes_sc.csv
python3 ingestao/scraping/ceasa_mg.py --mercados 214,218 --inicio 2026-01-01
python3 ingestao/scraping/<script>.py --so-extrair   # refaz o CSV sem acessar o site
```

Saídas vão para a raiz do repositório, ou para a pasta em `CEASA_DADOS` se a
variável estiver definida. Nada disso é versionado (`.gitignore`: `*.csv`,
`cotacoes_*/`).

Volume de uma carga completa, com o padrão `--delay 0.5`: MG ~4,5 mil
requisições, ES ~3 mil, SC ~1,5 mil PDFs, MS ~70. Consultas sem dado (MG, ES)
ficam em `<bruto>/vazios.txt` e
não são repetidas. Tudo dos últimos `--revisar-dias` (padrão 7) é consultado
de novo a cada execução, **inclusive o que já foi baixado**: o site publica
com atraso e completa boletins já publicados (ver "Cuidados").

## Tratamento de falhas

Mesma regra em todas as sedes. Toda falha aparece na saída, e o código de
saída diz o que aconteceu.

| Situação | O que acontece | Código de saída |
|---|---|---|
| Tudo certo | CSV regravado | 0 |
| Link publicado pelo próprio site dá 404 (ex.: MS nov/2023 e mar/2025) | Listado como `aviso: indisponivel na fonte`; não é repetido como erro | 0 |
| Erro de rede, timeout, 5xx, conteúdo que não é PDF/planilha, boletim com data errada | Item fica de fora e é tentado de novo na próxima execução; CSV regravado com o que existe | 2 |
| Site fora do ar | Coleta interrompida com mensagem; CSV regravado com o bruto já existente | 2 |
| Arquivo bruto ilegível (SC: PDF sem data/texto; MS: planilha corrompida) | Listado; CSV regravado sem ele | 1, salvo se `--falhas-esperadas N` cobrir |
| Estrutura inesperada (layout mudou), mesmo arquivo duas vezes no bruto | Aborta antes de gravar; **CSV anterior mantido** | 1 |
| Conferência final reprovada (nenhuma linha, linha sem data/produto) | **CSV anterior mantido** | 1 |
| Problema conhecido da fonte (MS: aba com data errada; SC: data repetida) | Listado; item fica de fora | 0 |

O CSV só é substituído depois de passar na conferência, e a gravação é
atômica (`.part` + renomear): nunca fica um CSV pela metade nem um CSV bom
trocado por um reprovado.

## Esquema do CSV (igual para todas as sedes)

`data, ano, mes, dia, fonte, mercado, grupo, produto, classificacao, tipo,
origem, embalagem, qtd_kg, preco_minimo, preco_comum, preco_maximo, situacao,
arquivo`

| Coluna | MS | MG / ES | SC |
|---|---|---|---|
| `mercado` | CAMPO GRANDE | nome do mercado no filtro | unidade impressa no PDF (São José) |
| `grupo` | seção da aba (FRUTAS, HORTALIÇAS…) | vazio | vazio |
| `produto` | "Produto" | "Produtos" | "Produto Variedade" |
| `classificacao` | vazio | vazio | "Classificação" |
| `tipo` | vazio | vazio | "Tipo" (Normal, Convenci, Organico) |
| `origem` | vazio | vazio | "Origem" (Nacional, Importado) |
| `embalagem` | "Embalagem" | "Embalagem" | "Embalagem" |
| `qtd_kg` | vazio | vazio | "Conv. Kg" |
| `situacao` | FRA/EST/FIR/AUS… | ME/MFR/MFI… | vazio |
| `arquivo` | `AAAA/MM.xls#aba` | boletim bruto | `AAAA/MM/<id>.pdf` |

## Cuidados — verificados na fonte

- **MG: boletim sempre sem cookie.** Com cookie de sessão, o servidor mantém
  o cabeçalho (data) do primeiro boletim da sessão, enquanto as linhas
  acompanham a data pedida, o que rotularia dados com a data errada. O
  coletor usa um cliente sem cookies e confere a data impressa contra a pedida.
- **MG/ES: a data do `nmgp_parms` é MM/DD/AAAA**, ao contrário da tela.
- **Boletim publicado em partes.** O boletim do ES de 05/10/2026 (Grande
  Vitória) tinha 144 linhas às 09h e 159 horas depois: os pescados entraram
  mais tarde. Por isso a janela de `--revisar-dias` baixa de novo o que já
  existe, e não só o que veio vazio. Fora dessa janela, o bruto não é
  reconsultado.
- **Período de cada mercado (lista de datas do próprio site, 06/10/2026):**
  ES — Grande Vitória nov/2021 → hoje; Noroeste set/2010 → dez/2024 (parou);
  Cachoeiro de Itapemirim jul/2015 → ago/2018 (parou). MG — todos desde
  out/2021; Barbacena tem ainda um bloco isolado de 2006 (245 linhas);
  Uberaba sem boletim desde 16/09/2026.
- **MS repete dias.** As 31 abas de cada mês vêm preenchidas, inclusive fim de
  semana e dias sem pregão, que repetem a aba anterior (em ago/2026, 20 das 31
  abas eram cópia da anterior). O CSV reproduz a fonte; descartar repetição é
  regra da Silver.
- **MS: abas com data errada ficam fora do CSV e são listadas.** Template do
  ano anterior não atualizado (ex.: set/2026 só tem os dias 1–2 preenchidos;
  as demais abas dizem 01/09/2025), abas "31" em mês de 30 dias e um ano
  digitado como 2219. Na última execução: 49 abas.
- **MS: 2 links quebrados no próprio site** — nov/2023 (404) e "Março" de
  2025, que aponta para `ABRIL.xls` (404). Esses meses não existem; saem como
  aviso a cada execução, sem afetar o código de saída.
- **MS: preço 0,00 com situação `AUS`** = produto ausente no dia. Também há
  linhas com mínimo > comum (erro de digitação da origem) e 23 células de
  preço ilegíveis (`'2,220,00'`), deixadas vazias.
- **MG traz itens que não são hortifruti** (`COMBUSTIVEL ALCOOL`, flores), e
  há boletins parciais (ex.: Uberlândia em 25/09/2026, 3 linhas). Filtrar é
  papel da Silver.
- **SC: extração por coordenada, não por texto.** Em registros com a
  classificação em duas linhas ("Especial" / "Escovada"), o `pdftotext
  -layout` joga o preço máximo numa linha e os demais em outra. O coletor usa
  `pdftotext -bbox`: cada palavra vai para a coluna do cabeçalho sob a qual
  está e para o registro cuja linha de preços está a até 10 pt. O cabeçalho
  é lido em cada página, restrito à faixa da palavra "Produto" (fora dela,
  "Tipo" é dado, como em "Alho nobre Tipo 4 e 5").
- **SC: a variedade faz parte do produto** ("Abobora Comum", "Uva Italia"):
  fica sob o cabeçalho "Produto Variedade", não sob "Classificação".
- **SC: slug com data errada.** O nome do arquivo no site tem erro de
  digitação (ex.: `877-03-01-2019-1` publicado em jan/2020); vale a data
  impressa no PDF, e o bruto é nomeado pelo id do site. Se dois PDFs tiverem
  a mesma data interna, fica o de maior id e os demais são listados.
- **SC: "Comum Kg" do PDF não é confiável em 2021–2022** (ex.: caixa de 12 kg
  a 120,00 impressa como 3,33/kg). A coluna não vai para o CSV (é derivada);
  o coletor só informa quantos registros divergem de comum / conv.
- **SC: `tipo` vem truncado na origem** ("Convenci" = convencional) e mudou
  de "Normal" para "Convenci" em 2022. Reproduzido como está.

## Conferência da última execução

| Sede | Recorte | Linhas | Datas | Sem data/produto | min ≤ comum ≤ max violado |
|---|---|---|---|---|---|
| MG | 24–30/09/2026 (6 mercados) | 1.821 | 5 | 0 | 0 |
| ES | 24–30/09/2026 | 765 | 5 | 0 | 0 |
| MS | histórico completo, 2021-01 → 2026-10-02 (68 planilhas) | 337.855 | 2.021 | 0 | 1.551 (amostra conferida: está assim na planilha) |
| SC | histórico completo, 2020-01 → 2026-10-06 (1.695 PDFs) | 454.197 | 1.694 | 0 | 126 (todas com comum 0,00 no PDF) |

- MG: contagem por boletim igual à de consultas isoladas (BH 25/09 = 241,
  28/09 = 223).
- SC: em 2026, as 48.039 linhas que o `pdftotext -layout` lê sem quebra saem
  idênticas no CSV (0 divergências); os outros 191 registros são os de
  classificação em duas linhas, conferidos à mão. Nas amostras de 2020–2025,
  as únicas divergências contra o modo texto são produto com variedade
  ("Abobora Comum"), em que o modo texto separa errado.
- Reexecução sobre os mesmos brutos gera CSV idêntico (`cmp`) em MG, MS e SC.
- Depois da mudança para `ingestao/scraping/`, MG, ES e MS foram rodados
  de novo, com os mesmos números.
- Bateria de testes antes do commit (06/10/2026), por sede: período recente e
  início do histórico; reexecução sem download novo e CSV idêntico;
  `--so-extrair` idêntico; boletins de MG e ES baixados de novo por
  código independente e comparados linha a linha (9 casos, 100% iguais); duas
  abas do MS lidas direto com `xlrd` (iguais); SC 2020 inteiro contra o modo
  texto (66.127 iguais; as 778 diferenças são todas produto + variedade,
  em que o modo texto separa errado).
- Falhas provocadas: PDF e planilha corrompidos, mesmo arquivo duas vezes no
  bruto, tabela com layout estranho, bruto vazio e site fora do ar; todas
  com o comportamento e o código de saída da tabela "Tratamento de falhas".
- Carga histórica completa de MG e ES (06/10/2026), validada por script
  independente do coletor:
  - MG: 470.886 linhas, 7 mercados; todas as 3.607 datas da lista do site
    coletadas (3.491 boletins + 116 vazios, 5 vazios reconsultados e
    confirmados); 27 boletins sorteados (2006–2026) idênticos ao site.
  - ES: 244.587 linhas, 3 mercados; todas as 2.261 datas coletadas
    (2.255 + 6 vazios, 5 reconsultados e confirmados); 24 boletins sorteados
    (2010–2026) idênticos ao site.
- Carga completa de MS e SC (07/10/2026): MS em 45 s, SC em 16,5 min;
  `--so-extrair` gera CSV idêntico (`cmp`) nas duas. No SC, 3 links do site
  dão 404 (mar–abr/2023). O PDF de id 1261, um "Relatório de Divulgação de
  Cotações" de 25/01/2021 com 25 produtos e só o preço comum, não é o boletim
  diário: está em `IDS_IGNORADOS` no `ceasa_sc.py`, não é baixado nem extraído
  (o dia fica sem dado).
- CEAGESP (SP) retirada em 07/10/2026: a consulta exige um POST por dia e
  por categoria (~11 mil requisições) e a página de cotações deixava de
  responder sob carga, o que impediu a carga completa.
