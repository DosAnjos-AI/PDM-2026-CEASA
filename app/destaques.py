"""Destaques do preço de um produto, mostrados em pílulas no cartão da página de previsões.

Funções puras sobre o histórico diário (colunas ds e y), testáveis sem o BigQuery.
"""
import pandas as pd

MESES = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro",
         "outubro", "novembro", "dezembro"]
MESES_CURTOS = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]


def janela(hist: pd.DataFrame, fim: pd.Timestamp, dias: int) -> pd.DataFrame:
    """Trecho do histórico nos `dias` que terminam em `fim` (inclusive)."""
    return hist[(hist["ds"] > fim - pd.Timedelta(days=dias)) & (hist["ds"] <= fim)].dropna(subset=["y"])


def tendencia(hist: pd.DataFrame, fim: pd.Timestamp, dias: int = 91, media: int = 7) -> float | None:
    """Variação da média dos últimos `media` dias contra a mesma média `dias` antes.

    A média de uma semana evita que um dia fora da curva decida se o preço está em alta.
    """
    agora = janela(hist, fim, media)["y"].mean()
    antes = janela(hist, fim - pd.Timedelta(days=dias), media)["y"].mean()
    if pd.isna(agora) or pd.isna(antes) or antes <= 0:
        return None
    return agora / antes - 1


def extremos(hist: pd.DataFrame, fim: pd.Timestamp, dias: int = 730) -> dict | None:
    """Pico, mínima (com as datas), média e variação entre os dois nos últimos `dias`."""
    trecho = janela(hist, fim, dias)
    if trecho.empty:
        return None
    pico = trecho.loc[trecho["y"].idxmax()]
    minima = trecho.loc[trecho["y"].idxmin()]
    return {
        "pico": float(pico["y"]), "data_pico": pd.Timestamp(pico["ds"]),
        "minima": float(minima["y"]), "data_minima": pd.Timestamp(minima["ds"]),
        "media": float(trecho["y"].mean()),
        "variacao": float(pico["y"] / minima["y"] - 1) if minima["y"] > 0 else None,
    }


def mes_mais_barato(hist: pd.DataFrame, fim: pd.Timestamp, anos: int = 5) -> int | None:
    """Mês (1 a 12) em que o preço costuma ser mais baixo, nos últimos `anos` anos completos.

    Cada mês é comparado com a média do próprio ano, para a inflação e os anos caros não pesarem.
    Precisa de pelo menos 2 anos com os 12 meses.
    """
    trecho = hist[hist["ds"].dt.year.between(fim.year - anos, fim.year - 1)].dropna(subset=["y"])
    mensal = trecho.groupby([trecho["ds"].dt.year.rename("ano"), trecho["ds"].dt.month.rename("mes")])["y"].mean()
    meses_por_ano = mensal.groupby(level="ano").size()
    completos = meses_por_ano[meses_por_ano == 12].index
    if len(completos) < 2:
        return None
    mensal = mensal[mensal.index.get_level_values("ano").isin(completos)]
    relativo = mensal / mensal.groupby(level="ano").transform("mean")
    return int(relativo.groupby(level="mes").mean().idxmin())


def comparar_ceasas(todas: pd.DataFrame | None, ceasa: str, fim: pd.Timestamp, tolerancia: int = 7) -> dict | None:
    """O mesmo produto nas outras CEASAs, no último dia com dado de cada uma (até `tolerancia` dias antes de `fim`).

    Devolve a outra CEASA mais barata e quanto ela é mais barata (negativo: esta CEASA já é a mais barata).
    CEASAs sem dado recente (como a MS atrasada) ficam de fora.
    """
    if todas is None or todas.empty:
        return None
    recentes = todas[(todas["ds"] <= fim) & (todas["ds"] > fim - pd.Timedelta(days=tolerancia))].dropna(subset=["y"])
    ultimos = recentes.sort_values("ds").groupby("ceasa")["y"].last()
    if ceasa not in ultimos.index or len(ultimos) < 2 or ultimos[ceasa] <= 0:
        return None
    outra = ultimos.drop(ceasa).idxmin()
    return {"ceasa": outra, "preco": float(ultimos[outra]), "diferenca": float(1 - ultimos[outra] / ultimos[ceasa]),
            "n_ceasas": int(len(ultimos))}


def mes_ano(data: pd.Timestamp) -> str:
    """2025-05-14 -> mai/25"""
    return f"{MESES_CURTOS[data.month - 1]}/{data:%y}"
