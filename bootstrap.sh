#!/usr/bin/env bash
# Spoke-Stack One-Liner-Bootstrap.
#
# Nutzung (auf NUC / evo-x2 / Desktop / Mac mit Linux-Subsystem):
#   curl -fsSL https://raw.githubusercontent.com/janpow77/spoke-stack/master/bootstrap.sh | bash
#
# Oder mit vorgegebenen Werten:
#   SPOKE_NAME=evo SPOKE_TAGS=gpu,linux ROUTER_URL=http://100.99.159.80:7842 \
#     SPOKE_REGISTRATION_TOKEN=… GHCR_TOKEN=… bash bootstrap.sh
#
# Was passiert:
#   1. Docker + Compose Plugin installieren (falls fehlt)
#   2. Tailscale installieren + `tailscale up` (falls fehlt)
#   3. NVIDIA Container Toolkit installieren (falls NVIDIA-GPU vorhanden)
#   4. GHCR-Login mit User-Token (für private Images)
#   5. Repo unter /opt/spoke-stack klonen / pullen
#   6. /etc/spoke-stack/env aus Template anlegen + (wenn ENV-Vars gesetzt) ausfüllen
#   7. `install.sh` ausfuehren (compose up -d mit GPU-Override wenn da)

set -euo pipefail

REPO="https://github.com/janpow77/spoke-stack"
INSTALL_DIR="/opt/spoke-stack"
ENV_FILE="/etc/spoke-stack/env"
LOG_TAG="[spoke-bootstrap]"

log() { echo "${LOG_TAG} $*" >&2; }
err() { echo "${LOG_TAG} ERROR: $*" >&2; exit 1; }

# ------------- Pre-Flight -----------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO=sudo
    else
        err "Bitte als root oder mit sudo ausfuehren."
    fi
else
    SUDO=""
fi

OS_FAMILY="$(uname -s)"
case "$OS_FAMILY" in
    Linux)   log "Linux erkannt." ;;
    Darwin)  err "macOS: bitte Docker Desktop manuell installieren, dann clone + ./install.sh." ;;
    *)       err "Unbekannte OS-Family: $OS_FAMILY" ;;
esac

# Distribution detect (apt / dnf / pacman)
DISTRO=""
if command -v apt-get >/dev/null 2>&1; then DISTRO=apt
elif command -v dnf >/dev/null 2>&1; then DISTRO=dnf
elif command -v pacman >/dev/null 2>&1; then DISTRO=pacman
else err "Unbekannter Paket-Manager. Manuelle Installation erforderlich."
fi

# ------------- Docker --------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
    log "Docker fehlt — installiere via convenience-Script (https://get.docker.com)…"
    curl -fsSL https://get.docker.com | $SUDO sh
    $SUDO usermod -aG docker "${SUDO_USER:-$USER}" 2>/dev/null || true
else
    log "Docker vorhanden: $(docker --version)"
fi

if ! docker compose version >/dev/null 2>&1; then
    log "docker compose plugin fehlt — installiere…"
    case "$DISTRO" in
        apt) $SUDO apt-get update -qq && $SUDO apt-get install -y -qq docker-compose-plugin ;;
        dnf) $SUDO dnf install -y docker-compose-plugin ;;
        pacman) $SUDO pacman -S --noconfirm docker-compose ;;
    esac
fi

# ------------- Tailscale ------------------------------------------------------

if ! command -v tailscale >/dev/null 2>&1; then
    log "Tailscale fehlt — installiere via offiziellem Script…"
    curl -fsSL https://tailscale.com/install.sh | $SUDO sh
fi

if ! $SUDO tailscale status >/dev/null 2>&1; then
    log "Tailscale nicht verbunden — bitte `sudo tailscale up` manuell ausfuehren."
    log "(Wir warten dann auf eine Tailscale-IP …)"
    $SUDO tailscale up || err "tailscale up fehlgeschlagen."
fi

TS_IP="$($SUDO tailscale ip -4 2>/dev/null | head -1 || echo '')"
[[ -z "$TS_IP" ]] && err "Tailscale-IP nicht ermittelbar. Setup haengt."
log "Tailscale-IP: $TS_IP"

# ------------- NVIDIA Container Toolkit (optional) ---------------------------

HAS_NVIDIA=0
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    HAS_NVIDIA=1
    log "NVIDIA-GPU erkannt: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
    if ! docker info 2>/dev/null | grep -q nvidia; then
        log "NVIDIA-Container-Toolkit fehlt — installiere…"
        case "$DISTRO" in
            apt)
                distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
                curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | $SUDO gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
                curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
                    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
                    | $SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
                $SUDO apt-get update -qq
                $SUDO apt-get install -y -qq nvidia-container-toolkit
                $SUDO nvidia-ctk runtime configure --runtime=docker
                $SUDO systemctl restart docker
                ;;
            *) log "Bitte nvidia-container-toolkit manuell installieren (https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)" ;;
        esac
    fi
fi

