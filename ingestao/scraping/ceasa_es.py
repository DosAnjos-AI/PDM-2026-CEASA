#!/usr/bin/env python3
"""
Coletor dos boletins diarios da CEASA-ES (3 mercados: Grande Vitoria, Noroeste e Cachoeiro de Itapemirim).

Sistema Scriptcase: a logica de coleta e extracao fica em scriptcase.py,
compartilhada com ceasa_mg.py. Aqui so a configuracao da sede.

Historico disponivel no site: Noroeste desde 2010, Cachoeiro desde 2015,
Grande Vitoria desde nov/2021.

Uso:
    python3 ingestao/scraping/ceasa_es.py                          # tudo
    python3 ingestao/scraping/ceasa_es.py --inicio 2026-01-01
    python3 ingestao/scraping/ceasa_es.py --mercados 211
    python3 ingestao/scraping/ceasa_es.py --so-extrair             # refaz o CSV sem acessar o site
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scriptcase  # noqa: E402
from comum import DIR_DADOS  # noqa: E402

# ------------------------------------------------------------ configuracao

CONFIG = {
    "fonte": "CEASA-ES",
    "filtro": "http://200.198.51.71/detec/filtro_boletim_es/filtro_boletim_es.php",
    "boletim": "http://200.198.51.71/detec/boletim_completo_es/boletim_completo_es.php",
    "bruto": DIR_DADOS / "cotacoes_es",
    "saida": DIR_DADOS / "cotacoes_es.csv",
}

if __name__ == "__main__":
    sys.exit(scriptcase.main(CONFIG))
