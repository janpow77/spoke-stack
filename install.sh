#!/usr/bin/env bash
# Spoke-Stack One-Liner-Setup.
#
# Kopiert .env.example nach /etc/spoke-stack/env (wenn nicht vorhanden),
# erstellt /var/lib/spoke-agent und /var/lib/reranker/data, startet die
# Compose-Datei. Fragt nach SPOKE_NAME wenn nicht in ENV gesetzt.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETC_DIR="/etc/spoke-stack"
DATA_AGENT="/var/lib/spoke-agent"
DATA_RERANKER="/var/lib/reranker/data"
DATA_OLLAMA="/var/lib/ollama"
DATA_VISION="/var/lib/vision/data"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker nicht installiert. Bitte erst Docker einrichten." >&2
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: docker compose plugin fehlt." >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
else
    SUDO=""
fi

$SUDO mkdir -p "$ETC_DIR" "$DATA_AGENT" "$DATA_RERANKER" "$DATA_OLLAMA" "$DATA_VISION"

if [[ ! -f "$ETC_DIR/env" ]]; then
    $SUDO cp "$REPO_DIR/.env.example" "$ETC_DIR/env"
    $SUDO chmod 600 "$ETC_DIR/env"
    echo "INFO: $ETC_DIR/env aus Template angelegt — BITTE ANPASSEN BEVOR DU UP-START."
    if [[ -n "${EDITOR:-}" ]]; then
        echo "Druecke Enter um '$EDITOR $ETC_DIR/env' zu oeffnen, oder Ctrl-C zum Abbrechen."
        read -r
        $SUDO "$EDITOR" "$ETC_DIR/env"
    fi
else
    echo "INFO: $ETC_DIR/env existiert bereits — nicht ueberschrieben."
fi

# Hartstop wenn Template-Platzhalter noch drin sind. Schuetzt davor, dass
# Ollama mit Default-Bind 0.0.0.0 ohne Auth ans LAN exposed wird oder das
# Vault-Token nie ersetzt wurde.
if $SUDO grep -qE "^[A-Z_]+=CHANGEME" "$ETC_DIR/env"; then
    echo ""
    echo "ABORT: $ETC_DIR/env enthaelt noch CHANGEME-Platzhalter. Bitte"
    echo "       editieren und Tokens/API-Keys setzen, dann install.sh erneut starten." >&2
    $SUDO grep -nE "^[A-Z_]+=CHANGEME" "$ETC_DIR/env" >&2
    exit 2
fi

# Compose-Datei nach /etc kopieren (read-only Bind im spoke-agent-Container).
$SUDO cp "$REPO_DIR/compose.yaml" "$ETC_DIR/compose.yaml"
if [[ -f "$REPO_DIR/compose.gpu.yaml" ]]; then
    $SUDO cp "$REPO_DIR/compose.gpu.yaml" "$ETC_DIR/compose.gpu.yaml"
fi

# GPU-Detection: NVIDIA / AMD-ROCm / Intel / CPU-only
COMPOSE_ARGS=("-f" "$ETC_DIR/compose.yaml")
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    echo "INFO: NVIDIA-GPU erkannt — compose.gpu.yaml mergen."
    $SUDO cp -f "$REPO_DIR/compose.gpu.yaml" "$ETC_DIR/compose.gpu.yaml"
    COMPOSE_ARGS+=("-f" "$ETC_DIR/compose.gpu.yaml")
elif command -v rocminfo >/dev/null 2>&1 && rocminfo 2>/dev/null | grep -qE 'gfx[0-9]+'; then
    echo "INFO: AMD-GPU (ROCm) erkannt — compose.amd.yaml mergen."
    $SUDO cp -f "$REPO_DIR/compose.amd.yaml" "$ETC_DIR/compose.amd.yaml"
    COMPOSE_ARGS+=("-f" "$ETC_DIR/compose.amd.yaml")
fi

echo "INFO: docker compose ${COMPOSE_ARGS[*]} up -d"
$SUDO docker compose "${COMPOSE_ARGS[@]}" --env-file "$ETC_DIR/env" up -d

echo "INFO: Status:"
$SUDO docker compose "${COMPOSE_ARGS[@]}" --env-file "$ETC_DIR/env" ps

echo ""
echo "Spoke-Agent UI:  http://localhost:7844/admin/"
echo "Konfig-Datei:    $ETC_DIR/env"
echo "Logs:            sudo docker logs -f spoke-agent"
