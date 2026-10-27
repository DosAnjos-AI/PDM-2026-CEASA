"""O CSS e as etiquetas precisam sobreviver ao sanitizador do st.html (DOMPurify)."""
import re

import pytest

import estilo


def test_css_nao_tem_nada_parecido_com_tag():
    # O DOMPurify descarta o <style> inteiro se o texto dele tiver "<" seguido de letra ou "/":
    # a página perderia todo o visual dos cartões.
    assert not re.search(r"<[/\w]", estilo.CSS + estilo.CSS_ICONES)
    assert all(f".icone-{nome}" in estilo.CSS_ICONES for nome in estilo.ICONES)


def test_etiqueta_usa_o_icone_do_css_e_escapa_o_texto():
    html = estilo.etiqueta("pico <R$ 8,18>", "pico", dica="Maior preço")
    assert html == ('<span class="etiqueta icone icone-pico" title="Maior preço">pico &lt;R$ 8,18&gt;</span>')
    with pytest.raises(ValueError):
        estilo.etiqueta("texto", "icone_que_nao_existe")
