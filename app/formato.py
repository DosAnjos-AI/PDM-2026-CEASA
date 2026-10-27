"""Nomes, números e cores usados em todas as páginas."""
import re

import pandas as pd

# Mesma paleta do artigo e do diagrama de arquitetura.
REAL = "#1f2421"
FOLHA = "#2f6b4f"
TERRA = "#a8612a"
CEU = "#3b6b8f"
SUAVE = "#8b938c"
RUIM = "#a33a32"
HOLDOUT = "rgba(168, 97, 42, 0.10)"

CORES = {
    "Naive": "#5d655f",
    "Chronos2_clima": FOLHA,
    "Chronos2": "#6fa184",
    "ChronosBolt": "#9cc2aa",
    "ChronosT5": "#c3dccb",
    "ARIMA": CEU,
    "SARIMA": "#7fa3c2",
    "ETS": "#5b86ad",
    "Theta": "#9db5cc",
    "LightGBM_direto": TERRA,
    "LightGBM": "#c68953",
    "LightGBM_clima": "#d9a678",
    "LightGBM_otimizado": "#7f4519",
    "Ridge": "#8a6a86",
    "SeasonalNaive": "#b5b5b5",
}

CORES_CEASA = {"GO": FOLHA, "MG": CEU, "ES": TERRA, "SC": "#8a6a86", "MS": "#b08d2e"}

CEASAS = {
    "GO": "CEASA-GO · Goiânia",
    "MG": "CEASA-MG · Grande BH",
    "ES": "CEASA-ES · Grande Vitória",
    "SC": "CEASA-SC · São José",
    "MS": "CEASA-MS · Campo Grande",
}

DESCRICAO_MODELO = {
    "Naive": "repete o último preço",
    "SeasonalNaive": "repete o preço de 1 ano antes",
    "ARIMA": "modelo estatístico clássico",
    "SARIMA": "ARIMA com sazonalidade anual",
    "ETS": "suavização exponencial",
    "Theta": "método Theta com sazonalidade",
    "LightGBM": "árvores de decisão (gradient boosting)",
    "LightGBM_direto": "LightGBM com um modelo por horizonte",
    "LightGBM_clima": "LightGBM direto com clima",
    "LightGBM_otimizado": "LightGBM com clima e ajuste automático (Optuna)",
    "Ridge": "regressão linear",
    "Chronos2": "foundation model da Amazon (2025)",
    "Chronos2_clima": "Chronos-2 recebendo o clima",
    "ChronosBolt": "Chronos 1ª geração, versão rápida",
    "ChronosT5": "Chronos 1ª geração, original",
}

_FORMATO_ANTIGO = re.compile(r"^(?P<produto>.+)__c(?P<classe>\d+)$")


def cor(modelo: str) -> str:
    return CORES.get(modelo, SUAVE)


def dividir(unique_id: str) -> tuple[str, str, str | None]:
    """(CEASA, produto, classe) de uma série.

    Formato atual: GO__tomate_longa_vida. Formato semanal antigo: tomate_longa_vida__c1 (só GO).
    """
    antigo = _FORMATO_ANTIGO.match(unique_id)
    if antigo:
        return "GO", antigo["produto"], antigo["classe"]
    ceasa, _, produto = unique_id.partition("__")
    return ceasa, produto, None


def com_partes(df: pd.DataFrame) -> pd.DataFrame:
    """Acrescenta as colunas ceasa e produto a partir de unique_id."""
    if df.empty:
        return df.assign(ceasa=pd.Series(dtype=str), produto=pd.Series(dtype=str))
    partes = df["unique_id"].map(dividir)
    return df.assign(ceasa=partes.str[0], produto=partes.str[1])


def nome_produto(produto: str) -> str:
    return produto.replace("_", " ").capitalize()


def nome_serie(unique_id: str) -> str:
    """GO__tomate_longa_vida -> Tomate longa vida · GO"""
    ceasa, produto, classe = dividir(unique_id)
    return f"{nome_produto(produto)} · " + (f"classe {classe}" if classe else ceasa)


def diario(cfg: dict) -> bool:
    return cfg["fonte"]["frequencia"] == "D"


def rotulo_horizonte(h: int, cfg: dict) -> str:
    if diario(cfg):
        return f"{h} dia" if h == 1 else f"{h} dias"
    return f"{h} semana" if h == 1 else f"{h} semanas"


def unidade(cfg: dict) -> str:
    return "R$/kg" if cfg["fonte"]["tipo"] == "silver_unificado" else "R$ por embalagem (caixa, saco, maço…)"


def brl(valor: float) -> str:
    if pd.isna(valor):
        return "—"
    return "R$ " + f"{valor:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


def pct(valor: float, sinal: bool = True) -> str:
    if pd.isna(valor):
        return "—"
    texto = f"{valor * 100:+.1f}%" if sinal else f"{valor * 100:.1f}%"
    return texto.replace(".", ",")


def data(valor) -> str:
    return "—" if pd.isna(valor) else pd.Timestamp(valor).strftime("%d/%m/%Y")


def hora_local(valor) -> pd.Timestamp:
    """Timestamp do BigQuery (UTC) no horário de Brasília."""
    ts = pd.Timestamp(valor)
    ts = ts.tz_localize("UTC") if ts.tzinfo is None else ts
    return ts.tz_convert("America/Sao_Paulo")


def data_hora_local(valor) -> str:
    """Timestamps do BigQuery vêm em UTC; mostra no horário de Brasília."""
    if pd.isna(valor):
        return "—"
    return hora_local(valor).strftime("%d/%m/%Y %H:%M")


def layout_grafico(fig, altura: int = 440):
    """Aparência comum dos gráficos Plotly."""
    fig.update_layout(
        height=altura,
        margin=dict(l=10, r=10, t=30, b=10),
        hovermode="x unified",
        legend=dict(orientation="h", yanchor="top", y=-0.12, xanchor="left", x=0),
        plot_bgcolor="rgba(0,0,0,0)",
        paper_bgcolor="rgba(0,0,0,0)",
        font=dict(size=13),
    )
    fig.update_xaxes(showgrid=False)
    fig.update_yaxes(gridcolor="rgba(128,128,128,0.18)", zeroline=False)
    return fig
