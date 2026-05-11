#!/usr/bin/env bash
# Spoke-Stack Bootstrap mit Pre-Flight + Post-Deploy-Validation + Rollback.
#
# Nutzung:
#   curl -fsSL https://raw.githubusercontent.com/janpow77/spoke-stack/master/bootstrap.sh | sudo bash
#
# ENV-Overrides:
#   SPOKE_NAME, SPOKE_TAGS, ROUTER_URL, SPOKE_REGISTRATION_TOKEN,
#   GHCR_TOKEN, GHCR_USER, EDITOR, SKIP_PREFLIGHT=1, SKIP_VALIDATE=1
#
# Pre-Flight-Checks (Abort bei Fail):
#   1. Root/sudo, bash 4+, curl, jq
#   2. Disk-Space >= 20GB frei
#   3. Tailscale up, IP da
#   4. Router-URL erreichbar
#   5. SPOKE_NAME nicht schon im Router belegt
#   6. Ports 11434/8004/8005/7844 frei (oder Adopt-Service)
#   7. Docker daemon running
#   8. GPU-Type detected (nvidia/amd/intel/cpu) — Toolkit ggf. installieren
#   9. Existing-Ollama: Modelle-Pfad existiert
#  10. /dev/kfd + /dev/dri (nur AMD)
#  11. User in video+render groups (nur AMD)
#  12. SPOKE_REGISTRATION_TOKEN nicht leer und nicht CHANGEME

set -euo pipefail

REPO="https://github.com/janpow77/spoke-stack"
INSTALL_DIR="/opt/spoke-stack"
ENV_FILE="/etc/spoke-stack/env"
LOG_TAG="[spoke-bootstrap]"
ROLLBACK_NEEDED=0
ADOPT_OLLAMA_DIR=""
ADOPT_OLLAMA_USER=""
ADOPT_OLLAMA_WAS_ACTIVE=0
PRE_DEPLOY_MODEL_COUNT=0

log()  { echo "${LOG_TAG} $*" >&2; }
warn() { echo "${LOG_TAG} ⚠ $*" >&2; }
ok()   { echo "${LOG_TAG} ✓ $*" >&2; }
err()  { echo "${LOG_TAG} ✗ ERROR: $*" >&2; exit 1; }

# Trap für Rollback bei unexpected exit
on_exit() {
    local rc=$?
    if [[ $rc -ne 0 && $ROLLBACK_NEEDED -eq 1 ]]; then
        warn "Bootstrap fehlgeschlagen (rc=$rc) — versuche Rollback…"
        rollback || true
    fi
}
trap on_exit EXIT


# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

preflight_check() {
    log "──────────────  Pre-Flight  ──────────────"
    check_runtime_basics
    check_disk_space
    check_tailscale
    check_router
    check_docker
    detect_gpu
    check_ports
    check_existing_ollama
    check_spoke_name_unique
    check_registration_token
    ok "Pre-Flight bestanden."
    echo "" >&2
}

check_runtime_basics() {
    [[ "$BASH_VERSION" =~ ^[4-9] ]] || err "bash >= 4 erforderlich (gefunden: $BASH_VERSION)"
    for cmd in curl git; do
        command -v "$cmd" >/dev/null 2>&1 || err "'$cmd' fehlt — bitte installieren."
    done
    # jq optional — fuer Router-API-Calls
    if ! command -v jq >/dev/null 2>&1; then
        warn "'jq' fehlt — installiere (fuer Router-API-Auswertung)…"
        case "$DISTRO" in
            apt) $SUDO apt-get install -y -qq jq ;;
            dnf) $SUDO dnf install -y jq ;;
            pacman) $SUDO pacman -S --noconfirm jq ;;
        esac
    fi
    ok "Runtime-Basics OK (bash, curl, git, jq)"
}

