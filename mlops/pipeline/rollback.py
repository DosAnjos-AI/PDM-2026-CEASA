"""Volta a produção para uma versão anterior do campeão.

Uso:
    python -m pipeline.rollback --listar
    python -m pipeline.rollback --versao 20261016T134152_9420cc --motivo "previsões estranhas"
    python -m pipeline.rollback --versao naive --motivo "voltar ao baseline"

A próxima execução do job já gera as previsões com a versão escolhida.
"""
import argparse
import logging
from datetime import datetime, timezone

import pandas as pd
import yaml
from google.cloud import bigquery

from pipeline.campeao import VERSAO_NAIVE
from pipeline.registro import Registro

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("rollback")


def main() -> None:
    args = argparse.ArgumentParser()
    args.add_argument("--config", default="config/treino.yaml")
    args.add_argument("--versao", help=f"versao_id de mlops.versoes, ou '{VERSAO_NAIVE}' para o baseline")
    args.add_argument("--motivo", default="rollback manual")
    args.add_argument("--listar", action="store_true", help="mostra o histórico de produção e sai")
    args = args.parse_args()

    with open(args.config, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    cliente = bigquery.Client(project=cfg["projeto"])
    registro = Registro(cliente, cfg)

    if args.listar or not args.versao:
        sql = f"""
            SELECT p.em, p.tipo, p.versao_id, v.mae_holdout_candidata, p.motivo
            FROM `{registro.dataset}.producao` p
            LEFT JOIN `{registro.dataset}.versoes` v USING (versao_id)
            ORDER BY p.em DESC LIMIT 20
        """
        print(cliente.query(sql).to_dataframe().to_string(index=False))
        return

    if args.versao != VERSAO_NAIVE and not registro.atribuicao(args.versao):
        raise SystemExit(f"Versão {args.versao} não existe em {registro.dataset}.versao_series")

    anterior, _ = registro.campeao_atual()
    registro.gravar("producao", pd.DataFrame([{
        "em": datetime.now(timezone.utc), "versao_id": args.versao, "tipo": "rollback",
        "motivo": f"{args.motivo} (antes: {anterior})", "run_id": None,
    }]))
    log.info("Produção: %s -> %s", anterior, args.versao)


if __name__ == "__main__":
    main()
