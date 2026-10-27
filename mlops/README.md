# Pipeline de MLOps: previsão do preço diário nas CEASAs

Pipeline automático no GCP. Ele lê o preço diário por kg de 25 produtos em 5 CEASAs
(`silver.ceasa_unificado`), avalia vários modelos com walk-forward, escolhe um campeão por
série (champion–challenger), publica as previsões de **3, 7 e 14 dias** à frente e guarda tudo
no dataset `mlops` do BigQuery. A aplicação que mostra os resultados está em [../app](../app).

```
Cloud Scheduler (toda terça 17:00, America/Sao_Paulo, depois da atualização diária da silver)
  └─> Cloud Run Job "treino-precos"
        1. Lê silver.ceasa_unificado: preço por kg e clima do estado de cada CEASA
        2. Dados iguais aos da última execução?  -> registra "sem_dados_novos" e encerra
        3. Otimiza o LightGBM com Optuna (só com dados anteriores ao walk-forward)
        4. Walk-forward: 13 modelos x 13 cortes x 3, 7 e 14 dias à frente
        5. Monta a versão candidata: o melhor modelo de cada série nos cortes de seleção
        6. Compara candidata x campeão atual nos cortes de holdout -> promove ou rejeita
        7. Prevê 3, 7 e 14 dias à frente com todos os modelos e marca o campeão em produção
        8. Grava execução, métricas, versão, decisão e previsões no BigQuery
```

## Dados

- **Fonte:** `silver.ceasa_unificado`, que é exatamente a união das tabelas `silver.ceasa_<estado>`,
  com os nomes de produto padronizados. Preço comum em **R$/kg**, um valor por dia.
- **Séries:** uma por CEASA e produto (`GO__tomate_longa_vida`). Hoje são 120: 25 em MG, ES, SC e
  MS, e 20 em GO (5 produtos pararam de ser cotados em GO).
- **Cada CEASA usa o período que tiver:** GO desde 2010, SC desde 2020, MS desde 2021, MG e ES
  desde 2021. Uma série é usada se chega até a última data da sua CEASA; por isso a MS, que está
  atrasada na silver, entra com os dados até onde existem.
- **Fins de semana:** em ES, GO e MG, sábado e domingo são interpolados entre o preço de sexta e o
  de segunda; em SC repetem a sexta. Por isso os cortes do walk-forward caem sempre num dia útil
  (um corte no sábado já "enxergaria" parte do preço de segunda).
- **Clima:** médias móveis de 60 dias do estado de cada CEASA (temperatura, umidade, nebulosidade,
  chuva e vento), que já vêm na silver. A janela termina no próprio dia, e cada dia previsto recebe
  o clima de **14 dias antes**: assim a previsão só usa clima conhecido no dia em que é feita.

A configuração semanal anterior (preço por embalagem, só CEASA-GO, `gold.analitica_semanal`)
continua em [config/semanal_go.yaml](config/semanal_go.yaml), para reproduzir os resultados do
artigo em [docs/artigo.html](docs/artigo.html).

## Modelos

| Família | Modelos | Biblioteca |
|---|---|---|
| Baselines | `Naive` (último preço), `SeasonalNaive` (1 ano antes) | statsforecast |
| Estatísticos (um por série) | `ARIMA`, `ETS`, `Theta` (`SARIMA` desativado) | statsforecast |
| ML (um modelo global) | `LightGBM`, `LightGBM_direto`, `LightGBM_clima`, `LightGBM_otimizado`, `Ridge` | mlforecast |
| Foundation models (zero-shot) | `Chronos2`, `Chronos2_clima`, `ChronosBolt` (`ChronosT5` desativado) | chronos-forecasting |

- **Janela de histórico:** o ARIMA e os Chronos usam os **últimos 5 anos** de cada série; ETS,
  Theta e os modelos de ML usam **3 anos**. A escolha veio de experimentos com janelas de 2, 3, 4, 5
  e 10 anos (`--janela-anos`): Chronos e ARIMA melhoraram até 4–5 anos e depois estabilizaram; o
  Theta piorou com mais histórico; o LightGBM não mudou.
