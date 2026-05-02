#!/usr/bin/env bash
#
# next-wallpaper.sh
# Descarga un wallpaper aleatorio desde varios repositorios públicos
# de GitHub y lo aplica con animación.
#
# Detecta automáticamente el motor disponible:
#   1. awww (fork de swww, usado por defecto en algunos setups de Hyprland)
#   2. swww (motor original)
#   3. omarchy-theme-bg-set (fallback sin animación, sólo Omarchy)
#
# Pensado para Omarchy / Arch Linux con Hyprland.
# Uso: bind a una tecla en Hyprland (ej: SUPER + B).
#

set -euo pipefail

# ---- Configuración ----
WALLPAPER_DIR="${HOME}/.local/share/wallpapers/fetched"
MAX_STORED=20

# Animación
TRANSITION_TYPE="grow"
TRANSITION_DURATION=2
TRANSITION_FPS=60

# Cuántos segundos vigilar swaybg después de aplicar (para que no nos tape)
SWAYBG_GUARD_SECONDS=3

# Fuentes disponibles
SOURCES=("dharmx" "denvercoder")

# Categorías de dharmx/walls (selección curada: minimalista, naturaleza,
# esquemas de color/rice y retro/synthwave)
DHARMX_CATEGORIES=(
    # Minimalistas y limpias
    "minimal" "monochrome" "paper" "geometry" "calm" "tile"
    # Naturaleza
    "aerial" "mountain" "nature" "fauna" "flowers" "fogsmoke"
    # Esquemas de color / rice
    "gruvbox" "nord" "solarized" "radium"
    # Retro / synthwave
    "outrun" "retro" "pixel" "chillop"
)

# ---- Detección de motor ----
ENGINE_CMD=""
ENGINE_DAEMON=""
ENGINE_NAME=""

detect_engine() {
    if command -v awww >/dev/null; then
        ENGINE_CMD="awww"
        ENGINE_DAEMON="awww-daemon"
        ENGINE_NAME="awww"
    elif command -v swww >/dev/null; then
        ENGINE_CMD="swww"
        ENGINE_DAEMON="swww-daemon"
        ENGINE_NAME="swww"
    fi
}

# ---- Helpers ----
log() {
    echo "[wlp-brm] $*" >&2
}

notify_error() {
    local msg="$1"
    log "ERROR: $msg"
    command -v notify-send >/dev/null && \
        notify-send -u critical "Wallpaper" "$msg" || true
}

notify_ok() {
    local msg="$1"
    log "$msg"
    command -v notify-send >/dev/null && \
        notify-send "Wallpaper" "$msg" || true
}

check_deps() {
    local missing=()
    for dep in curl jq; do
        command -v "$dep" >/dev/null || missing+=("$dep")
    done
    if [ -z "$ENGINE_CMD" ] && ! command -v omarchy-theme-bg-set >/dev/null; then
        missing+=("awww | swww | omarchy-theme-bg-set")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        notify_error "Faltan dependencias: ${missing[*]}"
        exit 1
    fi
}

# Limpieza segura de archivos viejos (maneja nombres con comillas/espacios)
cleanup_old() {
    local count
    count=$(find "$WALLPAPER_DIR" -type f 2>/dev/null | wc -l)
    if [ "$count" -gt "$MAX_STORED" ]; then
        find "$WALLPAPER_DIR" -type f -printf '%T@ %p\0' \
            | sort -z -n \
            | head -z -n $((count - MAX_STORED)) \
            | sed -z 's/^[0-9.]* //' \
            | xargs -0 -r rm -f
        log "Limpieza: se mantuvieron $MAX_STORED wallpapers"
    fi
}

# Mata swaybg de forma agresiva por unos segundos, por si Omarchy lo relanza
guard_against_swaybg() {
    local seconds="$1"
    (
        local end=$(( $(date +%s) + seconds ))
        while [ "$(date +%s)" -lt "$end" ]; do
            pkill -x swaybg 2>/dev/null || true
            sleep 0.3
        done
    ) &
}

# Aplica el wallpaper con animación si hay motor, o fallback sin animación
apply_wallpaper() {
    local image="$1"

    if [ -n "$ENGINE_CMD" ]; then
        # Matar swaybg siempre antes de aplicar (lo lanza Omarchy y nos tapa)
        pkill -x swaybg 2>/dev/null || true

        # Asegurar que el daemon esté corriendo
        if ! "$ENGINE_CMD" query &>/dev/null; then
            log "Iniciando $ENGINE_DAEMON"
            "$ENGINE_DAEMON" &
            sleep 1
        fi

        if "$ENGINE_CMD" img "$image" \
            --transition-type "$TRANSITION_TYPE" \
            --transition-duration "$TRANSITION_DURATION" \
            --transition-fps "$TRANSITION_FPS" 2>/dev/null; then
            log "Wallpaper aplicado con $ENGINE_NAME (animado)"
            # Vigilar swaybg unos segundos más, por si algo en Omarchy lo relanza
            guard_against_swaybg "$SWAYBG_GUARD_SECONDS"
            return 0
        else
            log "$ENGINE_NAME falló, intentando con omarchy-theme-bg-set"
        fi
    fi

    # Fallback
    if command -v omarchy-theme-bg-set >/dev/null; then
        omarchy-theme-bg-set "$image"
        log "Wallpaper aplicado con omarchy-theme-bg-set (sin animación)"
        return 0
    fi

    return 1
}

# ---- Fuentes ----

