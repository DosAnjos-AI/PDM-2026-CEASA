"""Foundation models (Chronos) da Amazon.

Os modelos não são treinados com os nossos dados (zero-shot): recebem o histórico disponível e
preveem os períodos seguintes. Os pesos ficam dentro da imagem Docker (ver Dockerfile), então a
execução não depende do Hugging Face.
"""
import gc
import logging

import pandas as pd

log = logging.getLogger(__name__)


class Chronos:
    def __init__(self, repo: str, freq: str, lote: int = 32, contexto: int | None = None):
        self.repo, self.freq = repo, freq
        # Séries por lote de inferência. O padrão da biblioteca (256) estourou 8 GiB no
        # Chronos-T5, que gera 20 amostras por série.
        self.lote = lote
        # Quantos períodos de histórico o modelo recebe (None = o padrão do modelo).
        self.contexto = contexto
        self._pipe = None

    def carregar(self) -> None:
        import torch
        from chronos import BaseChronosPipeline

        log.info("Carregando %s", self.repo)
        self._pipe = BaseChronosPipeline.from_pretrained(self.repo, device_map="cpu", torch_dtype=torch.float32)

    def liberar(self) -> None:
        self._pipe = None
        gc.collect()

    def prever(self, historico: pd.DataFrame, h: int, clima: pd.DataFrame | None = None) -> pd.DataFrame:
        """Prevê h períodos a partir da última data de cada série.

        Colunas de `historico` além de unique_id/ds/y são covariáveis (só o Chronos-2 as usa);
        com `clima`, os valores das datas futuras entram como covariáveis conhecidas.
        """
        if self._pipe is None:
            raise RuntimeError("chame carregar() antes de prever()")
        if self.contexto:
            historico = historico.groupby("unique_id", sort=False).tail(self.contexto)
        kwargs = {}
        if clima is not None:
            kwargs["future_df"] = self._grade_futura(historico, h).merge(clima, on=["unique_id", "ds"], how="left")
        p = self._pipe.predict_df(
            historico, id_column="unique_id", timestamp_column="ds", target="y",
            prediction_length=h, quantile_levels=[0.5], freq=self.freq, batch_size=self.lote, **kwargs,
        )
        return p[["unique_id", "ds", "predictions"]].rename(columns={"predictions": "yhat"})

    def _grade_futura(self, historico: pd.DataFrame, h: int) -> pd.DataFrame:
        """Os h períodos seguintes à última data de cada série."""
        ultimas = historico.groupby("unique_id")["ds"].max()
        partes = [
            pd.DataFrame({"unique_id": uid, "ds": pd.date_range(fim, periods=h + 1, freq=self.freq)[1:]})
            for uid, fim in ultimas.items()
        ]
        return pd.concat(partes, ignore_index=True)