- Os LightGBM diretos treinam um modelo para cada horizonte avaliado (3, 7 e 14 dias).
- Os modelos de ML são globais: aprendem com as 5 CEASAs ao mesmo tempo.

Ative, desative ou ajuste os modelos em [config/treino.yaml](config/treino.yaml).

## Avaliação e champion–challenger

- **Walk-forward:** 13 cortes, um a cada 28 dias, cobrindo o último ano. Os cortes são as mesmas
  datas para todas as séries e caem sempre no mesmo dia útil. Em cada corte o modelo treina com o
  que existia até aquela data (de todas as CEASAs) e prevê 3, 7 e 14 dias à frente das séries que
  têm dado naquele dia. Uma CEASA atrasada deixa de ser prevista nos cortes posteriores ao seu
  último dado.
- **Seleção (9 primeiros cortes):** em cada série, o modelo com menor MAE vira o escolhido, mas só
  se errar pelo menos 3% menos que o Naive. Caso contrário a série fica com o Naive.
- **Holdout (4 últimos cortes, 16 semanas):** não participa da escolha. Nele a versão candidata é
  comparada com o campeão em produção. A candidata é promovida se errar pelo menos 1% menos que o
  campeão e não errar mais que o Naive.
- O campeão padrão, antes da primeira promoção, é a versão `naive` (Naive em todas as séries).
- **Modelo definido pela equipe:** com `campeao.modelo_fixo` no yaml (hoje `Chronos2`), esse modelo
  vai para produção em todas as séries, sem passar pelo limiar. A decisão fica registrada como
  `fixada`, com o desempenho dele contra o Naive no holdout. Sem essa linha, vale a escolha automática.
- **Previsões publicadas:** cada um dos próximos 14 dias (`horizontes_previsao`), para a aplicação
  deixar escolher a data. A avaliação continua em 3, 7 e 14 dias.

## Tabelas (`pdm-ceasa.mlops`)

| Tabela / view | Conteúdo |
|---|---|
| `execucoes` | Uma linha por execução: status, versão dos dados, tempos, hiperparâmetros, decisão, experimento |
| `metricas` | MAE/RMSE/WAPE/R² por período (`todas`/`selecao`/`holdout`), modelo e horizonte (`0` = todos) |
| `metricas_serie` | Métricas por modelo e série |
| `previsoes_cv` | Todas as previsões do walk-forward |
| `versoes` | Registry: cada versão candidata com as métricas de holdout, a decisão e o motivo |
| `versao_series` | Modelo escolhido para cada série em cada versão |
| `producao` | Histórico de promoções e rollbacks |
| `producao_atual` (view) | Versão em produção agora |
| `previsoes` | Previsões futuras de todos os modelos; `e_campeao` marca o modelo em produção em cada série |
| `previsoes_atuais` (view) | Previsões da execução mais recente (usada pela aplicação) |
| `custo_execucoes` (view) | Custo estimado de cada execução no Cloud Run |

O campo `horizonte` está em períodos da frequência da execução: dias na configuração atual,
semanas nas execuções até a v0.4. `ultima_semana` guarda a última data com dados.

## Operação

Rodar agora, sem esperar o agendamento:

```powershell
gcloud scheduler jobs run treino-precos-semanal --location us-central1 --project pdm-ceasa
```

O agendamento roda na terça às 17:00, depois da cadeia diária do grupo: a coleta (`ciclo-ceasa`)
roda em dias úteis às 14:00, e o job `atualizar-prata-ouro-diario` recria a silver às 16:30, o que
já dispara a inferência diária (pronta por volta das 16:35). Assim o treino usa o dado do próprio
dia e não termina junto com a inferência: os dois gravam previsões, e a aplicação mostra as mais
recentes. Se a ingestão atrasar, dispare o comando acima na mão.

Forçar o treino mesmo sem dados novos (por exemplo, depois de mudar o `treino.yaml`):

```powershell
gcloud run jobs execute treino-precos --region us-central1 --project pdm-ceasa "--args=pipeline.treinar,--forcar"
```

Rodar um **experimento** (grava métricas e walk-forward com um rótulo, mas não decide promoção nem
publica previsões; a produção e a aplicação continuam iguais):

