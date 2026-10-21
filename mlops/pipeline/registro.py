"""Leitura e gravação das tabelas mlops.* do BigQuery (execuções, métricas, registry e previsões)."""
import logging

import pandas as pd
from google.api_core.exceptions import NotFound
from google.cloud import bigquery

from pipeline.campeao import VERSAO_NAIVE

log = logging.getLogger(__name__)

S, I, F, TS, D = "STRING", "INTEGER", "FLOAT", "TIMESTAMP", "DATE"

ESQUEMAS = {
    "execucoes": [
        ("run_id", S), ("inicio", TS), ("fim", TS), ("status", S), ("erro", S),
        ("origem", S), ("versao_codigo", S), ("versao_dados", S), ("ultima_semana", D),
        ("series_usadas", I), ("linhas", I), ("modelos", S), ("tempos_s", S), ("config", S),
        ("hiperparametros", S), ("decisao", S), ("experimento", S),
    ],
    "metricas": [
        ("run_id", S), ("modelo", S), ("horizonte", I), ("n", I),
        ("mae", F), ("rmse", F), ("wape", F), ("r2", F), ("ganho_vs_naive", F), ("periodo", S),
    ],
    "metricas_serie": [
        ("run_id", S), ("modelo", S), ("unique_id", S), ("n", I),
        ("mae", F), ("rmse", F), ("wape", F), ("r2", F),
    ],
    "previsoes_cv": [
        ("run_id", S), ("modelo", S), ("unique_id", S), ("cutoff", D), ("ds", D),
        ("horizonte", I), ("y", F), ("yhat", F),
    ],
    "versoes": [
        ("versao_id", S), ("run_id", S), ("criado_em", TS), ("n_series", I), ("modelos_usados", S),
        ("mae_holdout_candidata", F), ("campeao_anterior", S), ("mae_holdout_campeao", F),
        ("mae_holdout_naive", F), ("melhor_modelo_unico", S), ("mae_holdout_modelo_unico", F),
        ("decisao", S), ("motivo", S),
    ],
    "versao_series": [
        ("versao_id", S), ("unique_id", S), ("modelo", S), ("mae_selecao", F), ("mae_selecao_naive", F),
    ],
    "producao": [
        ("em", TS), ("versao_id", S), ("tipo", S), ("motivo", S), ("run_id", S),
    ],
    "previsoes": [
        ("run_id", S), ("versao_id", S), ("unique_id", S), ("modelo", S), ("ultima_semana", D),
        ("ds", D), ("horizonte", I), ("yhat", F), ("gerado_em", TS), ("e_campeao", "BOOLEAN"),
    ],
}

DESCRICOES = {
    "execucoes": "Uma linha por execução do job (config, versão dos dados, status, tempos, decisão). "
                 "experimento preenchido = execução de teste, que não mexe no campeão nem nas previsões oficiais. "
                 "ultima_semana = última data com dados (dia ou semana, conforme a frequência da config).",
    "metricas": "Métricas do walk-forward por período (todas/selecao/holdout), modelo e horizonte "
                "(em períodos da frequência da config: dias ou semanas; 0 = todos os horizontes).",
    "metricas_serie": "Métricas do walk-forward por modelo e série (produto__cclasse).",
    "previsoes_cv": "Previsões do walk-forward: cada corte (cutoff) prevê as semanas seguintes.",
    "versoes": "Registry: cada execução gera uma versão candidata (modelo por série) e a decisão de promoção.",
    "versao_series": "Modelo escolhido para cada série em cada versão.",
    "producao": "Histórico de promoções e rollbacks. A linha mais recente é a versão em produção.",
    "previsoes": "Previsões das próximas semanas de todos os modelos; e_campeao marca o modelo em produção "
                 "(nulo em execuções antigas, que só gravavam o campeão).",
}

VIEWS = {
    "producao_atual": "SELECT * FROM `{ds}.producao` WHERE TRUE QUALIFY ROW_NUMBER() OVER (ORDER BY em DESC) = 1",
    "previsoes_atuais": """
        SELECT SPLIT(unique_id, '__c')[OFFSET(0)] AS produto,
               CAST(SPLIT(unique_id, '__c')[OFFSET(1)] AS INT64) AS classe,
               p.* REPLACE (IFNULL(e_campeao, TRUE) AS e_campeao)
        FROM `{ds}.previsoes` p
        WHERE run_id = (SELECT run_id FROM `{ds}.previsoes` ORDER BY gerado_em DESC LIMIT 1)
    """,
    # Custo estimado de cada execução no Cloud Run (preços Tier 1 de out/2026, sem a cota
    # gratuita mensal, que vale por conta de faturamento). Soma ~60 s de inicialização do
    # container, que o Cloud Run cobra e o Python não enxerga. Execuções mortas pelo sistema
    # (ex.: falta de memória) não gravam linha em execucoes e ficam de fora.
    "custo_execucoes": """
        WITH e AS (
          SELECT run_id, inicio, status, decisao, versao_codigo, origem,
                 8 AS vcpu,
                 IF(versao_codigo IN ('v0.1', 'v0.2', 'v0.3'), 8, 16) AS memoria_gib,
                 TIMESTAMP_DIFF(fim, inicio, SECOND) + 60 AS segundos_cobrados
          FROM `{ds}.execucoes`
          WHERE origem != 'local'
        )
        SELECT *,
               ROUND(segundos_cobrados * vcpu * 0.000024, 4) AS custo_cpu_usd,
               ROUND(segundos_cobrados * memoria_gib * 0.0000025, 4) AS custo_memoria_usd,
               ROUND(segundos_cobrados * (vcpu * 0.000024 + memoria_gib * 0.0000025), 4) AS custo_usd
        FROM e
    """,
}