fetch_dharmx() {
    local cat_index category json total index url name dest
    cat_index=$((RANDOM % ${#DHARMX_CATEGORIES[@]}))
    category="${DHARMX_CATEGORIES[$cat_index]}"
    log "Fuente: dharmx ($category)"

    json=$(curl -fsSL --max-time 15 \
        "https://api.github.com/repos/dharmx/walls/contents/${category}") \
        || { log "dharmx: fallo de red"; return 1; }

    total=$(echo "$json" | jq 'length')
    [ "$total" -eq 0 ] && { log "dharmx: categoría vacía"; return 1; }

    index=$((RANDOM % total))
    url=$(echo "$json" | jq -r ".[$index].download_url // empty")
    name=$(echo "$json" | jq -r ".[$index].name // empty")
    [ -z "$url" ] && { log "dharmx: URL vacía"; return 1; }

    dest="$WALLPAPER_DIR/dharmx-${name}"
    curl -fsSL --max-time 60 -o "$dest" "$url" || { log "dharmx: fallo descarga"; return 1; }
    [ -s "$dest" ] || { rm -f "$dest"; return 1; }
    echo "$dest"
}

fetch_denvercoder() {
    local rand url dest
    log "Fuente: DenverCoder1 (minimalista)"
    rand=$RANDOM
    url="https://minimalistic-wallpaper.demolab.com/?random=${rand}"
    dest="$WALLPAPER_DIR/denvercoder-${rand}.jpg"
    curl -fsSL --max-time 60 -L -o "$dest" "$url" \
        || { log "denvercoder: fallo descarga"; return 1; }
    [ -s "$dest" ] || { rm -f "$dest"; return 1; }
    echo "$dest"
}

fetch_makccr() {
    local json categories cat_index category sub_json total index url name dest
    log "Fuente: makccr (4K)"

    json=$(curl -fsSL --max-time 15 \
        "https://api.github.com/repos/makccr/wallpapers/contents/wallpapers") \
        || { log "makccr: fallo de red"; return 1; }

    mapfile -t categories < <(echo "$json" | jq -r '.[] | select(.type=="dir") | .name')
    [ ${#categories[@]} -eq 0 ] && { log "makccr: sin categorías"; return 1; }

    cat_index=$((RANDOM % ${#categories[@]}))
    category="${categories[$cat_index]}"
    log "  → categoría: $category"

    sub_json=$(curl -fsSL --max-time 15 \
        "https://api.github.com/repos/makccr/wallpapers/contents/wallpapers/${category}") \
        || return 1

    total=$(echo "$sub_json" | jq '[.[] | select(.type=="file") | select(.name | test("\\.(jpg|jpeg|png|webp)$"; "i"))] | length')
    [ "$total" -eq 0 ] && { log "makccr: sin imágenes"; return 1; }

    index=$((RANDOM % total))
    url=$(echo "$sub_json" | jq -r "[.[] | select(.type==\"file\") | select(.name | test(\"\\\\.(jpg|jpeg|png|webp)\$\"; \"i\"))][$index].download_url")
    name=$(echo "$sub_json" | jq -r "[.[] | select(.type==\"file\") | select(.name | test(\"\\\\.(jpg|jpeg|png|webp)\$\"; \"i\"))][$index].name")

    [ -z "$url" ] || [ "$url" = "null" ] && { log "makccr: URL vacía"; return 1; }

    dest="$WALLPAPER_DIR/makccr-${name}"
    curl -fsSL --max-time 60 -o "$dest" "$url" || return 1
    [ -s "$dest" ] || { rm -f "$dest"; return 1; }
    echo "$dest"
}

fetch_mylinuxforwork() {
    local json total index url name dest
    log "Fuente: mylinuxforwork"

    json=$(curl -fsSL --max-time 15 \
        "https://api.github.com/repos/mylinuxforwork/wallpaper/contents/") \
        || { log "mylinuxforwork: fallo de red"; return 1; }

    total=$(echo "$json" | jq '[.[] | select(.type=="file") | select(.name | test("\\.(jpg|jpeg|png|webp)$"; "i"))] | length')
    [ "$total" -eq 0 ] && { log "mylinuxforwork: sin imágenes en raíz"; return 1; }

    index=$((RANDOM % total))
    url=$(echo "$json" | jq -r "[.[] | select(.type==\"file\") | select(.name | test(\"\\\\.(jpg|jpeg|png|webp)\$\"; \"i\"))][$index].download_url")
    name=$(echo "$json" | jq -r "[.[] | select(.type==\"file\") | select(.name | test(\"\\\\.(jpg|jpeg|png|webp)\$\"; \"i\"))][$index].name")

    [ -z "$url" ] || [ "$url" = "null" ] && return 1

    dest="$WALLPAPER_DIR/mylfw-${name}"
    curl -fsSL --max-time 60 -o "$dest" "$url" || return 1
    [ -s "$dest" ] || { rm -f "$dest"; return 1; }
    echo "$dest"
}

# ---- Main ----
main() {
    detect_engine
    check_deps
    mkdir -p "$WALLPAPER_DIR"

    local shuffled=()
    mapfile -t shuffled < <(printf '%s\n' "${SOURCES[@]}" | shuf)

    local dest=""
    for source in "${shuffled[@]}"; do
        case "$source" in
            dharmx)         dest=$(fetch_dharmx)         || dest="" ;;
            denvercoder)    dest=$(fetch_denvercoder)    || dest="" ;;
            makccr)         dest=$(fetch_makccr)         || dest="" ;;
            mylinuxforwork) dest=$(fetch_mylinuxforwork) || dest="" ;;
        esac
        [ -n "$dest" ] && [ -s "$dest" ] && break
    done

    if [ -z "$dest" ] || [ ! -s "$dest" ]; then
        notify_error "No se pudo descargar de ninguna fuente"
        exit 1
    fi

    if ! apply_wallpaper "$dest"; then
        notify_error "No se pudo aplicar el wallpaper"
        exit 1
    fi

    notify_ok "Nuevo wallpaper aplicado"
    cleanup_old
}

main "$@"