```powershell
gcloud run jobs execute treino-precos --region us-central1 --project pdm-ceasa "--args=pipeline.treinar,--experimento,so_go,--config,config/outra.yaml"
```

Ver o histórico de produção e fazer rollback:

```powershell
gcloud run jobs execute treino-precos --region us-central1 --project pdm-ceasa --wait "--args=pipeline.rollback,--listar"
gcloud run jobs execute treino-precos --region us-central1 --project pdm-ceasa "--args=pipeline.rollback,--versao,<versao_id>,--motivo,motivo do rollback"
gcloud run jobs execute treino-precos --region us-central1 --project pdm-ceasa "--args=pipeline.rollback,--versao,naive"
```

No PowerShell, o `--args=...` precisa ficar entre aspas: sem elas, a vírgula vira um
operador de lista e o job recebe todos os argumentos grudados.

O rollback só troca a versão em produção. As novas previsões saem na próxima execução que
tiver dados novos, ou na hora com `--forcar`.

## Inferência diária (Pub/Sub)

O treino completo (13 modelos, walk-forward, decisão do campeão) roda toda terça. Entre um treino e
outro, as previsões são refeitas **sempre que chega dado novo**, com o modelo em produção:

```
a silver.ceasa_unificado é regravada (todo dia às 16:30, pelo job atualizar-prata-ouro-diario do grupo)
  └─► o log de auditoria do BigQuery registra a gravação
        └─► o coletor de logs mlops-silver-unificada-atualizada publica no tópico ceasa-dados-atualizados
              └─► Eventarc chama o Workflow inferencia-diaria
                    └─► executa o job treino-precos com "pipeline.prever" (só previsão, ~5 min)
                          └─► grava as previsões novas em mlops.previsoes; a aplicação mostra na hora
```

Quem publica o aviso é o próprio Google Cloud (o coletor de logs filtra, no log de auditoria, as
gravações bem-sucedidas da `silver.ceasa_unificado`). Por isso **a ingestão não precisou mudar nada**:
o aviso funcionava com a montagem feita na mão e continua funcionando com o job
`atualizar-prata-ouro-diario`, que recria a silver todo dia às 16:30 desde 23/10/2026. No fim de
semana a coleta não roda: a silver é recriada com os mesmos dados, a inferência encerra como
`sem_dados_novos` e a aplicação mostra a hora dessa verificação.

- `pipeline.prever` usa a versão em produção (ou `campeao.modelo_fixo`) e os hiperparâmetros do último
  treino. Se os dados não mudaram desde a última previsão publicada, encerra sem fazer nada.
- Mensagens que falharem 5 vezes vão para o tópico `ceasa-dados-atualizados-dlq` e ficam guardadas
  na assinatura `ceasa-dados-atualizados-dlq-sub`.
- A infraestrutura (tópico, fila de erros, Workflow, gatilho e permissões) é criada por
  [infra/inferencia_diaria.sh](infra/inferencia_diaria.sh); o Workflow está em
  [infra/inferencia_diaria.workflow.yaml](infra/inferencia_diaria.workflow.yaml).
- O treino semanal só compara a versão dos dados com outros treinos (coluna `tipo` de
  `mlops.execucoes`), então a inferência diária não faz o retreino de terça ser pulado.

**Publicar o aviso por conta própria (opcional):** qualquer processo pode publicar no tópico, por
exemplo a ingestão ao terminar; a conta `ciclo-ceasa` já tem permissão. Avisos repetidos não causam
problema: se os dados não mudaram, a inferência encerra em cerca de 1 minuto. Em shell:

```bash
gcloud pubsub topics publish ceasa-dados-atualizados --project pdm-ceasa \
  --message "{\"origem\": \"ciclo-ceasa\", \"ultima_data\": \"$(date +%F)\"}"
```

Em Python (`google-cloud-pubsub`):

```python
from google.cloud import pubsub_v1

publicador = pubsub_v1.PublisherClient()
topico = publicador.topic_path("pdm-ceasa", "ceasa-dados-atualizados")
publicador.publish(topico, b'{"origem": "ciclo-ceasa"}').result()
```

