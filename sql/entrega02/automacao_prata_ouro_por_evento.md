# Automação por evento da camada prata e ouro — material de estudo e réplica

Documento escrito em 2026-11-04, ao fim da implantação. Tudo o que está aqui
foi conferido por leitura na nuvem (projeto `pdm-ceasa`) ou no repositório no
momento da escrita. Rótulos:

- **[FATO]** — visto em saída de comando, log, métrica ou consulta nesta sessão;
- **[HIPÓTESE]** — leitura de documentação ou inferência, **não** provada.

Horários em BRT (UTC−3) salvo quando marcados com `Z` (UTC).

---

## Sumário

1. [O problema](#1-o-problema)
2. [Arquitetura medalhão no projeto](#2-arquitetura-medalhão-no-projeto)
3. [Conceitos usados no desenho](#3-conceitos-usados-no-desenho)
4. [O fluxo, do início ao fim](#4-o-fluxo-do-início-ao-fim)
5. [Serviços ativos](#5-serviços-ativos)
6. [Papéis IAM](#6-papéis-iam)
7. [O plano B](#7-o-plano-b)
8. [Os 9 SQLs de tratamento](#8-os-9-sqls-de-tratamento)
9. [Decisões importantes e o motivo](#9-decisões-importantes-e-o-motivo)
10. [Armadilhas encontradas e a lição de cada uma](#10-armadilhas-encontradas-e-a-lição-de-cada-uma)
11. [Limitações conhecidas](#11-limitações-conhecidas)
12. [Como replicar](#12-como-replicar)
13. [Como testar](#13-como-testar)
14. [Como desmontar](#14-como-desmontar)
15. [Arquivos desta pasta e duplicação](#15-arquivos-desta-pasta-e-duplicação)

---

## 1. O problema

A camada bronze recebe cotações das 5 CEASAs (GO, SC, MS, MG, ES) pelo job
`ciclo-ceasa` (de outro integrante), em dias úteis, por volta das 14:10.
**[FATO]** Nos registros de outubro e novembro, ele escreve de 1 a 4 estados
por dia, numa rajada de até ~45 s (ex.: 03/11, GO 14:13:54 → ES 14:14:37).

Antes desta frente, a prata e o ouro só eram reconstruídos **uma vez por
dia, às 16:30**, pelo job `atualizar-prata-ouro-diario` (o "plano B", seção 7).
Consequências:

- entre ~14:15 e 16:30 a prata e o ouro ficavam **atrás** da bronze;
- um dado escrito na bronze fora do horário (correção, carga manual) só
  aparecia no dia seguinte às 16:30;
- `silver.ceasa_unificado`, que os modelos leem, ficava atrasado do mesmo modo.

**Objetivo:** quando a bronze de um estado for atualizada, reconstruir
automaticamente a prata **daquele** estado, em seguida **sempre**
`silver.ceasa_unificado`, e em seguida **sempre** as 2 tabelas gold. O plano B
continua como rede de segurança.

---

## 2. Arquitetura medalhão no projeto

**Arquitetura medalhão** é uma forma de organizar dados em camadas de
qualidade crescente, cada uma alimentada só pela anterior:

| Camada | Dataset | O que é | Quem escreve |
|---|---|---|---|
| Bronze | `bronze` | Dado bruto, como veio da fonte (planilhas/boletins das CEASAs, clima) | `ciclo-ceasa` (cotações, via `MERGE`); `clima-diario` (`bronze.clima_historico`) |
| Prata | `silver` | Dado limpo e padronizado: de-para de produtos, preço por kg, remoção de outliers, interpolação de dias sem cotação, junção com clima | plano B (16:30) e o job novo `atualizar-prata-ouro-evento` |
| Ouro | `gold` | Agregações prontas para análise/modelo (semanal ISO e quinzenal) | idem |

Tabelas desta frente, todas reconstruídas por `CREATE OR REPLACE TABLE`:

- prata por estado: `silver.ceasa_go`, `silver.ceasa_sc`, `silver.ceasa_ms`,
  `silver.ceasa_mg`, `silver.ceasa_es`;
- prata consolidada: `silver.ceasa_unificado` (união das 5);
- ouro: `gold.ceasa_unificado_semanal`, `gold.ceasa_unificado_quinzenal`.

**Por que a bronze é somente leitura para esta frente:** ela é o **insumo**
que dispara a cadeia, nunca o alvo. Quem a mantém é o `ciclo-ceasa`; qualquer
coluna de controle, tabela de marcação ou escrita nossa ali quebraria a
frente de outro integrante. A única exceção, nomeada e temporária, é o ensaio
sintético (seção 13), que insere e remove linhas marcadas.

---

## 3. Conceitos usados no desenho

**Reescrita total em vez de `append`.** Cada SQL faz `CREATE OR REPLACE TABLE`
— recria a tabela inteira a partir da camada anterior. Acrescentar só o novo
(`append`) seria mais barato, mas a prata depende de estatísticas sobre o
histórico todo (média e desvio para outliers, interpolação entre dias); um dia
novo muda linhas antigas. Reescrever tudo garante que o resultado é sempre o
mesmo que se teria rodando do zero.

**Idempotência.** Uma operação é idempotente quando rodá-la uma ou várias
vezes deixa o mesmo resultado. É o que sustenta todo o desenho: como cada SQL
é `CREATE OR REPLACE`, disparar a cadeia duas vezes (evento duplicado, corrida,
plano B logo depois) não corrompe nada — só gasta mais. O ensaio sintético
também é idempotente: o `INSERT` não reinsere se a marca já existe.

**Log de auditoria (Cloud Audit Logs).** Registro que o Google Cloud grava
para cada operação. No BigQuery, toda escrita que muda dados de uma tabela
gera uma entrada no log `data_access` com o campo
`protoPayload.metadata.tableDataChange` (quantas linhas entraram/saíram e em
qual tabela). É o "sensor" desta automação: ninguém precisa avisar que a
bronze mudou, o próprio BigQuery registra.

**Sink de log (log sink).** Regra que copia as entradas de log que casam com
um filtro para outro destino. Aqui, o destino é um tópico Pub/Sub. O sink tem
uma identidade própria (`writerIdentity`) que precisa de permissão para
publicar no tópico.

**Tópico Pub/Sub.** Canal de mensagens: quem publica não sabe quem recebe.
Uma **assinatura** é a fila de um consumidor sobre o tópico; mensagem
publicada num tópico **sem assinatura é descartada**. Uma **DLQ** (*dead
letter queue*, fila de mensagens mortas) recebe o que não pôde ser entregue
depois de N tentativas, para não se perder em silêncio.

**Eventarc.** Serviço que liga eventos a destinos. Por cima do Pub/Sub, ele
cria a assinatura e entrega cada mensagem a um destino (aqui, um Workflow),
autenticando com uma conta de serviço.

**Workflow (Cloud Workflows).** Orquestração declarativa em YAML: uma
sequência de passos que chama APIs do Google Cloud (BigQuery, Cloud Run) e
toma decisões. Aqui ele não transforma dado; só **decide** se a cadeia precisa
rodar e para quais estados.

**Cloud Run job.** Container que roda até terminar (não é servidor). Aqui ele
executa o script bash que roda os SQLs com a CLI `bq`.

**Conta de serviço.** Identidade de uma máquina, não de uma pessoa. Recebe
papéis IAM (permissões) como qualquer usuário.

---

## 4. O fluxo, do início ao fim

```
ciclo-ceasa (ou ensaio)  --MERGE/INSERT/DELETE-->  bronze.ceasa_<uf>
                                                        |
                         Cloud Audit Logs (data_access, tableDataChange)
                                                        |
                         sink  bronze-ceasa-alterada  (filtro: só bronze.ceasa_*)
                                                        |
                         tópico  bronze-ceasa-alterada  --(5 falhas)-->  DLQ bronze-ceasa-alterada-dlq
                                                        |
                         assinatura do Eventarc  (push autenticado, SA prata-ouro-evento@)
                                                        |
                         gatilho  verificar-e-atualizar-prata-ouro-trigger
                                                        |
                         Workflow  verificar-e-atualizar-prata-ouro
                           1. roda a consulta de defasagem (25_) e lê o resumo
                           2. sem resumo                      -> FALHA (ERROR)
                           3. job novo ou plano B em execução -> sai ("em curso")
                           4. zero atrasos                    -> sai ("nada a fazer")
                           5. estados atrasados               -> chama o job com esses estados
                                                        |
                         Cloud Run job  atualizar-prata-ouro-evento  <estados>
                           para cada estado: 1x_ (prata) + conferência
                           sempre: 15_ (unificado) + 06_ (2 gold) + conferências
                           consulta de defasagem de novo:
                             - unificado/gold atrás           -> FALHA (ERROR)
                             - estado ainda atrasado          -> repete só esses (até 3 vezes)
                             - limite atingido com sobra      -> FALHA (ERROR)
                             - zero                           -> fim: ok
                                                        |
                         silver.ceasa_<uf>  ->  silver.ceasa_unificado  ->  gold.ceasa_unificado_{semanal,quinzenal}
                                                        |
                         (efeito colateral, frente MLOps) regravação do unificado
                         dispara o Workflow inferencia-diaria
```

**O evento só acorda; quem decide é o estado da cadeia.** O Workflow não lê
o conteúdo da mensagem: ele consulta a defasagem (seção 9.3). Por isso
qualquer disparo — evento real, mensagem manual, repetição — chega à mesma
decisão.

Falhas em qualquer ponto geram log `ERROR`, que as duas políticas de alerta
transformam em e-mail (seção 5).

---

## 5. Serviços ativos

Nomes copiados da nuvem em 2026-11-04 ~18:45. Região `us-central1`;
datasets em `US`.

| Recurso | Nome canônico | O que faz | Depende de |
|---|---|---|---|
| Log sink | `bronze-ceasa-alterada` → `pubsub.googleapis.com/projects/pdm-ceasa/topics/bronze-ceasa-alterada` | Exporta `tableDataChange` de `bronze.ceasa_(go\|sc\|ms\|mg\|es)` | identidade `service-502988692211@gcp-sa-logging.iam.gserviceaccount.com` com `pubsub.publisher` no tópico |
| Tópico | `projects/pdm-ceasa/topics/bronze-ceasa-alterada` | Recebe uma mensagem por escrita na bronze | — |
| DLQ | `projects/pdm-ceasa/topics/bronze-ceasa-alterada-dlq` | Guarda o que falhar 5 vezes | agente `service-502988692211@gcp-sa-pubsub.iam.gserviceaccount.com` com `pubsub.publisher` |
| Assinatura da DLQ | `projects/pdm-ceasa/subscriptions/bronze-ceasa-alterada-dlq-sub` | Retém as mensagens mortas para inspeção | DLQ |
| Assinatura do gatilho | `projects/pdm-ceasa/subscriptions/eventarc-us-central1-verificar-e-atualizar-prata-ouro-trigger-sub-743` | Entrega push ao Workflow; DLQ = `bronze-ceasa-alterada-dlq`, 5 tentativas | gatilho (criada por ele); agente Pub/Sub com `pubsub.subscriber` |
| Gatilho Eventarc | `verificar-e-atualizar-prata-ouro-trigger` | Liga o tópico ao Workflow, com a SA `prata-ouro-evento@` | SA com `eventarc.eventReceiver` e `workflows.invoker` |
| Workflow | `projects/pdm-ceasa/locations/us-central1/workflows/verificar-e-atualizar-prata-ouro` (revisão `000004-ccb`) | Lê a defasagem e decide | SA com `bigquery.jobUser`, leitura em bronze/silver/gold, `run.viewer`, `run.developer` no job, `logging.logWriter` |
| Cloud Run job | `atualizar-prata-ouro-evento` (timeout 1800 s, 1 tentativa extra, sem argumento padrão) | Reconstrói os estados pedidos + unificado + gold | imagem abaixo; SA `prata-ouro-evento@` |
| Imagem | `us-central1-docker.pkg.dev/pdm-ceasa/cloud-run-source-deploy/atualizar-prata-ouro-evento@sha256:e88cb0ac24674ec6a55c0e53a8976619ebaac64a42ada1fea753b44fa06d8cf1` (tag `latest`, 2026-11-04 17:52Z). Versão anterior, sem uso: `sha256:ea6d4f5a9139590e35e793861674bd4f69fab69885445f2a956a435ab12bb4d7` | Contém `sql/` e `pipelines/atualizar_prata_ouro_estados.sh` | `pipelines/Dockerfile.evento`, `pipelines/cloudbuild.evento.yaml` |
| Conta de serviço | `prata-ouro-evento@pdm-ceasa.iam.gserviceaccount.com` | Identidade única de gatilho, Workflow e job | papéis da seção 6 |
| Política de alerta (jobs) | `projects/pdm-ceasa/alertPolicies/4226080771277096396` — "Cadeia prata/ouro: job terminou com falha" | Log `ERROR` em `atualizar-prata-ouro-diario` **ou** `atualizar-prata-ouro-evento` | canal abaixo |
| Política de alerta (Workflow) | `projects/pdm-ceasa/alertPolicies/10279204652876858775` — "Cadeia prata/ouro: Workflow verificador falhou" | Log `ERROR` no Workflow `verificar-e-atualizar-prata-ouro` | canal abaixo |
| Canal de notificação | `projects/pdm-ceasa/notificationChannels/12818637730969107935` (e-mail) | Recebe os alertas | — |

**[FATO]** As duas políticas dispararam incidente em teste real nesta
sessão: jobs às 20:02:00Z (entrada de teste) e 21:03:52Z (falha real do job
na nuvem); Workflow às 19:46:42Z (falha real do Workflow).

---

## 6. Papéis IAM

Todos para `prata-ouro-evento@pdm-ceasa.iam.gserviceaccount.com`, salvo
indicação. **[FATO]** Nenhum tem condição IAM (`condition = None` em todos,
conferido na política).

| Papel | Onde | Por que é necessário |
|---|---|---|
| `roles/bigquery.jobUser` | projeto | rodar consultas (SQLs e defasagem) |
| `roles/bigquery.dataViewer` (aparece como `READER` na ACL) | dataset `bronze` (GRANT) | ler a bronze; **só leitura** |
| `roles/bigquery.dataEditor` (aparece como `WRITER`) | datasets `silver` e `gold` (GRANT) | `CREATE OR REPLACE` nos destinos |
| `roles/workflows.invoker` | projeto | o gatilho iniciar o Workflow |
| `roles/eventarc.eventReceiver` | projeto | o gatilho receber eventos |
| `roles/logging.logWriter` | projeto | o Workflow gravar suas decisões (`sys.log`). **[FATO]** sem ele, o Workflow falhou com 403 em `logging.logEntries.create` |
| `roles/run.viewer` | projeto | o Workflow ver se o plano B está em execução (só leitura; não executa) |
| `roles/run.developer` | **só** no job `atualizar-prata-ouro-evento` | o Workflow chamar o job **passando os estados como argumento** (exige `run.jobs.runWithOverrides`) |
| `roles/pubsub.publisher` | tópico `bronze-ceasa-alterada` | para a identidade do sink (`service-502988692211@gcp-sa-logging…`). **Só no tópico**: essa identidade é compartilhada com o sink do MLOps |
| `roles/pubsub.publisher` | tópico `bronze-ceasa-alterada-dlq` | para o agente do Pub/Sub mover mensagens mortas |
| `roles/pubsub.subscriber` | assinatura `…-trigger-sub-743` | para o agente do Pub/Sub retirar da fila o que vai para a DLQ |

**Por que nenhuma condição IAM.** Na primeira versão desta frente (v1, criada
em 02/11 e já removida), o `workflows.invoker` foi concedido com condição em
`resource.name` (restrito a um Workflow). **[FATO]** Toda entrega ao Workflow
voltou com 403: 739 tentativas, de 03/11 17:15Z a 04/11. **[FATO]** A cadeia
`inferencia-diaria` do MLOps, com o mesmo desenho e o papel **sem** condição,
recebia `ack_200`. **[HIPÓTESE]** A condição foi a causa — a documentação diz
que condição sobre atributo não suportado pelo serviço nunca concede acesso,
mas não se achou a página específica do Workflows, e o Policy Troubleshooter
(que provaria) está desligado no projeto. A v2 removeu a condição e
**[FATO]** passou a receber `ack_200` (23 entregas em 04/11 a partir de 20:06Z,
nenhuma recusada).

**Por que uma conta de serviço só.** Gatilho, Workflow e job usam a mesma SA.
Menos bindings e nenhum `actAs` entre contas; o preço é mais poder numa
identidade. Mesmo padrão do plano B, em que a SA do Scheduler é a do job.

---

## 7. O plano B

| Recurso | Nome canônico |
|---|---|
| Cloud Run job | `atualizar-prata-ouro-diario` (imagem `…/atualizar-prata-ouro-diario@sha256:81a6461a42318d4cd0fce91f6308ada7325db1c60b42fc0ab36a18015ce7fbb0`) |
| Scheduler | `projects/pdm-ceasa/locations/us-central1/jobs/atualizar-prata-ouro-diario-trigger` — `30 16 * * *`, `America/Sao_Paulo`, `ENABLED` |
| Conta de serviço | `atualizar-prata-ouro-diario@pdm-ceasa.iam.gserviceaccount.com` |
| Script | `pipelines/atualizar_prata_ouro.sh` (com `pipelines/Dockerfile`, `pipelines/cloudbuild.yaml`) |

Criado em 2026-10-23 **[FATO]**, roda todo dia às 16:30 e reconstrói, em ~3
min, as 9 tabelas em 8 etapas — inclusive `silver.clima_historico`, que a
cadeia por evento **não** toca.

**[FATO] Nunca foi alterado nesta frente:** mesmo digest de imagem, mesma
política IAM (só a própria SA com `run.invoker`), mesmo Scheduler e mesmo
SHA-256 dos arquivos, conferidos ao fim de cada etapa. A execução das 16:30 de
04/11 terminou com `fim: ok nas 8 etapas` (`atualizar-prata-ouro-diario-wqftt`).

**Por que continua existindo:**

- **fallback** — se gatilho, Workflow ou job falharem, a prata e o ouro ainda
  são reconstruídos uma vez por dia;
- **reconciliação** — por ser reescrita total de tudo, ele corrige qualquer
  sobra que a cadeia por evento tenha deixado;
- **clima** — é o único que recria `silver.clima_historico`.

A guarda do Workflow não chama o job novo enquanto o plano B estiver em
execução, para as duas reconstruções não disputarem as mesmas tabelas.

---

## 8. Os 9 SQLs de tratamento

Todos em `sql/construir_tabelas/`, todos `CREATE OR REPLACE TABLE`
**[FATO, lido nos arquivos]**:

| Ordem | Arquivo | Destino | Lê |
|---|---|---|---|
| (plano B) | `sql/construir_tabelas/silver/09_clima_historico_bronze_to_silver.sql` | `silver.clima_historico` | `bronze.clima_historico` |
| estado | `sql/construir_tabelas/silver/10_ceasa_go_prata.sql` | `silver.ceasa_go` | `bronze.ceasa_go`, `silver.clima_historico` |
| estado | `sql/construir_tabelas/silver/11_ceasa_sc_prata.sql` | `silver.ceasa_sc` | `bronze.ceasa_sc`, `silver.clima_historico` |
| estado | `sql/construir_tabelas/silver/12_ceasa_ms_prata.sql` | `silver.ceasa_ms` | `bronze.ceasa_ms`, `silver.clima_historico` |
| estado | `sql/construir_tabelas/silver/13_ceasa_mg_prata.sql` | `silver.ceasa_mg` | `bronze.ceasa_mg`, `silver.clima_historico` |
| estado | `sql/construir_tabelas/silver/14_ceasa_es_prata.sql` | `silver.ceasa_es` | `bronze.ceasa_es`, `silver.clima_historico` |
| depois dos estados | `sql/construir_tabelas/silver/15_ceasa_unificado.sql` | `silver.ceasa_unificado` | as 5 pratas |
| por último | `sql/construir_tabelas/gold/06_ceasa_unificado_semanal_quinzenal.sql` | `gold.ceasa_unificado_semanal`, `gold.ceasa_unificado_quinzenal` | `silver.ceasa_unificado` |

**Ordem obrigatória: estado → unificado → gold.** O unificado lê as 5 pratas;
as gold leem o unificado. Qualquer outra ordem publica unificado ou ouro sobre
prata velha. Cada SQL de estado é independente dos outros 4 — é isso que
permite reconstruir um estado só.

Cada SQL de construção tem uma consulta de conferência em `sql/consultas/`
(`silver/19_` a `24_`, `gold/16_`), que o job roda depois de cada etapa.

---

## 9. Decisões importantes e o motivo

### 9.1 Evento em vez de polling periódico

*Polling* seria perguntar a cada N minutos "a bronze mudou?". Foi
considerado e documentado como alternativa (não perde mudança, tem menos
partes). Escolheu-se o evento porque reage em ~3 min **[FATO, medido nos
ensaios]** sem custo enquanto nada acontece. O risco do evento — perder uma
mensagem e ninguém perceber — foi tratado com DLQ, alertas e com a decisão
baseada em estado (9.3), que faz qualquer disparo seguinte corrigir o que
um disparo perdido deixou.

### 9.2 Script e job novos em vez de alterar o plano B

O script do plano B roda sempre as 8 etapas e não aceita argumento de estado.
Parametrizá-lo mudaria o digest da imagem em produção: um defeito ali deixaria
o projeto **sem nenhuma** atualização. Criou-se ao lado
`pipelines/atualizar_prata_ouro_estados.sh`, com imagem e job próprios.
Custo aceito: duplicação de ~40 linhas de orquestração (funções `log`,
`falhar`, `roda_sql` e o mapa estado → SQL). Os SQLs **não** são
duplicados — os dois jobs usam os mesmos arquivos.

### 9.3 "Em dia" como sinal positivo explícito, nunca ausência de saída

A consulta `25_defasagem_cadeia_check.sql` devolve **sempre** uma linha
`regra='resumo'` com a contagem de atrasos (estado, unificado, gold), mais
uma linha por tabela atrasada. "Em dia" é o resumo `0,0,0`. Se o resumo não
vier, script e Workflow **falham**: ausência significa consulta quebrada.
Motivo: quem decide (o Workflow) não pode confundir "nada atrasado" com "a
consulta não respondeu" — seria falha silenciosa no ponto de decisão.
A consulta também aborta com `RAISE` se faltar alguma das 13 tabelas
esperadas, porque `NULL` nunca é "mais novo" e a cadeia pareceria em dia.

Regras da defasagem (sobre `last_modified_time` de `__TABLES__`):

1. `bronze.ceasa_<uf>` mais nova que `silver.ceasa_<uf>` → estado atrasado;
2. a prata mais nova mais nova que `silver.ceasa_unificado` → unificado atrasado;
3. `silver.ceasa_unificado` mais novo que uma gold → aquela gold atrasada.

### 9.4 Falha alta em vez de falha silenciosa

Todo caminho de erro termina em log `ERROR` e código 1: estado fora da lista
fechada, chamada sem estado (não há valor padrão — um padrão errado
reconstruiria a coisa errada sem ninguém saber), arquivo SQL ausente,
resumo ausente, unificado/gold atrasado, sobra no limite de repetições.
O `ERROR` aciona as políticas de alerta. **[FATO]** Isto foi testado
na nuvem: job com `xx` falhou antes de qualquer escrita e abriu incidente.

### 9.5 Laço de repetição no job, e o problema que ele resolve

**[FATO] Problema, ensaio de 04/11 20:08Z:** 5 escritas em ~7 s; o primeiro
Workflow consultou a defasagem quando só GO, SC e MS apareciam atrasados e
chamou o job com `go;ms;sc`; os 4 seguintes saíram por "execução em curso";
quando o job terminou não havia mais evento — MG e ES ficaram atrasados (`2,0,0`
por 24 min) e o job terminou em `WARNING`, sem alerta.

**Correção:** ao terminar a cadeia, o job relê a defasagem; se ainda houver
estado atrasado, roda de novo **só esses** estados, seguidos de unificado e
gold. Limite `MAX_REPETICOES=3` (uma rajada dura ~45 s e uma passada 1–3 min;
a 1ª repetição já cobre o que chegou durante a passada original, e o pior
caso, ~4 passadas, fica bem abaixo do timeout de 1800 s). No limite com sobra:
`ERROR`, nunca `WARNING`.

**[FATO] Prova:** ensaio manual dos 5 em 21:32Z — cada job rodou `go ms sc`,
registrou `repeticao 1/3: … es mg` e terminou `fim: ok; repeticoes=1`;
defasagem `0,0,0` ao fim. Limite provado localmente com o `bq` real e dados
fixos no pipe (4 passadas, depois `ERROR`, `rc=1`).

### 9.6 Uma conta de serviço, sem condição IAM

Ver seção 6.

---

## 10. Armadilhas encontradas e a lição de cada uma

| Armadilha | O que aconteceu **[FATO]** | Lição |
|---|---|---|
| Condição IAM no `workflows.invoker` (v1) | 739 entregas recusadas com 403 em ~2 dias, sem ninguém perceber; o Workflow nunca recebeu evento real | Não restringir com condição o que o serviço pode não suportar; e entrega recusada precisa de DLQ + alerta, senão é silenciosa |
| Tópico sem assinatura | Em 02/11 o sink publicou uma escrita de MG antes de a assinatura existir; a mensagem se perdeu | Criar a assinatura (o gatilho) **antes** do sink |
| `jsonPayload` × `textPayload` | O script grava linhas JSON, mas o Cloud Logging guardou o log do job como texto; um filtro por `jsonPayload.message` não achava nada | Conferir o formato real do log antes de escrever filtro de prova ou de alerta |
| `bq` falso que escondia o resultado vazio | O teste local usava um `bq` falso que sempre imprimia cabeçalho; o `bq` real, com zero linhas em CSV, não imprime cabeçalho — o script deu falso negativo em produção | Testar com o serviço real em leitura; um dublê só prova o que ele foi programado para fingir. Origem da decisão 9.3 |
| Política de alerta que desligou ao ser alterada | `gcloud alpha monitoring policies update --policy-from-file` (19:14Z) e um `PATCH` REST em `conditions` deixaram a política com `enabled: false` sem aplicar o filtro novo; religada só `enabled`, ela **não disparou** mais em teste (entradas de 19:29:59Z e 19:41:00Z) | Não editar política de alerta em uso: criar uma nova, provar o disparo, só então apagar a antiga. A política dos jobs foi recriada (`4226080771277096396`) e disparou em 11 s |
| Corrida que deixou estados para trás | Ver 9.5 | O fim de um job é um momento sem evento; quem precisa reavaliar é o próprio job |

---

## 11. Limitações conhecidas

**Corrida entre execuções do Workflow → dois jobs simultâneos. [FATO]**
A guarda "execução em curso" lista as execuções e depois chama o job; entre
as duas ações há uma janela de ~1 s. Medido:

| Ensaio | Escritas | Workflows | Jobs | Reconstruções do unificado | Inferências MLOps |
|---|---|---|---|---|---|
| INSERT 20:08Z (antes do laço) | 5 em ~7 s | 5 | 1 | 1 | 1 |
| DELETE 20:53Z | 5 em ~7 s | 5 (2 chamaram o job) | **2 simultâneos** | 2 | 2 |
| INSERT manual 21:32Z | 5 em ~7 s | 5 (2 chamaram o job) | **2 simultâneos**, cada um com 1 repetição | 4 | 4 |
| DELETE manual 21:35Z | 5 em ~7 s | 5 (1 chamou o job) | 1, com 1 repetição | 2 | 2 |

Nos casos com 2 jobs, cada tabela foi recriada duas vezes, com segundos de
diferença. O estado final ficou correto em todos (defasagem `0,0,0`,
contagens conferidas), porque a reescrita é idempotente e cada job termina com
unificado e gold depois das suas pratas. Mas viola a regra do desenho
("duas reconstruções simultâneas da mesma tabela não são aceitáveis") e dobra
custo e inferências. **Não corrigido.**

**Inferência do MLOps a cada reconstrução do unificado. [FATO]** A frente
MLOps (outro integrante) tem um sink próprio que dispara o Workflow
`inferencia-diaria` sempre que `silver.ceasa_unificado` é regravado. Cada
passada da cadeia — inclusive cada repetição e cada job duplicado — gera uma
inferência. Em 04/11, a frente nova disparou 16 inferências entre 15:08 e
18:38 BRT (ensaios e testes incluídos; fora a do plano B às 16:33). **[HIPÓTESE]** a inferência decide
sozinha se há dado novo, então o custo é de execução, não de resultado.

**Divergência de esquema da `bronze.ceasa_go`. [FATO]** SC, MS, MG e ES têm
as mesmas 18 colunas; GO tem 17, sem `fonte`, `mercado`, `classificacao`,
`tipo`, `origem`, `situacao` e com `categoria`, `codigo`, `classe`,
`preco_kg`, `layout`. Os SQLs desta frente não dependem disso (cada um lê a
própria tabela; o ensaio usa `SELECT * REPLACE` e só toca `data`, `ano`,
`mes`, `dia`, `arquivo`, presentes nas 5), mas qualquer código futuro que
trate as 5 bronzes como iguais vai quebrar em GO.

**Outras:**

- o fim do job em sobra depois do limite é `ERROR`; o caso "unificado/gold
  atrasado sem estado atrasado" faz o Workflow falhar e espera o plano B — não
  há autocorreção para ele;
- `bronze.ceasa_ms` está parada em 2026-10-02 **[FATO]**; não é problema desta
  frente;
- o caminho "limite de repetições atingido" foi provado só localmente (com o
  BigQuery real e dados fixos), não numa execução na nuvem — reproduzi-lo na
  nuvem exigiria escrever na bronze ou alterar a consulta.

---

## 12. Como replicar

Pré-requisitos: projeto com as APIs `workflows`, `workflowexecutions`,
`eventarc`, `pubsub`, `logging`, `run`, `cloudbuild`, `artifactregistry`,
`monitoring` e `bigquery` ligadas **[FATO, todas ligadas em `pdm-ceasa`]**;
conta com permissão de conceder papéis. Todo comando leva
`--project pdm-ceasa` (ou `--project_id=pdm-ceasa` no `bq`). Comandos rodam
a partir da raiz do repositório.

**Etapa 0 — Alerta (protege antes de mudar).**
Criar o canal de e-mail e as duas políticas por log (filtros da seção 5),
com `notificationRateLimit` de 300 s e `autoClose` de 1800 s:

```bash
gcloud alpha monitoring channels create --project pdm-ceasa --type=email \
  --display-name="Cadeia prata/ouro: <email>" --channel-labels=email_address=<email>
gcloud alpha monitoring policies create --project pdm-ceasa --policy-from-file=<politica.json>
```

Sucesso: esperar ~3 min (política recém-criada pode ainda não avaliar), gravar
uma entrada `ERROR` de teste com recurso `cloud_run_job` e
`job_name=atualizar-prata-ouro-evento` (API `logging.googleapis.com/v2/entries:write`)
e ver o incidente abrir e o e-mail chegar. Garantir que não há incidente
aberto da mesma política antes de testar.

**Etapa 1 — Consulta de defasagem.** `sql/consultas/silver/25_defasagem_cadeia_check.sql`.
Sucesso: devolve a linha `resumo`; aborta com `RAISE` se uma tabela da lista
for trocada por nome inexistente.

**Etapa 2 — Script por estado.** `pipelines/atualizar_prata_ouro_estados.sh`.
Sucesso: `--simular es` imprime 3 etapas (`14_`, `15_`, `06_`); `xx`, sem
argumento e arquivo ausente abortam com `rc=1` antes de qualquer chamada ao
BigQuery.

**Etapa 3 — Conta de serviço, imagem e job.**

```bash
gcloud iam service-accounts create prata-ouro-evento --project pdm-ceasa
gcloud projects add-iam-policy-binding pdm-ceasa --member serviceAccount:prata-ouro-evento@pdm-ceasa.iam.gserviceaccount.com \
  --role roles/bigquery.jobUser --condition=None
bq query --project_id=pdm-ceasa --use_legacy_sql=false 'GRANT `roles/bigquery.dataViewer` ON SCHEMA `pdm-ceasa.bronze` TO "serviceAccount:prata-ouro-evento@pdm-ceasa.iam.gserviceaccount.com"'
# idem dataEditor em silver e gold
gcloud builds submit . --config pipelines/cloudbuild.evento.yaml --region us-central1 --project pdm-ceasa
gcloud run jobs create atualizar-prata-ouro-evento --project pdm-ceasa --region us-central1 \
  --image <imagem@sha256:...> --service-account prata-ouro-evento@pdm-ceasa.iam.gserviceaccount.com \
  --set-env-vars PROJETO=pdm-ceasa --tasks 1 --cpu 1 --memory 512Mi --task-timeout 1800s --max-retries 1
```

Sucesso: `gcloud run jobs execute atualizar-prata-ouro-evento --args=es --wait`
termina com `fim: ok`; com `--args=xx` falha antes de qualquer escrita e
abre incidente.

**Etapa 4 — Workflow verificador.** Conceder `workflows.invoker`,
`run.viewer`, `logging.logWriter` (projeto) e `run.developer` (só no job
novo), e implantar:

```bash
pipelines/implantar_verificador.sh
```

O script troca o marcador `__SQL_DEFASAGEM__` do YAML pelo texto do `.sql`
(fonte única). Sucesso: `gcloud workflows run verificar-e-atualizar-prata-ouro --data='{}'`
com a cadeia em dia devolve `"nada a fazer"` sem criar execução do job; com
o job em execução, devolve `"saiu: execucao em curso"`.

**Etapa 5 — Gatilho por evento.**

```bash
pipelines/criar_gatilho_evento.sh
```

Cria, nesta ordem: `eventarc.eventReceiver`, tópico, DLQ e sua assinatura,
gatilho (que cria a assinatura), DLQ na assinatura com os papéis do agente
Pub/Sub, e por último o sink com `pubsub.publisher` no tópico. Sucesso:
`gcloud pubsub topics publish bronze-ceasa-alterada --message='{}'` gera
`push_request_count` com `response_code=ack_200` e uma execução do Workflow.

---

## 13. Como testar

**Ensaio sintético** (dado falso na bronze — o par **tem** de ser rodado, e
fora das janelas do `ciclo-ceasa` (14:00) e do plano B (16:25–16:45)):

1. Leitura prévia: `02_verificacao_bronze_ensaio.sql`, `04_verificacao_prata_ouro_ensaio.sql`
   e `03_defasagem_cadeia_check.sql` (esperado `resumo 0,0,0`).
2. `01_ensaio_manual_5_estados_insert.sql` — copia as linhas da data mais
   recente de **cada** CEASA para o dia seguinte, com
   `arquivo = 'sintetico_manual_5'`. Os 5 `INSERT` num bloco, para reproduzir
   a rajada.
3. Esperar a cadeia (~3–4 min nos ensaios) e conferir:
   - `02_` — data máxima +1 dia e sintéticas = linhas da data copiada
     (medido: GO 230, SC 250, MS 167, MG 244, ES 152);
   - `04_` — cada prata e cada estado no unificado com data +1 dia; unificado
     por estado = prata do estado; gold com `modificada_brt` depois do INSERT
     (a contagem das gold pode não mudar);
   - `03_` — `resumo 0,0,0`.
4. `05_ensaio_manual_5_estados_delete.sql` — remove só a marca, também em bloco.
5. Conferir de novo: tudo igual à leitura prévia.

**[FATO] Resultado do ensaio automático das 20:53Z (DELETE):** contagens de
bronze, das 5 pratas, do unificado (327.139) e das gold (46.846 / 21.621)
idênticas às de antes do INSERT; 0 linhas sintéticas; defasagem `0,0,0`.

**O que observar** (onde ver):

- eventos e entregas: métricas `pubsub.googleapis.com/topic/send_request_count`
  e `subscription/push_request_count` (código esperado `ack_200`);
- decisões: `gcloud logging read 'resource.type="workflows.googleapis.com/Workflow" AND resource.labels.workflow_id="verificar-e-atualizar-prata-ouro" AND jsonPayload.decisao:*'`;
- jobs e repetições: `gcloud run jobs executions list --job atualizar-prata-ouro-evento`
  e o log do job, que está em `textPayload` (`inicio`, `repeticao`, `fim: ok`);
- inferências do MLOps: `gcloud workflows executions list inferencia-diaria`.

---

## 14. Como desmontar

Ordem: **do que dispara para o que é disparado**, para que nenhum evento chegue
a um destino já removido, e papéis antes da conta de serviço, para não deixar
bindings `deleted:` nas políticas.

| # | Remover | Comando | Por que nesta posição |
|---|---|---|---|
| 1 | Gatilho | `gcloud eventarc triggers delete verificar-e-atualizar-prata-ouro-trigger --location us-central1 --project pdm-ceasa` | para de disparar; descarta a fila pendente |
| 2 | Assinaturas (se sobrar a do gatilho) e a da DLQ | `gcloud pubsub subscriptions delete eventarc-us-central1-verificar-e-atualizar-prata-ouro-trigger-sub-743 --project pdm-ceasa`; idem `bronze-ceasa-alterada-dlq-sub` | depois do gatilho que as usa |
| 3 | Sink | `gcloud logging sinks delete bronze-ceasa-alterada --project pdm-ceasa` | para de publicar; **não** mexer no sink do MLOps |
| 4 | Tópicos | `gcloud pubsub topics delete bronze-ceasa-alterada --project pdm-ceasa`; idem `bronze-ceasa-alterada-dlq` | sem produtor nem consumidor |
| 5 | Workflow | `gcloud workflows delete verificar-e-atualizar-prata-ouro --location us-central1 --project pdm-ceasa` | nada mais o dispara |
| 6 | Papéis da SA | `gcloud projects remove-iam-policy-binding pdm-ceasa --project pdm-ceasa --member serviceAccount:prata-ouro-evento@pdm-ceasa.iam.gserviceaccount.com --role <papel> --condition=None` (5 papéis); `gcloud run jobs remove-iam-policy-binding atualizar-prata-ouro-evento --region us-central1 --project pdm-ceasa --member … --role roles/run.developer`; `REVOKE` nos 3 datasets | antes da SA |
| 7 | Conta de serviço | `gcloud iam service-accounts delete prata-ouro-evento@pdm-ceasa.iam.gserviceaccount.com --project pdm-ceasa` | depois dos papéis |
| 8 | Job | `gcloud run jobs delete atualizar-prata-ouro-evento --region us-central1 --project pdm-ceasa` | — |
| 9 | Imagens | `gcloud artifacts docker images delete us-central1-docker.pkg.dev/pdm-ceasa/cloud-run-source-deploy/atualizar-prata-ouro-evento --delete-tags --project pdm-ceasa` | o plano B usa outra imagem |
| 10 | Políticas de alerta | `gcloud alpha monitoring policies delete projects/pdm-ceasa/alertPolicies/4226080771277096396 --project pdm-ceasa`; idem `10279204652876858775` | **atenção:** a dos jobs também cobre o plano B; sem ela, falha do plano B fica silenciosa |
| 11 | Canal e log de teste | `gcloud alpha monitoring channels delete projects/pdm-ceasa/notificationChannels/12818637730969107935 --project pdm-ceasa`; `gcloud logging logs delete teste-alerta-cadeia-prata-ouro --project pdm-ceasa` | depois das políticas que o usam |
| 12 | Arquivos | `pipelines/{atualizar_prata_ouro_estados.sh, Dockerfile.evento, cloudbuild.evento.yaml, verificar_e_atualizar_prata_ouro.yaml, implantar_verificador.sh, criar_gatilho_evento.sh}`, `sql/consultas/silver/25_…`, e esta pasta (`sql/entrega02/`, onde ficam os ensaios) | por último: são a fonte para recriar |

O plano B não é tocado em nenhum passo.

---

## 15. Arquivos desta pasta e duplicação

| Arquivo | Uso | Local único ou cópia |
|---|---|---|
| `01_ensaio_manual_5_estados_insert.sql` | INSERT sintético dos 5 CEASAs | único (antes em `sql/construir_tabelas/bronze/06_…`, removido) |
| `02_verificacao_bronze_ensaio.sql` | conferência da bronze | único (antes em `sql/consultas/bronze/06_…`, removido) |
| `03_defasagem_cadeia_check.sql` | defasagem da cadeia (a mesma que o job e o Workflow usam) | **cópia** de `sql/consultas/silver/25_defasagem_cadeia_check.sql` |
| `04_verificacao_prata_ouro_ensaio.sql` | conferência das pratas, do unificado por estado e das gold | único (antes em `sql/consultas/silver/26_…`, removido) |
| `05_ensaio_manual_5_estados_delete.sql` | DELETE do sintético dos 5 | único (antes em `sql/construir_tabelas/bronze/07_…`, removido) |
| `06_ensaio_manual_go_insert.sql` | INSERT sintético só de GO (marca `sintetico_manual_go`) | único (movido de `sql/construir_tabelas/bronze/04_…`) |
| `07_ensaio_manual_go_delete.sql` | DELETE do sintético de GO | único (movido de `sql/construir_tabelas/bronze/05_…`) |

**Por que os ensaios moram aqui e não em `sql/construir_tabelas/bronze/`.**
O job `ciclo-ceasa` executa por glob todo `*.sql` de
`sql/construir_tabelas/{bronze,silver,gold}` da branch dele (o glob não desce
em subpastas). Se esta branch for mesclada na dele, um ensaio deixado ali
rodaria todo dia útil em produção.

**Duplicação que resta.** Só `03_defasagem_cadeia_check.sql` é cópia. **A
fonte usada em produção é o original** em `sql/consultas/silver/`: a imagem
do job copia `sql/` inteiro e o deploy do Workflow lê esse caminho. Alterar
só a cópia aqui **não** muda o que roda na nuvem.
