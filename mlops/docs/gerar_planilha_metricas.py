"""Planilha e PDF de métricas por horizonte (3, 7 e 14 dias) no formato de comparação usado pelo
grupo: MAE, RMSE, WAPE %, rMAE, Dir. %, Cob.90, n e observação, um bloco por horizonte.

Na planilha, as métricas são fórmulas sobre a aba "Previsões" (uma linha por previsão do
walk-forward), para quem for conferir poder refazer qualquer número; ela é marcada para recalcular
ao abrir (Excel ou Google Sheets). O PDF traz os mesmos números, calculados aqui em pandas.
Entram também três referências que não fazem parte do pipeline, calculadas a partir da silver nos
mesmos cortes: médias móveis de 7 e 30 dias e o ingênuo semanal.

Uso (de dentro da pasta mlops; precisa de openpyxl e matplotlib):
    python docs/gerar_planilha_metricas.py docs/metricas_por_horizonte.xlsx [run_id]
Grava também o PDF com o mesmo nome. Sem run_id, usa o último treino de produção.
"""
import json
import math
import sys
import textwrap
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
from google.cloud import bigquery  # noqa: E402
from matplotlib.backends.backend_pdf import PdfPages  # noqa: E402
from openpyxl import Workbook  # noqa: E402
from openpyxl.formatting.rule import FormulaRule  # noqa: E402
from openpyxl.styles import Alignment, Font, PatternFill  # noqa: E402

SAIDA = Path(sys.argv[1])
RUN = sys.argv[2] if len(sys.argv) > 2 else None
PROJETO = "pdm-ceasa"
HORIZONTES = [3, 7, 14]
NAIVE = "Ingênuo (repete último preço)"
# Nome de cada modelo na tabela; os demais ficam com o nome do pipeline.
NOMES = {
    "Naive": NAIVE,
    "SeasonalNaive": "Ingênuo anual (mesmo dia, 1 ano antes)",
    "Chronos2": "Chronos2 (em produção)",
}
REFERENCIAS = ["Média móvel 7", "Média móvel 30", "Ingênuo semanal"]   # calculadas aqui, fora do pipeline
COLUNAS = ["Modelos", "MAE", "RMSE", "WAPE %", "rMAE", "Dir. %", "Cob.90", "n", "Observação"]
VERDE_ESCURO, VERDE_CLARO, AMARELO, CINZA = "274E13", "D9EAD3", "FFF2CC", "EFEFEF"

cli = bigquery.Client(project=PROJETO)

# 1. Execução, previsões do walk-forward e silver em volta dos cortes
filtro = f"run_id = '{RUN}'" if RUN else "status = 'sucesso' AND decisao IS NOT NULL AND experimento IS NULL"
execucao = cli.query(f"""
    SELECT run_id, inicio, ultima_semana, config FROM `{PROJETO}.mlops.execucoes`
    WHERE {filtro} ORDER BY inicio DESC LIMIT 1
""").to_dataframe().iloc[0]
RUN = execucao["run_id"]
janelas_holdout = json.loads(execucao["config"])["validacao"]["janelas_holdout"]

prev = cli.query(f"""
    SELECT modelo, unique_id, cutoff, ds, horizonte, y, yhat FROM `{PROJETO}.mlops.previsoes_cv`
    WHERE run_id = '{RUN}' AND horizonte IN UNNEST(@h)
""", job_config=bigquery.QueryJobConfig(query_parameters=[bigquery.ArrayQueryParameter("h", "INT64", HORIZONTES)])
).to_dataframe()
for coluna in ("cutoff", "ds"):
    prev[coluna] = pd.to_datetime(prev[coluna])
cortes = [pd.Timestamp(c) for c in sorted(prev["cutoff"].unique())]
inicio_holdout = cortes[-janelas_holdout]

silver = cli.query(f"""
    SELECT CONCAT(ceasa, '__', produto_canonico) AS unique_id, data AS ds, preco_comum AS y
    FROM `{PROJETO}.silver.ceasa_unificado`
    WHERE data BETWEEN DATE_SUB(DATE '{cortes[0].date()}', INTERVAL 40 DAY) AND DATE '{cortes[-1].date()}'
""").to_dataframe()
silver["ds"] = pd.to_datetime(silver["ds"])
serie = {uid: g.set_index("ds")["y"].sort_index() for uid, g in silver.groupby("unique_id")}

