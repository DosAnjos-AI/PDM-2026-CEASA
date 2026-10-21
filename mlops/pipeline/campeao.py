"""Champion–challenger com um modelo por série.

A cada execução nasce uma versão candidata: para cada série, o modelo com menor MAE nas
janelas de seleção (desde que ganhe do Naive por uma margem). A candidata e o campeão em
produção são comparados nas janelas de holdout, que não participaram da escolha.
"""
import pandas as pd

NAIVE = "Naive"
# Campeão padrão: Naive em todas as séries. Vale antes da primeira promoção e pode ser
# restaurado com rollback.
VERSAO_NAIVE = "naive"


def _erro_abs(prev: pd.DataFrame) -> pd.Series:
    return (prev["y"] - prev["yhat"]).abs()


def candidata(prev: pd.DataFrame, cfg: dict) -> pd.DataFrame:
    sel = prev[prev["periodo"] == "selecao"]
    mae = sel.assign(erro=_erro_abs(sel)).groupby(["unique_id", "modelo"])["erro"].mean().unstack()

    naive = mae[NAIVE]
    melhor = mae.idxmin(axis=1)
    vence = mae.min(axis=1) <= naive * (1 - cfg["campeao"]["margem_serie"])
    modelo = melhor.where(vence, NAIVE)

    return pd.DataFrame({
        "unique_id": mae.index,
        "modelo": modelo.values,
        "mae_selecao": [mae.at[u, m] for u, m in modelo.items()],
        "mae_selecao_naive": naive.values,
    })


def versao_fixa(prev: pd.DataFrame, modelo: str) -> pd.DataFrame:
    """Versão com o mesmo modelo em todas as séries (modelo definido pela equipe no yaml)."""
    if modelo not in set(prev["modelo"]):
        raise ValueError(f"campeao.modelo_fixo = {modelo}, mas esse modelo não está ativo")
    sel = prev[prev["periodo"] == "selecao"]
    mae = sel.assign(erro=_erro_abs(sel)).groupby(["unique_id", "modelo"])["erro"].mean().unstack()
    return pd.DataFrame({
        "unique_id": mae.index,
        "modelo": modelo,
        "mae_selecao": mae[modelo].values,
        "mae_selecao_naive": mae[NAIVE].values,
    })


def mae_estrategia(hold: pd.DataFrame, atribuicao: dict[str, str]) -> float:
    """MAE no holdout usando, em cada série, o modelo atribuído (Naive se faltar ou estiver desativado)."""
    escolha = hold["unique_id"].map(lambda u: atribuicao.get(u, NAIVE))
    escolha = escolha.where(escolha.isin(set(hold["modelo"])), NAIVE)
    usadas = hold[hold["modelo"] == escolha]
    return float(_erro_abs(usadas).mean())


def decidir(prev: pd.DataFrame, cand: pd.DataFrame, versao_atual: str, atual: dict[str, str], cfg: dict) -> dict:
    hold = prev[prev["periodo"] == "holdout"]
    sel = prev[prev["periodo"] == "selecao"]

    # Referência: o melhor modelo único (o mesmo para todas as séries) escolhido na seleção.
    unico = _erro_abs(sel).groupby(sel["modelo"]).mean().idxmin()

    mae_cand = mae_estrategia(hold, dict(zip(cand["unique_id"], cand["modelo"])))
    mae_atual = mae_estrategia(hold, atual)
    mae_naive = mae_estrategia(hold, {})
    mae_unico = mae_estrategia(hold, {u: unico for u in hold["unique_id"].unique()})

    limiar = cfg["campeao"]["limiar_promocao"]
    ganho = 1 - mae_cand / mae_atual
    if mae_cand > mae_naive:
        decisao, motivo = "rejeitada", f"erra mais que o Naive no holdout ({mae_cand:.3f} > {mae_naive:.3f})"
    elif ganho >= limiar:
        decisao, motivo = "promovida", f"erra {ganho:.1%} menos que o campeão {versao_atual} no holdout (limiar {limiar:.0%})"
    else:
        decisao, motivo = "rejeitada", f"ganho de {ganho:.1%} sobre o campeão {versao_atual} não atinge o limiar de {limiar:.0%}"

    return {
        "n_series": int(len(cand)),
        "modelos_usados": cand["modelo"].value_counts().to_json(),
        "mae_holdout_candidata": mae_cand,
        "campeao_anterior": versao_atual,
        "mae_holdout_campeao": mae_atual,
        "mae_holdout_naive": mae_naive,
        "melhor_modelo_unico": unico,
        "mae_holdout_modelo_unico": mae_unico,
        "decisao": decisao,
        "motivo": motivo,
    }
