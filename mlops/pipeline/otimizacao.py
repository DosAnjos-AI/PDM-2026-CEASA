"""Busca de hiperparâmetros do LightGBM com Optuna.

Quem chama fornece a função de avaliação (um walk-forward só com dados anteriores ao primeiro
corte), então os parâmetros escolhidos nunca veem os períodos em que os modelos são comparados.
"""
import logging
from collections.abc import Callable

import optuna

log = logging.getLogger(__name__)
optuna.logging.set_verbosity(optuna.logging.WARNING)


def espaco_lightgbm(trial: optuna.Trial) -> dict:
    return {
        "n_estimators": trial.suggest_int("n_estimators", 100, 800, step=100),
        "learning_rate": trial.suggest_float("learning_rate", 0.01, 0.1, log=True),
        "num_leaves": trial.suggest_int("num_leaves", 15, 127, log=True),
        "min_child_samples": trial.suggest_int("min_child_samples", 10, 100, log=True),
        "colsample_bytree": trial.suggest_float("colsample_bytree", 0.5, 1.0),
        "reg_lambda": trial.suggest_float("reg_lambda", 1e-3, 10.0, log=True),
    }


def otimizar(nome: str, cfg: dict, avaliar: Callable[[dict], float]) -> tuple[dict, float]:
    """Devolve (melhores parâmetros, erro médio da busca); `avaliar(params)` devolve o MAE."""
    ocfg = cfg["modelos"][nome]["otimizar"]
    estudo = optuna.create_study(direction="minimize", sampler=optuna.samplers.TPESampler(seed=42))
    estudo.optimize(lambda trial: avaliar(espaco_lightgbm(trial)), n_trials=ocfg["trials"], timeout=ocfg.get("timeout_s"))
    log.info("%s: %d trials, melhor MAE %.3f com %s", nome, len(estudo.trials), estudo.best_value, estudo.best_params)
    return estudo.best_params, estudo.best_value
