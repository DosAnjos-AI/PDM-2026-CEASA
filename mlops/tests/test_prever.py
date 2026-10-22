from pipeline.prever import atribuicao_de_producao


def test_modelo_fixo_vale_para_todas_as_series(cfg):
    cfg["campeao"]["modelo_fixo"] = "Chronos2"
    registrada = {"GO__tomate": "ARIMA"}
    assert atribuicao_de_producao(cfg, ["GO__tomate", "MS__tomate"], registrada) == {
        "GO__tomate": "Chronos2", "MS__tomate": "Chronos2",
    }


def test_sem_modelo_fixo_usa_a_versao_registrada_no_treino(cfg):
    registrada = {"GO__tomate": "ARIMA"}
    assert atribuicao_de_producao(cfg, ["GO__tomate", "MS__tomate"], registrada) == registrada
