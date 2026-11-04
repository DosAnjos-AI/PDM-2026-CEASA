"""Previsão dos próximos períodos com os modelos publicados, marcando o campeão em produção."""
import logging
from datetime import date

import pandas as pd

from pipeline import modelos
from pipeline.campeao import NAIVE
from pipeline.dados import grupo, passo, periodos_de_atraso

log = logging.getLogger(__name__)


def publicados(cfg: dict, atribuicao: dict[str, str]) -> list[str]:
    """Modelos que publicam previsões, na ordem do yaml.

    São os de inferencia.modelos (todos os ativos, se a seção não existir), mais o Naive e o modelo
    em produção de cada série: assim toda série tem o seu campeão entre as previsões publicadas.
    """
    ativos = modelos.ativos(cfg)
    if NAIVE not in ativos:
        raise ValueError("o Naive precisa estar ativo: ele é o campeão padrão e o substituto de modelos desativados")
    lista = cfg.get("inferencia", {}).get("modelos", ativos)
    fora = sorted(set(lista) - set(ativos))
    if fora:
        raise ValueError(f"inferencia.modelos tem modelos que não estão ativos: {fora}")
    escolhidos = {*lista, NAIVE, *(m for m in atribuicao.values() if m in ativos)}
    return [m for m in ativos if m in escolhidos]


def gerar(df: pd.DataFrame, clima: pd.DataFrame | None, cfg: dict, atribuicao: dict[str, str],
          hiperparametros: dict, hoje: date | None = None) -> pd.DataFrame:
    """Previsões dos modelos publicados (ver publicados) para os próximos períodos a partir de hoje.

    Cada série é prevista a partir da sua última data. Numa série atualizada isso já são os
    próximos 14 dias; numa de CEASA atrasada (ex.: MS parada em 02/10), o modelo prevê também os
    dias que faltam até hoje e só os 14 a partir de hoje são publicados, com `horizonte` contado
    a partir do último dado. Sem `hoje`, toda série publica os 14 dias seguintes à sua última data.

    `e_campeao` marca, em cada série, o modelo em produção. Guardar outros modelos além do
    campeão permite comparar na aplicação o que cada um prevê.
    """
    ativos = modelos.ativos(cfg)
    d = passo(cfg)
    # Publica mais horizontes do que os avaliados quando configurado (ex.: cada dia até 14).
    horizontes = cfg["validacao"].get("horizontes_previsao") or cfg["validacao"]["horizontes"]
    ultimo = df.groupby("unique_id")["ds"].max()
    extra = periodos_de_atraso(ultimo, hoje, cfg)
    limite = cfg.get("inferencia", {}).get("atraso_maximo")
    if limite:
        demais = extra[extra > limite]
        if not demais.empty:
            por_ceasa = demais.groupby(demais.index.map(lambda u: grupo(u, cfg))).size().to_dict()
            log.warning("Sem previsão para %d séries com o último dado a mais de %d períodos de hoje: %s",
                        len(demais), limite, por_ceasa)
            ultimo, extra = ultimo.drop(demais.index), extra.drop(demais.index)
    escolha = {u: atribuicao.get(u, NAIVE) for u in ultimo.index}
    escolha = {u: (m if m in ativos else NAIVE) for u, m in escolha.items()}

    partes = []
    for nome in publicados(cfg, escolha):
        previsor = modelos.criar(nome, cfg, hiperparametros.get(nome))
        previsor.abrir()
        try:
            # Uma chamada por atraso: as séries atualizadas são previstas como antes, sem as atrasadas.
            for atraso, ids in extra.groupby(extra).groups.items():
                if atraso and getattr(previsor, "direta", False):
                    log.info("%s só prevê os horizontes treinados; fica sem as %d séries atrasadas", nome, len(ids))
                    continue
                p = previsor.prever(df, ids, max(horizontes) + int(atraso), clima)
                partes.append(p.assign(modelo=nome))
        finally:
            previsor.fechar()
        log.info("Previsão futura com %s concluída", nome)

    out = pd.concat(partes, ignore_index=True)
    out["ultima_semana"] = out["unique_id"].map(ultimo)   # último dado de cada série (dia ou semana)
    out["horizonte"] = ((out["ds"] - out["ultima_semana"]) / d).round().astype(int)
    # Horizontes publicados contados a partir de hoje; nas séries atualizadas, igual ao último dado.
    out = out[(out["horizonte"] - out["unique_id"].map(extra)).isin(horizontes)].reset_index(drop=True)
    out["e_campeao"] = out["modelo"] == out["unique_id"].map(escolha)
    return out
