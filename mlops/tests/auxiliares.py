"""Modelo falso para testar o walk-forward e a previsão sem treinar nada."""
import pandas as pd

from pipeline import modelos


class PrevisorFalso(modelos.Previsor):
    """Repete o último preço de cada série e registra o que recebeu em cada chamada."""

    def __init__(self, nome: str = "Falso", incremento: float = 0.0):
        self.nome, self.freq, self.usa_clima = nome, "D", False
        self.incremento = incremento
        self.chamadas: list[tuple[pd.Timestamp, set]] = []

    def prever(self, treino, ids, h, clima):
        self.chamadas.append((treino["ds"].max(), set(ids)))
        ultimos = treino[treino["unique_id"].isin(ids)].groupby("unique_id").agg(ds=("ds", "max"), y=("y", "last"))
        return pd.DataFrame([
            {"unique_id": uid, "ds": linha.ds + pd.Timedelta(days=i), "yhat": linha.y + self.incremento * i}
            for uid, linha in ultimos.iterrows() for i in range(1, h + 1)
        ])
