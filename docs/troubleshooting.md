# Диагностика

Типовые отказы пилотного стенда: симптом → проверка → причина → что сделать.

## С чего начинать всегда

```bash
./model.sh status                                   # что вообще запущено
docker compose ps -a                                # включая упавшие контейнеры
docker compose --profile main logs --tail=100 vllm-main
docker compose logs --tail=50 litellm nginx alloy
```

Правило: сначала смотрите **самый нижний** отказавший слой. Если vLLM не поднялся, разбираться с nginx бессмысленно.

---

## 1. `could not select device driver "nvidia" with capabilities: [[gpu]]`

**Проверка**

```bash
docker run --rm --gpus all nvidia/cuda:12.9.0-base-ubuntu22.04 nvidia-smi
```

**Причина.** NVIDIA Container Toolkit не установлен или не прописан в runtime Docker. Драйвер на хосте сам по себе не даёт контейнеру доступ к GPU.

**Что сделать**

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Если `nvidia-smi` на хосте тоже не работает — проблема в драйвере, не в Docker. vLLM не заработает, пока эта команда не отдаёт таблицу GPU. Не устанавливайте полный CUDA toolkit на хост: нужны только драйвер и Container Toolkit.

---

## 2. vLLM уже 20 минут в состоянии `starting` / `health: starting`

**Проверка**

```bash
docker compose --profile main logs -f vllm-main
du -sh data/huggingface
```

**Причина.** Это нормальное поведение первого запуска, а не отказ. Модель качается с Hugging Face (для дефолтного `QuantTrio/Qwen3.5-4B-AWQ` — около 4 GiB), затем загружается в VRAM и компилирует граф. В [compose.yaml](../compose.yaml) для vLLM задан `start_period: 15m` именно поэтому.

**Ожидаемые тайминги**

| Этап | Первый запуск | Повторный запуск |
|---|---|---|
| Скачивание весов | 3–20 мин (зависит от канала) | 0, кэш в `data/huggingface` |
| Загрузка в VRAM + прогрев | 1–4 мин | 1–4 мин |
| Итого до `healthy` | **10–30 мин** | 2–5 мин |

**Что сделать.** Дождаться. В логах видно прогресс загрузки файлов и строку `Starting vLLM API server`. Состояние `running` контейнера не означает готовность модели — ориентируйтесь на `healthy` и на реальный ответ `/v1/models`.

---

## 3. vLLM падает: `torch.OutOfMemoryError: CUDA out of memory`

**Проверка**

```bash
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
docker compose --profile main logs --tail=50 vllm-main
```

**Причина.** Веса + KV-cache + активации + CUDA overhead не помещаются в VRAM. Частые триггеры: слишком большой `MAX_MODEL_LEN`, запущены оба слота одновременно, на карте висит посторонний процесс (иксы, другой контейнер).

**Что сделать** — по одному изменению за раз, в этом порядке:

1. Убедиться, что запущен ровно один слот: `./model.sh stop && ./model.sh start main`.
2. Снизить контекст: `MAIN_VLLM_MAX_MODEL_LEN=4096`.
3. Снизить бюджет процесса: `MAIN_VLLM_GPU_MEMORY_UTILIZATION=0.80`.
4. Уменьшить лимит картинок: `--limit-mm-per-prompt.image` в `MAIN_EXTRA_ARGS`.
5. В крайнем случае — `MAIN_CPU_OFFLOAD_GB=2` (заметно медленнее).

Снижение `max-model-len` **не уменьшает размер весов** — только KV-cache. Если не помещаются сами веса, нужна модель меньше или сильнее квантованная.

---

## 4. `The .env setting X still contains CHANGE_ME`

**Причина.** Скрипт отказывается стартовать, пока в `.env` остался хотя бы один placeholder. Это защита от запуска с предсказуемыми секретами.

**Что сделать.** Найти и заменить все:

```bash
grep -n CHANGE_ME .env
```

Сгенерировать значения:

```bash
echo "sk-$(openssl rand -hex 24)"   # LITELLM_MASTER_KEY, LITELLM_SALT_KEY, VLLM_API_KEY
openssl rand -hex 32                # WEBUI_SECRET_KEY (64 hex-символа)
openssl rand -base64 24             # POSTGRES_PASSWORD, GRAFANA_ADMIN_PASSWORD
```

`OPEN_WEBUI_LITELLM_KEY` при первом запуске остаётся **пустым** — это не placeholder.

---

## 5. `./model.sh: line 2: $'\r': command not found`

**Причина.** Файл имеет CRLF-переводы строк. Так бывает, если каталог скопировали с Windows архивом/scp вместо `git clone`, либо редактировали в Windows-редакторе без сохранения LF.

**Что сделать**

