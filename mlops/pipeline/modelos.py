"""Modelos candidatos com uma interface comum: prever(treino, séries, h, clima).

Cada chamada treina com `treino` (só dados até a data de corte) e prevê os próximos `h`
períodos das séries pedidas, a partir da última data de cada uma. O walk-forward e a previsão
final usam essa mesma interface para todas as famílias de modelos.
"""
import os

import lightgbm as lgb
import numpy as np
import pandas as pd
from mlforecast import MLForecast
from mlforecast.lag_transforms import RollingMean
from mlforecast.target_transforms import Differences, GlobalSklearnTransformer
from sklearn.linear_model import Ridge
from sklearn.preprocessing import FunctionTransformer
from statsforecast import StatsForecast
from statsforecast.models import AutoARIMA, AutoETS, AutoTheta, Naive, SeasonalNaive

from pipeline.dados import com_clima
from pipeline.fundacao import Chronos

# No Cloud Run os.cpu_count() pode enxergar mais núcleos que os vCPUs do job.
N_JOBS = int(os.environ.get("N_JOBS", "-1"))

ESTATISTICOS = {
    "Naive": lambda s: Naive(alias="Naive"),
    "SeasonalNaive": lambda s: SeasonalNaive(season_length=s, alias="SeasonalNaive"),
    "ARIMA": lambda s: AutoARIMA(season_length=1, alias="ARIMA"),
    "SARIMA": lambda s: AutoARIMA(season_length=s, alias="SARIMA"),
    "ETS": lambda s: AutoETS(season_length=1, alias="ETS"),
    "Theta": lambda s: AutoTheta(season_length=s, alias="Theta"),
}

ML = {
    "lightgbm": lambda params: lgb.LGBMRegressor(**params),
    "ridge": lambda params: Ridge(**params),
}


def semana_do_ano(datas):
    return datas.isocalendar().week.to_numpy().astype(int)


DATAS = {"semana_do_ano": semana_do_ano}  # demais nomes (dayofweek, month…) são atributos do pandas


def ativos(cfg: dict) -> list[str]:
    return [nome for nome, m in cfg["modelos"].items() if m.get("ativo")]


def otimizavel(nome: str, cfg: dict) -> bool:
    return "otimizar" in cfg["modelos"][nome]


def _ultimos(df: pd.DataFrame, n: int | None) -> pd.DataFrame:
    """Últimos n períodos de cada série (limita o custo de treino em séries longas)."""
    return df if not n else df.groupby("unique_id", sort=False).tail(n)


class Previsor:
    def __init__(self, nome: str, cfg: dict):
        self.nome, self.cfg = nome, cfg
        self.mcfg = cfg["modelos"][nome]
        self.usa_clima = self.mcfg.get("clima", False)
        self.freq = cfg["fonte"]["frequencia"]

    def abrir(self) -> None:
        """Prepara recursos caros (pesos do Chronos) antes de uma sequência de previsões."""

    def fechar(self) -> None:
        """Libera os recursos de abrir()."""

    def prever(self, treino: pd.DataFrame, ids, h: int, clima: pd.DataFrame | None) -> pd.DataFrame:
        raise NotImplementedError


class Estatistico(Previsor):
    def prever(self, treino, ids, h, clima):
        dados = treino.loc[treino["unique_id"].isin(ids), ["unique_id", "ds", "y"]]
        janela = self.mcfg.get("janela_treino", self.cfg.get("estatisticos", {}).get("janela_treino"))
        dados = _ultimos(dados, janela)
        modelo = ESTATISTICOS[self.nome](self.cfg["fonte"]["sazonalidade"])
        sf = StatsForecast(models=[modelo], freq=self.freq, n_jobs=N_JOBS, fallback_model=Naive())
        p = sf.forecast(df=dados, h=h)
        return p.rename(columns={self.nome: "yhat"})[["unique_id", "ds", "yhat"]]


class AprendizadoDeMaquina(Previsor):
    def __init__(self, nome, cfg, params=None):
        super().__init__(nome, cfg)
        self.params = {**self.mcfg.get("params", {}), **(params or {})}
        self.direta = self.mcfg.get("estrategia", "recursiva") == "direta"

    def _mlforecast(self) -> MLForecast:
        feats = self.cfg["features_ml"]
        log_preco = GlobalSklearnTransformer(FunctionTransformer(func=np.log1p, inverse_func=np.expm1))
        return MLForecast(
            models={self.nome: ML[self.mcfg["tipo"]](self.params)},
            freq=self.freq,
            lags=feats["lags"],
            lag_transforms={1: [RollingMean(window_size=j) for j in feats["medias_moveis"]]},
            date_features=[DATAS.get(nome, nome) for nome in feats["datas"]],
            # O modelo aprende a variação percentual, então um único modelo serve para
            # produtos baratos e caros e para todas as CEASAs.
            target_transforms=[log_preco, Differences([1])],
        )

    def prever(self, treino, ids, h, clima):
        # Modelo global: aprende com todas as séries disponíveis até o corte, inclusive as que
        # não serão previstas (ex.: uma CEASA atrasada), e prevê só as pedidas.
        dados = treino[["unique_id", "ds", "y"]]
        dados = _ultimos(dados, self.cfg["features_ml"].get("janela_treino"))
        if self.usa_clima:
            dados = com_clima(dados, clima)
        mlf = self._mlforecast()
        kwargs = {"static_features": []}
        if self.direta:
            # Um modelo por horizonte avaliado (ex.: 3, 7 e 14 dias), em vez de um por dia.
            kwargs["horizons"] = [x for x in self.cfg["validacao"]["horizontes"] if x <= h]
        mlf.fit(dados, **kwargs)
        futuro = None
        if self.usa_clima:
            futuro = mlf.make_future_dataframe(h)
            futuro = com_clima(futuro[futuro["unique_id"].isin(ids)], clima)
        p = mlf.predict(h, ids=list(ids), X_df=futuro)
        return p.rename(columns={self.nome: "yhat"})[["unique_id", "ds", "yhat"]]


class Fundacao(Previsor):
    def __init__(self, nome, cfg):
        super().__init__(nome, cfg)
        self.chronos = Chronos(self.mcfg["repo"], self.freq, lote=self.mcfg.get("lote", 32),
                               contexto=self.mcfg.get("contexto"))

    def abrir(self):
        self.chronos.carregar()

    def fechar(self):
        self.chronos.liberar()

    def prever(self, treino, ids, h, clima):
        historico = treino.loc[treino["unique_id"].isin(ids), ["unique_id", "ds", "y"]]
        if self.usa_clima:
            historico = com_clima(historico, clima)
        return self.chronos.prever(historico, h, clima if self.usa_clima else None)


def criar(nome: str, cfg: dict, params: dict | None = None) -> Previsor:
    """Monta o modelo `nome`; `params` sobrescreve os hiperparâmetros do yaml (ex.: os do Optuna)."""
    if nome in ESTATISTICOS:
        return Estatistico(nome, cfg)
    tipo = cfg["modelos"][nome]["tipo"]
    if tipo == "chronos":
        return Fundacao(nome, cfg)
    return AprendizadoDeMaquina(nome, cfg, params)
