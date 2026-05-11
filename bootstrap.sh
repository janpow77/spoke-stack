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

# ------------- Existing host-Ollama detection (Adopt-Mode) -------------------
#
# Wenn ein systemd-managed `ollama.service` laeuft, uebernehmen wir das
# Modell-Verzeichnis in den Compose-Stack und stoppen+disable den Host-Service.
# Damit migrieren wir bestehende Setups (NUC, evo2) ohne Modelle neu zu pullen.

ADOPT_OLLAMA_DIR=""
ADOPT_OLLAMA_USER=""
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ollama 2>/dev/null; then
    log "Host-Ollama-Service erkannt — Adopt-Mode aktiv."
    ADOPT_OLLAMA_USER="$(systemctl show -p User --value ollama 2>/dev/null || echo ollama)"
    # Standard-Ablage je Distro / Setup
    for candidate in \
        "/usr/share/ollama/.ollama" \
        "/var/lib/ollama" \
        "/home/$ADOPT_OLLAMA_USER/.ollama" \
        "/root/.ollama"; do
        if [[ -d "$candidate/models" ]]; then
            ADOPT_OLLAMA_DIR="$candidate"
            break
        fi
    done
    if [[ -z "$ADOPT_OLLAMA_DIR" ]]; then
        log "WARN: Host-Ollama laeuft, aber Modell-Verzeichnis nicht gefunden."
        log "      Bitte OLLAMA_DATA_DIR manuell in /etc/spoke-stack/env setzen."
    else
        log "Modell-Verzeichnis: $ADOPT_OLLAMA_DIR ($($SUDO du -sh "$ADOPT_OLLAMA_DIR/models" 2>/dev/null | cut -f1))"
    fi
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

# ------------- GPU-Detection (NVIDIA / AMD-ROCm / Intel / CPU-only) -----------

HAS_NVIDIA=0
HAS_AMD=0
GPU_TYPE="cpu"   # cpu | nvidia | amd | intel
GFX_VERSION=""

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    HAS_NVIDIA=1
    GPU_TYPE="nvidia"
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
elif command -v rocminfo >/dev/null 2>&1 && rocminfo 2>/dev/null | grep -q "GPU Agent"; then
    HAS_AMD=1
    GPU_TYPE="amd"
    GFX_VERSION=$(rocminfo 2>/dev/null | grep -oE 'gfx[0-9]+' | head -1)
    GPU_NAME=$(lspci 2>/dev/null | grep -iE "vga|display|3d" | head -1 | cut -d: -f3- | xargs)
    log "AMD-GPU erkannt: $GPU_NAME ($GFX_VERSION) via ROCm"
    # /dev/kfd + /dev/dri muessen existieren
    if [[ ! -e /dev/kfd ]] || [[ ! -e /dev/dri ]]; then
        log "WARN: /dev/kfd oder /dev/dri fehlt — ROCm-Setup unvollstaendig."
    fi
    # User in video + render Group?
    REAL_USER="${SUDO_USER:-$USER}"
    for grp in video render; do
        if ! groups "$REAL_USER" 2>/dev/null | grep -q "\b$grp\b"; then
            log "Adding $REAL_USER zu Gruppe $grp…"
            $SUDO usermod -aG "$grp" "$REAL_USER"
            log "WARN: User muss sich neu einloggen damit $grp-Mitgliedschaft greift."
        fi
    done
elif lspci 2>/dev/null | grep -qiE "intel.*arc|intel.*xe"; then
    GPU_TYPE="intel"
    log "Intel-Arc-GPU erkannt — Ollama-Vulkan-Backend wird genutzt."
    log "WARN: Intel-Pfad ist experimentell. compose.intel.yaml steht noch aus."
else
    log "Keine dedizierte GPU erkannt — CPU-only Modus."
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
# Default Tags inkl. GPU-Architektur
if [[ -z "${SPOKE_TAGS:-}" ]]; then
    case "$GPU_TYPE" in
        nvidia) SPOKE_TAGS="gpu,linux,nvidia" ;;
        amd)    SPOKE_TAGS="gpu,linux,amd,rocm" ;;
        intel)  SPOKE_TAGS="gpu,linux,intel" ;;
        *)      SPOKE_TAGS="cpu,linux" ;;
    esac
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