# 2. Preço no corte (a previsão do Naive é exatamente ele) e as referências calculadas aqui
base = prev[prev["modelo"] == "Naive"].rename(columns={"yhat": "preco_corte"}).drop(columns="modelo")
no_silver = pd.Series([serie.get(u, pd.Series(dtype=float)).get(c) for u, c in zip(base["unique_id"], base["cutoff"])],
                      index=base.index, dtype=float)
divergentes = int((no_silver - base["preco_corte"]).abs().gt(1e-9).sum() + no_silver.isna().sum())
if divergentes:
    print(f"AVISO: {divergentes} preços no corte mudaram na silver desde o treino; as referências usam a silver atual")


def referencia(nome: str, uid: str, corte: pd.Timestamp, h: int) -> float:
    s = serie.get(uid)
    if s is None:
        return math.nan
    if nome == "Ingênuo semanal":   # mesmo dia da semana do alvo, na última semana conhecida no corte
        return s.get(corte + pd.Timedelta(days=h - 7 * math.ceil(h / 7)), math.nan)
    dias = 7 if nome == "Média móvel 7" else 30
    return s.loc[corte - pd.Timedelta(days=dias - 1):corte].mean()


partes = [prev.merge(base[["unique_id", "cutoff", "horizonte", "preco_corte"]], on=["unique_id", "cutoff", "horizonte"])]
for nome in REFERENCIAS:
    r = base.copy()
    r["modelo"] = nome
    r["yhat"] = [referencia(nome, u, c, h) for u, c, h in zip(r["unique_id"], r["cutoff"], r["horizonte"])]
    partes.append(r)
dados = pd.concat(partes, ignore_index=True)
sem_previsao = int(dados["yhat"].isna().sum())
dados = dados.dropna(subset=["yhat"])
dados["modelo"] = dados["modelo"].map(lambda m: NOMES.get(m, m))
dados["ceasa"] = dados["unique_id"].str.split("__").str[0]
dados["periodo"] = np.where(dados["cutoff"] >= inicio_holdout, "holdout", "selecao")
dados = dados.sort_values(["modelo", "unique_id", "cutoff", "horizonte"]).reset_index(drop=True)

# 3. Métricas em pandas: ordem das linhas na planilha e números do PDF (as mesmas regras das fórmulas)
erro = dados["yhat"] - dados["y"]
dados["erro_abs"], dados["erro2"] = erro.abs(), erro**2
dados["real_mudou"] = (dados["y"] != dados["preco_corte"]).astype(int)
dados["prev_mudou"] = (dados["yhat"] != dados["preco_corte"]).astype(int)
dados["acertou"] = (dados["real_mudou"].astype(bool)
                    & (np.sign(dados["yhat"] - dados["preco_corte"]) == np.sign(dados["y"] - dados["preco_corte"]))
                    ).astype(int)


def observacao(nome: str, mae: float, minimo: float, rmae: float) -> str:
    if mae == minimo:
        return "CAMPEÃO do horizonte"
    if nome == NAIVE:
        return "BASELINE — denominador do rMAE"
    if round(rmae, 6) == 1:
        return "igual ao ingênuo neste horizonte"
    return "pior que o ingênuo" if rmae > 1 else ""


