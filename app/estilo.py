"""Aparência da aplicação: CSS comum e os cartões em HTML da página de previsões.

As cores seguem a paleta de formato.py (a mesma do artigo e do diagrama de arquitetura); a fonte e
o fundo vêm do tema em .streamlit/config.toml.
"""
from html import escape
from urllib.parse import quote

import streamlit as st

CSS = """
h1 { letter-spacing: -0.02em; }
/* A fonte do tema é mais larga que a padrão: sem isso, valores como "Chronos2 em tudo" ficam cortados. */
[data-testid="stMetricValue"] { font-size: clamp(1.2rem, 1.6vw, 1.45rem); }

.cartao {
  background: #ffffff;
  border: 1px solid #e8ebe6;
  border-radius: 28px;
  box-shadow: 0 12px 32px rgba(31, 36, 33, 0.07);
  padding: 2.2rem 2.5rem 2rem;
  margin: 0.4rem 0 1.2rem;
  color: #1f2421;
}
.cartao .titulo {
  margin: 0; padding: 0; color: #1f2421;
  font-size: clamp(2rem, 4.2vw, 3.1rem); font-weight: 800; letter-spacing: -0.025em; line-height: 1.08;
}
.cartao .titulo em { font-style: normal; color: #2f6b4f; }
.cartao .subtitulo {
  margin: 0.7rem 0 0; color: #6b746d;
  font-size: 0.86rem; font-weight: 700; letter-spacing: 0.12em; text-transform: uppercase;
}
.cartao .rotulo {
  margin: 1.9rem 0 0.4rem; color: #6b746d;
  font-size: 0.74rem; font-weight: 800; letter-spacing: 0.1em; text-transform: uppercase;
}
.cartao .rotulo:first-child { margin-top: 0; }
.cartao .linha-preco { display: flex; flex-wrap: wrap; align-items: center; gap: 0.6rem 1.1rem; }
.cartao .preco { font-size: clamp(2.6rem, 6vw, 4rem); font-weight: 800; letter-spacing: -0.03em; line-height: 1; }
.cartao .preco small { margin-left: 0.08em; color: #98a29a; font-size: 0.42em; font-weight: 600; letter-spacing: 0; }
.cartao .pilula {
  display: inline-block; border-radius: 999px; padding: 0.55rem 1.1rem; background: #f0f2ee; color: #1f2421;
  font-size: 1.02rem; font-weight: 700;
}
.cartao .frase { margin: 1.1rem 0 0.3rem; color: #2e3530; font-size: 1.03rem; font-weight: 600; line-height: 1.5; }
.cartao .frase strong { color: #1f2421; font-weight: 800; }
.cartao .nota { margin: 0; color: #6b746d; font-size: 0.95rem; line-height: 1.5; }
.cartao .resultado {
  margin: 1.1rem 0 0; padding: 0.85rem 1.1rem; border-radius: 16px; background: #e6f2eb; color: #24533d;
  font-weight: 600; line-height: 1.5;
}
.cartao hr { margin: 1.5rem 0 1.25rem; border: none; border-top: 1px solid #e8ebe6; }
.cartao .etiquetas { display: flex; flex-wrap: wrap; gap: 0.6rem; }
.cartao .etiqueta {
  display: inline-flex; align-items: center; gap: 0.45rem; border-radius: 999px; padding: 0.5rem 0.95rem;
  background: #f0f2ee; color: #3a423c; font-size: 0.93rem; font-weight: 600; line-height: 1.2;
}
/* O ícone é uma máscara pintada com a cor do texto: o st.html remove elementos svg, mas mantém o CSS. */
.cartao .icone::before {
  content: ""; width: 1.05em; height: 1.05em; flex: none; background-color: currentColor;
  -webkit-mask: var(--icone) center / contain no-repeat; mask: var(--icone) center / contain no-repeat;
}
.cartao .alta { background: #fbeceb; color: #a33a32; }
.cartao .queda { background: #e6f2eb; color: #2f6b4f; }
.cartao .escolhida { background: #2f6b4f; color: #ffffff; }
@media (max-width: 640px) {
  .cartao { padding: 1.5rem 1.25rem 1.4rem; border-radius: 22px; }
}
"""