# Adopt-Mode: bestehendes Modell-Verzeichnis in compose-Volume mounten +
# Host-Service stoppen, sodass nur EIN Ollama laeuft (kein Port-Konflikt).
if [[ -n "$ADOPT_OLLAMA_DIR" ]]; then
    set_kv OLLAMA_DATA_DIR "$ADOPT_OLLAMA_DIR"
    log "Stoppe + disable Host-Ollama-Service (Modelle bleiben in $ADOPT_OLLAMA_DIR)…"
    $SUDO systemctl stop ollama || true
    $SUDO systemctl disable ollama 2>/dev/null || true
fi

# GPU-Defaults pro Hardware-Klasse (User kann ueberschreiben via Env):
case "$GPU_TYPE" in
    nvidia)
        GPU_COUNT_DETECTED=$(nvidia-smi -L 2>/dev/null | wc -l)
        : "${GPU_COUNT:=$GPU_COUNT_DETECTED}"
        # VRAM total ueber alle GPUs in MB
        VRAM_TOTAL_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {print s}')
        if [[ "$VRAM_TOTAL_MB" -gt 24000 ]]; then
            : "${OLLAMA_NUM_PARALLEL:=4}"; : "${OLLAMA_MAX_LOADED_MODELS:=3}"
        elif [[ "$VRAM_TOTAL_MB" -gt 14000 ]]; then
            : "${OLLAMA_NUM_PARALLEL:=2}"; : "${OLLAMA_MAX_LOADED_MODELS:=2}"
        else
            : "${OLLAMA_NUM_PARALLEL:=1}"; : "${OLLAMA_MAX_LOADED_MODELS:=1}"
        fi
        set_kv GPU_COUNT "$GPU_COUNT"
        ;;
    amd)
        # Unified-Memory: VRAM = System-RAM-Anteil. Strix Halo / Ryzen AI
        # MAX+ haben 128GB+ Pool — wir lassen Ollama selbst pacen.
        RAM_TOTAL_GB=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)
        if [[ "$RAM_TOTAL_GB" -gt 96 ]]; then
            : "${OLLAMA_NUM_PARALLEL:=4}"; : "${OLLAMA_MAX_LOADED_MODELS:=4}"
            log "AMD-iGPU mit ${RAM_TOTAL_GB}GB RAM-Pool — heavy-tier"
        elif [[ "$RAM_TOTAL_GB" -gt 32 ]]; then
            : "${OLLAMA_NUM_PARALLEL:=2}"; : "${OLLAMA_MAX_LOADED_MODELS:=2}"
        else
            : "${OLLAMA_NUM_PARALLEL:=1}"; : "${OLLAMA_MAX_LOADED_MODELS:=1}"
        fi
        # GFX-Version-Override (gfx1151 = Strix Halo, gfx1100 = RDNA3 dGPU…)
        case "$GFX_VERSION" in
            gfx1151) : "${HSA_OVERRIDE_GFX_VERSION:=11.5.1}" ;;
            gfx1150) : "${HSA_OVERRIDE_GFX_VERSION:=11.5.0}" ;;
            gfx1100|gfx1101|gfx1102) : "${HSA_OVERRIDE_GFX_VERSION:=11.0.0}" ;;
            gfx1030|gfx1031|gfx1032) : "${HSA_OVERRIDE_GFX_VERSION:=10.3.0}" ;;
            *) : "${HSA_OVERRIDE_GFX_VERSION:=}" ;;
        esac
        [[ -n "${HSA_OVERRIDE_GFX_VERSION:-}" ]] && set_kv HSA_OVERRIDE_GFX_VERSION "$HSA_OVERRIDE_GFX_VERSION"
        ;;
    intel|cpu)
        : "${OLLAMA_NUM_PARALLEL:=1}"; : "${OLLAMA_MAX_LOADED_MODELS:=1}"
        ;;
esac
set_kv OLLAMA_NUM_PARALLEL "$OLLAMA_NUM_PARALLEL"
set_kv OLLAMA_MAX_LOADED_MODELS "$OLLAMA_MAX_LOADED_MODELS"
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