def resumo(periodo: str, h: int) -> tuple[pd.DataFrame, float]:
    """Métricas de um bloco (período "*" = todos os cortes) e % de casos sem mudança no preço real."""
    d = dados[(dados["horizonte"] == h) & ((dados["periodo"] == periodo) if periodo != "*" else True)]
    g = d.groupby("modelo")
    t = pd.DataFrame({
        "MAE": g["erro_abs"].mean(), "RMSE": np.sqrt(g["erro2"].mean()),
        "WAPE %": 100 * g["erro_abs"].sum() / g["y"].sum(),
        "Dir. %": 100 * g["acertou"].sum() / g["real_mudou"].sum(), "n": g.size(),
    })
    t.loc[g["prev_mudou"].sum() == 0, "Dir. %"] = np.nan   # quem nunca sai do preço do corte não tem direção
    t["rMAE"] = t["MAE"] / t.loc[NAIVE, "MAE"]
    t = t.sort_values("MAE")
    t["Observação"] = [observacao(m, v, t["MAE"].min(), r) for m, v, r in zip(t.index, t["MAE"], t["rMAE"])]
    naive = d[d["modelo"] == NAIVE]
    return t, 100 * (1 - naive["real_mudou"].mean())


inicio_dados, fim_dados = cortes[0].strftime("%d/%m/%Y"), cortes[-1].strftime("%d/%m/%Y")
PERIODOS = [
    ("Todos os cortes", "*", f"{len(cortes)} cortes, de {inicio_dados} a {fim_dados}"),
    ("Holdout", "holdout", f"{janelas_holdout} últimos cortes (holdout), de {inicio_holdout.strftime('%d/%m/%Y')} "
                           f"a {fim_dados}"),
]
NOTAS = [
    f"Dados: preço comum diário em R$/kg da silver.ceasa_unificado, 120 séries (CEASA × produto) de GO, MG, ES, SC "
    f"e MS, até {pd.Timestamp(execucao['ultima_semana']).strftime('%d/%m/%Y')}.",
    f"Walk-forward: {len(cortes)} cortes a cada 28 dias ({inicio_dados} a {fim_dados}), sempre no mesmo dia útil. Em "
    "cada corte o modelo só vê dados até aquela data e prevê 3, 7 e 14 dias à frente.",
    "MAE e RMSE em R$/kg. WAPE % = soma dos erros absolutos / soma dos preços reais. rMAE = MAE do modelo / MAE do "
    "ingênuo no mesmo bloco (abaixo de 1 = melhor que repetir o último preço).",
    "Dir. % = acertos da direção (subiu ou desceu em relação ao preço do corte), só nos casos em que o preço real "
    "mudou; uma previsão igual ao preço do corte conta como erro.",
    "Cob.90: não calculada. O pipeline guarda só a previsão pontual de cada modelo, sem intervalo.",
    "Média móvel 7 e 30 = média dos 7 e 30 dias até o corte. Ingênuo semanal = preço no mesmo dia da semana do alvo, "
    "na última semana conhecida no corte (em 7 e 14 dias é o próprio preço do corte).",
    "As três referências acima foram calculadas para esta comparação; os outros modelos são os do pipeline.",
    "Para comparar com outra tabela, use o rMAE: o MAE só é comparável com o mesmo período de teste e as mesmas séries.",
]
if sem_previsao:
    NOTAS.append(f"{sem_previsao} previsões de referência ficaram de fora por falta de histórico na silver.")

# 4. Planilha: dados brutos e métricas como fórmulas
wb = Workbook()
wb._named_styles["Normal"].font = Font(name="Arial", size=10)
wb.calculation.fullCalcOnLoad = True   # o openpyxl não grava valores calculados; quem abrir recalcula
negrito = Font(name="Arial", size=10, bold=True)

bruto = wb.active
bruto.title = "Previsões"
bruto.append(["Modelo", "Série", "CEASA", "Corte", "Data prevista", "Horizonte (dias)", "Período", "Real (R$/kg)",
              "Previsto (R$/kg)", "Preço no corte", "Erro absoluto", "Erro ao quadrado", "Preço real mudou?",
              "Acertou a direção?", "Previsão mudou?"])
for i, r in enumerate(dados.itertuples(index=False), start=2):
    bruto.append([r.modelo, r.unique_id, r.ceasa, r.cutoff.date(), r.ds.date(), int(r.horizonte), r.periodo,
                  float(r.y), float(r.yhat), float(r.preco_corte),
                  f"=ABS(I{i}-H{i})", f"=(I{i}-H{i})^2", f"=IF(H{i}<>J{i},1,0)",
                  f"=IF(M{i}=1,IF(SIGN(I{i}-J{i})=SIGN(H{i}-J{i}),1,0),0)", f"=IF(I{i}<>J{i},1,0)"])
