# Idea Board: AI-First, Cloud-Agnostic DevOps Platform

A small **Idea Board** (React + FastAPI + PostgreSQL) delivered by a platform that is the real subject of this
project. It includes:

* **One Terraform interface, two clouds (AWS and GCP).** Network, security, **managed PostgreSQL**
  (RDS / Cloud SQL) and Kubernetes (k3s on a free-tier VM, or EKS / GKE).
* **Cloud-agnostic delivery.** The same container images, Kubernetes manifests and deploy script are used for every cloud.
* **An AI-powered CI/CD pipeline.** The AI analyzes rollout logs, **triggers automatic rollbacks** with a
  human-readable summary, gates the rollout between clouds, and turns high-level goals
  (*"cost-sensitive staging"*) into validated environment configuration.

## Live deployments

| Cloud | URL | Status |
|---|---|---|
| AWS (k3s on EC2 + RDS PostgreSQL, us-east-1) | **https://100-53-43-210.sslip.io/** | ✅ Live. Provisioned with `scripts/infra.sh aws free-tier apply` (22 resources), deployed by the pipeline (rollout + public smoke test + AI analysis + AI release gate, all green) |
| GCP (k3s on Compute Engine + Cloud SQL) | _pending_ | Infrastructure code validated; needs a GCP project |

The live site uses HTTPS with a Let's Encrypt certificate. `sslip.io` is a free DNS service that maps the
hostname to the server's IP, so no domain purchase was needed.

## How to review (about 10 minutes)

1. **Use the live app:** open https://100-53-43-210.sslip.io/
   * **Ideas** (left): add an idea. It is stored in the managed RDS PostgreSQL database.
   * **AI Deployment Assistant:** click *Load failing logs → Analyze logs*, then *Load healthy logs → Analyze logs*.
   * **AI Environment Planner:** click *high-availability production → Plan*, then *cost-sensitive staging → Plan*.
   * API docs: https://100-53-43-210.sslip.io/api/ideas (JSON). `POST /api/ideas` takes `{"content": "..."}`.
