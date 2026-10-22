"""Cria ou atualiza os alertas do pipeline no Cloud Monitoring (idempotente: reexecutar não duplica).

Uso (de dentro da pasta mlops, com credenciais de quem pode editar o projeto):
    python infra/alertas.py --email pessoa@exemplo.com [--email outra@exemplo.com]

Alertas criados:
- "MLOps: job treino-precos falhou": a execução do Cloud Run Job terminou com erro
  (métrica run.googleapis.com/job/completed_execution_count com result = failed);
- "MLOps: CEASA sem dados novos": o job escreveu ALERTA_DADOS_ATRASADOS no log, porque alguma
  CEASA passou de alertas.dias_sem_dados no treino.yaml (ver pipeline/dados.py, verificar_atraso).
"""
import argparse

import google.auth
from google.auth.transport.requests import AuthorizedSession

PROJETO = "pdm-ceasa"
JOB = "treino-precos"
API = f"https://monitoring.googleapis.com/v3/projects/{PROJETO}"
DO_JOB = f'resource.type = "cloud_run_job" AND resource.labels.job_name = "{JOB}"'

POLITICAS = [
    {
        "displayName": "MLOps: job treino-precos falhou",
        "documentation": {
            "mimeType": "text/markdown",
            "content": "O job de treino terminou com erro. Veja a execução em Cloud Run > Jobs > treino-precos "
                       "e a coluna `erro` da tabela `mlops.execucoes`.",
        },
        "combiner": "OR",
        "conditions": [{
            "displayName": "Execução terminou com result = failed",
            "conditionThreshold": {
                "filter": f'{DO_JOB} AND metric.type = "run.googleapis.com/job/completed_execution_count" '
                          'AND metric.labels.result = "failed"',
                "aggregations": [{"alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_SUM"}],
                "comparison": "COMPARISON_GT",
                "thresholdValue": 0,
                "duration": "0s",
                "trigger": {"count": 1},
            },
        }],
        "alertStrategy": {"autoClose": "86400s"},
    },
    {
        "displayName": "MLOps: CEASA sem dados novos",
        "documentation": {
            "mimeType": "text/markdown",
            "content": "Alguma CEASA está há mais dias sem dados do que o limite `alertas.dias_sem_dados` do "
                       "`treino.yaml`. A linha ALERTA_DADOS_ATRASADOS no log do job diz qual CEASA e desde quando. "
                       "Verifique a ingestão (job `ciclo-ceasa`).",
        },
        "combiner": "OR",
        "conditions": [{
            "displayName": "Linha ALERTA_DADOS_ATRASADOS no log do job",
            "conditionMatchedLog": {"filter": f'{DO_JOB} AND textPayload : "ALERTA_DADOS_ATRASADOS"'},
        }],
        # No máximo um e-mail por dia enquanto o atraso continuar.
        "alertStrategy": {"notificationRateLimit": {"period": "86400s"}, "autoClose": "604800s"},
    },
]


def _verificar(resposta):
    if not resposta.ok:
        raise SystemExit(f"Erro {resposta.status_code} na API do Monitoring: {resposta.text}")
    return resposta.json()


def canais_de_email(sessao: AuthorizedSession, emails: list[str]) -> list[str]:
    existentes = _verificar(sessao.get(f"{API}/notificationChannels")).get("notificationChannels", [])
    nomes = []
    for email in emails:
        canal = next((c for c in existentes
                      if c["type"] == "email" and c.get("labels", {}).get("email_address") == email), None)
        if canal is None:
            canal = _verificar(sessao.post(f"{API}/notificationChannels", json={
                "type": "email", "displayName": f"MLOps: {email}", "labels": {"email_address": email},
            }))
            print(f"canal criado: {email}")
        else:
            print(f"canal já existia: {email}")
        nomes.append(canal["name"])
    return nomes


def aplicar_politica(sessao: AuthorizedSession, politica: dict, canais: list[str]) -> None:
    politica = {**politica, "notificationChannels": canais, "enabled": True}
    existentes = _verificar(sessao.get(f"{API}/alertPolicies")).get("alertPolicies", [])
    atual = next((p for p in existentes if p["displayName"] == politica["displayName"]), None)
    if atual:
        # Sem updateMask, o PATCH substitui a política inteira pela definição acima.
        _verificar(sessao.patch(f"https://monitoring.googleapis.com/v3/{atual['name']}", json=politica))
        print(f"alerta atualizado: {politica['displayName']}")
    else:
        _verificar(sessao.post(f"{API}/alertPolicies", json=politica))
        print(f"alerta criado: {politica['displayName']}")


def main() -> None:
    args = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    args.add_argument("--email", action="append", required=True, help="quem recebe os alertas (pode repetir)")
    args = args.parse_args()

    credenciais, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    sessao = AuthorizedSession(credenciais)
    sessao.headers["x-goog-user-project"] = PROJETO
    canais = canais_de_email(sessao, args.email)
    for politica in POLITICAS:
        aplicar_politica(sessao, politica, canais)


if __name__ == "__main__":
    main()
