"""Gera docs/arquitetura.png: diagrama didático do pipeline de MLOps.

Uso: python docs/gerar_arquitetura.py   (requer matplotlib)
"""
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.patches import Circle, FancyArrowPatch, FancyBboxPatch

PAPEL = "#fbfaf7"
TINTA = "#1f2421"
SUAVE = "#5d655f"
LINHA = "#d5d9d1"
FOLHA = "#2f6b4f"
FOLHA_CLARA = "#e2eee5"
TERRA = "#a8612a"
TERRA_CLARA = "#f5e7da"
CEU = "#3b6b8f"
CEU_CLARA = "#e1ebf3"

fig = plt.figure(figsize=(16, 9), dpi=150)
fig.patch.set_facecolor(PAPEL)
ax = fig.add_axes([0, 0, 1, 1])
ax.set_xlim(0, 16)
ax.set_ylim(0, 9)
ax.axis("off")


def caixa(x, y, w, h, fundo, borda, raio=0.18, lw=1.6):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle=f"round,pad=0,rounding_size={raio}",
                                facecolor=fundo, edgecolor=borda, linewidth=lw))


def texto(x, y, s, tam=12, cor=TINTA, peso="normal", ha="left", va="top", **kw):
    ax.text(x, y, s, fontsize=tam, color=cor, fontweight=peso, ha=ha, va=va, linespacing=1.35, **kw)


def seta(x1, y1, x2, y2, cor=SUAVE, rotulo=None, rx=0, ry=0.18):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>", mutation_scale=22,
                                 color=cor, linewidth=2.2, shrinkA=0, shrinkB=0))
    if rotulo:
        texto((x1 + x2) / 2 + rx, (y1 + y2) / 2 + ry, rotulo, tam=10, cor=cor, ha="center", va="bottom", style="italic")


def etiqueta(x, y, s, cor):
    texto(x, y, s.upper(), tam=9.5, cor=cor, peso="bold")


# Título
texto(0.6, 8.55, "Como funciona o pipeline de previsão de preços", tam=24, peso="bold")
texto(0.6, 7.95, "CEASAs de GO, MG, ES, SC e MS  ·  Google Cloud  ·  roda sozinho, sem ninguém apertar botão", tam=13, cor=SUAVE)

# 1. Agendador
caixa(0.6, 5.45, 2.7, 1.75, CEU_CLARA, CEU)
etiqueta(0.85, 7.0, "Cloud Scheduler", CEU)
texto(0.85, 6.6, "Despertador", tam=15, peso="bold")
texto(0.85, 6.15, "Toda terça às 16:00\nmanda o job rodar", tam=11.5, cor=SUAVE)

# 2. Dados
caixa(0.6, 1.5, 2.7, 3.45, FOLHA_CLARA, FOLHA)
etiqueta(0.85, 4.75, "BigQuery", FOLHA)
texto(0.85, 4.35, "Dados de entrada", tam=15, peso="bold")
texto(0.85, 3.85, "Preço diário por kg\nem 5 CEASAs:\nGO, MG, ES, SC e MS\n(camada silver)", tam=11.5, cor=SUAVE)
texto(0.85, 2.3, "Clima de cada estado\n(médias de 60 dias)", tam=11.5, cor=SUAVE)

# 3. Job
caixa(4.15, 1.0, 6.75, 6.35, "#ffffff", TINTA, raio=0.25, lw=2)
etiqueta(4.45, 7.15, "Cloud Run Job · liga, executa e desliga", TINTA)
texto(4.45, 6.75, "Job de treino (toda terça-feira)", tam=15, peso="bold")

passos = [
    ("Tem dado novo?", "Se não tiver, encerra em poucos segundos."),
    ("Treina e testa 13 modelos", "Naive, ARIMA, LightGBM, Chronos…\nsimulando 13 rodadas no passado (walk-forward)."),
    ("Escolhe o campeão", "Só troca o modelo em produção se ele acertar mais\nem dias que não foram usados na escolha (holdout)."),
    ("Prevê 3, 7 e 14 dias à frente", "Com todos os modelos, para as 120 séries (CEASA × produto)."),
]
y = 6.15
for i, (titulo, desc) in enumerate(passos, start=1):
    altura = 1.12 if "\n" in desc else 0.9
    caixa(4.45, y - altura, 6.15, altura, PAPEL, LINHA, raio=0.12, lw=1.2)
    ax.add_patch(Circle((4.88, y - altura / 2), 0.25, facecolor=FOLHA, edgecolor="none"))
    texto(4.88, y - altura / 2, str(i), tam=13, cor="white", peso="bold", ha="center", va="center")
    texto(5.3, y - 0.14, titulo, tam=12.5, peso="bold")
    texto(5.3, y - 0.48, desc, tam=10.5, cor=SUAVE)
    if i < len(passos):
        seta(7.5, y - altura - 0.02, 7.5, y - altura - 0.2, cor=LINHA)
    y -= altura + 0.22

# 4. Resultados
caixa(11.75, 1.5, 2.25, 5.7, TERRA_CLARA, TERRA)
etiqueta(12.0, 7.0, "BigQuery · mlops", TERRA)
texto(12.0, 6.6, "Resultados", tam=15, peso="bold")
itens = [
    ("Previsões", "3, 7 e 14 dias"),
    ("Métricas", "erro de cada modelo"),
    ("Versões", "quem é o campeão\ne por quê"),
    ("Custos", "quanto custou\ncada execução"),
]
yy = 6.05
for nome, desc in itens:
    texto(12.0, yy, nome, tam=12, peso="bold")
    texto(12.0, yy - 0.33, desc, tam=10.5, cor=SUAVE)
    yy -= 1.08 if "\n" in desc else 0.85

# 5. Uso
caixa(14.5, 2.6, 1.25, 3.5, "#ffffff", LINHA)
etiqueta(14.62, 5.9, "Uso", SUAVE)
texto(14.62, 5.45, "Dashboard", tam=11.5, peso="bold")
texto(14.62, 4.55, "Relatório", tam=11.5, peso="bold")
texto(14.62, 3.65, "API\n(opcional)", tam=11.5, peso="bold")

# Setas principais
seta(3.3, 6.3, 4.15, 6.3, cor=CEU, rotulo="dispara")
seta(3.3, 3.2, 4.15, 3.2, cor=FOLHA, rotulo="lê")
seta(10.9, 4.3, 11.75, 4.3, cor=TERRA, rotulo="grava")
seta(14.0, 4.3, 14.5, 4.3, cor=SUAVE)

# Rodapé
chips = [
    "Nenhuma máquina fica ligada entre execuções",
    "≈ US$ 0,31 por execução (~21 min)",
    "Tudo registrado: versões, métricas e custos",
]
x = 0.6
for c in chips:
    largura = 0.105 * len(c) + 0.5
    caixa(x, 0.2, largura, 0.5, PAPEL, LINHA, raio=0.25, lw=1.1)
    ax.add_patch(Circle((x + 0.28, 0.45), 0.07, facecolor=FOLHA, edgecolor="none"))
    texto(x + 0.45, 0.45, c, tam=10.5, cor=TINTA, va="center")
    x += largura + 0.3

saida = Path(__file__).with_name("arquitetura.png")
fig.savefig(saida, facecolor=PAPEL)
print(saida)