check_disk_space() {
    local needed_gb=20
    local target="/var/lib"
    local free_kb=$(df -k "$target" 2>/dev/null | awk 'NR==2 {print $4}')
    local free_gb=$((free_kb / 1024 / 1024))
    if [[ $free_gb -lt $needed_gb ]]; then
        err "Nicht genug Disk-Space in $target: ${free_gb}GB frei, ${needed_gb}GB benoetigt."
    fi
    ok "Disk-Space: ${free_gb}GB frei in $target"
}

check_tailscale() {
    if ! command -v tailscale >/dev/null 2>&1; then
        warn "Tailscale fehlt — installiere via offiziellem Script…"
        curl -fsSL https://tailscale.com/install.sh | $SUDO sh
    fi
    if ! $SUDO tailscale status >/dev/null 2>&1; then
        log "tailscaled nicht verbunden — versuche tailscale up (kann interaktiv sein)…"
        $SUDO tailscale up || err "tailscale up fehlgeschlagen — bitte 'sudo tailscale up' manuell ausfuehren."
    fi
    TS_IP="$($SUDO tailscale ip -4 2>/dev/null | head -1 || echo '')"
    [[ -n "$TS_IP" ]] || err "Tailscale-IP nicht ermittelbar."
    ok "Tailscale verbunden: $TS_IP"
}

check_router() {
    local url="${ROUTER_URL:-http://100.99.159.80:7842}"
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${url}/admin/api/health" 2>&1 || echo "000")
    if [[ "$status" =~ ^[23] ]]; then
        ok "Router erreichbar: $url (HTTP $status)"
    else
        warn "Router antwortet nicht (HTTP $status) — Migration laeuft trotzdem, aber Spoke-Registrierung wird scheitern bis Router online."
    fi
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log "Docker fehlt — installiere via get.docker.com (kann 30-60s dauern)…"
        curl -fsSL https://get.docker.com | $SUDO sh
        $SUDO usermod -aG docker "${SUDO_USER:-$USER}" 2>/dev/null || true
    fi
    if ! docker compose version >/dev/null 2>&1; then
        log "docker compose plugin fehlt — installiere…"
        case "$DISTRO" in
            apt) $SUDO apt-get install -y -qq docker-compose-plugin ;;
            dnf) $SUDO dnf install -y docker-compose-plugin ;;
            *) err "docker compose plugin manuell installieren" ;;
        esac
    fi
    if ! $SUDO docker info >/dev/null 2>&1; then
        err "Docker daemon antwortet nicht — 'sudo systemctl status docker' pruefen."
    fi
    ok "Docker $(docker --version | grep -oP '[0-9]+\.[0-9]+' | head -1) + compose plugin OK"
}

