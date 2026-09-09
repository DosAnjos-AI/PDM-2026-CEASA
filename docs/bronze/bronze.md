# Bronze — `pdm-ceasa.bronze.cotacoes`

Camada Bronze do pipeline de cotações CEASA: dado carregado como veio, sem
tratamento. Este documento descreve origem, schema, o recorte separado antes
da ingestão e o que foi deliberadamente deixado de fora.

## Origem

- Arquivo local: `historico/cotacoes_historico.csv` (fora do repositório e do
  versionamento; caminho resolvido por `ingestao/upload_historico.sh` a partir
  da variável de ambiente `ARQUIVO_ORIGEM`, com default relativo à raiz do
  repositório).
- Sobe para `gs://pdm-ceasa-dados/raw/cotacoes_historico.csv` via
  `gcloud storage cp`, upload idempotente (mesmo objeto, sobrescreve).
- `sql/construir_tabelas/bronze/01_bronze.sql` lê o bucket inteiro por wildcard:
  `uris = ['gs://pdm-ceasa-dados/raw/*.csv']` — qualquer arquivo novo colocado
  nesse prefixo entra na próxima carga sem editar o script.
- Carga: `LOAD DATA OVERWRITE` — reconstrói a tabela inteira a cada execução
  (idempotente), `skip_leading_rows = 1` (ignora cabeçalho), sem tolerância a
  linha inválida (`max_bad_records` no default, 0 — a carga falha em vez de
  descartar linha em silêncio).

## Schema

17 colunas, todas nullable (nenhuma `NOT NULL` — nulo é defeito a resolver na
Silver, não motivo para rejeitar linha na Bronze):

| Coluna | Tipo | Observação |
|---|---|---|
| `data` | DATE | Data do pregão |
| `ano` | INT64 | Ano, redundante com `data` (vem assim da fonte) |
| `mes` | INT64 | Mês, redundante com `data` |
| `dia` | INT64 | Dia, redundante com `data` |
| `grupo` | STRING | Sigla do grupo do produto |
| `categoria` | STRING | Categoria com prefixo numérico (ver seção abaixo) |
| `codigo` | STRING | **STRING, não INT64** — preserva zero à esquerda do código do produto |
| `produto` | STRING | Nome do produto |
| `embalagem` | STRING | Tipo de embalagem |
| `qtd_kg` | NUMERIC | Peso da embalagem em kg |
| `classe` | INT64 | Classe do produto dentro do código |
| `preco_comum` | NUMERIC | Preço mais frequente do pregão |
| `preco_maximo` | NUMERIC | Preço máximo do pregão |
| `preco_minimo` | NUMERIC | Preço mínimo do pregão |
| `preco_kg` | NUMERIC | Preço por kg (ver ressalva de confiabilidade abaixo) |
| `layout` | STRING | Layout de origem do PDF processado |
| `arquivo` | STRING | Caminho do PDF de origem do pregão |

**Justificativas de tipo menos óbvias:**
- `codigo` é STRING, não INT64: um código como `"0294"` viraria `294` como
  inteiro, perdendo o zero à esquerda. Preservar a string original evita esse
  tipo de corrupção silenciosa.
- Os quatro campos de preço (`qtd_kg`, `preco_comum`, `preco_maximo`,
  `preco_minimo`, `preco_kg`) são NUMERIC, não FLOAT64: NUMERIC é decimal
  exato (sem erro de arredondamento de ponto flutuante), apropriado para
  valor monetário/peso.
- Nenhuma coluna é `NOT NULL`: a Bronze aceita o dado como veio; qualquer
  nulo é assunto da Silver, não motivo para a carga rejeitar a linha aqui.

## O recorte, com o motivo

O CSV histórico completo (`cotacoes_2010-2026.csv`, 413.562 linhas de dado)
vai até `2026-09-04`. A Bronze, porém, termina em `2026-08-28`.

As 4 datas mais recentes do arquivo completo — `2026-08-31`, `2026-09-01`,
`2026-09-03`, `2026-09-04` — foram separadas **antes da ingestão** para um
arquivo à parte (`recorte/cotacoes_recorte_demo.csv`, 901 linhas de dado) e
não fazem parte do que subiu para `gs://pdm-ceasa-dados/raw/`. O arquivo que
efetivamente sobe é `historico/cotacoes_historico.csv`, que já vai só até
`2026-08-28`.

Motivo: esse recorte serve de conjunto fora da amostra para demonstração de
reprocessamento ao vivo — dado que a Bronze nunca viu, usado para mostrar a
carga (`LOAD DATA OVERWRITE` por wildcard) e as previsões dos modelos
reagindo a pregões novos. Se o arquivo completo (com as 4 datas) tivesse sido
enviado ao bucket, o wildcard `raw/*.csv` as traria de volta na carga e o
efeito de "dado nunca visto" desapareceria.

## Contagens

| Conjunto | Linhas |
|---|---|
| Bronze (`pdm-ceasa.bronze.cotacoes`) | 412.661 |
| Recorte de demo (fora da Bronze) | 901 |
| Original (`cotacoes_2010-2026.csv`, histórico + recorte) | 413.562 |

Verificação: `412.661 + 901 = 413.562`.

Faixa de datas da Bronze: `2010-01-04` a `2026-08-28`.
Cardinalidade: 372 produtos distintos, 9 classes distintas, 508 pares
(produto, classe) distintos.

## O que NÃO foi tratado (deliberado)

A Bronze é o dado como veio. Nada abaixo foi corrigido, filtrado ou
normalizado nesta camada — fica registrado como característica conhecida do
dado, a ser endereçada (ou não) na Silver:

- **Duplicatas**: 1.234 combinações de (`produto`, `classe`, `data`) têm mais
  de uma linha na Bronze. Nenhuma deduplicação foi aplicada.
- **Preços fora do intervalo esperado**: 12.082 linhas em que `preco_comum`
  fica fora do intervalo [`preco_minimo`, `preco_maximo`] da própria linha.
- **Preços zerados**: 61 linhas com `preco_comum = 0`; 113 com
  `preco_minimo = 0`; 114 com `preco_maximo = 0`.
- **Capitalização de `embalagem`**: 20 valores distintos de `embalagem`, mas
  só 19 depois de normalizar para maiúsculas — pelo menos um par de valores
  difere apenas em capitalização.
- **Categoria com prefixo ambíguo**: `categoria` traz um prefixo numérico que
  não identifica a categoria de forma única — por exemplo, `"01-"` aparece
  tanto em `"01-HORTALICAS, FOLHAS, FLOR, HASTES-HFFH"` quanto em
  `"01-RAIZES-TUBERCULOS-BULBO-RTB"`, e `"03-"` aparece tanto em
  `"03-AVES E OVOS-AO"` quanto em `"03-RAIZES-TUBERCULOS-BULBO-RTB"`.
- **`preco_kg` não confiável**: em 16 linhas (com `qtd_kg > 0`), `preco_kg`
  diverge em mais de 0,01 do valor calculado como `preco_comum / qtd_kg` —
  indício de que a coluna não é consistentemente derivada dos outros preços
  e não deve ser tratada como fonte confiável sem checagem adicional.

Nenhum desses pontos foi corrigido nesta camada; documentar aqui é o
contrato de que a Bronze não escondeu o problema, só não resolveu.