ultima = len(dados) + 1
for celula in bruto[1]:
    celula.font = negrito
for coluna, largura in zip("ABCDEFGHIJKLMNO", [36, 28, 8, 12, 13, 10, 10, 12, 13, 13, 12, 13, 12, 13, 12]):
    bruto.column_dimensions[coluna].width = largura
for linha in bruto.iter_rows(min_row=2, min_col=4, max_col=5):
    for celula in linha:
        celula.number_format = "DD/MM/YYYY"
bruto.freeze_panes = "A2"
bruto.auto_filter.ref = f"A1:O{ultima}"


def faixa(coluna: str) -> str:
    return f"'Previsões'!${coluna}$2:${coluna}${ultima}"


def criterios(linha: int) -> str:
    """Modelo da coluna A, horizonte da coluna K e período da coluna L (ocultas): '*' = todos os cortes."""
    return f"{faixa('A')},$A{linha},{faixa('F')},$K{linha},{faixa('G')},$L{linha}"


blocos_pdf = {}
for titulo_aba, periodo, descricao in PERIODOS:
    ws = wb.create_sheet(titulo_aba, index=len(wb.sheetnames) - 1)
    ws["A1"] = f"Métricas por horizonte — walk-forward do treino {RUN} ({descricao})"
    ws["A1"].font = Font(name="Arial", size=12, bold=True)
    for coluna, texto in zip("ABCDEFGHI", COLUNAS):
        ws[f"{coluna}3"] = texto
        ws[f"{coluna}3"].font = Font(name="Arial", size=10, bold=True, color="FFFFFF")
        ws[f"{coluna}3"].fill = PatternFill("solid", fgColor=VERDE_ESCURO)
        ws[f"{coluna}3"].alignment = Alignment(horizontal="left" if coluna in "AI" else "center")
    linha = 4
    for n_bloco, h in enumerate(HORIZONTES, start=1):
        tabela, sem_mudanca = resumo(periodo, h)
        blocos_pdf[(periodo, h)] = (tabela, sem_mudanca)
        ws[f"A{linha}"] = f"BLOCO {n_bloco} — 5 CEASAs, diário (120 séries) · HORIZONTE {h} DIAS"
        ws[f"A{linha}"].font = negrito
        for coluna in "ABCDEFGHI":
            ws[f"{coluna}{linha}"].fill = PatternFill("solid", fgColor=VERDE_CLARO)
        primeira, ultima_bloco = linha + 1, linha + len(tabela)
        for r, nome in enumerate(tabela.index, start=primeira):
            ws[f"A{r}"], ws[f"K{r}"], ws[f"L{r}"] = nome, h, periodo
            ws[f"B{r}"] = f"=AVERAGEIFS({faixa('K')},{criterios(r)})"
            ws[f"C{r}"] = f"=SQRT(AVERAGEIFS({faixa('L')},{criterios(r)}))"
            ws[f"D{r}"] = f"=100*SUMIFS({faixa('K')},{criterios(r)})/SUMIFS({faixa('H')},{criterios(r)})"
            ws[f"E{r}"] = f'=B{r}/INDEX($B${primeira}:$B${ultima_bloco},MATCH("{NAIVE}",$A${primeira}:$A${ultima_bloco},0))'
            # Sem nenhuma previsão diferente do preço do corte (o ingênuo), não há direção a avaliar.
            ws[f"F{r}"] = (f'=IF(SUMIFS({faixa("O")},{criterios(r)})=0,"—",'
                           f"IFERROR(100*SUMIFS({faixa('N')},{criterios(r)})/SUMIFS({faixa('M')},{criterios(r)}),\"—\"))")
            ws[f"G{r}"] = "—"
            ws[f"H{r}"] = f"=COUNTIFS({criterios(r)})"
            ws[f"I{r}"] = (f'=IF(B{r}=MIN($B${primeira}:$B${ultima_bloco}),"CAMPEÃO do horizonte",'
                           f'IF($A{r}="{NAIVE}","BASELINE — denominador do rMAE",'
                           f'IF(ROUND(E{r},6)=1,"igual ao ingênuo neste horizonte",'
                           f'IF(E{r}>1,"pior que o ingênuo",""))))')
            for coluna, formato in zip("BCDEFH", ["0.0000", "0.0000", "0.00", "0.000", "0.0", "#,##0"]):
                ws[f"{coluna}{r}"].number_format = formato
                ws[f"{coluna}{r}"].alignment = Alignment(horizontal="right")
            ws[f"G{r}"].alignment = Alignment(horizontal="right")
        intervalo = f"A{primeira}:I{ultima_bloco}"
        ws.conditional_formatting.add(intervalo, FormulaRule(
            formula=[f"$B{primeira}=MIN($B${primeira}:$B${ultima_bloco})"],
            fill=PatternFill("solid", bgColor=AMARELO), font=Font(bold=True)))
        ws.conditional_formatting.add(intervalo, FormulaRule(
            formula=[f'$A{primeira}="{NAIVE}"'], fill=PatternFill("solid", bgColor=CINZA), font=Font(italic=True)))
        nota = ultima_bloco + 1
        # ROUND em vez de TEXT: o formato do TEXT muda com o idioma do Excel; o ROUND segue a vírgula do sistema.
        ws[f"A{nota}"] = (f'="Casos em que o preço real ficou igual ao do corte (fora do Dir. %): "&'
                          f"ROUND(100*(1-SUMIFS({faixa('M')},{faixa('A')},\"{NAIVE}\",{faixa('F')},{h},"
                          f"{faixa('G')},\"{periodo}\")/COUNTIFS({faixa('A')},\"{NAIVE}\",{faixa('F')},{h},"
                          f"{faixa('G')},\"{periodo}\")),1)&\"%\"")
        ws[f"A{nota}"].font = Font(name="Arial", size=9, italic=True, color="666666")
        linha = nota + 2
    ws[f"A{linha}"] = "Como foi calculado"
    ws[f"A{linha}"].font = negrito
    for k, texto in enumerate([*NOTAS, "Todos os números desta aba são fórmulas sobre a aba Previsões."], start=1):
        ws[f"A{linha + k}"] = texto
        ws[f"A{linha + k}"].font = Font(name="Arial", size=9)
    ws.column_dimensions["A"].width = 44
    for coluna in "BCDEFGH":
        ws.column_dimensions[coluna].width = 10
    ws.column_dimensions["I"].width = 36
    ws.column_dimensions["K"].hidden = ws.column_dimensions["L"].hidden = True
    ws.freeze_panes = "A4"
    ws.page_setup.orientation, ws.page_setup.paperSize = "landscape", ws.PAPERSIZE_A4
    ws.page_setup.fitToWidth, ws.page_setup.fitToHeight = 1, 0
    ws.sheet_properties.pageSetUpPr.fitToPage = True
    ws.print_area = f"A1:I{linha + len(NOTAS) + 1}"