```bash
sed -i 's/\r$//' model.sh
chmod +x model.sh
```

Правильный способ получить файлы на Ubuntu — `git clone`: репозиторий содержит [.gitattributes](../.gitattributes), который принудительно выдаёт LF для `*.sh`, конфигурации nginx, `*.yaml` и `*.alloy`.

---

## 6. `Invalid .env line: '...'. Expected NAME=value.`

**Причина.** В `.env` есть строка без `=`, которая не является комментарием. Чаще всего — перенос длинного значения на вторую строку или вставленный из чата текст.

**Что сделать.** Привести строку к виду `NAME=value` в одну строку. Значения с пробелами или `#` заключить в кавычки:

```dotenv
GRAFANA_ADMIN_PASSWORD="a b#c"
```

---

## 7. vLLM: `401 Client Error` / `Repository Not Found` от Hugging Face

**Причина.** Модель gated (требует принятия лицензии) либо приватная, а `HF_TOKEN` пуст или без нужных прав.

**Что сделать.** Принять лицензию на странице модели своим аккаунтом, создать read-only токен и положить в `HF_TOKEN`. Затем пересоздать слот:

```bash
docker compose --profile main up -d --force-recreate vllm-main
```

Для air-gap токен не поможет — нужны заранее скачанные файлы в `data/huggingface`.

---

## 8. `dependency failed to start: container ...-open-webui-1 is unhealthy`

**Проверка**

```bash
docker compose ps
docker compose logs --tail=50 open-webui litellm postgres
```

**Причина.** nginx зависит от healthy `litellm` и `open-webui`, а `open-webui` — от healthy `litellm`, который в свою очередь ждёт healthy `postgres`. Отказ внизу цепочки блокирует nginx.

**Что сделать.** Чинить самый нижний нездоровый сервис. Типичные варианты:

- `postgres` unhealthy → неверный `POSTGRES_PASSWORD` при уже существующем volume. Пароль в `.env` должен совпадать с тем, с которым база инициализировалась. Смена пароля постфактум требует `ALTER USER` внутри контейнера, а не правки `.env`;
- `litellm` unhealthy → смотрите его логи: чаще всего невалидный YAML в [config/litellm.yaml](../config/litellm.yaml) или изменённый `LITELLM_SALT_KEY`.

---

## 9. `Bind for 0.0.0.0:443 failed: port is already allocated`

**Проверка**

```bash
sudo ss -lntp | grep ':443'
```

**Причина.** Порт занят посторонним веб-сервером (Apache, IIS, чужой nginx) или прошлым контейнером этого же стека.

**Что сделать.** Освободить порт либо задать другой в `.env`:

```dotenv
PUBLIC_HTTPS_PORT=8443
```

Тогда клиентский URL становится `https://api.vlm.local:8443`. На Windows порт может держать служба `http.sys` — проверяйте `netstat -ano | findstr :443`.

---

## 10. `curl: (60) SSL certificate problem: self signed certificate in certificate chain`

**Причина.** Режим `gateway internal`, а root CA локального центра не установлен в trust store клиента.

**Что сделать** — установить CA, а не добавлять `-k`. Корневой сертификат лежит файлом в `TLS_CERTS_DIR`, доставать его из контейнера не нужно:

```bash
sudo install -m 0644 secrets/tls/internal-ca.crt \
  /usr/local/share/ca-certificates/vlm-internal-ca.crt
sudo update-ca-certificates
```

Подробности и Windows-вариант — в [quick-start-https.md](quick-start-https.md).

`-k` отключает проверку подлинности сервера. Он не «временный обход», а отмена смысла теста.

**Отдельный случай Windows.** Встроенный в Windows `curl.exe` использует бэкенд Schannel и **игнорирует `--cacert` с PEM-файлом**: проверка идёт только по хранилищу Windows. Симптом — `schannel: failed to receive handshake, SSL/TLS connection failed` и `http=000`, хотя сервер исправен. Варианты:

```powershell
# 1. установить root CA в хранилище Windows (правильный путь)
Import-Certificate -FilePath .\internal-ca.crt -CertStoreLocation Cert:\LocalMachine\Root

# 2. либо проверять Linux-курлом из контейнера
docker run --rm -v "${PWD}\internal-ca.crt:/ca.crt:ro" curlimages/curl:latest `
  --cacert /ca.crt --resolve api.vlm.local:443:<host-ip> https://api.vlm.local/v1/models
