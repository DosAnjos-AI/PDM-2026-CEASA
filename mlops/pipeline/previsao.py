"""Previsão dos próximos períodos com todos os modelos, marcando o campeão em produção."""
import logging

import pandas as pd

from pipeline import modelos
from pipeline.campeao import NAIVE
from pipeline.dados import passo

log = logging.getLogger(__name__)


def gerar(df: pd.DataFrame, clima: pd.DataFrame | None, cfg: dict, atribuicao: dict[str, str],
          hiperparametros: dict) -> pd.DataFrame:
    """Previsões de todos os modelos ativos, a partir da última data de cada série.

    `e_campeao` marca, em cada série, o modelo em produção. Guardar todos os modelos (e não só
    o campeão) permite comparar na aplicação o que cada um prevê.
    """
    ativos = modelos.ativos(cfg)
    if NAIVE not in ativos:
        raise ValueError("o Naive precisa estar ativo: ele é o campeão padrão e o substituto de modelos desativados")
    d = passo(cfg)
    # Publica mais horizontes do que os avaliados quando configurado (ex.: cada dia até 14).
    horizontes = cfg["validacao"].get("horizontes_previsao") or cfg["validacao"]["horizontes"]
    ultimo = df.groupby("unique_id")["ds"].max()
    escolha = {u: atribuicao.get(u, NAIVE) for u in ultimo.index}
    escolha = {u: (m if m in ativos else NAIVE) for u, m in escolha.items()}

    partes = []
    for nome in ativos:
        previsor = modelos.criar(nome, cfg, hiperparametros.get(nome))
        previsor.abrir()
        try:
            p = previsor.prever(df, ultimo.index, max(horizontes), clima)
        finally:
            previsor.fechar()
        partes.append(p.assign(modelo=nome))
        log.info("Previsão futura com %s concluída", nome)

    out = pd.concat(partes, ignore_index=True)
    out["ultima_semana"] = out["unique_id"].map(ultimo)   # último dado de cada série (dia ou semana)
    out["horizonte"] = ((out["ds"] - out["ultima_semana"]) / d).round().astype(int)
    out = out[out["horizonte"].isin(horizontes)].reset_index(drop=True)
    out["e_campeao"] = out["modelo"] == out["unique_id"].map(escolha)
    return out
