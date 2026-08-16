# Команды проверки стенда

Все команды выполняет оператор. Агент/CI не заменяет эту приёмку.

Подставьте свои hostnames и пути. Для internal CA используйте `--cacert secrets/tls/internal-ca.crt` или системный trust store после установки root.

> **На Windows `--cacert` не работает.** И `curl.exe`, и curl из Git Bash собраны со Schannel, который берёт доверие только из системного хранилища и этот флаг игнорирует. Симптом — не ошибка сертификата, а `schannel: failed to receive handshake` и `HTTP 000`. Установите root через `Import-Certificate` (см. [quick-start-https.md](quick-start-https.md)) и выполняйте команды без `--cacert`.
>
> Отдельная особенность PowerShell 5.1: он теряет двойные кавычки при передаче аргументов нативным программам, поэтому `curl.exe -d '{"a":"b"}'` доходит до сервера как невалидный JSON. Используйте `Invoke-RestMethod` либо передавайте тело файлом через `--data-binary "@файл"`.

## Переменные, используемые ниже

| Переменная | Что это | Откуда взять |
|---|---|---|
| `LITELLM_MASTER_KEY` | админский ключ LiteLLM | из `.env`; только с хоста через loopback |
| `CLIENT_VIRTUAL_KEY` | ограниченный virtual key для проверок API | создаётся в §3 |

```bash
export CLIENT_VIRTUAL_KEY='sk-...'   # не сохраняйте в shell history
```

Если проверка падает — расшифровка типовых отказов в [troubleshooting.md](troubleshooting.md).

## 1. Конфигурация без запуска нагрузки

```bash
# preflight хоста: Docker, GPU, диск, порт, hostnames
./model.sh preflight

# Compose с локальной observability и gateway
docker compose --env-file .env \
  --profile main --profile gateway --profile local-observability \
  config >/dev/null

# remote без profile local-observability
OBSERVABILITY_MODE=remote \
ALLOY_CONFIG_FILE=./observability/config.remote.alloy \
docker compose --env-file .env --profile main --profile gateway config >/dev/null

# все шаблоны nginx. Запуск идёт под тем же UID и с той же раскладкой томов,
# что и боевой сервис, поэтому проверка ловит не только синтаксис, но и
# нечитаемые сертификаты. tmpfs на conf.d обязателен: туда entrypoint
# рендерит шаблоны, а сам /etc/nginx в образе только для чтения.
for mode in internal external migration; do
  docker run --rm --user 101:101 \
    --tmpfs /etc/nginx/conf.d:mode=1777 --tmpfs /tmp:mode=1777 \
    -e PUBLIC_HOST -e DNS_ZONE -e OLD_PUBLIC_HOST -e ADMIN_ALLOW_CIDR \
    -e TLS_CERT_FILE -e TLS_KEY_FILE \
    -e TLS_INTERNAL_CERT_FILE -e TLS_INTERNAL_KEY_FILE \
    -e NGINX_CLIENT_MAX_BODY_SIZE \
    -e 'NGINX_ENVSUBST_FILTER=^(PUBLIC_|OLD_PUBLIC_|TLS_|NGINX_CLIENT_|DNS_ZONE|ADMIN_)' \
    -v "$PWD/nginx/templates/common.conf.template:/etc/nginx/templates/00-common.conf.template:ro" \
    -v "$PWD/nginx/templates/gateway.$mode.conf.template:/etc/nginx/templates/10-gateway.conf.template:ro" \
    -v "$PWD/nginx/routes:/etc/nginx/routes:ro" \
    -v "$PWD/secrets/tls:/etc/nginx/certs:ro" \
    nginxinc/nginx-unprivileged:1.29-alpine nginx -t \
    && echo "OK: $mode"
done
```

Ожидание: exit code `0`. Команды `./model.sh gateway <mode>` выполняют такую же валидацию автоматически и не переключают gateway при ошибке.

Режимы `external` и `migration` требуют реальных `server.crt`/`server.key` в `secrets/tls`. Если их ещё нет, эти два режима закономерно не пройдут — проверяйте их перед сменой сертификата, а не на пустом каталоге.