wb.active = 0
SAIDA.parent.mkdir(parents=True, exist_ok=True)
wb.save(SAIDA)


# 5. PDF com os mesmos blocos (A4 em pé, uma página por período e uma de notas)
def numero(valor: float, casas: int) -> str:
    return "—" if pd.isna(valor) else f"{valor:,.{casas}f}".replace(",", "X").replace(".", ",").replace("X", ".")


LARGURAS = [1.95, 0.55, 0.55, 0.55, 0.5, 0.5, 0.5, 0.52, 1.65]   # polegadas; soma = 7,27 (A4 menos margens)
ALTURA_LINHA, FONTE = 0.168, 6.8
plt.rcParams["font.family"] = "Arial"


def celula(ax, x, y, largura, texto, fundo=None, cor="#1f2421", peso="normal", estilo="normal", direita=False):
    if fundo:
        ax.add_patch(plt.Rectangle((x, y), largura, ALTURA_LINHA, color=fundo, lw=0))
    ax.text(x + (largura - 0.05 if direita else 0.05), y + ALTURA_LINHA / 2, texto, va="center",
            ha="right" if direita else "left", fontsize=FONTE, color=cor, weight=peso, style=estilo)


def pagina(pdf, titulo: str, periodo: str):
    fig = plt.figure(figsize=(8.27, 11.69))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, 8.27)
    ax.set_ylim(11.69, 0)
    ax.axis("off")
    ax.text(0.5, 0.55, titulo, fontsize=11, weight="bold", color="#1f2421")
    ax.text(0.5, 0.78, f"Treino {RUN} · métricas do walk-forward, como na tabela de comparação do grupo",
            fontsize=7.5, color="#666666")
    y = 1.0
    x = 0.5
    for nome, largura in zip(COLUNAS, LARGURAS):
        celula(ax, x, y, largura, nome, "#" + VERDE_ESCURO, "white", "bold", direita=nome not in ("Modelos", "Observação"))
        x += largura
    y += ALTURA_LINHA
    for numero_bloco, h in enumerate(HORIZONTES, start=1):
        tabela, sem_mudanca = blocos_pdf[(periodo, h)]
        celula(ax, 0.5, y, sum(LARGURAS), f"BLOCO {numero_bloco} — 5 CEASAs, diário (120 séries) · HORIZONTE {h} DIAS",
               "#" + VERDE_CLARO, peso="bold")
        y += ALTURA_LINHA
        for nome, m in tabela.iterrows():
            campeao, ingenuo = m["Observação"] == "CAMPEÃO do horizonte", nome == NAIVE
            fundo = "#" + AMARELO if campeao else ("#" + CINZA if ingenuo else None)
            peso, estilo = ("bold" if campeao else "normal"), ("italic" if ingenuo and not campeao else "normal")
            valores = [nome, numero(m["MAE"], 4), numero(m["RMSE"], 4), numero(m["WAPE %"], 2), numero(m["rMAE"], 3),
                       numero(m["Dir. %"], 1), "—", numero(m["n"], 0), m["Observação"]]
            x = 0.5
            for k, (valor, largura) in enumerate(zip(valores, LARGURAS)):
                celula(ax, x, y, largura, valor, fundo, peso=peso, estilo=estilo, direita=0 < k < 8)
                x += largura
            ax.plot([0.5, 0.5 + sum(LARGURAS)], [y + ALTURA_LINHA] * 2, color="#e3e7e1", lw=0.4)
            y += ALTURA_LINHA
        ax.text(0.55, y + 0.1, f"Casos em que o preço real ficou igual ao do corte (fora do Dir. %): "
                                f"{numero(sem_mudanca, 1)}%", fontsize=6, style="italic", color="#666666")
        y += 0.32
    pdf.savefig(fig)
    plt.close(fig)