# Ícones de traço simples (grade de 24 x 24). Só a forma importa: a cor vem da etiqueta.
ICONES = {
    "alta": '<polyline points="3 17 9 11 13 15 21 7"/><polyline points="15 7 21 7 21 13"/>',
    "queda": '<polyline points="3 7 9 13 13 9 21 17"/><polyline points="15 17 21 17 21 11"/>',
    "estavel": '<line x1="3" y1="12" x2="21" y2="12"/><polyline points="16 7 21 12 16 17"/>',
    "pico": '<path d="M12 6 19 18H5z" fill="black" stroke="none"/>',
    "minima": '<path d="M12 18 5 6h14z" fill="black" stroke="none"/>',
    "variacao": '<line x1="12" y1="3" x2="12" y2="21"/><polyline points="8 7 12 3 16 7"/>'
                '<polyline points="8 17 12 21 16 17"/>',
    "mapa": '<path d="M12 21s-7-6.1-7-11a7 7 0 0 1 14 0c0 4.9-7 11-7 11z"/><circle cx="12" cy="10" r="2.5"/>',
    "calendario": '<rect x="3" y="5" width="18" height="16" rx="2"/><line x1="3" y1="10" x2="21" y2="10"/>'
                  '<line x1="8" y1="3" x2="8" y2="7"/><line x1="16" y1="3" x2="16" y2="7"/>',
    "relogio": '<circle cx="12" cy="12" r="9"/><polyline points="12 7 12 12 15.5 14"/>',
}


def _mascara(desenho: str) -> str:
    """O ícone como data URI de SVG, para a máscara do CSS."""
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="black" '
           f'stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">{desenho}</svg>')
    return f'url("data:image/svg+xml,{quote(svg)}")'


CSS_ICONES = "\n".join(f".cartao .icone-{nome} {{ --icone: {_mascara(desenho)}; }}" for nome, desenho in ICONES.items())


def aplicar() -> None:
    """Coloca o CSS comum na página (app.py chama a cada execução).

    O st.html passa pelo DOMPurify, que descarta o bloco inteiro se o texto do CSS tiver algo
    parecido com uma tag (um sinal de menor seguido de letra): por isso os ícones vão codificados.
    """
    st.html(f"<style>{CSS}{CSS_ICONES}</style>")


def negrito(texto: str) -> str:
    return f"<strong>{escape(texto)}</strong>"


def etiqueta(texto: str, icone: str, tom: str = "", dica: str = "") -> str:
    """Pílula com ícone. tom: "" (neutro), "alta", "queda" ou "escolhida"; dica aparece ao passar o mouse."""
    if icone not in ICONES:
        raise ValueError(f"ícone desconhecido: {icone}")
    classes = " ".join(c for c in ["etiqueta", "icone", f"icone-{icone}", tom] if c)
    titulo = f' title="{escape(dica)}"' if dica else ""
    return f'<span class="{classes}"{titulo}>{escape(texto)}</span>'


def cartao(*, rotulo: str, valor: str, unidade: str = "", titulo: str = "", subtitulo: str = "", pilula: str = "",
           tom_pilula: str = "", frase: str = "", nota: str = "", resultado: str = "",
           etiquetas: list[str] | None = None) -> str:
    """Cartão com um valor em destaque, no estilo de ficha de produto.

    `titulo`, `frase`, `nota` e `resultado` já vêm em HTML (com negrito() nos trechos variáveis);
    os demais textos são escapados aqui.
    """
    partes = ['<div class="cartao">']
    if titulo:
        partes.append(f'<h2 class="titulo">{titulo}</h2>')
    if subtitulo:
        partes.append(f'<p class="subtitulo">{escape(subtitulo)}</p>')
    partes.append(f'<p class="rotulo">{escape(rotulo)}</p>')
    pilula_html = f'<span class="pilula {tom_pilula}">{escape(pilula)}</span>' if pilula else ""
    partes.append(f'<div class="linha-preco"><span class="preco">{escape(valor)}<small>{escape(unidade)}</small></span>'
                  f'{pilula_html}</div>')
    if frase:
        partes.append(f'<p class="frase">{frase}</p>')
    if nota:
        partes.append(f'<p class="nota">{nota}</p>')
    if resultado:
        partes.append(f'<p class="resultado">{resultado}</p>')
    if etiquetas:
        partes.append('<hr><div class="etiquetas">' + "".join(etiquetas) + "</div>")
    partes.append("</div>")
    return "".join(partes)