class Registro:
    def __init__(self, cliente: bigquery.Client, cfg: dict):
        self.cliente = cliente
        self.dataset = f"{cfg['projeto']}.{cfg['dataset_mlops']}"
        self.local = cfg["local_bq"]

    def preparar(self) -> None:
        """Cria o dataset, as tabelas e as views se ainda não existirem (idempotente)."""
        ds = bigquery.Dataset(self.dataset)
        ds.location = self.local
        ds.description = "Resultados do pipeline de MLOps de previsão de preços (execuções, métricas, registry, previsões)."
        self.cliente.create_dataset(ds, exists_ok=True)
        for nome in ESQUEMAS:
            tabela = bigquery.Table(f"{self.dataset}.{nome}", schema=self._schema(nome))
            tabela.description = DESCRICOES[nome]
            tabela = self.cliente.create_table(tabela, exists_ok=True)
            # Tabelas criadas por versões antigas do pipeline ganham as colunas novas
            # antes das views, que podem depender delas.
            existentes = {c.name for c in tabela.schema}
            novas = [c for c in self._schema(nome) if c.name not in existentes]
            if novas:
                tabela.schema = [*tabela.schema, *novas]
                self.cliente.update_table(tabela, ["schema"])
                log.info("Colunas adicionadas em %s: %s", nome, [c.name for c in novas])
        for nome, sql in VIEWS.items():
            # Só recria a view se a definição mudou: várias execuções em paralelo (ex.: experimentos)
            # recriando a mesma view ao mesmo tempo podem entrar em conflito no BigQuery.
            definicao = sql.format(ds=self.dataset).strip()
            try:
                atual = self.cliente.get_table(f"{self.dataset}.{nome}").view_query
            except NotFound:
                atual = None
            if (atual or "").strip() != definicao:
                self.cliente.query(f"CREATE OR REPLACE VIEW `{self.dataset}.{nome}` AS {definicao}").result()

    def gravar(self, nome: str, df: pd.DataFrame) -> None:
        colunas = [c for c, _ in ESQUEMAS[nome]]
        df = df.reindex(columns=colunas)
        for coluna, tipo in ESQUEMAS[nome]:
            if tipo == D:
                df[coluna] = pd.to_datetime(df[coluna]).dt.date
        job_cfg = bigquery.LoadJobConfig(
            schema=self._schema(nome),
            write_disposition="WRITE_APPEND",
            # Permite acrescentar colunas novas a tabelas criadas por versões antigas do pipeline.
            schema_update_options=[bigquery.SchemaUpdateOption.ALLOW_FIELD_ADDITION],
        )
        self.cliente.load_table_from_dataframe(df, f"{self.dataset}.{nome}", job_config=job_cfg).result()
        log.info("Gravadas %d linhas em %s.%s", len(df), self.dataset, nome)

    def ultima_versao_dados(self) -> str | None:
        sql = (f"SELECT versao_dados FROM `{self.dataset}.execucoes` "
               "WHERE status = 'sucesso' AND experimento IS NULL ORDER BY inicio DESC LIMIT 1")
        linhas = list(self.cliente.query(sql).result())
        return linhas[0].versao_dados if linhas else None

    def campeao_atual(self) -> tuple[str, dict[str, str]]:
        """Versão em produção e o modelo de cada série. Sem promoção ainda, é o Naive em tudo."""
        linhas = list(self.cliente.query(f"SELECT versao_id FROM `{self.dataset}.producao_atual`").result())
        if not linhas or linhas[0].versao_id == VERSAO_NAIVE:
            return VERSAO_NAIVE, {}
        versao = linhas[0].versao_id
        return versao, self.atribuicao(versao)

    def atribuicao(self, versao: str) -> dict[str, str]:
        sql = f"SELECT unique_id, modelo FROM `{self.dataset}.versao_series` WHERE versao_id = @v"
        job_cfg = bigquery.QueryJobConfig(query_parameters=[bigquery.ScalarQueryParameter("v", "STRING", versao)])
        return {r.unique_id: r.modelo for r in self.cliente.query(sql, job_config=job_cfg).result()}

    @staticmethod
    def _schema(nome: str) -> list[bigquery.SchemaField]:
        return [bigquery.SchemaField(c, t) for c, t in ESQUEMAS[nome]]
