# CLAUDE.md — PDM-2026-CEASA

Orientações de comportamento e padrão de código para trabalhar neste repositório.
Não descreve tarefas, cronograma ou estado — isso vive nos documentos de plano e inventário, fora do repositório.

## Contexto

Pipeline de dados de cotações de CEASA (bronze/silver/gold no BigQuery).

| Item | Valor |
|---|---|
| Repositório local | `/home/dos-anjos/Dropbox/PDM/PDM-2026-CEASA` |
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

## Git

- Trabalho na branch `dosAnjos`.
- CSVs não são versionados.
- Mensagem de commit em português, descrevendo o que mudou.