2. **See the pipeline run:** [Actions → CI/CD](https://github.com/praveena2004-spec/ideaboard-devops/actions/workflows/ci-cd.yml).
   Open the latest run on `main`. Each job's **Summary** shows the AI log analysis, the AI release gate decision and the deploy result.
3. **Read the key code** (each file is short and commented):

   | What | File |
   |---|---|
   | AI features (analysis, rollback verdict, release gate, environment planning) | [backend/app/ai.py](backend/app/ai.py) |
   | Deploy with automatic rollback | [scripts/deploy.sh](scripts/deploy.sh) |
   | Pipeline | [.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml), [deploy-cloud.yml](.github/workflows/deploy-cloud.yml) |
   | Cloud-agnostic IaC | [terraform/modules/aws/main.tf](terraform/modules/aws/main.tf), [terraform/modules/gcp/main.tf](terraform/modules/gcp/main.tf) |
   | Kubernetes | [k8s/](k8s/) |

4. **Run it yourself:** `docker compose up --build` (see [section 2](#2-run-locally-with-docker-compose)).

## Verification status

| Area | Status |
|---|---|
| Backend API, health checks, AI features: 20 unit tests | ✅ `pytest` |
| Docker images + `docker compose` stack | ✅ Smoke-tested locally and in CI on every push |
| Kubernetes manifests (4 overlays) | ✅ Schema-validated with `kubeconform` |
| **Deploy + automatic rollback on a real Kubernetes cluster** | ✅ Tested on kind: a deliberately broken release was detected and rolled back with zero downtime ([details](#rollback-tested-on-a-real-cluster)) |
| AI environment plan applied during a real deploy | ✅ Tested on kind |
| Terraform for AWS and GCP | ✅ `fmt` + `validate` for both; **AWS applied for real** (VPC, security groups, RDS, EC2 + k3s) |
| CD pipeline to a cloud | ✅ AWS: images → deploy → AI analysis → AI release gate, all green |
| LLM path against the live Claude API | ⚠️ Tested with a mocked client only; set `ANTHROPIC_API_KEY` to use Claude. Without it a rule-based analyzer answers, and every result says which one did. |
| Cloud deployments | ⏳ See [Live deployments](#live-deployments) |

---

## 1. Architecture

```mermaid
flowchart TB
  subgraph Dev["Developer"]
    code[git push / PR] --> gha
    goal["goal: 'cost-sensitive staging'"] -.-> gha
  end

  subgraph gha["GitHub Actions"]
    t[tests · build · IaC + manifest validation · compose smoke test] --> img[images → GHCR]
    img --> d1["deploy AWS<br/>rollout → smoke test → AI log analysis<br/>→ auto-rollback"]
    d1 --> gate{"AI release gate"}
    gate -->|deploy / canary| d2["deploy GCP<br/>(same steps)"]
    gate -->|hold / rollback| stop[stop rollout]
  end

  subgraph AWS
    k1["k3s on EC2<br/>(or EKS)"] --> rds[(RDS PostgreSQL<br/>private subnet)]
  end
  subgraph GCP
    k2["k3s on Compute Engine<br/>(or GKE)"] --> csql[(Cloud SQL<br/>private IP)]
  end
  d1 --> k1
  d2 --> k2
  llm["Claude API"] -. structured JSON .- d1
  llm -. .- gate
```

**Inside each cluster:** `frontend` (nginx serving the React build, proxies `/api`) → `backend` (FastAPI) →
managed PostgreSQL. The frontend Service is of type `LoadBalancer`: on k3s, ServiceLB serves it on the VM's port 80, and on
EKS/GKE it becomes a cloud load balancer.

| Component | Choice | Why |
|---|---|---|
| Edge | Caddy (HTTPS, automatic Let's Encrypt certificate, HTTP→HTTPS redirect) | One public entry point on every cloud |
| Frontend | React + Vite, served by `nginx-unprivileged` | Static build, non-root container, `/api` proxy so the browser sees one origin |
| Backend | FastAPI + SQLAlchemy | `GET/POST /api/ideas`, `/health` (liveness), `/ready` (readiness incl. DB), AI endpoints |
| Database | PostgreSQL 16, table `ideas(id, content, created_at)` | Managed in the cloud (RDS / Cloud SQL), container locally |
| Registry | GitHub Container Registry | Neutral: both clouds pull the same image, so no per-cloud registry is needed |
| IaC | Terraform, one module per cloud with an identical interface | See [Cloud-agnostic approach](#5-cloud-agnostic-approach) |
| Orchestration | Kubernetes: k3s (free tier) or EKS / GKE (`cluster_flavor`) | Same manifests on all of them |
| CI/CD | GitHub Actions + `scripts/deploy.sh` | Pipeline logic lives in a script you can run by hand too |
| AI | Claude via the Anthropic SDK, structured outputs, rule-based fallback | See [AI integration](#4-ai-integration) |

```
.
├── backend/            FastAPI app (app/ai.py = AI features, app/analyze_cli.py = AI CLI for the pipeline), tests/
├── frontend/           React UI: Idea Board, AI Deployment Assistant, AI Environment Planner; Dockerfile + nginx.conf
├── docker-compose.yml  local stack
├── k8s/
│   ├── base/                       backend + frontend (probes, rolling-update strategy, PDB, security context)
│   ├── components/in-cluster-postgres/   Postgres for local clusters only
│   └── overlays/{free-tier,staging,production,local}/
├── terraform/
│   ├── modules/aws/    VPC, subnets, security groups, RDS, k3s-on-EC2 | EKS
│   ├── modules/gcp/    VPC, firewall, private services access, Cloud SQL, k3s-on-GCE | GKE
│   ├── modules/shared/ k3s bootstrap script used by both clouds
│   └── environments/{aws,gcp}/   root configs + free-tier.tfvars / production.tfvars
├── scripts/
│   ├── infra.sh        one CLI for every cloud: plan/apply/destroy/kubeconfig/github-secrets
│   ├── deploy.sh       render → apply → wait → smoke test → AI analysis → rollback
│   ├── rollback.sh     manual rollback
│   └── smoke_test.sh   end-to-end check through the public entry point
├── samples/logs/       real + synthetic rollout logs (AI demo and regression tests)
└── .github/workflows/  ci-cd.yml (pipeline) + deploy-cloud.yml (reusable, per cloud)
```

---

## 2. Run locally with Docker Compose

Requirements: Docker Desktop (or Docker Engine + Compose v2).

```bash
git clone https://github.com/praveena2004-spec/ideaboard-devops.git
cd ideaboard-devops
cp .env.example .env            # Windows: copy .env.example .env
# edit .env: set POSTGRES_PASSWORD to any value; optionally ANTHROPIC_API_KEY
docker compose up --build
```

| URL | What |
|---|---|
| http://localhost:3000 | Idea Board + AI panels |
| http://localhost:8000/docs | Swagger UI |

Check the whole stack: `bash scripts/smoke_test.sh http://localhost:3000`

Startup order is enforced by health checks: `db` (pg_isready) → `backend` (`/health`) → `frontend`.

```bash
curl -X POST localhost:3000/api/ideas -H 'Content-Type: application/json' -d '{"content": "My new idea"}'
curl localhost:3000/api/ideas
```

**Without Docker:** `cd backend && pip install -r requirements-dev.txt && DATABASE_URL=sqlite:///./dev.db uvicorn app.main:app --reload`,
then in another terminal `cd frontend && npm install && npm run dev` (http://localhost:5173).

**On a local Kubernetes cluster (kind):**
```bash
kind create cluster --name ideaboard
docker build -t ideaboard-backend:v1 backend && docker build -t ideaboard-frontend:v1 frontend
kind load docker-image ideaboard-backend:v1 ideaboard-frontend:v1 --name ideaboard
POSTGRES_HOST=postgres POSTGRES_PASSWORD=devpass bash scripts/deploy.sh local ideaboard-backend:v1 ideaboard-frontend:v1
```

---

## 3. Deploy to a cloud with the pipeline

### 3.1 Provision infrastructure (once per cloud)

Install Terraform ≥ 1.6. Then:

```bash
# AWS: credentials from `aws configure` / SSO
bash scripts/infra.sh aws free-tier plan
bash scripts/infra.sh aws free-tier apply          # VPC, security groups, RDS, EC2 + k3s (~10 min)

# GCP: `gcloud auth application-default login` and a project with billing (free trial works)
export TF_VAR_project_id=<your-project-id>
bash scripts/infra.sh gcp free-tier apply          # VPC, firewall, Cloud SQL (private IP), VM + k3s
```

`free-tier.tfvars` uses free-tier-eligible resources. `production.tfvars` switches the same modules to
EKS/GKE with 3 nodes and a high-availability database (paid).

### 3.2 Connect the pipeline

```bash
gh auth login
bash scripts/infra.sh aws free-tier github-secrets   # creates GitHub Environment "aws" with
bash scripts/infra.sh gcp free-tier github-secrets   # KUBE_CONFIG, POSTGRES_*, APP_URL
```

Optional: add the repository secret `ANTHROPIC_API_KEY` to use Claude instead of the rule-based analyzer.

### 3.3 Run it

* **Every push to `main`:** tests → images → deploy AWS → AI gate → deploy GCP.
* **Actions → CI/CD → Run workflow** offers two inputs:
  * `simulate_bad_release` deploys a deliberately broken backend to AWS, to watch the automatic rollback.
  * `environment_goal` (e.g. `high-availability production`) makes the AI size replicas/resources for this rollout.
* Each deploy writes a job summary with the AI analysis. Logs and rendered manifests are uploaded as artifacts.

Manual deploy without CI: `eval "$(bash scripts/infra.sh aws free-tier deploy-env)"` then
`bash scripts/deploy.sh free-tier <backend-image> <frontend-image>`.

**Tear down:** `bash scripts/infra.sh aws free-tier destroy` (and `gcp`).

| Pipeline job | What it does |
|---|---|
| `backend-tests` | pytest; AI analysis of a sample failing rollout → job summary |
| `frontend-build` | `npm ci && npm run build` |
| `iac-validate` | `terraform fmt -check` + `validate` (AWS, GCP); `kubeconform` on all overlays |
| `compose-smoke-test` | builds the images, `docker compose up --wait`, end-to-end smoke test, AI analysis on failure |
| `publish-images` | pushes `ghcr.io/<owner>/ideaboard-{backend,frontend}:<sha>` |
| `deploy-aws` | reusable `deploy-cloud.yml`: deploy, AI analysis, auto-rollback, public URL check |
| `ai-release-gate` | AI reads the AWS rollout and returns deploy/canary/hold/rollback; hold/rollback stops the rollout |
| `deploy-gcp` | same reusable workflow, next cloud |

---

## 4. AI integration

**The problem it targets:** a failed deployment usually means someone digging through `kubectl` events and pod logs
under time pressure, then deciding whether to roll back. Sizing an environment means translating vague goals
("cheap", "highly available") into a dozen settings. Both are tedious, error-prone and repetitive, which makes them
a good fit for an LLM, provided it can't break production on its own.

### What I built

| Feature | Where it runs | What it does |
|---|---|---|
| **1. Deployment log analysis** | every deploy (`deploy.sh`), UI, `POST /api/ai/analyze-logs` | Collects pod status, events and logs (incl. previous crashed containers) and returns *status, root cause, issues, suggested fixes, recommendation (proceed / investigate / rollback), confidence*. Written to the GitHub job summary. |
| **2. AI-triggered rollback** | `deploy.sh` step 6 | If the rollout passed every check **but** the LLM is *highly confident* the release is broken (e.g. errors on every request), the release is rolled back anyway, with the AI's summary in the job output. |
| **3. AI release gate** | `ai-release-gate` job | AWS acts as the canary cloud. The AI reads its rollout and returns **deploy / canary / hold / rollback** with reasons. Anything but deploy/canary stops the rollout before GCP. |
| **4. AI environment planning** | `environment_goal` input, UI, `POST /api/ai/environment-plan`, `analyze_cli plan` | Turns a goal like *"cost-sensitive staging"* or *"high-availability production"* into cluster flavor, node size/count, replicas, CPU/memory, DB size and HA. Generates a **Kustomize patch** (applied in the rollout) and **Terraform variables**. |

### Design choices
* **Structured outputs, not free text.** Every call uses `output_config.format` with a JSON schema, and the result is
  validated with Pydantic. The pipeline consumes fields (`recommendation`, `confidence`), never prose.
* **The AI proposes, guardrails decide.**
  * Environment plans are clamped to hard limits (replicas 1–10, memory 128–2048 MiB, k3s = 1 node).
    Every correction is listed in `adjustments`.
  * An AI-triggered rollback requires `source=llm` **and** `confidence=high`.
  * Objective checks (`kubectl rollout status`, readiness probes, smoke test) always win: a wrong answer from the
    model can't keep a broken release, and it can only roll back a release it is highly confident about.
* **Always works, always honest.** With no API key, if the API fails, or if the model declines, a deterministic rule-based
  analyzer (CrashLoopBackOff, OOMKilled, ImagePullBackOff, probe failures, DB errors, 5xx on `/api`, tracebacks)
  answers instead. Every response carries `source: "llm" | "rules"` and a note.
  * The rules know that probe failures during startup are normal once a rollout succeeded.
  * This was tuned on **real** kind rollout logs, which are kept as a regression test (`samples/logs/kind-healthy-deploy.log`).
* **No silent truncation.** Oversized logs are rejected (HTTP 413) rather than cut, so the analysis never misses the
  part that mattered.
* **Model/API:** Anthropic Python SDK, `claude-opus-5-5` (configurable via `AI_MODEL`), server-side refusal fallbacks
  enabled. The same `app/ai.py` powers the API, the UI and the pipeline CLI.

### Tangible value
* **Time to understand a failure:** the job summary states the likely root cause and fixes. Nobody has to open
  `kubectl` first.
* **Blast radius:** a bad release is stopped after the first cloud. A rollback restores the exact previous revision,
  and the old pods keep serving throughout (`maxUnavailable: 0`).
* **Environment requests become intent ("cheap", "HA")**, not YAML, and stay inside guardrails.

```bash
cd backend
python -m app.analyze_cli logs ../samples/logs/failed-deploy.log
python -m app.analyze_cli recommend --environment production --logs ../samples/logs/healthy-deploy.log
python -m app.analyze_cli plan "high-availability production" --patch-out plan.yaml --tfvars-out plan.tfvars
```

---

## 5. Cloud-agnostic approach

**Principle:** cloud-specific code is confined to one Terraform module per cloud. Everything above that line is
identical for every cloud.

| Layer | Cloud-specific? | How |
|---|---|---|
| Container images | No | One build, pushed to GHCR, pulled by every cluster |
| Kubernetes manifests | No | Same base + overlay. The DB location arrives at deploy time in the `ideaboard-db` Secret. LoadBalancer works on k3s, EKS and GKE |
| Deploy, rollback, AI | No | `scripts/deploy.sh` only needs a kubeconfig and DB settings |
| Pipeline | No | One reusable `deploy-cloud.yml`. The cloud name selects a GitHub Environment (secrets) |
| Infrastructure | **Yes, behind one interface** | `modules/aws` and `modules/gcp` take the **same variables** and return the **same outputs** |

**The interface** (both modules):

```hcl
# inputs
name, environment, region
cluster_flavor        = "k3s" | "managed"         # one VM with k3s, or EKS/GKE
node_size             = "small" | "medium" | "large"   # → t3.small / e2-micro, t3.medium / e2-medium, ...
node_count, kubernetes_version
db_size               = "micro" | "small" | "medium"   # → db.t3.micro / db-f1-micro, ...
db_high_availability  = true | false              # Multi-AZ / REGIONAL
admin_cidrs                                        # who may reach SSH / Kubernetes API

# outputs
cloud, cluster_flavor, cluster_name, public_ip, kubeconfig_command,
database_host, database_port, database_name, database_username, database_password, ssh_private_key
```

Each module implements the same building blocks: private network for the database, firewall/security groups (only port 80
public, DB reachable only from inside the VPC, encrypted storage), managed PostgreSQL, and the chosen Kubernetes
flavor. The k3s bootstrap script is shared; only the "what is my public IP" metadata call differs.

**Switching cloud = changing one argument:** `scripts/infra.sh aws free-tier apply` ↔ `scripts/infra.sh gcp free-tier apply`.
The `.tfvars` files of both clouds differ only in the region name.

**Adding a third cloud (e.g. Azure):**
1. `terraform/modules/azure/`: implement the interface (VNet, NSG, Azure Database for PostgreSQL, VM + k3s or AKS).
   Reuse `modules/shared/k3s-bootstrap.sh.tftpl`.
2. `terraform/environments/azure/`: copy a root config and change the provider block.
3. Add a `deploy-azure` job that calls `deploy-cloud.yml` with `cloud: azure`.

No change is needed to the application, the images, the Kubernetes manifests, `deploy.sh` or the AI features.

---

## 6. Reliability and security

| Concern | Implementation |
|---|---|
| Health checks | `startupProbe` + `livenessProbe` on `/health` (no DB dependency, so a DB outage doesn't cause restart storms); `readinessProbe` on `/ready` (DB + schema) |
| DB not ready yet | The backend never crashes. It stays not-ready and retries (found and fixed during the kind test) |
| Zero-downtime rollout | `RollingUpdate`, `maxUnavailable: 0`, `maxSurge: 1`, `minReadySeconds`, `progressDeadlineSeconds: 120` |
| Rollback | `deploy.sh` records each Deployment's revision **before** applying, and undoes to exactly that revision only for Deployments it changed. Config is hashed into the ConfigMap name, so config rolls back with code |
| Secrets | Never in git. `.env` locally, Kubernetes Secrets from GitHub Environment secrets, and Terraform-generated DB passwords |
| Containers | Non-root users, `allowPrivilegeEscalation: false`, all capabilities dropped |
| Network | DB in private subnets / private IP only. VM exposes 80 publicly, SSH + Kubernetes API (key / client-cert auth) to `admin_cidrs`. IMDSv2 enforced on EC2, Shielded VM on GCE |
| Cost safety | No NAT gateways, gp2/pd-standard disks within free-tier limits, T3 `standard` CPU credits (no burst billing), single-AZ DB in the free profile |

### Rollback tested on a real cluster
On a local kind cluster (`overlay: local`):
1. **v1 deployed** with AI environment plan *"cost-sensitive staging"*. Rollout and smoke test passed, and the AI said
   *healthy → proceed*.
2. **v2 deployed with `SIMULATE_UNHEALTHY=true`**. Its readiness probe failed, so the rollout never completed.
3. `deploy.sh` flagged the failure, the AI summarized it as *failed → rollback*, and the script ran
   `kubectl rollout undo --to-revision=1` on the backend only, leaving the frontend alone since it was unchanged.
4. The v1 pod **kept serving the whole time** (0 restarts). `/api/version` → `v1`, `/ready` → `ready`.

## 7. Known limitations and next steps
* Schema is created with `create_all`. Use Alembic and expand/contract migrations so code rollbacks stay safe across schema changes.
* The free-tier profile is one VM per cloud, so there's no node redundancy (use `production.tfvars`). There's no TLS on the
  raw IP; add a domain, Ingress and cert-manager.
* The k3s Kubernetes API is internet-reachable (client-certificate auth) because GitHub-hosted runners have no fixed IPs.
  A self-hosted runner or a pull-based GitOps agent (Argo CD) would allow closing it.
* Error-rate/latency signals for the release gate come from logs. Prometheus metrics would make them quantitative.
