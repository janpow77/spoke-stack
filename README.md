# spoke-stack

Compose-Stack fuer einen LLM-Router-Spoke. Wird auf jedem Host (NUC, evo-x2,
Desktop, MacBook) deployt. Beinhaltet:

| Service | Port | Image | Zweck |
|---|---|---|---|
| `ollama` | 11434 | `ollama/ollama:latest` | LLM-Inference |
| `reranker-service` | 8004 | `ghcr.io/janpow77/reranker-service` | Cross-Encoder Rerank |
| `vision-service` | 8005 | `ghcr.io/janpow77/vision-service` | (PLACEHOLDER) Vision/OCR |
| `spoke-agent` | 7844 | `ghcr.io/janpow77/spoke-agent` | Discovery + Heartbeat + UI |

## Architektur

```
                          +--------------------+
                          |  llm-router (CCX23)|
                          +---------^----------+
                                    |
                            heartbeat / register
                                    |
+-----------------------------------+----------------------------------+
| Host (NUC / evo-x2 / Desktop / MacBook)                              |
|                                                                      |
|  +-------------+   +-------------+   +-------------+  +-----------+  |
|  |   ollama    |   |  reranker   |   |   vision    |  |  spoke-   |  |
|  |  :11434     |   |   :8004     |   |   :8005     |  |  agent    |  |
|  +-----^-------+   +-----^-------+   +-----^-------+  |  :7844    |  |
|        |                 |                 |          +-----+-----+  |
|        +-----------------+-----------------+----------------+        |
|                          local HTTP probes                           |
+-----------------------------------------------------------------------+
```

`spoke-agent` laeuft als **host-network**-Container damit er die anderen
Services unter `127.0.0.1:<port>` erreicht. Er greift via gemountetem
`/var/run/docker.sock` auf die anderen Container zu (logs, restart, update).

## Quick Start (One-Liner)

```bash
# Komplette Installation: Docker + Tailscale + nvidia-toolkit + Repo + compose up
curl -fsSL https://raw.githubusercontent.com/janpow77/spoke-stack/master/bootstrap.sh | sudo bash
```

Mit vorgegebener Konfig:
```bash
sudo SPOKE_NAME=evo SPOKE_TAGS=gpu,linux \
    ROUTER_URL=http://100.99.159.80:7842 \
    SPOKE_REGISTRATION_TOKEN=… \
    GHCR_TOKEN=… \
    bash bootstrap.sh
```

Was `bootstrap.sh` macht:
1. Docker + Compose-Plugin (via get.docker.com falls fehlt)
2. Tailscale-Daemon installieren + `tailscale up` (falls fehlt)
3. NVIDIA Container Toolkit (falls NVIDIA-GPU)
4. GHCR-Login mit `GHCR_TOKEN` (optional bei public Packages)
5. Repo klonen nach `/opt/spoke-stack`
6. `/etc/spoke-stack/env` aus Template, Tailscale-IP als Bind-Default
7. `install.sh` ausführen (GPU-Override automatisch detected)

## Manuelle Installation (advanced)

```bash
git clone https://github.com/janpow77/spoke-stack.git
cd spoke-stack
./install.sh
```

`install.sh`:
1. Prueft Docker + docker-compose-plugin.
2. Legt `/etc/spoke-stack/{env,compose.yaml}` an (`.env.example` -> `env`).
3. Detektiert NVIDIA-GPU (via `nvidia-smi`) und mergt automatisch
   `compose.gpu.yaml`.
4. `docker compose up -d`.

## Konfig

Alle Variablen leben in `/etc/spoke-stack/env` (siehe `.env.example`).
Wichtige Felder:

| Feld | Default | Zweck |
|---|---|---|
| `SPOKE_NAME` | hostname | Identitaet im Router |
| `ROUTER_URL` | `http://100.99.159.80:8080` | Primary Router |
| `FALLBACK_ROUTER_URL` | — | Aktiv nach 3 Failures |
| `API_KEY` | — | Bearer fuer Router |
| `SPOKE_REGISTRATION_TOKEN` | — | `X-Spoke-Token` Header |
| `SPOKE_AGENT_ADMIN_PASSWORD` | `spoke-admin` | UI-Login |

## Per-Host-Konfig (Beispiele)

**NUC** (Linux + RTX 5070 Ti):
```env
SPOKE_NAME=nuc
SPOKE_TAGS=gpu,linux,rtx5070ti
RERANKER_DEVICE=cuda
```

**evo-x2** (Linux + RTX 3090):
```env
SPOKE_NAME=evo-x2
SPOKE_TAGS=gpu,linux,rtx3090
RERANKER_DEVICE=cuda
```

**Desktop**:
```env
SPOKE_NAME=desktop
SPOKE_TAGS=gpu,linux
```

**MacBook** (macOS, kein NVIDIA):
```env
SPOKE_NAME=macbook
SPOKE_TAGS=apple-metal,arm64
RERANKER_DEVICE=cpu
# compose.gpu.yaml NICHT verwenden
```

## Verwandte Repos

- [`spoke-agent`](https://github.com/janpow77/spoke-agent) — Agent-Code (FastAPI + Vue)
- [`reranker-service`](https://github.com/janpow77/reranker-service)
- [`llm-router`](https://github.com/janpow77/llm-router) — Zentraler Router auf CCX23

## CI

`.github/workflows/ci.yml` smoketestet `docker compose config` auf jeden
Push (validiert die Compose-Syntax + Env-Substitution).