detect_gpu() {
    HAS_NVIDIA=0; HAS_AMD=0; GPU_TYPE="cpu"; GFX_VERSION=""
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        HAS_NVIDIA=1
        GPU_TYPE="nvidia"
        local gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
        ok "GPU: NVIDIA $gpu_name"
        # NVIDIA-Container-Toolkit
        if ! $SUDO docker info 2>/dev/null | grep -q nvidia; then
            log "nvidia-container-toolkit fehlt — installiere…"
            case "$DISTRO" in
                apt)
                    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | $SUDO gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
                    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
                        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
                        | $SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
                    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq nvidia-container-toolkit
                    $SUDO nvidia-ctk runtime configure --runtime=docker
                    $SUDO systemctl restart docker
                    ;;
                *) warn "nvidia-container-toolkit manuell installieren" ;;
            esac
        fi
    elif command -v rocminfo >/dev/null 2>&1 && { rocminfo 2>/dev/null > /tmp/.rocminfo.$$ || true; grep -qE 'gfx[0-9]+' /tmp/.rocminfo.$$; }; then
        HAS_AMD=1
        GPU_TYPE="amd"
        GFX_VERSION=$(grep -oE 'gfx[0-9]+' /tmp/.rocminfo.$$ | head -1)
        rm -f /tmp/.rocminfo.$$
        local gpu_name=$(lspci 2>/dev/null | grep -iE "vga|display|3d" | head -1 | cut -d: -f3- | xargs)
        ok "GPU: AMD $gpu_name ($GFX_VERSION) via ROCm"
        # /dev/kfd + /dev/dri Plausi
        [[ -e /dev/kfd ]] || err "AMD-GPU erkannt, aber /dev/kfd fehlt — Kernel-Driver nicht geladen?"
        [[ -e /dev/dri ]] || err "AMD-GPU erkannt, aber /dev/dri fehlt"
        ok "ROCm-Devices: /dev/kfd + /dev/dri vorhanden"
        # User in video+render Groups?
        local real_user="${SUDO_USER:-$USER}"
        local missing_groups=()
        for grp in video render; do
            if ! groups "$real_user" 2>/dev/null | grep -qw "$grp"; then
                missing_groups+=("$grp")
            fi
        done
        if [[ ${#missing_groups[@]} -gt 0 ]]; then
            warn "User $real_user nicht in Gruppen: ${missing_groups[*]} — adde jetzt…"
            for g in "${missing_groups[@]}"; do $SUDO usermod -aG "$g" "$real_user"; done
            warn "User muss sich neu einloggen damit Group-Membership greift (oder reboot)."
        else
            ok "User $real_user in video+render Groups"
        fi
    elif lspci 2>/dev/null | grep -qiE "intel.*arc|intel.*xe"; then
        GPU_TYPE="intel"
        warn "Intel-Arc-GPU erkannt — Vulkan-Pfad ist experimentell."
    else
        GPU_TYPE="cpu"
        warn "Keine GPU erkannt — CPU-only Modus (Modell-Inferenz langsam!)"
    fi
}

check_ports() {
    local ports=(11434 8004 7700 7844)
    local conflicts=()
    for port in "${ports[@]}"; do
        if ss -tlnp 2>/dev/null | grep -qE ":${port}\s"; then
            local proc=$(ss -tlnp 2>/dev/null | grep -E ":${port}\s" | head -1 | grep -oP 'users:\(\("\K[^"]+')
            if [[ "$port" == "11434" && "$proc" == "ollama" ]]; then
                # Erwartet: wird gleich gestoppt im Adopt-Mode
                continue
            fi
            conflicts+=("$port=$proc")
        fi
    done
    if [[ ${#conflicts[@]} -gt 0 ]]; then
        err "Port-Konflikte: ${conflicts[*]} — bitte vorher freigeben."
    fi
    ok "Ports 11434/8004/7700/7844 frei (oder von ollama-service belegt)"
}

check_existing_ollama() {
    if command -v systemctl >/dev/null 2>&1 && $SUDO systemctl is-active --quiet ollama 2>/dev/null; then
        ADOPT_OLLAMA_WAS_ACTIVE=1
        ADOPT_OLLAMA_USER="$($SUDO systemctl show -p User --value ollama 2>/dev/null || echo ollama)"
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
            err "Host-Ollama-Service aktiv, aber Modell-Verzeichnis nicht gefunden. Bitte OLLAMA_DATA_DIR manuell setzen."
        fi
        local size=$($SUDO du -sh "$ADOPT_OLLAMA_DIR/models" 2>/dev/null | cut -f1)
        # Modell-Count snapshot fuer post-deploy-Vergleich
        PRE_DEPLOY_MODEL_COUNT=$(curl -s --max-time 3 http://localhost:11434/api/tags 2>/dev/null | jq -r '.models | length' 2>/dev/null || echo "0")
        ok "Adopt-Mode: $ADOPT_OLLAMA_DIR ($size, $PRE_DEPLOY_MODEL_COUNT Modelle)"
    else
        ok "Adopt-Mode: nicht aktiv (kein laufender ollama.service)"
    fi
}

check_spoke_name_unique() {
    [[ -z "${SPOKE_NAME:-}" ]] && SPOKE_NAME="$(hostname -s)"
    local url="${ROUTER_URL:-http://100.99.159.80:7842}"
    # /admin/api/spokes braucht Bearer-Auth — ohne Token geht's nicht.
    # Wir versuchen den Call, scheitern stillschweigend wenn 401.
    # `set -euo pipefail`-safe: alle Teile mit || true gewrappt.
    local raw existing=""
    raw=$(curl -s --max-time 3 "${url}/admin/api/spokes" 2>/dev/null || true)
    if [[ -n "$raw" && "${raw:0:1}" == "[" ]]; then
        existing=$(echo "$raw" | jq -r --arg n "$SPOKE_NAME" '.[]? | select(.name==$n) | .id' 2>/dev/null | head -1 || true)
    fi
    if [[ -n "$existing" ]]; then
        warn "Spoke '$SPOKE_NAME' bereits im Router (id=$existing) — wird beim Heartbeat überschrieben."
    else
        ok "Spoke-Name '$SPOKE_NAME' frei im Router (oder Router-Auth fehlt — Spoke-Agent registriert beim Start)"
    fi
}

check_registration_token() {
    if [[ -z "${SPOKE_REGISTRATION_TOKEN:-}" ]]; then
        warn "SPOKE_REGISTRATION_TOKEN nicht gesetzt — Spoke kann sich nicht selbst registrieren."
    elif [[ "${SPOKE_REGISTRATION_TOKEN}" == "CHANGEME"* ]]; then
        err "SPOKE_REGISTRATION_TOKEN ist noch CHANGEME-Platzhalter — bitte echten Wert setzen."
    else
        ok "SPOKE_REGISTRATION_TOKEN gesetzt (${#SPOKE_REGISTRATION_TOKEN} chars)"
    fi
}


# ============================================================================
# DEPLOY
# ============================================================================

prepare_config() {
    log "──────────────  Config  ──────────────"
    $SUDO mkdir -p /etc/spoke-stack
    if [[ ! -f "$ENV_FILE" ]]; then
        $SUDO cp "$INSTALL_DIR/.env.example" "$ENV_FILE"
        $SUDO chmod 600 "$ENV_FILE"
        ok "Template-Env angelegt: $ENV_FILE"
    fi

    set_kv() {
        local key="$1" val="$2"
        [[ -z "$val" ]] && return
        if $SUDO grep -qE "^${key}=" "$ENV_FILE"; then
            $SUDO sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
        else
            echo "${key}=${val}" | $SUDO tee -a "$ENV_FILE" >/dev/null
        fi
    }

    # Defaults befuellen
    : "${SPOKE_NAME:=$(hostname -s)}"
    if [[ -z "${SPOKE_TAGS:-}" ]]; then
        case "$GPU_TYPE" in
            nvidia) SPOKE_TAGS="gpu,linux,nvidia" ;;
            amd)    SPOKE_TAGS="gpu,linux,amd,rocm" ;;
            intel)  SPOKE_TAGS="gpu,linux,intel" ;;
            *)      SPOKE_TAGS="cpu,linux" ;;
        esac
    fi
    # Bind-Adressen — Codex hat zwei sich widersprechende P1 gefunden:
    #   - 127.0.0.1 only: spoke-agent (host-network) erreicht zwar localhost,
    #     aber Router von CCX23 erreicht den Spoke nicht im Tailnet.
    #   - 0.0.0.0: Inference-API auch im LAN erreichbar (kein Auth in ollama!).
    #
    # Pragmatischer Default: 0.0.0.0 + Firewall-Lockdown auf Tailscale-Range.
    # Wir aktivieren ufw automatisch wenn vorhanden:
    : "${OLLAMA_BIND:=0.0.0.0}"
    : "${RERANKER_BIND:=0.0.0.0}"
    : "${VISION_BIND:=0.0.0.0}"
    if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
        log "ufw aktiv — beschraenke Spoke-Ports auf Tailscale-Range 100.64.0.0/10…"
        for p in 11434 8004 8005 7844; do
            $SUDO ufw allow from 100.64.0.0/10 to any port "$p" comment "spoke-stack" >/dev/null 2>&1 || true
            $SUDO ufw deny in to any port "$p" comment "spoke-stack-deny-default" >/dev/null 2>&1 || true
        done
        ok "ufw konfiguriert: Spoke-Ports nur aus Tailscale-Range (100.64.0.0/10)."
    else
        warn "ufw nicht aktiv — Inference-Ports sind LAN-erreichbar! Bitte 'sudo ufw enable' + spoke-stack-Regeln."
    fi

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

    # Adopt-Mode: OLLAMA_DATA_DIR
    if [[ -n "$ADOPT_OLLAMA_DIR" ]]; then
        set_kv OLLAMA_DATA_DIR "$ADOPT_OLLAMA_DIR"
    fi

    # GPU-Tier
    case "$GPU_TYPE" in
        nvidia)
            local n=$(nvidia-smi -L 2>/dev/null | wc -l)
            : "${GPU_COUNT:=$n}"
            local vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {print s}')
            if   [[ $vram -gt 24000 ]]; then : "${OLLAMA_NUM_PARALLEL:=4}"; : "${OLLAMA_MAX_LOADED_MODELS:=3}"
            elif [[ $vram -gt 14000 ]]; then : "${OLLAMA_NUM_PARALLEL:=2}"; : "${OLLAMA_MAX_LOADED_MODELS:=2}"
            else                              : "${OLLAMA_NUM_PARALLEL:=1}"; : "${OLLAMA_MAX_LOADED_MODELS:=1}"
            fi
            set_kv GPU_COUNT "$GPU_COUNT"
            ;;
        amd)
            local ram_gb=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)
            if   [[ $ram_gb -gt 96 ]]; then : "${OLLAMA_NUM_PARALLEL:=4}"; : "${OLLAMA_MAX_LOADED_MODELS:=4}"
            elif [[ $ram_gb -gt 32 ]]; then : "${OLLAMA_NUM_PARALLEL:=2}"; : "${OLLAMA_MAX_LOADED_MODELS:=2}"
            else                              : "${OLLAMA_NUM_PARALLEL:=1}"; : "${OLLAMA_MAX_LOADED_MODELS:=1}"
            fi
            case "$GFX_VERSION" in
                gfx1151) : "${HSA_OVERRIDE_GFX_VERSION:=11.5.1}" ;;
                gfx1150) : "${HSA_OVERRIDE_GFX_VERSION:=11.5.0}" ;;
                gfx1100|gfx1101|gfx1102) : "${HSA_OVERRIDE_GFX_VERSION:=11.0.0}" ;;
                gfx1030|gfx1031|gfx1032) : "${HSA_OVERRIDE_GFX_VERSION:=10.3.0}" ;;
            esac
            [[ -n "${HSA_OVERRIDE_GFX_VERSION:-}" ]] && set_kv HSA_OVERRIDE_GFX_VERSION "$HSA_OVERRIDE_GFX_VERSION"
            ;;
    esac
    set_kv OLLAMA_NUM_PARALLEL "${OLLAMA_NUM_PARALLEL:-2}"
    set_kv OLLAMA_MAX_LOADED_MODELS "${OLLAMA_MAX_LOADED_MODELS:-2}"

    # CHANGEME-Check (final)
    if $SUDO grep -qE "^[A-Z_]+=CHANGEME" "$ENV_FILE"; then
        warn "$ENV_FILE enthaelt noch CHANGEME-Platzhalter:"
        $SUDO grep -nE "^[A-Z_]+=CHANGEME" "$ENV_FILE" >&2
        err "Bitte editieren und Tokens setzen, dann erneut starten."
    fi
    ok "Konfig geschrieben: $ENV_FILE"
}