```

Проверить используемый бэкенд: `curl --version` — в строке должно быть `OpenSSL`, а не `Schannel`.

---

## 11. `curl: (6) Could not resolve host` или сертификат не подходит

**Проверка**

```bash
getent hosts api.vlm.local chat.vlm.local
openssl s_client -connect api.vlm.local:443 -servername api.vlm.local </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName -dates
```

**Причина.** Нет DNS/hosts-записей, либо обращение идёт по IP. Сертификат выпускается на DNS-имена, на IP он не подходит.

**Что сделать.** Создать обе записи (`api` и `chat`) на IP хоста. Для пилота допустим hosts-файл клиента. Проверять только по имени, никогда по IP.

---

## 12. `/v1/models` возвращает 401 или `Invalid proxy server token`

**Причина.** Ключ не тот. Через 443 нужен LiteLLM virtual key (или master key), а **не** `VLLM_API_KEY` — последний внутренний, между LiteLLM и vLLM.

**Что сделать.** Проверить в обход nginx, чтобы отделить проблему шлюза от проблемы ключа:

```bash
curl -fsS http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

Если loopback работает, а HTTPS нет — проблема в nginx/TLS. Если не работает и loopback — неверный ключ или ключ отозван.

---

## 13. `/key/generate` через HTTPS отдаёт 404

**Это не ошибка, а замысел.** Публичный API-route в [nginx/routes/api.conf](../nginx/routes/api.conf) пропускает только `/v1` и `/v1/*`; админские эндпоинты и UI LiteLLM наружу закрыты.

Создавайте ключи с самого хоста через loopback:

```bash
curl -fsS http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"open-webui","models":["qwen3.5-4b-awq"]}'
```

С рабочего ноутбука — через SSH tunnel: `ssh -L 4000:127.0.0.1:4000 <user>@<server>`.

---

## 14. В Open WebUI пустой список моделей

**Проверка**

```bash
grep -n OPEN_WEBUI_LITELLM_KEY .env
docker compose logs --tail=30 open-webui
```

**Причины и что сделать**

1. `OPEN_WEBUI_LITELLM_KEY` пуст — так и задумано при первом запуске. Создайте virtual key (см. п. 13), впишите его в `.env` и пересоздайте **только** UI:
   ```bash
   docker compose up -d --force-recreate open-webui
   ```
2. Ключ вписан, но модели нет в его allowlist. При создании ключа в `models` должны быть перечислены имена из `/v1/models`.
3. Модель не запущена: `./model.sh start main`.
4. Имя в [config/litellm.yaml](../config/litellm.yaml) не совпадает с `--served-model-name` в `.env`. Эти два значения обязаны совпадать.

---

## 15. Grafana пустая, панели `No data`

**Проверка**

```bash
curl -fsS http://127.0.0.1:12345/-/ready
docker compose logs --tail=50 alloy
```

**Причины**

- Не было трафика. Метрики LiteLLM появляются только после первого запроса — сгенерируйте его;
- запущен `observability remote`, а вы смотрите локальную Grafana. В remote-режиме локальные LGTM остановлены;
- targets неактивного слота дают `up=0` — это ожидаемо, а не отказ.

Grafana доступна только через SSH tunnel:

```bash
ssh -L 3001:127.0.0.1:3001 <user>@<server>
```

---

## 16. Alloy в логах: ошибки записи в Prometheus/Loki

**Если режим `local`.** Alloy пишет в `http://prometheus:9090/api/v1/write`, а Prometheus не запущен. Это происходит, если базовый стек подняли не через `observability local`:

```bash
./model.sh observability local
```

**Если режим `remote`.** Проверьте с хоста доступность и авторизацию endpoint:

```bash
curl -v -H "Authorization: Bearer $REMOTE_METRICS_TOKEN" "$REMOTE_METRICS_URL"
```

Частые причины: приватный CA не смонтирован (нужен `REMOTE_CA_FILE=/etc/alloy/remote-ca/root.crt` и файл в `secrets/remote-ca/`), токен не write-scope, endpoint без полного пути (`/api/v1/write`, `/loki/api/v1/push`).

Кратковременный обрыв связи не останавливает inference: Alloy буферизует и досылает.

---

## 17. `start-many requires ALLOW_CONCURRENT_MODELS=true`

**Это защита, а не баг.** Скрипт не проверяет VRAM, поэтому одновременный запуск двух моделей включается только явно.

Перед включением посчитайте, помещаются ли обе. На 12 GiB карте две модели по `gpu-memory-utilization=0.85` почти гарантированно дадут OOM. Расчёт — в [model-operations.md](model-operations.md).

---

## 18. Кончилось место на диске

**Проверка**

```bash
df -h
docker system df -v
du -sh data/huggingface
```

**Что удалять безопасно**

```bash
docker image prune -a          # неиспользуемые образы
docker builder prune           # кэш сборки
rm -rf data/huggingface/models--<старая-модель>   # только после приёмки новой
```