Para disparar na mão (mesmo efeito do aviso da ingestão):

```powershell
gcloud pubsub topics publish ceasa-dados-atualizados --project pdm-ceasa --message '{\"origem\":\"manual\"}'
```

## Alertas e orçamento

| Alerta | Quando dispara | Como foi criado |
|---|---|---|
| MLOps: job treino-precos falhou | Uma execução do job termina com erro | [infra/alertas.py](infra/alertas.py) |
| MLOps: CEASA sem dados novos | Alguma CEASA passou de `alertas.dias_sem_dados` (7) dias sem dado novo; o job escreve `ALERTA_DADOS_ATRASADOS` no log | [infra/alertas.py](infra/alertas.py) |
| Orçamento pdm-ceasa: US$ 5 por mês | O gasto do mês passa de 50%, 90% e 100% de US$ 5 (só avisa, não bloqueia) | `gcloud billing budgets create` (conta de faturamento) |

Os e-mails ficam nos canais de notificação `MLOps: <email>`. Para criar ou atualizar os alertas
(reexecutar não duplica):

```powershell
python infra/alertas.py --email pessoa@exemplo.com --email outra@exemplo.com
```

Para checar os dados sem treinar (rápido e barato; dispara o alerta se houver CEASA atrasada):

```powershell
gcloud run jobs execute treino-precos --region us-central1 --project pdm-ceasa "--args=pipeline.treinar,--so-verificar"
```

## Testes e CI

Os testes rodam sem acesso ao GCP: o pipeline usa dados sintéticos (inclusive uma CEASA atrasada e
um produto que parou de ser cotado) e modelos falsos ou pequenos. Eles conferem, entre outras coisas,
que o walk-forward nunca vê dado posterior ao corte, que o clima não usa o futuro, que os cortes caem
em dia útil, que só há um campeão por série e data e que as configurações versionadas são coerentes.

```powershell
python -m pip install -r requirements-teste.txt
pytest
```

O GitHub Actions ([../.github/workflows/testes.yml](../.github/workflows/testes.yml)) roda os testes
do pipeline e da aplicação a cada push ou pull request que mexa em `mlops/` ou `app/`.

## Desenvolvimento

Teste local rápido (não grava nada):

```powershell
python -m pip install -r requirements.txt
python -m pipeline.treinar --amostra 5 --sem-gravar
```

Deploy de uma nova versão do código (o Cloud Build monta a imagem a partir do `Dockerfile`):

```powershell
gcloud run jobs deploy treino-precos --source . --region us-central1 --project pdm-ceasa `
  --service-account airflow-mlops@pdm-ceasa.iam.gserviceaccount.com `
  --cpu 8 --memory 16Gi --task-timeout 3h --max-retries 0 `
  --set-env-vars VERSAO_CODIGO=v0.7,N_JOBS=8
```

## Infraestrutura criada

| Recurso | Nome |
|---|---|
| Cloud Run Job | `treino-precos` (us-central1, 8 vCPU, 16 GiB, timeout 3h) |
| Cloud Scheduler | `treino-precos-semanal` (`0 17 * * 2`, America/Sao_Paulo) |
| Pub/Sub | tópico `ceasa-dados-atualizados` e fila de erros `ceasa-dados-atualizados-dlq` (+ assinatura `-dlq-sub`) |
| Eventarc + Workflows | gatilho e workflow `inferencia-diaria`, com a conta `inferencia-diaria` |
| Cloud Logging | coletor `mlops-silver-unificada-atualizada` (log de auditoria do BigQuery → tópico) |
| Cloud Monitoring | alertas "job treino-precos falhou" e "CEASA sem dados novos"; orçamento de US$ 5/mês na conta de faturamento |
| Cloud Run Service | `app-precos` (aplicação Streamlit, ver [../app](../app)) |
| Contas de serviço | `airflow-mlops` (pipeline: BigQuery + `run.invoker` no job) e `app-precos` (aplicação: só leitura) |
| Imagens | Artifact Registry `cloud-run-source-deploy` |
| Dados | Dataset BigQuery `mlops` (US) |
