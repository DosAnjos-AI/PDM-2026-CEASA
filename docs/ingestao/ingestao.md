# Ingestão no GCP — do projeto vazio ao ciclo diário

Como colocar a ingestão das cinco CEASAs (GO, MS, SC, MG e ES) para rodar no
Google Cloud: preparar o projeto, construir a imagem, criar o Cloud Run Job,
fazer a carga inicial, conferir e agendar o ciclo diário. No fim, como rodar
o mesmo ciclo sem o Cloud Run.

Cada passo traz dois caminhos equivalentes. Escolha um por passo; não faça os dois.

- **No console**: clicando nas telas do GCP (<https://console.cloud.google.com>).
- **Pelo Cloud Shell**: os comandos que fazem a mesma coisa. Também servem num terminal local com o Google Cloud SDK (Passo 0).

A única etapa que só tem caminho por comando é o build da imagem (Passo 4.2).

## Sumário

| Parte | Passos | Quando |
|---|---|---|
| A. Preparar o projeto | 0 a 2 | uma vez por projeto |
| B. Job e carga inicial | 3 a 8 | uma vez |
| C. Ciclo diário | 9 e 10 | depois da carga inicial |
| D. Rodar sem o Cloud Run | 11 | testes ou execução manual |

## Visão geral

O ciclo inteiro é o `entrypoint.sh`, empacotado pelo `Dockerfile` numa imagem
que roda como Cloud Run Job. A cada execução, para cada sede:

1. **Coleta:** baixa do site só o bruto que ainda não está no bucket.
2. **Extração:** gera o CSV da sede. MS, SC, MG e ES extraem só os boletins que faltam na Bronze, mais os dos 2 últimos meses. A GO refaz o CSV inteiro, salvo quando os PDFs não mudaram (assinatura igual).
3. **Upload:** envia o CSV ao bucket.
4. **Manifesto:** grava a lista de todos os brutos do bucket, usada na conferência de duas vias (`sql/consultas/bronze/05_ceasa_check.sql`, rodada à mão).
5. **BigQuery:** roda os `.sql` de `sql/construir_tabelas/` (Bronze, Silver e Gold). Cada `bronze.ceasa_<uf>` é atualizada por `MERGE`, só nos boletins novos ou alterados.

| Sede | Bruto em `cotacoes/` | CSV no bucket | Tabela Bronze |
|---|---|---|---|
| CEASA-GO | `go/` (PDF) | `raw/cotacoes_site.csv` | `bronze.ceasa_go` e `bronze.cotacoes` |
| CEASA-MS | `ms/` (XLS/XLSX) | `csv/ceasa_ms.csv` | `bronze.ceasa_ms` |
| CEASA-SC | `sc/` (PDF) | `csv/ceasa_sc.csv` | `bronze.ceasa_sc` |
| CEASA-MG | `mg/` (HTML) | `csv/ceasa_mg.csv` | `bronze.ceasa_mg` |
| CEASA-ES | `es/` (HTML) | `csv/ceasa_es.csv` | `bronze.ceasa_es` |

Estrutura do bucket depois da carga:

```
gs://pdm-ceasa-dados/
  cotacoes/                              brutos, gravados pelo job
    go/2019/01/2019-01-03.pdf            GO: ano/mês/PDF do dia
    ms/2021/01.xls                       MS: ano/planilha do mês
    sc/2020/01/876.pdf                   SC: ano/mês/PDF (nome = id do site)
    mg/214/2021/10/2021-10-27.html       MG: mercado/ano/mês/boletim do dia
    es/211/2021/11/2021-11-03.html       ES: mercado/ano/mês/boletim do dia
  raw/cotacoes_historico.csv             GO, série histórica (desde 2010), enviada à mão (Passo 2)
  raw/cotacoes_site.csv                  GO, extraída dos PDFs do site
  csv/ceasa_<uf>.csv                     MS, SC, MG e ES
  csv/manifesto_brutos.csv               lista de todo bruto do bucket
  csv/assinatura_go.txt                  impressão dos PDFs da GO que geraram o CSV
```

A descrição de cada site, formato e particularidade está em
[`docs/coleta/coleta.md`](../coleta/coleta.md). A carga da `bronze.cotacoes`
está em [`docs/bronze/bronze.md`](../bronze/bronze.md).

Valores usados nos exemplos (os de `CLAUDE.md`). Em outro projeto, troque-os:

| Item | Valor |
|---|---|
| Projeto | `pdm-ceasa` |
| Bucket | `gs://pdm-ceasa-dados` |
| Datasets | `bronze`, `silver`, `gold` (região US) |
| Região do Cloud Run | `us-central1` |
| Job | `ciclo-ceasa` |
| Conta de serviço | `ciclo-ceasa@pdm-ceasa.iam.gserviceaccount.com` |
| Imagem | `us-central1-docker.pkg.dev/pdm-ceasa/ceasa/ciclo:latest` |

---

# Parte A — Preparar o projeto (uma vez)

## Passo 0 — Terminal com `gcloud` e `bq`

**No console**, clique em **Ativar o Cloud Shell** (`>_`), no canto superior
direito. Ele já vem com `gcloud`, `bq`, `git` e o login feito. É o caminho
recomendado.

**Num terminal local (Linux)**, instale o Google Cloud SDK sem `sudo`:

```bash
curl -sSL https://sdk.cloud.google.com | bash   # instala em ~/google-cloud-sdk; aceite os padrões
exec -l $SHELL                                  # recarrega o PATH
gcloud --version                                # tem que listar bq também
gcloud init                                     # login no navegador e escolha do projeto
```

Se o `bq` não aparecer no `gcloud --version`, instale com `gcloud components install bq`.
No `gcloud init`, recuse a configuração de região e zona do Compute Engine: o
pipeline não usa.

**No Windows**, use o instalador `GoogleCloudSDKInstaller.exe`
(<https://cloud.google.com/sdk/docs/install>). Os laços `for` deste guia e o
`entrypoint.sh` são bash: rode-os pelo WSL ou pelo Git Bash.

Em qualquer terminal, defina as variáveis que os passos usam. Elas valem só
naquele terminal; se ele reiniciar, defina de novo.

```bash
gcloud config set project pdm-ceasa
PROJETO=pdm-ceasa
BUCKET=gs://pdm-ceasa-dados
REGIAO=us-central1
SA=ciclo-ceasa@pdm-ceasa.iam.gserviceaccount.com
IMAGEM=$REGIAO-docker.pkg.dev/pdm-ceasa/ceasa/ciclo:latest
```

## Passo 1 — APIs, bucket e datasets

Pule o que já existir. Repetir um comando só gera o aviso de que o recurso já existe.

**No console**

1. No seletor de projeto, no topo, escolha o projeto (ou **Novo projeto**). Confira o **ID**, não o nome de exibição: é o ID que o BigQuery usa. O projeto precisa de faturamento ativo.
2. Menu (☰) → **APIs e serviços** → **Biblioteca**. Ative: **BigQuery API**, **Cloud Storage**, **Cloud Run Admin API**, **Cloud Build API**, **Artifact Registry API** e **Cloud Scheduler API**. Se uma já estiver ativa, a tela mostra **Gerenciar** no lugar do botão.
3. Menu (☰) → **Cloud Storage** → **Buckets** → **Criar**. Nome `pdm-ceasa-dados`, tipo de local **Multirregião**, **us**. O resto no padrão.
4. Menu (☰) → **BigQuery** → **BigQuery Studio**. No **Explorador**, nos três pontos do projeto → **Criar conjunto de dados**. Crie `bronze`, `silver` e `gold`, todos com local **US (várias regiões nos Estados Unidos)**.

**Pelo Cloud Shell**

```bash
gcloud services enable bigquery.googleapis.com storage.googleapis.com \
    run.googleapis.com cloudbuild.googleapis.com \
    artifactregistry.googleapis.com cloudscheduler.googleapis.com
gcloud storage buckets create $BUCKET --location=US --project=$PROJETO
for ds in bronze silver gold; do bq --location=US mk --dataset $PROJETO:$ds; done
gcloud storage ls                    # o bucket aparece
bq ls --project_id=$PROJETO          # bronze, gold, silver
```

Se a criação do bucket responder `HTTPError 409`, o nome já é usado por
alguém: nome de bucket é único no mundo. Escolha outro e use-o em todo o guia.

Os datasets `baseline` e `metricas` só servem ao treino de modelos e ficam
fora da ingestão.

## Passo 2 — Histórico da GO no bucket

A `bronze.cotacoes`, de onde a Silver e os modelos leem, carrega **todo**
`raw/*.csv` do bucket. Os dados da GO de 2010 a 2018 vêm de um CSV histórico
local, obtido numa visita à CEASA-GO e fora do repositório. Ele precisa estar
em `raw/` antes da primeira carga.

**No console**: **Cloud Storage** → **Buckets** → `pdm-ceasa-dados` →
**Criar pasta** `raw` → entre nela → **Fazer upload de arquivos** →
`cotacoes_historico.csv`.

**Pelo Cloud Shell**, ou num terminal local com o arquivo:

```bash
ARQUIVO_ORIGEM=/caminho/para/cotacoes_historico.csv ingestao/upload_historico.sh
```

Sem `ARQUIVO_ORIGEM`, o script procura `../historico/cotacoes_historico.csv`
a partir da raiz do repositório. O destino é sempre
`gs://pdm-ceasa-dados/raw/cotacoes_historico.csv`; reenviar sobrescreve o
mesmo objeto.

Cuidados com `raw/`:

- **Só CSV no formato da GO** (17 colunas). Um CSV de MS, SC, MG ou ES faz a carga da `bronze.cotacoes` falhar. Eles ficam em `csv/`.
- **Histórico e site se sobrepõem** de 2019 em diante (`cotacoes_historico.csv` e `cotacoes_site.csv`). A deduplicação da Silver tem que absorver isso: confira `chaves_duplicadas = 0` no Passo 8.3.

---

# Parte B — Job e carga inicial (uma vez)

## Passo 3 — Código no Cloud Shell

A imagem é construída a partir de um clone do repositório. No Cloud Shell:

```bash
git clone https://github.com/DosAnjos-AI/PDM-2026-CEASA.git ~/PDM-2026-CEASA
cd ~/PDM-2026-CEASA
git checkout <branch>        # a que tem entrypoint.sh e Dockerfile com as cinco sedes
git pull
grep -E '^(PROJETO|BUCKET)=' entrypoint.sh
```

Enquanto a coleta das cinco sedes não estiver integrada à branch de trabalho
(`dosAnjos`), a branch é `coleta-outras-ceasas`. O `grep` tem que mostrar
`pdm-ceasa` e `gs://pdm-ceasa-dados`; outro valor indica um clone antigo.

**Se as tabelas `bronze.ceasa_*` já existirem** (de uma carga anterior), confira
o esquema. O `MERGE` cita cada coluna pelo nome: coluna faltando ou com tipo
incompatível faz a carga daquela sede falhar, e a tabela fica exatamente como
estava.

```bash
for uf in go ms sc mg es; do echo "== ceasa_$uf"; bq show --schema --format=csv $PROJETO:bronze.ceasa_$uf 2>&1 | head -3; done
```

| Tabela | Colunas esperadas |
|---|---|
| `ceasa_go` | `data, ano, mes, dia, grupo, categoria, codigo, produto, embalagem, qtd_kg, classe, preco_comum, preco_maximo, preco_minimo, preco_kg, layout, arquivo` |
| `ceasa_ms`, `_sc`, `_mg`, `_es` | `data, ano, mes, dia, fonte, mercado, grupo, produto, classificacao, tipo, origem, embalagem, qtd_kg, preco_minimo, preco_comum, preco_maximo, situacao, arquivo` |

O `arquivo` das linhas antigas precisa estar no formato que os coletores
gravam (por exemplo, `2021/01.xls#1` na MS e `214/2021/10/2021-10-27.html` na
MG). Em outro formato, essas linhas não são reconhecidas como o mesmo boletim,
e o boletim entra duplicado ao lado delas. Se as tabelas não existirem, a
carga as cria.

## Passo 4 — Construir a imagem

### 4.1 Repositório de imagens

**No console**: Menu (☰) → **Artifact Registry** → **Repositórios** →
**Criar repositório**.

| Campo | Valor |
|---|---|
| Nome | `ceasa` |
| Formato | Docker |
| Modo | Padrão |
| Tipo de local | Região |
| Região | `us-central1` |

**Pelo Cloud Shell**

```bash
gcloud artifacts repositories create ceasa --repository-format=docker --location=$REGIAO
```

### 4.2 Build (só pelo Cloud Shell)

O Cloud Build constrói o `Dockerfile` na nuvem; não é preciso Docker no
Cloud Shell. A imagem parte do `google/cloud-sdk:slim`, que já traz `gcloud`
e `bq`, e instala poppler, tesseract com português e as bibliotecas Python de
todas as sedes. O `ENTRYPOINT` é o `entrypoint.sh`.

```bash
cd ~/PDM-2026-CEASA
gcloud builds submit --region=$REGIAO --tag $IMAGEM .
...
STATUS: SUCCESS
```

Sem `.gcloudignore`, o `gcloud` usa o `.gitignore`: os CSVs e as pastas
`cotacoes*` não sobem junto com o código.

Conferir no console: **Cloud Build** → **Histórico** (build verde em 3 a 6
minutos; o tesseract é a parte lenta) e **Artifact Registry** → `ceasa` (imagem
`ciclo` com a tag `latest`).

Se o build falhar por permissão, sua conta precisa do papel **Editor do Cloud
Build**. Se falhar ao publicar a imagem, dê o papel **Gravador do Artifact
Registry** à conta `<número-do-projeto>-compute@developer.gserviceaccount.com`
(**IAM e administrador** → **IAM**).

## Passo 5 — Conta de serviço e papéis

O job roda com uma conta própria, só com os papéis de que precisa. Não use a
conta padrão do Compute, que costuma ter permissão demais, e não gere chave
JSON: o Cloud Run usa a conta direto.

**No console**

1. Menu (☰) → **IAM e administrador** → **Contas de serviço** → **Criar conta de serviço**.
2. Nome `ciclo-ceasa` → **Criar e continuar**.
3. Em **Permissões**, adicione os quatro papéis da tabela → **Continuar** → **Concluir**.

| Papel no console | Nome técnico | Para quê |
|---|---|---|
| Usuário de jobs do BigQuery | `roles/bigquery.jobUser` | Executar consultas e cargas |
| Editor de dados do BigQuery | `roles/bigquery.dataEditor` | Criar e atualizar tabelas |
| Administrador de objetos do Storage | `roles/storage.objectAdmin` | Ler e gravar brutos e CSVs no bucket |
| Invocador do Cloud Run | `roles/run.invoker` | Deixar o Scheduler disparar o job (Passo 9) |

Não adicione **Editor** nem **Proprietário**. Se o nome do papel aparecer
diferente, procure pelo nome técnico.

**Pelo Cloud Shell**

```bash
gcloud iam service-accounts create ciclo-ceasa
for papel in bigquery.jobUser bigquery.dataEditor storage.objectAdmin run.invoker; do
  gcloud projects add-iam-policy-binding $PROJETO --member=serviceAccount:$SA \
    --role=roles/$papel --condition=None --quiet > /dev/null && echo "ok $papel"
done
```

Se o `create` responder que a conta já existe, rode só o laço: ele pode ser
repetido sem problema.

## Passo 6 — Criar o job

O job monta o bucket inteiro em `/mnt/bucket` e aponta `DIR_BRUTO` para
`/mnt/bucket/cotacoes`. É isso que faz os brutos sobreviverem ao contêiner:
cada PDF, planilha e boletim vai direto para `gs://pdm-ceasa-dados/cotacoes/`,
e a próxima execução os encontra lá. Os CSVs vão para `/tmp`, que some no fim
da execução (depois de enviados ao bucket).

**No console**

1. Menu (☰) → **Cloud Run** → aba **Jobs** → **Implantar contêiner** (ou **Criar job**).
2. **URL da imagem do contêiner** → **Selecionar** → **Artifact Registry** → `ceasa` → `ciclo` → `latest`.
3. Nome do job `ciclo-ceasa`, região `us-central1`, número de tarefas `1`.
4. Abra **Contêiner(es), volumes, conexões, segurança**. Aba **Volumes** → **Adicionar volume**: tipo **Bucket do Cloud Storage**, nome `dados`, bucket `pdm-ceasa-dados`, **Somente leitura desmarcado**.
5. Aba **Contêiner**:

   | Onde | Campo | Valor |
   |---|---|---|
   | Configurações | Memória | 4 GiB |
   | Configurações | CPU | 2 |
   | Configurações | Tempo limite da tarefa | 1 hora (confira a unidade) |
   | Configurações | Número máximo de novas tentativas | 0 |
   | Variáveis e secrets | `PROJETO` | `pdm-ceasa` |
   | Variáveis e secrets | `BUCKET` | `gs://pdm-ceasa-dados` |
   | Variáveis e secrets | `DIR_BRUTO` | `/mnt/bucket/cotacoes` |
   | Montagens de volume | Nome / Caminho | `dados` / `/mnt/bucket` |

6. Aba **Segurança** → **Conta de serviço** → `ciclo-ceasa@pdm-ceasa.iam.gserviceaccount.com`.
7. Deixe **Executar job imediatamente** desmarcado e clique em **Criar**.

**Atenção ao caminho de montagem:** tem que ser exatamente `/mnt/bucket`. O
console sugere outro (como `/dados`), e com ele o job grava os brutos dentro
do contêiner: a execução parece normal, mas nada chega ao bucket.

**Pelo Cloud Shell**

```bash
gcloud run jobs create ciclo-ceasa \
    --image=$IMAGEM --region=$REGIAO --service-account=$SA \
    --cpu=2 --memory=4Gi --task-timeout=3600 --max-retries=0 \
    --set-env-vars=PROJETO=$PROJETO,BUCKET=$BUCKET,DIR_BRUTO=/mnt/bucket/cotacoes \
    --add-volume=name=dados,type=cloud-storage,bucket=pdm-ceasa-dados \
    --add-volume-mount=volume=dados,mount-path=/mnt/bucket
```

Por que esses valores:

- **Volume gravável:** somente leitura, o coletor da GO falha ao gravar o primeiro PDF.
- **2 vCPU:** o OCR da GO usa várias threads; com menos CPU, ele já estourou o tempo limite.
- **4 GiB:** o `/tmp` do Cloud Run fica em memória (os cinco CSVs somam cerca de 230 MB), e o volume do bucket também guarda em memória cada arquivo até enviá-lo.
- **1 hora:** limite do ciclo diário. A carga inicial ganha um limite próprio no Passo 7.
- **0 novas tentativas:** uma falha aparece como falha, sem repetição silenciosa.

## Passo 7 — Carga inicial

É uma execução comum do job com dois valores trocados só nela: a GO é
percorrida desde 2019 e o tempo limite sobe para 4 horas. As substituições
valem só para essa execução; as seguintes voltam sozinhas ao modo diário. Sem
`ANO_INICIAL_GO=2019`, a GO começaria no ano anterior e o CSV dela sairia com
uma fração das linhas.

**No console**

1. **Cloud Run** → **Jobs** → `ciclo-ceasa`.
2. Seta ao lado de **Executar** → **Executar com substituições**.
3. Em **Variáveis de ambiente**, adicione `ANO_INICIAL_GO` = `2019`. Em **Tempo limite da tarefa**, `14400` segundos (ou 240, se a unidade for minutos).
4. **Executar**.

Não adicione `ANO_INICIAL_GO` na configuração do job: ela passaria a valer
para todas as execuções.

**Pelo Cloud Shell**

```bash
gcloud run jobs execute ciclo-ceasa --region=$REGIAO \
    --update-env-vars=ANO_INICIAL_GO=2019 --task-timeout=4h --async
```

A execução roda no Cloud Run: pode fechar a aba. Para acompanhar,
**Cloud Run → Jobs → ciclo-ceasa → Execuções** → clique na execução →
**Registros**. O log tem os cinco marcos do `entrypoint.sh`:

```
== 1/5 CEASA-GO: coleta (a partir de 2019), extracao e upload
== 2/5 demais sedes: ms sc mg es
== 3/5 manifesto dos brutos
== 4/5 BigQuery
== 5/5 resumo
== ciclo concluido
```

Se um marco não aparecer, o erro está no passo anterior a ele. Na primeira
linha, confira `a partir de 2019`.

| Etapa | Tempo esperado da carga inicial |
|---|---|
| GO: ~1.530 PDFs e extração com OCR | ~15 min de download + 1 a 3 min de extração |
| MS: ~70 planilhas | ~1 min |
| SC: ~1.700 PDFs | ~17 min |
| MG: ~3.500 boletins | ~35–40 min (estimado) |
| ES: ~2.250 boletins | ~20–25 min (estimado) |
| BigQuery: Bronze, Silver e Gold | alguns minutos |

Os tempos são de um teste local, com 0,5 s entre requisições, e somam cerca
de 1h30. As 4 h dão folga para o Cloud Run.

## Passo 8 — Conferir a carga

A prova tem quatro partes: o resumo de cada coletor no log, as contagens no
bucket, a Bronze no BigQuery e uma segunda execução que não encontra nada
para baixar.

### 8.1 Resumo de cada coletor no log

**No console**: copie o nome da execução (como `ciclo-ceasa-abc12`).
Menu (☰) → **Logging** → **Explorador de registros** → **Mostrar consulta**,
cole e clique em **Executar consulta**:

```
resource.type="cloud_run_job"
resource.labels.job_name="ciclo-ceasa"
labels."run.googleapis.com/execution_name"="ciclo-ceasa-abc12"
textPayload=~"^(Resumo|Coleta|Total:|Extracao|CEASA-|ERRO)|indisponivel|linhas de"
```

**Pelo Cloud Shell**

```bash
EXEC=$(gcloud run jobs executions list --job=ciclo-ceasa --region=$REGIAO \
    --limit=1 --format='value(metadata.name)')
gcloud logging read "resource.type=\"cloud_run_job\" AND labels.\"run.googleapis.com/execution_name\"=\"$EXEC\" AND textPayload=~\"^(Resumo|Coleta|Total:|Extracao|CEASA-|ERRO)|indisponivel|linhas de\"" \
    --order=asc --limit=200 --format='value(textPayload)'
```

Nenhuma linha pode começar com `ERRO`, e cada coletor tem que mostrar
`0 erro(s)` ou `erro=0`. Os únicos `indisponivel` aceitos são as faltas
conhecidas da tabela do 8.2: links quebrados no próprio site.

### 8.2 Contagens no bucket

Referência: teste local do `entrypoint.sh` em 15/10/2026. Cada dia útil
depois disso acrescenta arquivos e linhas; os seus números podem ser maiores,
nunca menores.

| Sede | Brutos no bucket | Linhas no CSV | Período | Faltas conhecidas na fonte |
|---|---|---|---|---|
| GO | 1.531 PDFs | 354.709 | 2019 a 2026-10 | 2 boletins semanais sem cotação |
| MS | 68 planilhas | 337.855 | 2021-01-01 a 2026-10-02 | 404 em nov/2023 e mar/2025 |
| SC | 1.700 PDFs | 455.703 | 2020-01-02 a 2026-10-15 | 3 PDFs 404 (mar–abr/2023) e o id 1261, ignorado de propósito |
| MG | 3.513 | 473.417 | 2006-01-02 a 2026-10-15 | nenhuma |
| ES | 2.263 | 245.543 | 2010-09-01 a 2026-10-15 | nenhuma |

**No console** dá para ver as pastas em **Cloud Storage → pdm-ceasa-dados →
cotacoes**, mas a tela não soma arquivos de subpastas. **Pelo Cloud Shell**, a
contagem exata (o `grep -v '/$'` tira as pastas; o `- 1` tira o cabeçalho):

```bash
for d in go ms sc mg es; do
  echo "$d $(gcloud storage ls "$BUCKET/cotacoes/$d/**" | grep -vc '/$')"
done
for o in $BUCKET/raw/cotacoes_site.csv $(gcloud storage ls "$BUCKET/csv/*.csv"); do
  echo "$(basename $o) $(($(gcloud storage cat $o | wc -l) - 1))"
done
```

### 8.3 Bronze, Silver e Gold no BigQuery

**No console**: **BigQuery** → **BigQuery Studio** → **+** (consulta nova),
cole o conteúdo do `.sql` indicado e clique em **Executar**. **Pelo Cloud
Shell**, da raiz do clone:

```bash
bq query --project_id=$PROJETO --use_legacy_sql=false < sql/consultas/bronze/05_ceasa_check.sql
bq query --project_id=$PROJETO --use_legacy_sql=false < sql/consultas/bronze/01_bronze_check.sql
bq query --project_id=$PROJETO --use_legacy_sql=false < sql/consultas/silver/07_silver_check.sql
```

O `05_ceasa_check.sql` imprime quatro tabelas:

1. **Tamanho e nulos** por tabela (`linhas`, `boletins`, datas, nulos). As linhas têm que ser iguais ou maiores que as do CSV na tabela do 8.2. `data_nula`, `produto_nulo` e `arquivo_nulo` têm que dar 0. Os 23 `preco_comum` nulos da MS já vêm assim da fonte.
2. **Prova do `MERGE`**: `boletins_divergentes` = **0 nas cinco**. Diferente de 0 é boletim faltando ou com linhas duplicadas.
3. **Conferência de duas vias**, por sede. Esperado depois da carga inicial: `so_no_bucket` = 2 na GO (os 2 boletins semanais) e 0 nas demais; `so_no_bigquery` = 0, a menos que a tabela já tivesse linhas de antes. Um `so_no_bigquery` alto junto de um `so_no_bucket` alto indica `arquivo` antigo em outro formato (Passo 3).
4. **Até 50 caminhos por sede** que ficaram só no bucket, para investigar.

No `01_bronze_check.sql`, o total da `bronze.cotacoes` tem que ser a soma das
linhas de todos os CSVs de `raw/`. No `07_silver_check.sql`,
`chaves_duplicadas` e os preços inválidos têm que dar 0.

### 8.4 Segunda execução

Execute o job de novo, **sem substituição nenhuma**: é o modo diário.

**No console**: **Cloud Run → Jobs → ciclo-ceasa** → **Executar** (o botão
principal). **Pelo Cloud Shell**:
`gcloud run jobs execute ciclo-ceasa --region=$REGIAO --wait`.

Depois, repita a consulta do 8.1 com o nome da nova execução, trocando a
última linha por `textPayload=~"^(Resumo|Coleta|Total:)|a baixar"`. Esperado:

```
Resumo: existente=...                         <- GO: nenhum baixado=
Coleta: baixado=0, atualizado=0, existente=68, indisponivel=2, erro=0   <- MS
Total: 1703 PDF(s), 3 a baixar                <- SC: só os 3 que dão 404
  CEASA-MG 214 Grande BH - CEAMG: ... data(s) no periodo, 6 a baixar
  CEASA-ES 211 CEASA GRANDE VITÓRIA: ... data(s) no periodo, 6 a baixar
```

- GO, MS e SC não podem baixar nada além das faltas conhecidas. Se aparecer `1703 a baixar` na SC ou um `baixado=` alto na GO, o job não está vendo os brutos: confira o volume e o `DIR_BRUTO` (Passo 6).
- MG e ES sempre mostram alguns boletins "a baixar": pedem de novo, de propósito, os últimos 7 dias (`--revisar-dias 7`), que a fonte ainda pode corrigir.
- Cada sede mostra `Extracao incremental: N de M bruto(s)`, com N pequeno; a GO mostra `extracao pulada` quando nenhum PDF novo chegou.
- Na Bronze, cada `0N_ceasa_<uf>.sql` imprime `boletins_inseridos` e `boletins_substituidos`: 0 ou poucos. Um número na casa dos milhares indica que as linhas da tabela não casam com as do CSV (Passo 3).

---

# Parte C — Ciclo diário

## Passo 9 — Agendar

O horário é escolha do grupo. O exemplo dispara em dias úteis, às 16h de Brasília.

**No console**

1. **Cloud Run** → **Jobs** → `ciclo-ceasa` → aba **Gatilhos** → **Adicionar gatilho do Scheduler**.
2. Preencha e clique em **Criar**:

   | Campo | Valor |
   |---|---|
   | Nome | `ciclo-ceasa-diario` |
   | Região | `us-central1` |
   | Frequência | `0 16 * * 1-5` |
   | Fuso horário | `America/Sao_Paulo` |
   | Conta de serviço | `ciclo-ceasa@pdm-ceasa.iam.gserviceaccount.com` |

Para testar sem esperar o horário: **Cloud Scheduler** → marque
`ciclo-ceasa-diario` → **Forçar execução**. Uma execução nova aparece em
**Cloud Run → Jobs → ciclo-ceasa → Execuções**.

**Pelo Cloud Shell**

```bash
gcloud scheduler jobs create http ciclo-ceasa-diario --location=$REGIAO \
    --schedule='0 16 * * 1-5' --time-zone=America/Sao_Paulo \
    --uri=https://run.googleapis.com/v2/projects/$PROJETO/locations/$REGIAO/jobs/ciclo-ceasa:run \
    --http-method=POST --oauth-service-account-email=$SA
gcloud scheduler jobs run ciclo-ceasa-diario --location=$REGIAO     # testa agora
```

## Passo 10 — Acompanhar e manter

| Quero | No console | Pelo Cloud Shell |
|---|---|---|
| Ver as últimas execuções | **Cloud Run → Jobs → ciclo-ceasa → Execuções** | `gcloud run jobs executions list --job=ciclo-ceasa --region=$REGIAO` |
| Ler o log de uma execução | clicar na execução → **Registros**, ou a consulta do 8.1 | o `gcloud logging read` do 8.1 |
| Publicar código novo | o build só tem caminho por comando; depois, **Cloud Run → Jobs → ciclo-ceasa → Editar**, escolher a imagem nova e **Atualizar** | `git pull`, `gcloud builds submit --region=$REGIAO --tag $IMAGEM .` e `gcloud run jobs update ciclo-ceasa --image=$IMAGEM --region=$REGIAO` |
| Reextrair tudo (depois de mudar um extrator) | **Executar com substituições** com `EXTRAIR_TUDO` = `1` | `gcloud run jobs execute ciclo-ceasa --region=$REGIAO --update-env-vars=EXTRAIR_TUDO=1` |
| Pausar o agendamento | **Cloud Scheduler** → marcar `ciclo-ceasa-diario` → **Pausar** | `gcloud scheduler jobs pause ciclo-ceasa-diario --location=$REGIAO` |
| Retomar o agendamento | **Cloud Scheduler** → **Retomar** | `gcloud scheduler jobs resume ciclo-ceasa-diario --location=$REGIAO` |

Uma execução marcada como falha com `ERRO: sede(s) com falha` quer dizer que
só aquela sede ficou sem atualizar: o CSV anterior dela continua no bucket, e
as demais foram para o BigQuery normalmente. Se a falha se repetir por vários
dias, o site da sede provavelmente mudou.

### Variáveis do `entrypoint.sh`

Todas têm padrão; no job, só `PROJETO`, `BUCKET` e `DIR_BRUTO` são definidas.

| Variável | Padrão | O que é |
|---|---|---|
| `PROJETO` | `pdm-ceasa` | Projeto do upload e do `bq query` |
| `BUCKET` | `gs://pdm-ceasa-dados` | Bucket dos CSVs e parâmetro dos `.sql` da Bronze |
| `DIR_BRUTO` | `/mnt/dados` | Pasta persistente dos brutos, uma subpasta por sede |
| `DIR_CSV` | `/tmp` | Pasta dos CSVs gerados, refeitos a cada execução |
| `ANO_INICIAL_GO` | ano anterior | Primeiro ano percorrido na GO; `2019` na carga inicial |
| `FALHAS_ESPERADAS_GO` | `2` | Os 2 boletins semanais da GO, que não são cotação |
| `SEDES` | `ms sc mg es` | Sedes além da GO |
| `MESES_REEXTRAIR` | `2` | Meses recentes sempre reextraídos em MS, SC, MG e ES |
| `EXTRAIR_TUDO` | `0` | `1` volta à extração completa de todas as sedes |

### Se algo der errado

| Sintoma | Causa | O que fazer |
|---|---|---|
| Execução falha por tempo esgotado na carga inicial | Faltou o tempo limite de 4 h | Repetir o Passo 7; o que já está no bucket é pulado |
| `Permission denied` ao gravar em `/mnt/bucket/cotacoes` | Volume somente leitura, ou conta sem `storage.objectAdmin` | Conferir os Passos 6 e 5 |
| `Access Denied` no `bq` | Conta de serviço sem os papéis do BigQuery | Refazer o Passo 5 |
| Execução termina por memória | Menos de 4 GiB no job | `gcloud run jobs update ciclo-ceasa --memory=4Gi --region=$REGIAO` |
| `tesseract: not found` ou `pdftotext` ausente | Imagem construída de um clone antigo | Conferir a branch (Passo 3) e refazer o build (Passo 4.2) |
| `ERRO: ceasa_xx falhou` e saída 1 | Site da sede fora do ar ou formato novo | Ler o trecho de `ceasa_xx` nos Registros; executar de novo mais tarde |
| Extrator da GO sai 2 | Mais PDFs sem dados que os 2 boletins conhecidos | Ver o CSV de falhas indicado no log |
| GO com bem menos linhas que o esperado | Carga inicial sem `ANO_INICIAL_GO=2019` | Repetir o Passo 7; só os anos que faltam são baixados |
| Bronze da GO falha pelo número de colunas | CSV de outra sede em `raw/` | Mover o arquivo para `csv/` |
| `Not found: Dataset pdm-ceasa:bronze` | Dataset não criado, ou outro projeto ativo | Passo 1; conferir `gcloud config list` |

Como todo coletor pula o que já existe no bucket, executar o job de novo
nunca duplica brutos: ele continua de onde a execução anterior parou.

---

# Parte D — Rodar sem o Cloud Run

Para testar uma mudança ou rodar à mão, o mesmo ciclo roda num terminal com
`gcloud` e `bq` autenticados (Passo 0) e as dependências da imagem. Os
Passos 1 e 2 continuam valendo.

## Passo 11 — Dependências e execução

As mesmas do `Dockerfile` (Linux, Debian/Ubuntu):

```bash
sudo apt install poppler-utils tesseract-ocr tesseract-ocr-por
pip install requests beautifulsoup4 xlrd openpyxl msoffcrypto-tool
```

### O ciclo inteiro

O `entrypoint.sh` aceita as mesmas variáveis da tabela do Passo 10. Fora do
Cloud Run, aponte `DIR_BRUTO` para uma pasta local que persista entre
execuções:

```bash
cd PDM-2026-CEASA
DIR_BRUTO=$HOME/cotacoes_ceasa ANO_INICIAL_GO=2019 ./entrypoint.sh    # primeira vez
DIR_BRUTO=$HOME/cotacoes_ceasa ./entrypoint.sh                        # dias seguintes
```

Ele envia os CSVs ao bucket e roda Bronze, Silver e Gold, exatamente como o
job. A carga inicial completa leva perto de 1h30 (tabela do Passo 7).

### Uma sede por vez

Útil para depurar uma sede sem rodar as outras. O CSV sai completo (sem a
extração incremental), e o `MERGE` grava só o que mudou. Exemplo com a SC;
MS, MG e ES são iguais, trocando a sigla e o número do `.sql`
(`03_` MS, `04_` SC, `05_` MG, `06_` ES):

```bash
python3 ingestao/scraping/ceasa_sc.py --bruto $HOME/cotacoes_ceasa/sc --saida /tmp/ceasa_sc.csv
gcloud storage cp /tmp/ceasa_sc.csv $BUCKET/csv/ceasa_sc.csv --project=$PROJETO
bq query --project_id=$PROJETO --use_legacy_sql=false \
    --parameter="bucket:STRING:$BUCKET" < sql/construir_tabelas/bronze/04_ceasa_sc.sql
```

A GO usa o par coletor e extrator e alimenta duas tabelas:

```bash
python3 ingestao/ceasa_scraper.py --start-year 2019 --out $HOME/cotacoes_ceasa/go
python3 ingestao/ceasa_extrair.py --ocr --entrada $HOME/cotacoes_ceasa/go \
    --saida /tmp/cotacoes_site.csv --falhas-esperadas 2
gcloud storage cp /tmp/cotacoes_site.csv $BUCKET/raw/cotacoes_site.csv --project=$PROJETO
for f in 01_bronze 02_ceasa_go; do
  bq query --project_id=$PROJETO --use_legacy_sql=false \
      --parameter="bucket:STRING:$BUCKET" < sql/construir_tabelas/bronze/$f.sql
done
```

O extrator da GO sai com 0 quando está tudo certo e com 2 quando há mais PDFs
sem dados que os 2 boletins semanais conhecidos.

### Silver e Gold

Em ordem numérica, parando no primeiro erro:

```bash
for f in sql/construir_tabelas/silver/*.sql sql/construir_tabelas/gold/*.sql; do
  echo "-- $f"
  bq query --project_id=$PROJETO --use_legacy_sql=false --quiet < "$f" || break
done
```

Ficam fora, de propósito, `sql/modelo/` e `sql/construir_tabelas/metricas/`:
cada script de modelo tem `CREATE OR REPLACE MODEL` e retreina, com custo.
Para validar um deles sem treinar:

```bash
bq query --dry_run --use_legacy_sql=false < sql/modelo/<camada>/<arquivo>.sql
```

A conferência de duas vias (`05_ceasa_check.sql`) depende do manifesto, que
só o `entrypoint.sh` gera. Rodando uma sede por vez, use as duas primeiras
tabelas dele (tamanho e prova do `MERGE`).