# ------------- GHCR-Login (private Packages) ---------------------------------
#
# Wenn die Images public sind, ist Login optional. Falls private, prüfen wir
# auf GHCR_TOKEN-Env oder bestehenden Login.

if [[ -n "${GHCR_TOKEN:-}" ]]; then
    log "GHCR-Login mit GHCR_TOKEN-Env…"
    echo "$GHCR_TOKEN" | $SUDO docker login ghcr.io -u "${GHCR_USER:-janpow77}" --password-stdin
elif $SUDO docker info 2>/dev/null | grep -q "Registry.*ghcr.io"; then
    log "GHCR-Login bereits vorhanden."
else
    log "WARN: kein GHCR-Login. Wenn Images private, faellt der Pull spaeter."
    log "      Setze GHCR_TOKEN=<gh-pat-with-read:packages> + neu starten."
fi

# ------------- Repo klonen / aktualisieren -----------------------------------

if [[ ! -d "$INSTALL_DIR/.git" ]]; then
    log "Klone Repo nach $INSTALL_DIR…"
    $SUDO git clone "$REPO" "$INSTALL_DIR"
else
    log "Repo existiert — pulle…"
    $SUDO git -C "$INSTALL_DIR" pull --ff-only
fi

# ------------- .env vorbereiten ----------------------------------------------

$SUDO mkdir -p /etc/spoke-stack

if [[ ! -f "$ENV_FILE" ]]; then
    $SUDO cp "$INSTALL_DIR/.env.example" "$ENV_FILE"
    $SUDO chmod 600 "$ENV_FILE"
    log "Template-Env unter $ENV_FILE angelegt."
fi

# Vorgegebene ENV-Vars in /etc/spoke-stack/env eintragen.
set_kv() {
    local key="$1" val="$2"
    [[ -z "$val" ]] && return
    if $SUDO grep -qE "^${key}=" "$ENV_FILE"; then
        $SUDO sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" | $SUDO tee -a "$ENV_FILE" >/dev/null
    fi
}

# Default SPOKE_NAME = hostname wenn nicht gesetzt
: "${SPOKE_NAME:=$(hostname -s)}"
# Default Tags inkl. gpu/cpu
if [[ -z "${SPOKE_TAGS:-}" ]]; then
    if [[ $HAS_NVIDIA -eq 1 ]]; then
        SPOKE_TAGS="gpu,linux,nvidia"
    else
        SPOKE_TAGS="cpu,linux"
    fi
fi

# Default bind = Tailscale-IP (kein 0.0.0.0!)
: "${OLLAMA_BIND:=$TS_IP}"
: "${RERANKER_BIND:=$TS_IP}"
: "${VISION_BIND:=$TS_IP}"

set_kv SPOKE_NAME "$SPOKE_NAME"
set_kv SPOKE_TAGS "$SPOKE_TAGS"
set_kv OLLAMA_BIND "$OLLAMA_BIND"
set_kv RERANKER_BIND "$RERANKER_BIND"
set_kv VISION_BIND "$VISION_BIND"
[[ -n "${ROUTER_URL:-}" ]] && set_kv ROUTER_URL "$ROUTER_URL"
[[ -n "${FALLBACK_ROUTER_URL:-}" ]] && set_kv FALLBACK_ROUTER_URL "$FALLBACK_ROUTER_URL"
[[ -n "${API_KEY:-}" ]] && set_kv API_KEY "$API_KEY"
[[ -n "${SPOKE_REGISTRATION_TOKEN:-}" ]] && set_kv SPOKE_REGISTRATION_TOKEN "$SPOKE_REGISTRATION_TOKEN"
[[ -n "${SPOKE_AGENT_ADMIN_PASSWORD:-}" ]] && set_kv SPOKE_AGENT_ADMIN_PASSWORD "$SPOKE_AGENT_ADMIN_PASSWORD"

# CHANGEME-Check
if $SUDO grep -qE "^[A-Z_]+=CHANGEME" "$ENV_FILE"; then
    log "WARN: $ENV_FILE enthaelt noch CHANGEME-Platzhalter. Bitte editieren:"
    $SUDO grep -nE "^[A-Z_]+=CHANGEME" "$ENV_FILE" >&2
    log "Dann erneut: sudo bash $INSTALL_DIR/bootstrap.sh"
    err "Abort."
fi

# ------------- Compose starten -----------------------------------------------

cd "$INSTALL_DIR"
$SUDO ./install.sh

# ------------- Final ---------------------------------------------------------

log ""
log "============================================================"
log "  Spoke-Stack ist installiert."
log ""
log "  Konfig:      $ENV_FILE"
log "  Tailscale:   $TS_IP"
log "  Spoke-Agent: http://$TS_IP:7700/admin/"
log "  Logs:        sudo docker compose -f /etc/spoke-stack/compose.yaml logs -f"
log ""
log "  Naechste Schritte:"
log "    1. Spoke-Agent UI oeffnen + Verbindung zum llm-router pruefen"
log "    2. (optional) spoke-widget Tray-App installieren:"
log "       https://github.com/janpow77/spoke-widget/releases/latest"
log "============================================================"