**Чего не делать.** `docker compose down -v` и `docker volume prune` удалят PostgreSQL (ключи и учёт), Open WebUI (чаты), Grafana, метрики, логи, трейсы **и приватный ключ internal CA** — после этого всем клиентам придётся переустанавливать root CA.

---

## 19. После перезагрузки хоста стек не поднялся полностью

**Причина.** У всех сервисов стоит `restart: unless-stopped`, но сервисы под профилями (`vllm-*`, `nginx`, LGTM) вернутся только если контейнеры существовали. Если перед reboot был выполнен `./model.sh stop`, слот останется остановленным намеренно.

**Что сделать**

```bash
./model.sh observability local
./model.sh start main --gpu-metrics
./model.sh gateway internal
./model.sh status
```

Для автостарта после reboot заведите systemd unit, вызывающий эти команды. Compose сам по себе не оркестратор.

---

## 20. Заменили файлы сертификата, а nginx отдаёт старый

**Причина.** nginx читает cert/key при старте конфигурации. Подмена файлов на диске сама по себе перечитывания не вызывает.

**Что сделать**

```bash
docker compose --profile gateway restart nginx
```

Проверить, что отдаётся именно новый сертификат:

```bash
openssl s_client -connect api.vlm.local:443 -servername api.vlm.local </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

---

## 21. После `gateway external` вернулся internal-сертификат

**Причина.** Команда `gateway` задаёт `NGINX_CONFIG_FILE` для своего вызова Compose. Если после неё выполнить голый `docker compose up -d`, будет использовано значение из `.env`.

**Что сделать.** Убедиться, что `.env` содержит актуальный режим:

```bash
grep -n 'NGINX_CONFIG_FILE\|ALLOY_CONFIG_FILE' .env
```

Начиная с текущей версии скрипты записывают выбранный режим обратно в `.env` — если значение разошлось, значит nginx поднимали не через `./model.sh gateway`.

---

## 22. Модель ответила, но `content` пустой

**Симптом.** HTTP 200, `usage.completion_tokens` большой, а `choices[0].message.content` — пустая строка.

**Причина.** У слота включён `--reasoning-parser`, поэтому vLLM делит ответ на два поля: рассуждение попадает в `reasoning_content`, финальный ответ — в `content`. Если `max_tokens` исчерпан во время рассуждения, до `content` дело не доходит.

**Проверка**

```bash
curl -fsS https://api.vlm.local/v1/chat/completions \
  -H "Authorization: Bearer $CLIENT_VIRTUAL_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.5-4b-awq","max_tokens":600,
       "messages":[{"role":"user","content":"Сколько будет 2+2? Ответь только числом."}]}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); m=d['choices'][0]['message']; \
print('finish:', d['choices'][0]['finish_reason']); \
print('reasoning:', bool(m.get('reasoning_content'))); print('content:', repr(m.get('content')))"
```

`finish_reason: length` вместе с пустым `content` — это исчерпанный лимит, а не поломка.

**Что сделать**

- увеличить `max_tokens`: для этой модели ответу «одним словом» реально требуется 200–600 токенов, потому что рассуждение тоже считается;
- в клиенте читать оба поля: `content` показывать пользователю, `reasoning_content` — только в отладке;
- если рассуждение не нужно вовсе, убрать `--reasoning-parser` из `MAIN_EXTRA_ARGS` и пересоздать слот. Тогда всё придёт в `content`, но модель может выводить служебные теги прямо в текст.

---

## 23. Модель отвечает, но tool calling или reasoning не работает

**Причина.** Parsers привязаны к конкретному семейству моделей. Флаги `--tool-call-parser qwen3_coder` и `--reasoning-parser qwen3` в `MAIN_EXTRA_ARGS` подходят Qwen3; для другой модели их нужно менять вместе с моделью. Пустое значение `MAIN_EXTRA_ARGS=` убирает все флаги семейства — это и есть штатный вариант для моделей без reasoning и tool calling.

**Что сделать.** Свериться с документацией vLLM по поддерживаемым parsers для вашей модели и обновить `.env`. Обратите внимание: у слота `alt` в [compose.yaml](../compose.yaml) вообще нет `--enable-auto-tool-choice` — tool calling там не включён.

Помните: LiteLLM и vLLM **не вызывают функцию сами**, они лишь возвращают `tool_calls`. Выполнение — обязанность клиентского приложения. Пример полного цикла — в [examples/api.http](../examples/api.http).

---

## Если ничего не помогло

Соберите минимальный набор для разбора и **уберите из него секреты**:

```bash
./model.sh status > diag.txt
docker compose config >> diag.txt          # ВНИМАНИЕ: содержит значения .env
docker compose logs --tail=200 >> diag.txt
```

`docker compose config` печатает пароли и ключи в открытом виде. Перед отправкой кому-либо вычистите их. `.env` не передавайте никогда.
