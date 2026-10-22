"""Job de MLOps: avalia os modelos, decide a promoção do campeão e gera as previsões.

Uso:
    python -m pipeline.treinar                                   # execução normal (produção)
    python -m pipeline.treinar --forcar                          # roda mesmo sem dados novos
    python -m pipeline.treinar --experimento so_go --config X    # teste: grava métricas, não mexe na produção
    python -m pipeline.treinar --amostra 10 --sem-gravar         # teste rápido, não grava nada
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

from pipeline import avaliacao, campeao, dados, modelos, previsao
from pipeline.registro import Registro

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("treinar")


def aplicar_janela(cfg: dict, anos: float) -> None:
    """Mesma janela de histórico para todos os modelos que treinam (o Naive não depende dela).

    Cada série usa no máximo `anos` de histórico; séries mais curtas usam o que tiverem.
    """
    periodos = round(anos * (365 if cfg["fonte"]["frequencia"] == "D" else 52))
    cfg.setdefault("estatisticos", {})["janela_treino"] = periodos
    cfg["features_ml"]["janela_treino"] = periodos
    for modelo in cfg["modelos"].values():
        if modelo.get("tipo") == "chronos":
            modelo["contexto"] = periodos
        if "janela_treino" in modelo:   # janela própria de um modelo (ex.: ARIMA) também é substituída
            modelo["janela_treino"] = periodos
    log.info("Janela de histórico: %s anos (%d períodos) em todos os modelos", anos, periodos)


def main() -> None:
    args = argparse.ArgumentParser()
    args.add_argument("--config", default="config/treino.yaml")
    args.add_argument("--amostra", type=int, help="usa só as N primeiras séries (para testes)")
    args.add_argument("--sem-gravar", action="store_true", help="não grava nada no BigQuery")
    args.add_argument("--forcar", action="store_true", help="roda mesmo se os dados não mudaram desde a última execução")
    args.add_argument("--experimento", help="rótulo de uma execução de teste: grava métricas e walk-forward, "
                                            "mas não decide promoção nem publica previsões")
    args.add_argument("--janela-anos", type=float,
                      help="usa a mesma janela de histórico (em anos) em todos os modelos que treinam: "
                           "estatísticos, ML e contexto do Chronos")
    args.add_argument("--so-verificar", action="store_true",
                      help="só lê os dados e roda as checagens (ex.: CEASA atrasada), sem treinar")
    args = args.parse_args()

    with open(args.config, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    if args.janela_anos:
        aplicar_janela(cfg, args.janela_anos)

    agora = datetime.now(timezone.utc)
    run_id = agora.strftime("%Y%m%dT%H%M%S") + "_" + uuid.uuid4().hex[:6]
    execucao = {
        "run_id": run_id,
        "inicio": agora,
        "origem": os.environ.get("CLOUD_RUN_EXECUTION", "local"),
        "versao_codigo": os.environ.get("VERSAO_CODIGO", "dev"),
        "modelos": ",".join(modelos.ativos(cfg)),
        "config": json.dumps(cfg, ensure_ascii=False),
        "experimento": args.experimento,
    }
    log.info("Execução %s (origem=%s, experimento=%s)", run_id, execucao["origem"], args.experimento)

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

        if args.so_verificar:
            execucao["status"] = "verificacao"
            return

        producao = not args.experimento
        if registro and producao and not args.forcar and execucao["versao_dados"] == registro.ultima_versao_dados():
            log.info("Dados iguais aos da última execução bem-sucedida (%s); nada a fazer.", execucao["versao_dados"])
            execucao["status"] = "sem_dados_novos"
            return

        precisa_clima = any(cfg["modelos"][m].get("clima") for m in modelos.ativos(cfg))
        clima = dados.preparar_clima(cliente, cfg, df, clima_bruto) if precisa_clima else None

        # 1. Avaliação walk-forward de todos os modelos
        prev, tempos, hiperparametros = avaliacao.walk_forward(df, clima, cfg)
        metricas, por_serie = avaliacao.resumir(prev)
        geral = metricas[(metricas["periodo"] == "todas") & (metricas["horizonte"] == 0)]
        log.info("Métricas gerais:\n%s", geral.to_string(index=False))
        execucao.update(tempos_s=json.dumps(tempos), hiperparametros=json.dumps(hiperparametros))

        if producao:
            # 2. Champion–challenger (ou o modelo definido pela equipe em campeao.modelo_fixo)
            versao_atual, atribuicao_atual = registro.campeao_atual() if registro else (campeao.VERSAO_NAIVE, {})
            fixo = cfg["campeao"].get("modelo_fixo")
            if fixo:
                cand = campeao.versao_fixa(prev, fixo)
                decisao = campeao.decidir(prev, cand, versao_atual, atribuicao_atual, cfg)
                ganho = 1 - decisao["mae_holdout_candidata"] / decisao["mae_holdout_naive"]
                decisao.update(
                    decisao="fixada",
                    motivo=f"{fixo} definido pela equipe (campeao.modelo_fixo); no holdout erra "
                           f"{abs(ganho):.1%} {'menos' if ganho >= 0 else 'mais'} que o Naive",
                )
            else:
                cand = campeao.candidata(prev, cfg)
                decisao = campeao.decidir(prev, cand, versao_atual, atribuicao_atual, cfg)
            log.info("Decisão: %s — %s", decisao["decisao"], decisao["motivo"])
            if decisao["decisao"] in ("promovida", "fixada"):
                atribuicao_prod = dict(zip(cand["unique_id"], cand["modelo"]))
                versao_prod = run_id
            else:
                versao_prod, atribuicao_prod = versao_atual, atribuicao_atual

            # 3. Previsão dos próximos períodos com todos os modelos (o campeão fica marcado)
            futuras = previsao.gerar(df, clima, cfg, atribuicao_prod, hiperparametros)
            execucao["decisao"] = decisao["decisao"]

        execucao["status"] = "sucesso"
        if registro:
            registro.gravar("previsoes_cv", prev.assign(run_id=run_id))
            registro.gravar("metricas", metricas.assign(run_id=run_id))
            registro.gravar("metricas_serie", por_serie.assign(run_id=run_id))
            if producao:
                registro.gravar("versoes", pd.DataFrame([{**decisao, "versao_id": run_id, "run_id": run_id, "criado_em": agora}]))
                registro.gravar("versao_series", cand.assign(versao_id=run_id))
                if decisao["decisao"] in ("promovida", "fixada"):
                    registro.gravar("producao", pd.DataFrame([{
                        "em": datetime.now(timezone.utc), "versao_id": run_id,
                        "tipo": "promocao" if decisao["decisao"] == "promovida" else "fixacao",
                        "motivo": decisao["motivo"], "run_id": run_id,
                    }]))
                registro.gravar("previsoes", futuras.assign(
                    run_id=run_id, versao_id=versao_prod, gerado_em=datetime.now(timezone.utc)))
    except Exception as erro:
        execucao.update(status="falhou", erro=repr(erro)[:2000])
        log.exception("Execução %s falhou", run_id)
        raise
    finally:
        execucao["fim"] = datetime.now(timezone.utc)
        if registro:
            registro.gravar("execucoes", pd.DataFrame([execucao]))


if __name__ == "__main__":
    main()
