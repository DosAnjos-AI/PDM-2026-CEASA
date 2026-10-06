#!/usr/bin/env python3
"""
Coletor dos boletins diarios da CEASA-MG (7 mercados: Grande BH, Juiz de Fora, Uberlandia, Caratinga, Gov. Valadares, Barbacena e Uberaba).

Sistema Scriptcase: a logica de coleta e extracao fica em scriptcase.py,
compartilhada com ceasa_es.py. Aqui so a configuracao da sede.

Historico disponivel no site: out/2021 em diante nos 7 mercados (Barbacena
tem tambem um bloco isolado de 2006).

Uso:
    python3 ingestao/scraping/ceasa_mg.py                          # tudo
    python3 ingestao/scraping/ceasa_mg.py --inicio 2026-01-01
    python3 ingestao/scraping/ceasa_mg.py --mercados 214,218
    python3 ingestao/scraping/ceasa_mg.py --so-extrair             # refaz o CSV sem acessar o site
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scriptcase  # noqa: E402
from comum import DIR_DADOS  # noqa: E402

# ------------------------------------------------------------ configuracao

CONFIG = {
    "fonte": "CEASA-MG",
    "filtro": "https://minas1.ceasa.mg.gov.br/detec/filtro_boletim/filtro_boletim_mob.php",
    "boletim": "https://minas1.ceasa.mg.gov.br/detec/boletim_completo/boletim_completo.php",
    "bruto": DIR_DADOS / "cotacoes_mg",
    "saida": DIR_DADOS / "cotacoes_mg.csv",
}

if __name__ == "__main__":
    sys.exit(scriptcase.main(CONFIG))
