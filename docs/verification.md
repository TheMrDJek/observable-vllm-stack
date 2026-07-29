# Команды проверки стенда

Все команды выполняет оператор. Агент/CI не заменяет эту приёмку.

Подставьте свои hostnames, ключи и пути. Для internal CA используйте `--cacert ./caddy-local-root.crt` или системный trust store после установки root.

## 1. Конфигурация без запуска нагрузки

```bash
# Compose с локальной observability и gateway
docker compose --env-file .env \
  --profile main --profile gateway --profile local-observability \
  config >/dev/null

# remote без profile local-observability
OBSERVABILITY_MODE=remote \
ALLOY_CONFIG_FILE=./observability/config.remote.alloy \
docker compose --env-file .env --profile main --profile gateway config >/dev/null

# Caddyfile internal
docker run --rm \
  -e PUBLIC_API_HOST -e PUBLIC_CHAT_HOST \
  -v "$PWD/caddy/Caddyfile.internal:/etc/caddy/Caddyfile:ro" \
  -v "$PWD/caddy/routes.caddy:/etc/caddy/routes.caddy:ro" \
  caddy:2.10.2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

Ожидание: exit code `0`.

## 2. GPU и базовый стек

```bash
docker run --rm --gpus all nvidia/cuda:12.9.0-base-ubuntu22.04 nvidia-smi
./model.sh observability local
./model.sh start main --gpu-metrics
./model.sh gateway internal
./model.sh status
docker compose --profile main logs --tail=100 vllm-main
```

Ожидание:

- `nvidia-smi` видит GPU;
- `vllm-main` eventually healthy;
- `litellm`, `open-webui`, `caddy`, `alloy` запущены.

## 3. Virtual key для Open WebUI

Через SSH tunnel к `127.0.0.1:4000` создайте ограниченный key:

```bash
curl -fsS http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models":["qwen3.5-4b-awq","qwen3-4b-awq"],"max_budget":100}'
```

Запишите key в `OPEN_WEBUI_LITELLM_KEY`, затем:

```bash
docker compose up -d --force-recreate open-webui
```

## 4. TLS и маршрутизация

```bash
# экспорт internal CA
docker compose --profile gateway cp \
  caddy:/data/caddy/pki/authorities/local/root.crt \
  ./caddy-local-root.crt

openssl x509 -in ./caddy-local-root.crt -noout -subject -issuer -dates

# API host
curl -fsS --cacert ./caddy-local-root.crt https://api.vlm.local/v1/models \
  -H "Authorization: Bearer $OPEN_WEBUI_LITELLM_KEY"

# неизвестный Host должен получить отказ/пустой сайт, не Open WebUI
curl -vk --resolve evil.example:443:<server-ip> https://evil.example/ || true

# порт 80 закрыт
nc -zv <server-ip> 80 || true
```

Ожидание: `/v1/models` возвращает JSON; 80 недоступен; unknown Host не отдаёт chat UI.

## 5. API / streaming / VLM

```bash
# обычный chat
curl -fsS --cacert ./caddy-local-root.crt \
  https://api.vlm.local/v1/chat/completions \
  -H "Authorization: Bearer $CLIENT_VIRTUAL_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.5-4b-awq","messages":[{"role":"user","content":"Ответь одним словом: работает?"}]}'

# streaming
curl -N --cacert ./caddy-local-root.crt \
  https://api.vlm.local/v1/chat/completions \
  -H "Authorization: Bearer $CLIENT_VIRTUAL_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.5-4b-awq","stream":true,"messages":[{"role":"user","content":"Считай до трёх"}]}'

# VLM через data URI, не через произвольный http(s) image_url
# см. examples/api.http
```

Ожидание: non-stream JSON; stream SSE chunks; VLM принимает data URI и отклоняет запрещённый remote URL.

## 6. Модели

```bash
./model.sh stop
./model.sh start alt --gpu-metrics
curl -fsS --cacert ./caddy-local-root.crt https://api.vlm.local/v1/models \
  -H "Authorization: Bearer $CLIENT_VIRTUAL_KEY"

# concurrent только на подходящем GPU-стенде
# ALLOW_CONCURRENT_MODELS=true
# ./model.sh start-many main alt --gpu-metrics
```

Ожидание: после `start alt` отвечает `qwen3-4b-awq`; неактивный слот даёт явную ошибку соединения, не silent fallback.

## 7. Gateway migration / external

```bash
# после подготовки secrets/caddy/server.crt|key и SAN
./model.sh gateway migration
# проверить старые и новые имена на 443
./model.sh gateway external
# закрыть старые DNS/hosts после cutover
```

Ожидание: client base URL при смене только сертификата не меняется; при смене DNS cookies Open WebUI не переносятся.

## 8. Observability

Local:

```bash
curl -fsS http://127.0.0.1:12345/-/ready
# Grafana via SSH tunnel :3001
# фильтры deployment/site/instance на dashboard Local LLM
```

Remote:

```bash
# заполнить REMOTE_* в .env
./model.sh observability remote
curl -fsS http://127.0.0.1:12345/-/ready
# PromQL: up{deployment="ai-vllm-pilot-01"}
# LogQL:  {deployment="ai-vllm-pilot-01"}
# TraceQL по resource.deployment
```

Ожидание: inactive targets `up=0`; локальные LGTM остановлены после remote; история не мигрировала.

## 9. Периметр

Из пользовательской сети:

```bash
nmap -Pn -p 22,80,443,3000,3001,4000,8001,8002,9090,12345 <server-ip>
```

Ожидание: открыт только `443`. Из admin-сети дополнительно допустим `22`.

## 10. Отказ и rollback

```bash
./model.sh gateway internal          # если external сломан
./model.sh observability local       # если remote сломан
./model.sh start main --gpu-metrics  # вернуть рабочий слот
```

Volumes не удаляйте (`down -v`) без явного решения о потере данных.
