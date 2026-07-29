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
            return
        fi
    done < "$ENV_FILE"
}

assert_slots() {
    local minimum="$1" maximum="$2" slot seen=""
    shift 2
    (( $# >= minimum && $# <= maximum )) ||
        fail "Expected between $minimum and $maximum slot arguments: main or alt."
    for slot in "$@"; do
        [[ "$slot" == "main" || "$slot" == "alt" ]] ||
            fail "Unknown model slot '$slot'. Allowed slots: main, alt."
        [[ " $seen " != *" $slot "* ]] || fail "Model slots must not be repeated."
        seen="$seen $slot"
    done
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
    directory="$(env_setting TLS_CERTS_DIR)"
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
    start)
        assert_slots 1 1 "${TARGETS[@]}"
        slot="${TARGETS[0]}"
        compose --profile main --profile alt stop vllm-main vllm-alt
        arguments=(--profile "$slot")
        $GPU_METRICS && arguments+=(--profile gpu-metrics)
        arguments+=(up -d)
        compose "${arguments[@]}"
        printf "Model slot '%s' is starting in the background.\n" "$slot"
        printf 'Follow progress: docker compose --profile %s logs -f vllm-%s\n' "$slot" "$slot"
        ;;
    start-many)
        assert_slots 2 2 "${TARGETS[@]}"
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
        compose --profile main --profile alt stop vllm-main vllm-alt
        printf 'Both vLLM slots are stopped. The rest of the stack is still running.\n'
        ;;
    status)
        assert_no_targets
        compose --profile main --profile alt --profile gpu-metrics \
            --profile gateway --profile local-observability ps
        ;;
    gateway)
        (( ${#TARGETS[@]} == 1 )) ||
            fail "Usage: model.sh gateway <internal|migration|external|status>"
        mode="${TARGETS[0]}"
        case "$mode" in
            status)
                compose --profile gateway ps caddy
                ;;
            internal|migration|external)
                if [[ "$mode" == "migration" || "$mode" == "external" ]]; then
                    assert_tls_files
                fi
                if [[ "$mode" == "migration" ]]; then
                    assert_non_empty_setting OLD_PUBLIC_API_HOST
                    assert_non_empty_setting OLD_PUBLIC_CHAT_HOST
                    assert_non_empty_setting PUBLIC_API_HOST
                    assert_non_empty_setting PUBLIC_CHAT_HOST
                fi
                [[ -f "$SCRIPT_DIR/caddy/Caddyfile.$mode" ]] ||
                    fail "Missing Caddy config for gateway mode '$mode': $SCRIPT_DIR/caddy/Caddyfile.$mode"
                has_compose_profile gateway ||
                    fail "compose.yaml does not define the expected 'gateway' profile."
                export GATEWAY_MODE="$mode"
                export CADDY_CONFIG_FILE="./caddy/Caddyfile.$mode"
                compose --profile gateway up -d caddy
                ;;
            *) fail "Usage: model.sh gateway <internal|migration|external|status>" ;;
        esac
        ;;
    observability)
        (( ${#TARGETS[@]} == 1 )) ||
            fail "Usage: model.sh observability <local|remote>"
        mode="${TARGETS[0]}"
        [[ "$mode" == "local" || "$mode" == "remote" ]] ||
            fail "Usage: model.sh observability <local|remote>"
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
            compose --profile local-observability up -d
        else
            [[ -f "$SCRIPT_DIR/observability/config.remote.alloy" ]] ||
                fail "Remote observability requires observability/config.remote.alloy."
            export ALLOY_CONFIG_FILE="./observability/config.remote.alloy"
            compose --profile local-observability stop prometheus loki tempo grafana
            compose up -d alloy
        fi
        ;;
    *)
        fail "Usage: model.sh <start|start-many|stop|status|gateway|observability> [arguments]"
        ;;
esac
