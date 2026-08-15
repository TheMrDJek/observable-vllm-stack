#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
ACTION="${1:-}"
GPU_METRICS=false
TARGETS=()

if [[ $# -gt 0 ]]; then
    shift
fi
for argument in "$@"; do
    if [[ "$argument" == "--gpu-metrics" ]]; then
        GPU_METRICS=true
    else
        TARGETS+=("$argument")
    fi
done

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

compose() {
    docker compose "$@"
}

env_setting() {
    local name="$1" line value
    value="${!name:-}"
    if [[ -n "$value" ]]; then
        printf '%s\n' "$value"
        return
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*# || "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" == "$name="* ]]; then
            value="${line#*=}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            if [[ ${#value} -ge 2 ]] &&
                { [[ "$value" == \"*\" ]] || [[ "$value" == \'*\' ]]; }; then
                value="${value:1:${#value}-2}"
            fi
            printf '%s\n' "$value"
            return 0
        fi
    done < "$ENV_FILE"
    # Отсутствующий ключ даёт пустое значение, а не ошибку: вызывающий код сам
    # проверяет пустоту, а ненулевой код возврата здесь оборвал бы скрипт из-за set -e.
    return 0
}

# Слоты определяются по профилям Compose, а не жёстко зашитым списком main/alt.
# Профили инфраструктуры исключаются, всё остальное считается слотом модели.
# Благодаря этому добавление третьего слота требует правки только compose.yaml
# и config/litellm.yaml — скрипты менять не нужно.
list_slots() {
    local profile
    while IFS= read -r profile; do
        profile="${profile%$'\r'}"
        case "$profile" in
            gateway | local-observability | telemetry | gpu-metrics | "") continue ;;
            *) printf '%s\n' "$profile" ;;
        esac
    done < <(compose config --profiles)
}

slot_profile_arguments() {
    local slot
    for slot in $(list_slots); do
        printf -- '--profile\n%s\n' "$slot"
    done
}

slot_service_names() {
    local slot
    for slot in $(list_slots); do
        printf 'vllm-%s\n' "$slot"
    done
}

assert_slots() {
    local minimum="$1" maximum="$2" slot seen="" known
    shift 2
    known="$(list_slots | tr '\n' ' ')"
    (( $# >= minimum )) ||
        fail "Expected at least $minimum slot argument(s). Available slots: ${known% }."
    if (( maximum > 0 )); then
        (( $# <= maximum )) ||
            fail "Expected at most $maximum slot argument(s). Available slots: ${known% }."
    fi
    for slot in "$@"; do
        [[ " $known " == *" $slot "* ]] ||
            fail "Unknown model slot '$slot'. Available slots: ${known% }."
        [[ " $seen " != *" $slot "* ]] || fail "Model slots must not be repeated."
        seen="$seen $slot"
    done
}

stop_all_slots() {
    local profile_arguments=() service_names=()
    mapfile -t profile_arguments < <(slot_profile_arguments)
    mapfile -t service_names < <(slot_service_names)
    (( ${#service_names[@]} > 0 )) || return 0
    compose "${profile_arguments[@]}" stop "${service_names[@]}"
}

assert_no_targets() {
    (( ${#TARGETS[@]} == 0 )) || fail "Command '$ACTION' does not accept arguments."
}

has_compose_profile() {
    local expected="$1" profile profiles
    profiles="$(compose config --profiles)"
    while IFS= read -r profile; do
        [[ "$profile" == "$expected" ]] && return 0
    done <<< "$profiles"
    return 1
}

assert_tls_files() {
    local directory name file_name path
    directory="$(env_setting_default TLS_CERTS_DIR ./secrets/tls)"
    [[ -n "$directory" ]] || fail "Missing required setting TLS_CERTS_DIR."
    if [[ "$directory" != /* && ! "$directory" =~ ^[A-Za-z]:[\\/].* ]]; then
        directory="$SCRIPT_DIR/$directory"
    fi
    for name in TLS_CERT_FILE TLS_KEY_FILE; do
        file_name="$(env_setting "$name")"
        [[ -n "$file_name" ]] || fail "Missing required setting $name."
        if [[ "$file_name" == /* || "$file_name" =~ ^[A-Za-z]:[\\/].* ]]; then
            path="$file_name"
        else
            path="$directory/$file_name"
        fi
        [[ -f "$path" ]] || fail "$name points to a missing TLS file: $path"
    done
}

assert_remote_endpoint() {
    local name="$1" value
    value="$(env_setting "$name")"
    [[ "$value" =~ ^https?://[^[:space:]]+$ ]] ||
        fail "$name must be an absolute http(s) endpoint."
}

assert_non_empty_setting() {
    local name="$1"
    [[ -n "$(env_setting "$name")" ]] ||
        fail "$name must be set for remote observability."
}

# Перезаписывает NAME=value прямо в .env, чтобы последующий обычный
# 'docker compose up' сохранил выбранный здесь режим. Усечение исходного файла
# сохраняет его права доступа; временная копия секретов не создаётся.
persist_setting() {
    local name="$1" value="$2" line content="" replaced=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" == "$name="* ]] && [[ "$replaced" == false ]]; then
            content+="$name=$value"$'\n'
            replaced=true
        elif [[ "$line" == "$name="* ]]; then
            continue
        else
            content+="$line"$'\n'
        fi
    done < "$ENV_FILE"
    [[ "$replaced" == true ]] || content+="$name=$value"$'\n'
    printf '%s' "$content" > "$ENV_FILE"
}

resolve_path() {
    local path="$1"
    if [[ "$path" != /* && ! "$path" =~ ^[A-Za-z]:[\\/].* ]]; then
        path="$SCRIPT_DIR/$path"
    fi
    printf '%s\n' "$path"
}

# Повторяет значения по умолчанию из compose.yaml. Валидация обязана видеть ту
# же конфигурацию, что и запуск, иначе .env без новых ключей прошёл бы nginx -t
# с пустыми путями к сертификату и упал уже на старте контейнера.
env_setting_default() {
    local value
    value="$(env_setting "$1")"
    printf '%s\n' "${value:-$2}"
}

nginx_image() {
    printf 'nginxinc/nginx-unprivileged:%s\n' "$(env_setting_default NGINX_VERSION 1.29-alpine)"
}

gateway_template() {
    printf '%s\n' "./nginx/templates/gateway.$1.conf.template"
}

# У nginx нет аналога директивы 'tls internal' прежнего Caddy, поэтому
# сертификат локального CA выпускается здесь. Ключ CA переиспользуется, пока
# файл на месте: его смена обесценила бы trust store всех клиентов.
# Leaf покрывает все заполненные имена сразу, включая OLD_PUBLIC_*, — тогда
# переключение internal -> migration не требует отдельного выпуска.
ensure_internal_ca() {
    local certs_dir names=() name value openssl_version arguments=()
    certs_dir="$(resolve_path "$(env_setting_default TLS_CERTS_DIR ./secrets/tls)")"
    mkdir -p "$certs_dir"

    for name in PUBLIC_API_HOST PUBLIC_CHAT_HOST OLD_PUBLIC_API_HOST OLD_PUBLIC_CHAT_HOST; do
        value="$(env_setting "$name")"
        [[ -n "$value" ]] && names+=("$value")
    done
    (( ${#names[@]} > 0 )) ||
        fail "No hostnames are set. The internal certificate cannot be issued."

    openssl_version="$(env_setting_default OPENSSL_VERSION 3.5.4)"
    arguments=(run --rm
        -e "SAN_NAMES=${names[*]}"
        -e "CERT_FILE=$(env_setting_default TLS_INTERNAL_CERT_FILE internal.crt)"
        -e "KEY_FILE=$(env_setting_default TLS_INTERNAL_KEY_FILE internal.key)"
        -v "$certs_dir:/certs"
        -v "$SCRIPT_DIR/nginx/internal-ca.sh:/internal-ca.sh:ro"
        --entrypoint /bin/sh
        "alpine/openssl:${openssl_version}" /internal-ca.sh)

    MSYS_NO_PATHCONV=1 docker "${arguments[@]}" ||
        fail "Issuing the internal certificate failed. The gateway was not changed."
}

# nginx работает под UID 101 и читает ключ сам. Проверка вынесена отдельно от
# nginx -t только ради понятного сообщения: иначе оператор получил бы
# 'cannot load certificate key ... Permission denied' без объяснения причины.
assert_key_readable_by_nginx() {
    local certs_dir key_file
    certs_dir="$(resolve_path "$(env_setting_default TLS_CERTS_DIR ./secrets/tls)")"
    key_file="$(env_setting TLS_KEY_FILE)"
    [[ -n "$key_file" ]] || fail "Missing required setting TLS_KEY_FILE."

    MSYS_NO_PATHCONV=1 docker run --rm --user 101:101 \
        -v "$certs_dir:/certs:ro" --entrypoint /bin/sh "$(nginx_image)" \
        -c "test -r /certs/$key_file" >/dev/null 2>&1 ||
        fail "$key_file is not readable by UID 101, under which nginx runs.
On Linux: sudo chown 0:101 '$certs_dir/$key_file' && sudo chmod 0640 '$certs_dir/$key_file'"
}

# Прогоняется тот же образ, entrypoint, пользователь и раскладка томов, что и в
# compose, поэтому проверка ловит не только синтаксис, но и нечитаемые
# сертификаты. tmpfs на conf.d обязателен: туда entrypoint рендерит шаблоны.
validate_nginx_config() {
    local mode="$1" certs_dir template arguments=()
    certs_dir="$(resolve_path "$(env_setting_default TLS_CERTS_DIR ./secrets/tls)")"
    template="$SCRIPT_DIR/nginx/templates/gateway.$mode.conf.template"

    arguments=(run --rm --user 101:101
        --tmpfs "/etc/nginx/conf.d:mode=1777"
        --tmpfs "/tmp:mode=1777"
        -e "PUBLIC_API_HOST=$(env_setting PUBLIC_API_HOST)"
        -e "PUBLIC_CHAT_HOST=$(env_setting PUBLIC_CHAT_HOST)"
        -e "OLD_PUBLIC_API_HOST=$(env_setting OLD_PUBLIC_API_HOST)"
        -e "OLD_PUBLIC_CHAT_HOST=$(env_setting OLD_PUBLIC_CHAT_HOST)"
        -e "TLS_CERT_FILE=$(env_setting_default TLS_CERT_FILE server.crt)"
        -e "TLS_KEY_FILE=$(env_setting_default TLS_KEY_FILE server.key)"
        -e "TLS_INTERNAL_CERT_FILE=$(env_setting_default TLS_INTERNAL_CERT_FILE internal.crt)"
        -e "TLS_INTERNAL_KEY_FILE=$(env_setting_default TLS_INTERNAL_KEY_FILE internal.key)"
        -e "NGINX_CLIENT_MAX_BODY_SIZE=$(env_setting_default NGINX_CLIENT_MAX_BODY_SIZE 0)"
        -e 'NGINX_ENVSUBST_FILTER=^(PUBLIC_|OLD_PUBLIC_|TLS_|NGINX_CLIENT_)'
        -v "$SCRIPT_DIR/nginx/templates/common.conf.template:/etc/nginx/templates/00-common.conf.template:ro"
        -v "$template:/etc/nginx/templates/10-gateway.conf.template:ro"
        -v "$SCRIPT_DIR/nginx/routes:/etc/nginx/routes:ro")
    [[ -d "$certs_dir" ]] && arguments+=(-v "$certs_dir:/etc/nginx/certs:ro")
    arguments+=("$(nginx_image)" nginx -t)

    # MSYS_NO_PATHCONV не даёт Git Bash под Windows переписывать пути внутри
    # контейнера вроде /etc/nginx/conf.d в C:/Program Files/Git/etc/...
    # На Linux переменная не имеет смысла и игнорируется.
    MSYS_NO_PATHCONV=1 docker "${arguments[@]}" >/dev/null ||
        fail "$(gateway_template "$mode") did not pass 'nginx -t'. The gateway was not changed."
}

PREFLIGHT_FAILURES=0

check_ok() { printf '  [ ok ] %s\n' "$*"; }
check_warn() { printf '  [warn] %s\n' "$*"; }
check_fail() {
    printf '  [FAIL] %s\n' "$*" >&2
    PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
}

preflight_gpu() {
    if ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
        check_fail "NVIDIA runtime is not registered in Docker. Run: sudo nvidia-ctk runtime configure --runtime=docker"
        return
    fi
    check_ok "NVIDIA runtime is registered in Docker."
    if docker run --rm --gpus all nvidia/cuda:12.9.0-base-ubuntu22.04 \
        nvidia-smi >/dev/null 2>&1; then
        check_ok "A container can reach the GPU."
    else
        check_fail "'docker run --gpus all ... nvidia-smi' failed. vLLM will not start until this works."
    fi
}

preflight_disk() {
    local available_kb available_gb
    available_kb="$(df -Pk "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
    if [[ -z "$available_kb" ]]; then
        check_warn "Free disk space could not be determined."
        return
    fi
    available_gb=$((available_kb / 1024 / 1024))
    if (( available_gb < 20 )); then
        check_fail "Only ${available_gb} GiB free. Images and one model cache need far more."
    elif (( available_gb < 60 )); then
        check_warn "${available_gb} GiB free. 60 GiB is recommended for images, model cache and telemetry."
    else
        check_ok "${available_gb} GiB free on the stack filesystem."
    fi
}

preflight_port() {
    local port listeners
    port="$(env_setting PUBLIC_HTTPS_PORT)"
    port="${port:-443}"
    if docker compose --profile gateway ps --status running nginx 2>/dev/null | grep -q nginx; then
        check_ok "Port ${port} is held by this stack's nginx."
        return
    fi
    if command -v ss >/dev/null 2>&1; then
        listeners="$(ss -lnt 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print $4}' || true)"
    elif command -v netstat >/dev/null 2>&1; then
        listeners="$(netstat -lnt 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print $4}' || true)"
    else
        check_warn "Neither ss nor netstat is available; port ${port} was not checked."
        return
    fi
    if [[ -n "$listeners" ]]; then
        check_fail "Port ${port} is already in use. Free it or change PUBLIC_HTTPS_PORT."
    else
        check_ok "Port ${port} is free."
    fi
}

preflight_hostnames() {
    local name value
    for name in PUBLIC_API_HOST PUBLIC_CHAT_HOST; do
        value="$(env_setting "$name")"
        if [[ -z "$value" ]]; then
            check_fail "$name is empty."
            continue
        fi
        if ! command -v getent >/dev/null 2>&1; then
            check_warn "getent is unavailable; $name=$value was not resolved."
            continue
        fi
        if getent hosts "$value" >/dev/null 2>&1; then
            check_ok "$name=$value resolves."
        else
            check_warn "$name=$value does not resolve yet. Add DNS or hosts entries before client testing."
        fi
    done
}

preflight_modes() {
    local gateway_mode observability_mode name
    gateway_mode="$(env_setting GATEWAY_MODE)"
    if [[ "$gateway_mode" == "external" || "$gateway_mode" == "migration" ]]; then
        # assert_tls_files завершает скрипт при ошибке, поэтому вызывается в subshell.
        if ( assert_tls_files ) >/dev/null 2>&1; then
            check_ok "TLS certificate and key for gateway mode '$gateway_mode' are present."
        else
            check_fail "GATEWAY_MODE=$gateway_mode but the files from TLS_CERTS_DIR are missing."
        fi
    fi
    observability_mode="$(env_setting OBSERVABILITY_MODE)"
    if [[ "$observability_mode" == "remote" ]]; then
        local missing=0
        for name in REMOTE_METRICS_URL REMOTE_LOKI_URL REMOTE_TEMPO_ENDPOINT \
            REMOTE_METRICS_TOKEN REMOTE_LOKI_TOKEN REMOTE_TEMPO_TOKEN; do
            if [[ -z "$(env_setting "$name")" ]]; then
                check_fail "OBSERVABILITY_MODE=remote but $name is empty."
                missing=$((missing + 1))
            fi
        done
        (( missing > 0 )) || check_ok "Remote observability endpoints and tokens are set."
    fi
}

command -v docker >/dev/null 2>&1 || fail "Docker CLI was not found in PATH."
[[ -f "$ENV_FILE" ]] ||
    fail "Missing .env. Copy .env.example to .env and replace every CHANGE_ME value."

while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*# || "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" == *=* ]] || fail "Invalid .env line: '$line'. Expected NAME=value."
    [[ "${line#*=}" != *CHANGE_ME* ]] ||
        fail "The .env setting ${line%%=*} still contains CHANGE_ME."
done < "$ENV_FILE"

docker compose version >/dev/null 2>&1 ||
    fail "Docker Compose v2 is required ('docker compose')."

cd "$SCRIPT_DIR"

case "$ACTION" in
    preflight)
        assert_no_targets
        printf 'Host preflight for the AI vLLM stack\n\n'
        check_ok "Docker CLI and Compose v2 are available."
        check_ok ".env exists and contains no CHANGE_ME placeholders."
        preflight_gpu
        preflight_disk
        preflight_port
        preflight_hostnames
        preflight_modes
        printf '\n'
        if (( PREFLIGHT_FAILURES > 0 )); then
            fail "$PREFLIGHT_FAILURES preflight check(s) failed. See docs/troubleshooting.md."
        fi
        printf 'Preflight passed. Nothing was changed on the host.\n'
        ;;
    start)
        assert_slots 1 1 "${TARGETS[@]}"
        slot="${TARGETS[0]}"
        stop_all_slots
        arguments=(--profile "$slot")
        $GPU_METRICS && arguments+=(--profile gpu-metrics)
        arguments+=(up -d)
        compose "${arguments[@]}"
        printf "Model slot '%s' is starting in the background.\n" "$slot"
        printf 'Follow progress: docker compose --profile %s logs -f vllm-%s\n' "$slot" "$slot"
        ;;
    start-many)
        assert_slots 2 0 "${TARGETS[@]}"
        [[ "$(env_setting ALLOW_CONCURRENT_MODELS)" == "true" ]] ||
            fail "start-many requires ALLOW_CONCURRENT_MODELS=true. No VRAM preflight is performed."
        arguments=()
        for slot in "${TARGETS[@]}"; do
            arguments+=(--profile "$slot")
        done
        $GPU_METRICS && arguments+=(--profile gpu-metrics)
        arguments+=(up -d)
        compose "${arguments[@]}"
        printf 'Requested model slots: %s.\n' "${TARGETS[*]}"
        printf 'MAIN_VLLM_GPU_MEMORY_UTILIZATION=%s; ALT_VLLM_GPU_MEMORY_UTILIZATION=%s\n' \
            "$(env_setting MAIN_VLLM_GPU_MEMORY_UTILIZATION)" \
            "$(env_setting ALT_VLLM_GPU_MEMORY_UTILIZATION)"
        printf 'Warning: concurrent startup was explicitly enabled; available VRAM was not preflighted.\n' >&2
        ;;
    stop)
        assert_no_targets
        stop_all_slots
        printf 'All vLLM slots are stopped. The rest of the stack is still running.\n'
        ;;
    status)
        assert_no_targets
        status_arguments=()
        mapfile -t status_arguments < <(slot_profile_arguments)
        status_arguments+=(--profile gpu-metrics --profile gateway
            --profile local-observability --profile telemetry ps)
        compose "${status_arguments[@]}"
        ;;
    gateway)
        (( ${#TARGETS[@]} == 1 )) ||
            fail "Usage: model.sh gateway <internal|migration|external|status>"
        mode="${TARGETS[0]}"
        case "$mode" in
            status)
                compose --profile gateway ps nginx
                ;;
            internal|migration|external)
                if [[ "$mode" == "migration" || "$mode" == "external" ]]; then
                    assert_tls_files
                    assert_key_readable_by_nginx
                fi
                if [[ "$mode" == "migration" ]]; then
                    assert_non_empty_setting OLD_PUBLIC_API_HOST
                    assert_non_empty_setting OLD_PUBLIC_CHAT_HOST
                    assert_non_empty_setting PUBLIC_API_HOST
                    assert_non_empty_setting PUBLIC_CHAT_HOST
                fi
                template="$(gateway_template "$mode")"
                [[ -f "$SCRIPT_DIR/${template#./}" ]] ||
                    fail "Missing nginx template for gateway mode '$mode': $SCRIPT_DIR/${template#./}"
                has_compose_profile gateway ||
                    fail "compose.yaml does not define the expected 'gateway' profile."
                # Выпуск сертификата идёт до валидации: в режимах internal и
                # migration nginx -t не пройдёт, пока файлов локального CA нет.
                if [[ "$mode" == "internal" || "$mode" == "migration" ]]; then
                    ensure_internal_ca
                fi
                validate_nginx_config "$mode"
                export GATEWAY_MODE="$mode"
                export NGINX_CONFIG_FILE="$template"
                compose --profile gateway up -d nginx
                persist_setting GATEWAY_MODE "$mode"
                persist_setting NGINX_CONFIG_FILE "$template"
                printf "Gateway mode '%s' is active and recorded in .env.\n" "$mode"
                if [[ "$mode" == "internal" || "$mode" == "migration" ]]; then
                    printf "Install this root certificate into every client trust store: %s/internal-ca.crt\n" \
                        "$(env_setting_default TLS_CERTS_DIR ./secrets/tls)"
                fi
                ;;
            *) fail "Usage: model.sh gateway <internal|migration|external|status>" ;;
        esac
        ;;
    observability)
        (( ${#TARGETS[@]} == 1 )) ||
            fail "Usage: model.sh observability <local|remote|off>"
        mode="${TARGETS[0]}"
        [[ "$mode" == "local" || "$mode" == "remote" || "$mode" == "off" ]] ||
            fail "Usage: model.sh observability <local|remote|off>"
        if [[ "$mode" == "off" ]]; then
            compose --profile local-observability stop prometheus loki tempo grafana
            compose --profile telemetry stop alloy
            persist_setting OBSERVABILITY_MODE off
            printf 'Telemetry is stopped. ALLOY_CONFIG_FILE was left unchanged.\n'
            printf 'Applications keep serving and will log OTLP export errors until Alloy returns.\n'
            printf 'Resume with: model.sh observability local|remote\n'
            exit 0
        fi
        if [[ "$mode" == "remote" ]]; then
            assert_remote_endpoint REMOTE_METRICS_URL
            assert_remote_endpoint REMOTE_LOKI_URL
            assert_remote_endpoint REMOTE_TEMPO_ENDPOINT
            assert_non_empty_setting REMOTE_METRICS_TOKEN
            assert_non_empty_setting REMOTE_LOKI_TOKEN
            assert_non_empty_setting REMOTE_TEMPO_TOKEN
        fi
        export OBSERVABILITY_MODE="$mode"
        if [[ "$mode" == "local" ]]; then
            has_compose_profile local-observability ||
                fail "compose.yaml does not define the expected 'local-observability' profile."
            export ALLOY_CONFIG_FILE="./observability/config.alloy"
            compose --profile local-observability --profile telemetry up -d
            alloy_config="./observability/config.alloy"
        else
            [[ -f "$SCRIPT_DIR/observability/config.remote.alloy" ]] ||
                fail "Remote observability requires observability/config.remote.alloy."
            export ALLOY_CONFIG_FILE="./observability/config.remote.alloy"
            compose --profile local-observability stop prometheus loki tempo grafana
            compose --profile telemetry up -d alloy
            alloy_config="./observability/config.remote.alloy"
        fi
        persist_setting OBSERVABILITY_MODE "$mode"
        persist_setting ALLOY_CONFIG_FILE "$alloy_config"
        printf "Observability mode '%s' is active and recorded in .env.\n" "$mode"
        printf 'Base services (postgres, litellm, open-webui, alloy) are up. Start a model next.\n'
        ;;
    *)
        fail "Usage: model.sh <preflight|start|start-many|stop|status|gateway|observability> [arguments]"
        ;;
esac