pdf_saida = SAIDA.with_suffix(".pdf")
with PdfPages(pdf_saida) as pdf:
    for titulo_aba, periodo, descricao in PERIODOS:
        pagina(pdf, f"Métricas por horizonte — {descricao}", periodo)
    fig = plt.figure(figsize=(8.27, 11.69))
    fig.text(0.06, 0.95, "Como foi calculado", fontsize=11, weight="bold")
    y = 0.92
    for texto in NOTAS:
        quebrado = textwrap.fill(texto, 110)
        fig.text(0.06, y, quebrado, fontsize=8, va="top", linespacing=1.4)
        y -= 0.014 * (quebrado.count("\n") + 1) + 0.014
    pdf.savefig(fig)
    plt.close(fig)

print(f"execução {RUN}: {len(cortes)} cortes, {len(dados)} previsões, {dados['modelo'].nunique()} modelos")
print(f"gravados: {SAIDA} e {pdf_saida}")
for periodo in ("*", "holdout"):
    for h in HORIZONTES:
        t, sem = blocos_pdf[(periodo, h)]
        print(f"\n== {'todos os cortes' if periodo == '*' else 'holdout'} · {h} dias (preço sem mudança: {sem:.1f}%) ==")
        print(t[["MAE", "RMSE", "WAPE %", "rMAE", "Dir. %", "n", "Observação"]].round(4).to_string())
