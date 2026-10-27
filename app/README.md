# Aplicação de previsões (Streamlit no Cloud Run)

Aplicação web que mostra os dados, as previsões e os bastidores do pipeline de MLOps
([../mlops](../mlops)). Ela só **lê** o BigQuery: tudo o que aparece foi gravado pelo pipeline
no dataset `mlops` ou vem das camadas `silver` e `gold`.

No ar em: https://app-precos-502988692211.us-central1.run.app

| Página | O que mostra |
|---|---|
| Previsões | Escolha de CEASA, produto e **data da previsão** (qualquer dia até 14 à frente); preço diário por kg, previsão oficial e o que os outros modelos preveem; se a data já passou, mostra o preço real ao lado; o mesmo produto nas outras CEASAs; maiores altas e quedas previstas |
| O modelo acertou? | O walk-forward em gráfico: em cada corte, as previsões de 3, 7 e 14 dias saem do preço real daquele dia, com seleção e holdout destacados |
| Comparação de modelos | Ganho de cada modelo sobre o Naive, no geral, por horizonte e por CEASA (mapa de calor) |
| Bastidores do MLOps | Versão em produção, decisões do champion–challenger, execuções (inclusive experimentos), custos e tempo de cada modelo |

As previsões mostradas são sempre as mais recentes em `mlops.previsoes`: quando a inferência diária
(Pub/Sub) publica previsões novas, elas aparecem em até 10 minutos (o tempo de cache das consultas),
ou na hora com o botão **Atualizar dados** da barra lateral. A página de previsões diz se elas vieram
da atualização diária ou do treino semanal. Quando a última verificação diária não achou dado novo
(no fim de semana a coleta não roda), a página mostra a hora dela; se a verificação falhou, mostra
um aviso.

A aplicação lê a configuração gravada pela última execução de produção e se adapta a ela: com a
configuração atual mostra o preço diário por kg das 5 CEASAs; com execuções antigas (até a v0.4)
mostra o preço semanal por embalagem da CEASA-GO. Experimentos (`--experimento`) não aparecem nas
páginas de previsão e comparação, só na lista de execuções.

## Rodar localmente

Precisa de credenciais do GCP com leitura no BigQuery (`gcloud auth application-default login`).

```powershell
python -m pip install -r requirements.txt
streamlit run app.py
```

## Testes

Abrem cada página como o Streamlit faria, com o BigQuery trocado por respostas sintéticas
([tests/bigquery_falso.py](tests/bigquery_falso.py)); qualquer tentativa de acessar o BigQuery de
verdade faz o teste falhar. Rodam também no GitHub Actions a cada push.

```powershell
python -m pip install -r requirements.txt pytest
pytest
```

## Deploy

```powershell
gcloud run deploy app-precos --source . --region us-central1 --project pdm-ceasa `
  --service-account app-precos@pdm-ceasa.iam.gserviceaccount.com `
  --allow-unauthenticated --memory 1Gi --cpu 1 --min-instances 0 --max-instances 2 `
  --session-affinity --timeout 3600
```

- `min-instances 0`: desliga quando ninguém está usando (custo perto de zero). A primeira visita
  depois de um tempo parado demora alguns segundos a mais para abrir.
- `session-affinity` e `timeout 3600`: o Streamlit mantém uma conexão aberta (websocket) com
  cada navegador; isso evita que ela caia no meio da apresentação.
- A conta `app-precos` só tem `bigquery.dataViewer` e `bigquery.jobUser`.
- `--allow-unauthenticated` deixa o link público. Para restringir, troque por
  `--no-allow-unauthenticated` e dê `roles/run.invoker` a quem puder acessar.

Para atualizar o diagrama da página de bastidores, gere de novo `../mlops/docs/arquitetura.png`
e copie para `assets/`.
