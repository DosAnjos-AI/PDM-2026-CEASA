"""Inferência: prevê os próximos dias com o modelo em produção, sem avaliar nem trocar o campeão.

Disparada pelo Pub/Sub quando a ingestão termina (ver infra/inferencia_diaria.sh), ou na mão:
    python -m pipeline.prever                  # prevê se os dados mudaram desde a última previsão
    python -m pipeline.prever --forcar         # prevê mesmo sem dados novos
    python -m pipeline.prever --sem-gravar     # teste: não grava nada

Usa a versão em produção registrada pelo último treino (ou campeao.modelo_fixo) e os
hiperparâmetros encontrados nele (ex.: os do Optuna). Gera as previsões de todos os modelos ativos,
como o treino, para a aplicação continuar comparando-os; o campeão fica marcado em e_campeao.
"""
import argparse
import json
import logging
import os
import uuid
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

import pandas as pd
import yaml
from google.cloud import bigquery

from pipeline import campeao, dados, modelos, previsao
from pipeline.registro import Registro

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("prever")


def atribuicao_de_producao(cfg: dict, ids, registrada: dict[str, str]) -> dict[str, str]:
    """Modelo em produção de cada série: o fixado pela equipe, se houver, senão o registrado no treino."""
    fixo = cfg.get("campeao", {}).get("modelo_fixo")
    return {u: fixo for u in ids} if fixo else dict(registrada)


def main() -> None:
    args = argparse.ArgumentParser()
    args.add_argument("--config", default="config/treino.yaml")
    args.add_argument("--amostra", type=int, help="usa só as N primeiras séries (para testes)")
    args.add_argument("--sem-gravar", action="store_true", help="não grava nada no BigQuery")
    args.add_argument("--forcar", action="store_true", help="prevê mesmo se os dados não mudaram")
    args = args.parse_args()

    with open(args.config, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    agora = datetime.now(timezone.utc)
    run_id = agora.strftime("%Y%m%dT%H%M%S") + "_" + uuid.uuid4().hex[:6]
    execucao = {
        "run_id": run_id,
        "inicio": agora,
        "origem": os.environ.get("CLOUD_RUN_EXECUTION", "local"),
        "versao_codigo": os.environ.get("VERSAO_CODIGO", "dev"),
        "modelos": ",".join(modelos.ativos(cfg)),
        "config": json.dumps(cfg, ensure_ascii=False),
        "tipo": "inferencia",
    }
    log.info("Inferência %s (origem=%s)", run_id, execucao["origem"])

    cliente = bigquery.Client(project=cfg["projeto"])
    registro = None if args.sem_gravar else Registro(cliente, cfg)
    if registro:
        registro.preparar()

    try:
        hoje = datetime.now(ZoneInfo(cfg["fuso"])).date()
        brutos, clima_bruto = dados.carregar(cliente, cfg, hoje)
        dados.verificar_atraso(brutos, cfg, hoje)
        df, resumo = dados.selecionar_series(brutos, cfg)
        if args.amostra:
            df = df[df["unique_id"].isin(df["unique_id"].unique()[: args.amostra])]
            resumo.update(series_usadas=int(df["unique_id"].nunique()), linhas=len(df))
        execucao.update(
            versao_dados=dados.versao_dados(df),
            ultima_semana=resumo["ultima_data"],
            series_usadas=resumo["series_usadas"],
            linhas=resumo["linhas"],
        )

        # Previsões já publicadas (por um treino ou por outra inferência) com estes mesmos dados.
        publicada = registro.ultima_versao_dados(("treino", "inferencia")) if registro else None
        if not args.forcar and execucao["versao_dados"] == publicada:
            log.info("As previsões publicadas já usam estes dados (%s); nada a fazer.", publicada)
            execucao["status"] = "sem_dados_novos"
            return

        versao, registrada = registro.campeao_atual() if registro else (campeao.VERSAO_NAIVE, {})
        atribuicao = atribuicao_de_producao(cfg, df["unique_id"].unique(), registrada)
        hiperparametros = registro.hiperparametros_do_ultimo_treino() if registro else {}
        precisa_clima = any(cfg["modelos"][m].get("clima") for m in modelos.ativos(cfg))
        clima = dados.preparar_clima(cliente, cfg, df, clima_bruto) if precisa_clima else None

        futuras = previsao.gerar(df, clima, cfg, atribuicao, hiperparametros)
        log.info("Previsões: %d linhas, %d séries, dados até %s, versão em produção %s",
                 len(futuras), futuras["unique_id"].nunique(), resumo["ultima_data"], versao)
        execucao.update(status="sucesso", hiperparametros=json.dumps(hiperparametros))
        if registro:
            registro.gravar("previsoes", futuras.assign(
                run_id=run_id, versao_id=versao, gerado_em=datetime.now(timezone.utc)))
    except Exception as erro:
        execucao.update(status="falhou", erro=repr(erro)[:2000])
        log.exception("Inferência %s falhou", run_id)
        raise
    finally:
        execucao["fim"] = datetime.now(timezone.utc)
        if registro:
            registro.gravar("execucoes", pd.DataFrame([execucao]))


if __name__ == "__main__":
    main()
