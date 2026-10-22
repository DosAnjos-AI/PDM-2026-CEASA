"""As configurações versionadas precisam ser coerentes antes de chegar ao Cloud Run."""
from pathlib import Path

import pytest
import yaml

from pipeline import modelos
from pipeline.treinar import aplicar_janela

PASTA_CONFIG = Path(__file__).resolve().parents[1] / "config"
CONFIGS = sorted(PASTA_CONFIG.glob("*.yaml"))


def carregar(caminho: Path) -> dict:
    return yaml.safe_load(caminho.read_text(encoding="utf-8"))


@pytest.mark.parametrize("caminho", CONFIGS, ids=lambda p: p.name)
def test_config_coerente(caminho):
    cfg = carregar(caminho)
    ativos = modelos.ativos(cfg)
    val = cfg["validacao"]
    publicados = val.get("horizontes_previsao", val["horizontes"])

    assert "Naive" in ativos, "o Naive é o campeão padrão e o substituto de modelos desativados"
    assert set(val["horizontes"]) <= set(publicados)
    assert 0 < val["janelas_holdout"] < val["janelas"]
    if any(cfg["modelos"][m].get("clima") for m in ativos):
        assert cfg["clima"]["defasagem"] >= max(publicados), "clima com defasagem menor que o horizonte vaza o futuro"
    fixo = cfg.get("campeao", {}).get("modelo_fixo")
    if fixo:
        assert fixo in ativos
    for nome in ativos:
        modelos.criar(nome, cfg)   # monta sem erro (o Chronos só carrega os pesos em abrir())


def test_janela_anos_vale_para_todos_os_modelos_que_treinam():
    cfg = carregar(PASTA_CONFIG / "treino.yaml")
    aplicar_janela(cfg, 2)
    assert cfg["estatisticos"]["janela_treino"] == 730
    assert cfg["features_ml"]["janela_treino"] == 730
    assert cfg["modelos"]["ARIMA"]["janela_treino"] == 730            # janela própria também é substituída
    assert {m["contexto"] for m in cfg["modelos"].values() if m.get("tipo") == "chronos"} == {730}