pre_migration() {
    if [[ $ADOPT_OLLAMA_WAS_ACTIVE -eq 1 ]]; then
        log "──────────────  Adopt-Migration  ──────────────"
        log "Stoppe + disable Host-Ollama-Service (Modelle bleiben in $ADOPT_OLLAMA_DIR)…"
        $SUDO systemctl stop ollama || true
        $SUDO systemctl disable ollama 2>/dev/null || true
        ROLLBACK_NEEDED=1
        # Warte bis Port 11434 frei (max 10s)
        for i in {1..10}; do
            ss -tlnp 2>/dev/null | grep -qE ":11434\s" || break
            sleep 1
        done
        ok "Host-Ollama gestoppt + disabled."
    fi
}

deploy() {
    log "──────────────  Deploy  ──────────────"
    cd "$INSTALL_DIR"

    # Codex-Befund P2: spoke-agent erwartet compose.yaml in /etc/spoke-stack/
    # (DOCKER_COMPOSE_PATH env-var verweist darauf). Bisher kopierte nur
    # install.sh die Files; bootstrap.sh muss das auch tun.
    $SUDO cp -f "$INSTALL_DIR/compose.yaml" /etc/spoke-stack/compose.yaml
    [[ -f "$INSTALL_DIR/compose.gpu.yaml" ]] && $SUDO cp -f "$INSTALL_DIR/compose.gpu.yaml" /etc/spoke-stack/compose.gpu.yaml
    [[ -f "$INSTALL_DIR/compose.amd.yaml" ]] && $SUDO cp -f "$INSTALL_DIR/compose.amd.yaml" /etc/spoke-stack/compose.amd.yaml

    # compose-Datei + GPU-Override
    local args=(-f compose.yaml)
    case "$GPU_TYPE" in
        nvidia) args+=(-f compose.gpu.yaml); log "GPU-Override: NVIDIA" ;;
        amd)    args+=(-f compose.amd.yaml); log "GPU-Override: AMD-ROCm ($GFX_VERSION)" ;;
        intel|cpu) log "Kein GPU-Override (CPU-only)" ;;
    esac

    $SUDO docker compose "${args[@]}" --env-file "$ENV_FILE" pull 2>&1 | tail -5
    $SUDO docker compose "${args[@]}" --env-file "$ENV_FILE" up -d 2>&1 | tail -10
    ok "Compose up -d ausgefuehrt."
}


