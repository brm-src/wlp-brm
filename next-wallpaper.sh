#!/usr/bin/env bash
#
# next-wallpaper.sh v4
# Descarga un wallpaper aleatorio desde varios repositorios públicos
# de GitHub y lo aplica con animación.
#
# Detecta automáticamente el motor disponible:
#   1. awww (fork de swww, usado por defecto en algunos setups de Hyprland)
#   2. swww (motor original)
#   3. omarchy-theme-bg-set (fallback sin animación, sólo Omarchy)
#
# Pensado para Omarchy / Arch Linux con Hyprland.
# Uso:
#   next-wallpaper.sh                         Descarga y aplica uno nuevo
#   next-wallpaper.sh --load-last-or-fetch    Aplica el último válido o descarga si no hay
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

# Categorías de dharmx/walls
DHARMX_CATEGORIES=(
    "minimal" "monochrome" "paper" "geometry" "calm" "tile"
    "aerial" "mountain" "nature" "fauna" "flowers" "fogsmoke"
    "gruvbox" "nord" "solarized" "radium"
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
    for dep in curl jq file; do
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

# Valida que un archivo descargado sea realmente una imagen (no JSON de error,
# no HTML, no README de markdown, etc.) usando MIME type.
is_valid_image() {
    local f="$1"
    [ -s "$f" ] || return 1
    local mime
    mime=$(file -bL --mime-type "$f" 2>/dev/null || echo "")
    case "$mime" in
        image/jpeg|image/png|image/webp|image/gif|image/bmp|image/avif)
            return 0
            ;;
        *)
            log "  → descarga inválida (mime: $mime), descartando"
            rm -f "$f"
            return 1
            ;;
    esac
}

# Devuelve la ruta del wallpaper válido más reciente, o vacío si no hay.
find_latest_valid() {
    [ -d "$WALLPAPER_DIR" ] || return 1
    local f
    while IFS= read -r -d '' f; do
        if is_valid_image "$f" 2>/dev/null; then
            echo "$f"
            return 0
        fi
    done < <(find "$WALLPAPER_DIR" -type f -printf '%T@ %p\0' 2>/dev/null \
              | sort -z -rn \
              | sed -z 's/^[0-9.]* //')
    return 1
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
        pkill -x swaybg 2>/dev/null || true

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
            guard_against_swaybg "$SWAYBG_GUARD_SECONDS"
            return 0
        else
            log "$ENGINE_NAME falló, intentando con omarchy-theme-bg-set"
        fi
    fi

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

    # Filtrar solo archivos con extensión de imagen (excluye READMEs, dirs, etc.)
    total=$(echo "$json" | jq '[.[] | select(.type=="file") | select(.name | test("\\.(jpg|jpeg|png|webp)$"; "i"))] | length')
    [ "$total" -eq 0 ] && { log "dharmx: sin imágenes en categoría"; return 1; }

    index=$((RANDOM % total))
    url=$(echo "$json" | jq -r "[.[] | select(.type==\"file\") | select(.name | test(\"\\\\.(jpg|jpeg|png|webp)\$\"; \"i\"))][$index].download_url")
    name=$(echo "$json" | jq -r "[.[] | select(.type==\"file\") | select(.name | test(\"\\\\.(jpg|jpeg|png|webp)\$\"; \"i\"))][$index].name")

    [ -z "$url" ] || [ "$url" = "null" ] && { log "dharmx: URL vacía"; return 1; }

    dest="$WALLPAPER_DIR/dharmx-${name}"
    curl -fsSL --max-time 60 -o "$dest" "$url" || { log "dharmx: fallo descarga"; return 1; }
    is_valid_image "$dest" || return 1
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
    is_valid_image "$dest" || return 1
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
    is_valid_image "$dest" || return 1
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
    is_valid_image "$dest" || return 1
    echo "$dest"
}

# ---- Flujos ----

fetch_new() {
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
        [ -n "$dest" ] && is_valid_image "$dest" 2>/dev/null && break
        dest=""
    done

    if [ -z "$dest" ]; then
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

# Modo autostart: aplica el último wallpaper válido sin descargar nada.
# Si no hay ninguno válido, cae al flujo normal (descarga uno).
load_last_or_fetch() {
    local latest
    latest=$(find_latest_valid || true)
    if [ -n "$latest" ]; then
        log "Aplicando último wallpaper válido: $(basename "$latest")"
        apply_wallpaper "$latest" || { log "Falló aplicar, intentando descarga"; fetch_new; return; }
        return
    fi
    log "No hay wallpapers locales, descargando uno"
    fetch_new
}

# ---- Main ----
main() {
    detect_engine
    check_deps
    mkdir -p "$WALLPAPER_DIR"

    case "${1:-}" in
        --load-last-or-fetch)
            load_last_or_fetch
            ;;
        ""|--fetch)
            fetch_new
            ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            ;;
        *)
            log "Opción desconocida: $1"
            exit 1
            ;;
    esac
}

main "$@"
