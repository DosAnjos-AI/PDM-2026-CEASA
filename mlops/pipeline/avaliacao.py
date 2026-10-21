"""Walk-forward comum a todos os modelos e cálculo das métricas.

Os cortes são datas do calendário, iguais para todas as séries: em cada corte o modelo treina
com o que existia até aquela data (de todas as CEASAs) e prevê as séries que têm dado naquele
dia. Uma CEASA atrasada simplesmente deixa de ser prevista nos cortes posteriores ao seu
último dado.
"""
import logging
import time

import numpy as np
import pandas as pd

from pipeline import modelos, otimizacao
from pipeline.dados import passo

log = logging.getLogger(__name__)


def pico_memoria() -> str:
    """Pico de memória do processo principal (só no Linux, ou seja, no Cloud Run)."""
    try:
        import resource
    except ImportError:
        return "n/d"
    return f"{resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024**2:.1f} GiB"


def cortes(df: pd.DataFrame, cfg: dict, janelas: int | None = None) -> list[pd.Timestamp]:
    """Datas de corte: a última fica `maior horizonte` antes do fim dos dados; as outras, a cada `passo`."""
    val, d = cfg["validacao"], passo(cfg)
    ultimo = df["ds"].max() - max(val["horizontes"]) * d
    if cfg["fonte"]["frequencia"] == "D":
        # Na silver, sábado e domingo são interpolados entre o preço de sexta e o de segunda:
        # um corte no fim de semana já "enxergaria" parte do preço de segunda. Por isso o
        # corte cai sempre num dia útil (e todos no mesmo dia da semana).
        while ultimo.dayofweek >= 5:
            ultimo -= d
    n = janelas or val["janelas"]
    return [ultimo - i * val["passo"] * d for i in reversed(range(n))]


def avaliar(previsor: modelos.Previsor, df: pd.DataFrame, clima: pd.DataFrame | None,
            datas_corte: list[pd.Timestamp], cfg: dict) -> pd.DataFrame:
    """Previsões de um modelo em cada corte, só nos horizontes configurados, com o valor real."""
    d, horizontes = passo(cfg), cfg["validacao"]["horizontes"]
    h = max(horizontes)
    partes = []
    previsor.abrir()
    try:
        for corte in datas_corte:
            treino = df[df["ds"] <= corte]
            ultimo = treino.groupby("unique_id")["ds"].max()
            ids = ultimo.index[ultimo == corte]   # séries com dado no dia do corte
            alvo = df[df["unique_id"].isin(ids) & (df["ds"] > corte) & (df["ds"] <= corte + h * d)]
            if alvo.empty:
                continue
            p = previsor.prever(treino, ids, h, clima)
            p["horizonte"] = ((p["ds"] - corte) / d).round().astype(int)
            p = p[p["horizonte"].isin(horizontes)]
            partes.append(p.merge(alvo[["unique_id", "ds", "y"]], on=["unique_id", "ds"]).assign(cutoff=corte))
    finally:
        previsor.fechar()
    return pd.concat(partes, ignore_index=True)


def erro_medio(prev: pd.DataFrame) -> float:
    return float((prev["y"] - prev["yhat"]).abs().mean())


def walk_forward(df: pd.DataFrame, clima: pd.DataFrame | None, cfg: dict) -> tuple[pd.DataFrame, dict, dict]:
    """Roda todos os modelos ativos nos mesmos cortes.

    Devolve as previsões em formato longo, o tempo de cada modelo e os hiperparâmetros
    encontrados pelo Optuna (para reusar na previsão final).
    """
    val = cfg["validacao"]
    datas_corte = cortes(df, cfg)
    log.info("Walk-forward: %d cortes de %s a %s", len(datas_corte), datas_corte[0].date(), datas_corte[-1].date())
    previsoes, tempos, hiperparametros = [], {}, {}

    for nome in modelos.ativos(cfg):
        inicio = time.perf_counter()

        params = None
        if modelos.otimizavel(nome, cfg):
            # A busca usa só dados até o 1º corte: os parâmetros nunca veem as semanas avaliadas.
            ajuste = df[df["ds"] <= datas_corte[0]]
            cortes_ajuste = cortes(ajuste, cfg, janelas=cfg["modelos"][nome]["otimizar"]["janelas"])
            params, _ = otimizacao.otimizar(
                nome, cfg,
                lambda p: erro_medio(avaliar(modelos.criar(nome, cfg, p), ajuste, clima, cortes_ajuste, cfg)),
            )
            hiperparametros[nome] = params

        prev = avaliar(modelos.criar(nome, cfg, params), df, clima, datas_corte, cfg)
        tempos[nome] = round(time.perf_counter() - inicio, 1)
        log.info("%s concluído em %.1fs (pico de memória até aqui: %s)", nome, tempos[nome], pico_memoria())
        previsoes.append(prev.assign(modelo=nome))

    prev = pd.concat(previsoes, ignore_index=True)
    inicio_holdout = datas_corte[-val["janelas_holdout"]]
    prev["periodo"] = np.where(prev["cutoff"] >= inicio_holdout, "holdout", "selecao")
    return prev, tempos, hiperparametros


def _metricas(g: pd.DataFrame) -> pd.Series:
    erro = g["y"] - g["yhat"]
    sq_total = ((g["y"] - g["y"].mean()) ** 2).sum()
    return pd.Series({
        "n": len(g),
        "mae": erro.abs().mean(),
        "rmse": np.sqrt((erro**2).mean()),
        "wape": erro.abs().sum() / g["y"].abs().sum(),
        "r2": 1 - (erro**2).sum() / sq_total if sq_total > 0 else np.nan,
    })


def _por_horizonte(prev: pd.DataFrame) -> pd.DataFrame:
    por_h = prev.groupby(["modelo", "horizonte"]).apply(_metricas, include_groups=False).reset_index()
    geral = prev.groupby("modelo").apply(_metricas, include_groups=False).reset_index().assign(horizonte=0)
    metricas = pd.concat([geral, por_h], ignore_index=True)

    # Comparação com o Naive no mesmo horizonte: positivo = modelo erra menos.
    mae_naive = metricas[metricas["modelo"] == "Naive"].set_index("horizonte")["mae"]
    metricas["ganho_vs_naive"] = 1 - metricas["mae"] / metricas["horizonte"].map(mae_naive)
    return metricas


def resumir(prev: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Métricas por período x modelo x horizonte (horizonte 0 = todos) e por modelo x série.

    Períodos: "todas" as janelas, "selecao" (usadas para escolher modelos) e "holdout"
    (usadas só para decidir a promoção).
    """
    partes = {"todas": prev, "selecao": prev[prev["periodo"] == "selecao"], "holdout": prev[prev["periodo"] == "holdout"]}
    metricas = pd.concat([_por_horizonte(p).assign(periodo=nome) for nome, p in partes.items()], ignore_index=True)
    metricas["n"] = metricas["n"].astype(int)

    por_serie = prev.groupby(["modelo", "unique_id"]).apply(_metricas, include_groups=False).reset_index()
    por_serie["n"] = por_serie["n"].astype(int)
    return metricas.sort_values(["periodo", "horizonte", "mae"]), por_serie