# ============================================================================
# POST-DEPLOY VALIDATE
# ============================================================================

validate_deploy() {
    log "──────────────  Post-Deploy-Validation  ──────────────"
    local errors=0

    # 1. Container Up + healthy
    sleep 5
    for svc in ollama reranker-service spoke-agent; do
        local status=$($SUDO docker inspect "$svc" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
        if [[ "$status" != "running" ]]; then
            warn "Container '$svc' nicht running (state=$status)"
            errors=$((errors+1))
        else
            ok "Container '$svc' running"
        fi
    done

    # 2. Health-Polling (max 90s)
    for i in {1..18}; do
        local all_healthy=1
        for svc in ollama reranker-service spoke-agent; do
            local h=$($SUDO docker inspect "$svc" --format '{{.State.Health.Status}}' 2>/dev/null || echo "no-health")
            if [[ "$h" != "healthy" && "$h" != "no-health" ]]; then
                all_healthy=0
                break
            fi
        done
        [[ $all_healthy -eq 1 ]] && break
        sleep 5
    done

    # 3. Ollama-Modelle sichtbar?
    local model_count=$(curl -s --max-time 5 http://localhost:11434/api/tags 2>/dev/null | jq -r '.models | length' 2>/dev/null || echo "0")
    if [[ $model_count -gt 0 ]]; then
        ok "Ollama: $model_count Modelle sichtbar (vorher: $PRE_DEPLOY_MODEL_COUNT)"
        if [[ $PRE_DEPLOY_MODEL_COUNT -gt 0 && $model_count -lt $PRE_DEPLOY_MODEL_COUNT ]]; then
            warn "Modelle-Anzahl geringer als vorher ($model_count < $PRE_DEPLOY_MODEL_COUNT) — Volume-Adoption pruefen!"
            errors=$((errors+1))
        fi
    else
        warn "Ollama: 0 Modelle"
        errors=$((errors+1))
    fi

    # 4. Reranker-Health
    if curl -sf --max-time 5 http://localhost:8004/health >/dev/null 2>&1; then
        ok "Reranker-Service /health antwortet"
    else
        warn "Reranker-Service /health failed"
        errors=$((errors+1))
    fi

    # 5. Spoke-Agent /health
    local agent_port="${SPOKE_AGENT_PORT:-7844}"
    if curl -sf --max-time 5 "http://localhost:${agent_port}/health" >/dev/null 2>&1; then
        ok "Spoke-Agent /health antwortet (Port $agent_port)"
    else
        warn "Spoke-Agent /health failed"
        errors=$((errors+1))
    fi

    # 6. Spoke beim Router registriert? (15s warten + check)
    # Codex-Befund P2: /admin/api/spokes braucht Bearer-Auth. Wenn wir kein
    # Admin-Token haben, ist der Check best-effort — kein hartes Fail.
    sleep 15
    local url="${ROUTER_URL:-http://100.99.159.80:7842}"
    local raw_spokes registered=""
    local -a auth_args=()
    if [[ -n "${ROUTER_ADMIN_TOKEN:-}" ]]; then
        auth_args=(-H "Authorization: Bearer ${ROUTER_ADMIN_TOKEN}")
    fi
    raw_spokes=$(curl -s --max-time 5 "${auth_args[@]}" "${url}/admin/api/spokes" 2>/dev/null || true)
    if [[ -n "$raw_spokes" && "${raw_spokes:0:1}" == "[" ]]; then
        registered=$(echo "$raw_spokes" | jq -r --arg n "$SPOKE_NAME" '.[]? | select(.name==$n) | "\(.status)|\(.source)"' 2>/dev/null | head -1 || true)
        if [[ -n "$registered" ]]; then
            ok "Spoke '$SPOKE_NAME' im Router: $registered"
        else
            warn "Spoke '$SPOKE_NAME' nicht im Router gefunden — Token/Connectivity pruefen."
            errors=$((errors+1))
        fi
    else
        # Auth fehlte oder Router antwortet anders — kein hartes Fail.
        warn "Router-Spoke-Liste nicht zugaenglich (kein ROUTER_ADMIN_TOKEN?). Spoke-Agent-Logs pruefen."
    fi

    # 7. E2E-Test: kleines Modell-Inferenz wenn moeglich
    if [[ $model_count -gt 0 ]]; then
        local tags_raw smallest=""
        tags_raw=$(curl -s --max-time 5 http://localhost:11434/api/tags 2>/dev/null || true)
        if [[ -n "$tags_raw" ]]; then
            smallest=$(echo "$tags_raw" | jq -r '.models | sort_by(.size) | .[0].name' 2>/dev/null || true)
        fi
        if [[ -n "$smallest" && "$smallest" != "null" ]]; then
            log "E2E-Test: ollama-Inferenz mit $smallest…"
            local infer_raw infer_ok=""
            infer_raw=$(curl -s --max-time 30 -X POST http://localhost:11434/api/generate \
                -d "{\"model\":\"$smallest\",\"prompt\":\"hi\",\"stream\":false,\"options\":{\"num_predict\":5}}" 2>/dev/null || true)
            if [[ -n "$infer_raw" ]]; then
                infer_ok=$(echo "$infer_raw" | jq -r '.done' 2>/dev/null || true)
            fi
            if [[ "$infer_ok" == "true" ]]; then
                ok "Inferenz-Test passed ($smallest)"
            else
                warn "Inferenz-Test failed — Modell startet evtl. gerade noch."
                errors=$((errors+1))
            fi
        fi
    fi

    if [[ $errors -gt 0 ]]; then
        warn "Validation: $errors Fehler — siehe oben."
        if [[ "${SKIP_VALIDATE:-0}" != "1" ]]; then
            warn "Container laufen, aber nicht alles ist OK. Rollback per:"
            warn "  cd /opt/spoke-stack && sudo docker compose down && sudo systemctl start ollama"
        fi
        return 1
    fi
    ok "Validation komplett bestanden."
    ROLLBACK_NEEDED=0
    return 0
}


# ============================================================================
# ROLLBACK
# ============================================================================

rollback() {
    log "──────────────  Rollback  ──────────────"
    if [[ -d "$INSTALL_DIR" ]]; then
        cd "$INSTALL_DIR"
        $SUDO docker compose down 2>&1 | tail -5 || true
    fi
    if [[ $ADOPT_OLLAMA_WAS_ACTIVE -eq 1 ]]; then
        log "Reaktiviere Host-Ollama-Service…"
        $SUDO systemctl enable ollama 2>/dev/null || true
        $SUDO systemctl start ollama || warn "ollama-Service konnte nicht gestartet werden — manuell pruefen."
    fi
    warn "Rollback abgeschlossen. Bitte Logs durchsehen und Bootstrap erneut starten."
}


# ============================================================================
# PRE-FLIGHT INFRASTRUCTURE
# ============================================================================

setup_sudo_and_distro() {
    if [[ "$EUID" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then SUDO=sudo
        else err "Bitte als root oder mit sudo ausfuehren."
        fi
    else
        SUDO=""
    fi
    case "$(uname -s)" in
        Linux)   ;;
        Darwin)  err "macOS: bitte Docker Desktop installieren, dann clone+./install.sh (kein bootstrap)." ;;
        *)       err "Unbekannte OS-Family: $(uname -s)" ;;
    esac
    if command -v apt-get >/dev/null 2>&1; then DISTRO=apt
    elif command -v dnf >/dev/null 2>&1; then DISTRO=dnf
    elif command -v pacman >/dev/null 2>&1; then DISTRO=pacman
    else err "Unbekannter Paket-Manager."
    fi
}

ghcr_login_if_token() {
    if [[ -n "${GHCR_TOKEN:-}" ]]; then
        log "GHCR-Login mit GHCR_TOKEN…"
        echo "$GHCR_TOKEN" | $SUDO docker login ghcr.io -u "${GHCR_USER:-janpow77}" --password-stdin
    fi
}

clone_or_pull_repo() {
    if [[ ! -d "$INSTALL_DIR/.git" ]]; then
        log "Klone Repo nach $INSTALL_DIR…"
        $SUDO git clone "$REPO" "$INSTALL_DIR"
    else
        log "Repo existiert — pulle…"
        $SUDO git -C "$INSTALL_DIR" pull --ff-only
    fi
}

print_summary() {
    echo "" >&2
    log "═════════════════════════════════════════════"
    log "  Spoke-Stack ist installiert."
    log "  Konfig:      $ENV_FILE"
    log "  Tailscale:   $TS_IP"
    log "  Spoke-Agent: http://$TS_IP:7700/admin/"
    log ""
    log "  Naechste Schritte:"
    log "    1. Im llm-router-Admin Spoke pruefen:"
    log "       ${ROUTER_URL:-http://100.99.159.80:7842}/admin/api/spokes"
    log "    2. Logs: sudo docker compose -f /etc/spoke-stack/compose.yaml logs -f"
    log "    3. (optional) spoke-widget Tray-App:"
    log "       https://github.com/janpow77/spoke-widget/releases/latest"
    log "═════════════════════════════════════════════"
}


# ============================================================================
# MAIN
# ============================================================================

main() {
    setup_sudo_and_distro
    [[ "${SKIP_PREFLIGHT:-0}" != "1" ]] && preflight_check
    ghcr_login_if_token
    clone_or_pull_repo
    prepare_config
    pre_migration
    deploy
    if [[ "${SKIP_VALIDATE:-0}" != "1" ]]; then
        if ! validate_deploy; then
            warn "Bootstrap fertig, aber Validation hat Probleme gemeldet."
            warn "Spoke-Stack laeuft moeglicherweise teilweise. Pruefe Logs."
            exit 2
        fi
    fi
    print_summary
}

main "$@"
