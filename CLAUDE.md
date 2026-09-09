# CLAUDE.md — PDM-2026-CEASA

Orientações de comportamento e padrão de código para trabalhar neste repositório.
Não descreve tarefas, cronograma ou estado — isso vive nos documentos de plano e inventário, fora do repositório.

## Contexto

Pipeline de dados de cotações de CEASA (bronze/silver/gold no BigQuery).

| Item | Valor |
|---|---|
| Branch de trabalho | `dosAnjos` |
| Projeto GCP | `pdm-ceasa` |
| Bucket | `gs://pdm-ceasa-dados` |
| Datasets | `bronze`, `silver`, `gold` — região US |

## Portabilidade

- Nunca gravar caminho absoluto de máquina em arquivo versionado. Caminho vem de variável de ambiente com default relativo à raiz do repositório.
- Em Python, caminho sempre com `pathlib`, nunca concatenação de string nem separador literal.
- O repositório precisa rodar em Linux e em Windows. Código que só funciona em um dos dois é declarado como tal.

## Padrão de código

- Comentários em português.
- Sem emojis em código; emojis apenas em documentação.
- Variáveis de configuração no topo do arquivo, nunca espalhadas pelo corpo.
- Scripts idempotentes: reexecutar produz o mesmo resultado, não duplica.
- Falha ruidosa: abortar com mensagem clara em vez de seguir em estado inválido.

## SQL

- Todo `.sql` é a fonte da verdade e roda por CLI a partir do repositório, nunca colado no console.
- Transformação acontece dentro do BigQuery. Nada de tratamento em Python ou pandas.
- Cada script vem acompanhado da consulta de conferência que prova o resultado.

## Comportamento esperado

- Prova executada, nunca deduzida. Nenhuma afirmação de resultado sem a saída do comando.
- Execução sem erro não é validação: conferir contagem, nulos e faixa de valores.
- Escopo do bloco é o escopo do bloco. Achado fora dele vira uma linha, sem investigar.
- Nada é criado, commitado ou enviado sem autorização explícita.
- Lacuna declarada é resposta válida; inferência apresentada como verificação, não.
- Todo relatório de entrega começa com um marcador explícito de início, separado do log de operações, para não se confundir com a saída dos comandos.

## Estrutura de `sql/`

Organização por função e camada, definida no Bloco 13:

```
sql/
  construir_tabelas/     cria e substitui tabelas no BigQuery
    bronze/
    silver/
    gold/
  modelo/                treino e avaliação de modelos
    bronze/
    silver/
    gold/
  consultas/              conferência e exploração
    bronze/
    silver/
    gold/
ingestao/
  upload_historico.sh    permanece na raiz do repositório (upload para o GCS, não BigQuery)
```

Dentro de cada pasta, arquivos numerados a partir de `01_` na ordem de
execução, com nome descritivo depois do número.

- **Não criar pasta nem arquivo fora dessa estrutura.** Arquivo novo vai na
  pasta correspondente à sua função (`construir_tabelas`, `modelo` ou
  `consultas`) e camada (`bronze`, `silver` ou `gold`).
- Verificar a estrutura existente antes de criar qualquer coisa. Se nenhuma
  pasta servir, **parar e perguntar** em vez de inventar caminho novo.
- Um `.txt` vazio marca pasta ainda sem conteúdo (só para o Git versionar a
  pasta) e deve ser removido assim que a pasta receber um arquivo real.

## Git

- Trabalho na branch `dosAnjos`.
- CSVs não são versionados.
- Mensagem de commit em português, descrevendo o que mudou.