`NGINX_ENVSUBST_FILTER` в команде обязателен. Без него envsubst подставит и переменные самого nginx — `$host`, `$scheme`, `$connection_upgrade` — пустыми строками, и конфигурация пройдёт проверку, потеряв заголовки проксирования.

## 2. GPU и базовый стек

```bash
docker run --rm --gpus all nvidia/cuda:12.9.0-base-ubuntu22.04 nvidia-smi
./model.sh observability local
./model.sh gateway internal
./model.sh start main --gpu-metrics
./model.sh status
docker compose --profile main logs --tail=100 vllm-main
```

Ожидание:

- `nvidia-smi` видит GPU;
- `vllm-main` eventually healthy;
- `litellm`, `nginx`, `alloy` запущены.

## 3. Virtual key для клиентов

Админский эндпоинт доступен только на loopback: публичный route в nginx его не пропускает. Выполняйте команду **на самом хосте**. С рабочей машины предварительно поднимите tunnel: `ssh -L 4000:127.0.0.1:4000 <user>@<server>`.

```bash
curl -fsS http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"client-app","models":["qwen3.5-4b-awq"],"max_budget":100}'
```

Ключ из поля `key` выдайте клиенту. Master-ключ не выдаётся никому: им управляется весь стек.

Отдельным ключом создайте `CLIENT_VIRTUAL_KEY` для проверок API ниже — не переиспользуйте ключ UI:

```bash
curl -fsS http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"acceptance","models":["qwen3.5-4b-awq","qwen3-4b-awq"]}'
```

## 4. TLS и маршрутизация

```bash
# корневой сертификат локального CA лежит файлом, экспортировать нечего
openssl x509 -in secrets/tls/internal-ca.crt -noout -subject -issuer -dates -fingerprint -sha256

# какие имена реально покрывает сертификат шлюза
openssl x509 -in secrets/tls/internal.crt -noout -ext subjectAltName -dates

# API host
curl -fsS --cacert secrets/tls/internal-ca.crt https://vlm.rpa.local/v1/models \
  -H "Authorization: Bearer $CLIENT_VIRTUAL_KEY"

# неизвестный SNI должен обрываться на рукопожатии, а не отдавать сертификат
curl -vk --resolve evil.example:443:<server-ip> https://evil.example/ || true

# порт 80 закрыт
nc -zv <server-ip> 80 || true
```

Ожидание: `/v1/models` возвращает JSON; 80 недоступен; unknown Host не отдаёт chat UI.

## 5. API / streaming / VLM

```bash
# обычный chat
curl -fsS --cacert secrets/tls/internal-ca.crt \
  https://vlm.rpa.local/v1/chat/completions \
  -H "Authorization: Bearer $CLIENT_VIRTUAL_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.5-4b-awq","messages":[{"role":"user","content":"Ответь одним словом: работает?"}]}'

# streaming
curl -N --cacert secrets/tls/internal-ca.crt \
  https://vlm.rpa.local/v1/chat/completions \
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
curl -fsS --cacert secrets/tls/internal-ca.crt https://vlm.rpa.local/v1/models \
  -H "Authorization: Bearer $CLIENT_VIRTUAL_KEY"

# concurrent только на подходящем GPU-стенде
# ALLOW_CONCURRENT_MODELS=true
# ./model.sh start-many main alt --gpu-metrics
```

Ожидание: после `start alt` отвечает `qwen3-4b-awq`; неактивный слот даёт явную ошибку соединения, не silent fallback.

## 7. Gateway migration / external

```bash
# после подготовки secrets/tls/server.crt|key и SAN
./model.sh gateway migration
# проверить старые и новые имена на 443
./model.sh gateway external
# закрыть старые DNS/hosts после cutover
```

Ожидание: client base URL при смене только сертификата не меняется; при смене имени cookies сессии админки не переносятся.

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
nmap -Pn -p 22,80,443,3001,4000,8001,8002,9090,12345 <server-ip>
```

Ожидание: открыт только `443`. Из admin-сети дополнительно допустим `22`.

## 10. Отказ и rollback

```bash
./model.sh gateway internal          # если external сломан
./model.sh observability local       # если remote сломан
./model.sh start main --gpu-metrics  # вернуть рабочий слот
```

Volumes не удаляйте (`down -v`) без явного решения о потере данных.
