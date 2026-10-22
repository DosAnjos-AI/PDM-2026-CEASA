# Pipeline de MLOps: previsão do preço diário nas CEASAs

Pipeline automático no GCP. Ele lê o preço diário por kg de 25 produtos em 5 CEASAs
(`silver.ceasa_unificado`), avalia vários modelos com walk-forward, escolhe um campeão por
série (champion–challenger), publica as previsões de **3, 7 e 14 dias** à frente e guarda tudo
no dataset `mlops` do BigQuery. A aplicação que mostra os resultados está em [../app](../app).

```
Cloud Scheduler (toda terça 16:00, America/Sao_Paulo, depois da ingestão de segunda)
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

O agendamento roda na terça porque o job de ingestão do grupo (`ciclo-ceasa`) atualiza os dados
em dias úteis às 14:00, com o dado do dia anterior; na terça à tarde a silver já tem a segunda-feira.
Se a ingestão atrasar, dispare o comando acima na mão.

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
  --set-env-vars VERSAO_CODIGO=v0.6.1,N_JOBS=8
```

## Infraestrutura criada

| Recurso | Nome |
|---|---|
| Cloud Run Job | `treino-precos` (us-central1, 8 vCPU, 16 GiB, timeout 3h) |
| Cloud Scheduler | `treino-precos-semanal` (`0 16 * * 2`, America/Sao_Paulo) |
| Cloud Run Service | `app-precos` (aplicação Streamlit, ver [../app](../app)) |
| Contas de serviço | `airflow-mlops` (pipeline: BigQuery + `run.invoker` no job) e `app-precos` (aplicação: só leitura) |
| Imagens | Artifact Registry `cloud-run-source-deploy` |
| Dados | Dataset BigQuery `mlops` (US) |
