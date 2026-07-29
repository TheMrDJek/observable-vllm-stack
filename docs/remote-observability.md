# Локальная и удалённая наблюдаемость

## Режимы

| Режим | Что работает на VLM-хосте | Куда уходят данные |
|-------|--------------------------|--------------------|
| `local` | Alloy + Prometheus + Loki + Tempo + Grafana | локальные volumes |
| `remote` | только Alloy | удалённый LGTM |

Приложения всегда отправляют OTLP traces на `alloy:4317`. Меняются только sinks Alloy.

## Локальный режим

```dotenv
OBSERVABILITY_MODE=local
ALLOY_CONFIG_FILE=./observability/config.alloy
DEPLOYMENT_ID=ai-vllm-pilot-01
ENVIRONMENT=pilot
SITE=local
INSTANCE_ID=vlm-host-01
```

```bash
./model.sh observability local
```

```powershell
.\model.ps1 observability local
```

Команда поднимает профиль `local-observability` и Alloy с локальной конфигурацией.

Alloy:

- scrape LiteLLM / vLLM / GPU exporter / себя;
- собирает cAdvisor и базовые host metrics;
- читает Docker logs;
- принимает OTLP traces;
- пишет в локальные Prometheus, Loki и Tempo;
- добавляет labels `deployment`, `environment`, `site`, `instance`.

Порты наблюдаемости привязаны к `127.0.0.1`. На Ubuntu используйте SSH tunnel:

```bash
ssh -L 3001:127.0.0.1:3001 <user>@<server>
```

Затем откройте `http://127.0.0.1:3001`. Не публикуйте Grafana, Prometheus или Alloy UI в сеть.

## Удалённый режим

Пока endpoints неизвестны, оставляйте remote-переменные пустыми и работайте в `local`.

Когда удалённый LGTM готов:

```dotenv
OBSERVABILITY_MODE=remote
ALLOY_CONFIG_FILE=./observability/config.remote.alloy
REMOTE_METRICS_URL=https://mimir.example/api/v1/write
REMOTE_METRICS_TOKEN=CHANGE_ME_WRITE_ONLY
REMOTE_LOKI_URL=https://loki.example/loki/api/v1/push
REMOTE_LOKI_TOKEN=CHANGE_ME_WRITE_ONLY
REMOTE_TEMPO_ENDPOINT=https://tempo.example
REMOTE_TEMPO_TOKEN=CHANGE_ME_WRITE_ONLY
REMOTE_CA_DIR=./secrets/remote-ca
REMOTE_CA_FILE=/etc/ssl/certs/ca-certificates.crt
```

Для private CA:

```dotenv
REMOTE_CA_FILE=/etc/alloy/remote-ca/root.crt
```

и положите `root.crt` в `secrets/remote-ca/` по образцу `secrets.example/remote-ca/`.

```bash
./model.sh observability remote
```

```powershell
.\model.ps1 observability remote
```

Скрипт:

1. проверяет абсолютные HTTP(S) URL и непустые токены;
2. останавливает локальные `prometheus`, `loki`, `tempo`, `grafana`;
3. запускает Alloy с `config.remote.alloy`.

Локальные volumes при этом не удаляются.

## Labels

Одинаковые labels в local и remote:

```text
deployment   = DEPLOYMENT_ID
environment  = ENVIRONMENT
site         = SITE
instance     = INSTANCE_ID
service      = litellm | vllm-main | open-webui | ...
model_slot   = main | alt | none
```

Не кладите в labels model revision, request id, prompt или user text.

## Dashboards

Файлы:

- `observability/grafana/dashboards/llm-stack.json`
- `observability/grafana/dashboards/llm-api-performance.json`

В локальной Grafana они provisioned автоматически.

В удалённой Grafana:

1. создайте datasources Prometheus/Mimir, Loki, Tempo;
2. выровняйте UID с `observability/grafana/provisioning/datasources/datasources.yaml` (`prometheus`, `loki`, `tempo`) либо поправьте UID в JSON;
3. импортируйте оба dashboard;
4. используйте фильтры `deployment` / `site` / `instance`.

## Отложенное подключение

1. Стартуйте пилот в `local`.
2. Позже заполните remote URL/token.
3. Проверьте DNS/TLS/auth с хоста.
4. Выполните `observability remote`.
5. Сгенерируйте тестовый запрос и проверьте метрики, логи и трейс.

История не мигрирует автоматически. Удалённый стек получает только новые данные с момента переключения. Старые local volumes можно временно поднять через `observability local` для просмотра.

## Что не уходит в observability по умолчанию

- полные prompts/responses LiteLLM: `STORE_PROMPTS_IN_SPEND_LOGS=false`;
- OTLP metrics/logs приложений отключены, чтобы не дублировать scrape и Docker logs;
- Authorization, cookies и тела запросов не должны попадать в labels.

## Alloy privileged

Alloy работает `privileged` и монтирует Docker socket. Для пилота это осознанный trade-off ради cAdvisor/Docker discovery. Меры:

- не публиковать Alloy UI;
- ограничить доступ к `.env` и compose;
- закреплять версию образа;
- считать компрометацию Alloy компрометацией хоста.

## Проверка после remote

```bash
# readiness Alloy на loopback
curl -fsS http://127.0.0.1:12345/-/ready

# один тестовый chat completion через API host
# затем в remote Grafana:
# PromQL: up{deployment="ai-vllm-pilot-01"}
# LogQL:  {deployment="ai-vllm-pilot-01"}
# TraceQL: { resource.deployment = "ai-vllm-pilot-01" }
```

Ожидаемо:

- inactive vLLM slot и выключенный GPU exporter дают `up=0`;
- краткий обрыв remote backend не останавливает inference;
- rollback: `./model.sh observability local`.

## Air-gap

В закрытой сети используйте только `local` либо внутренний LGTM. Образы, dashboards и модели подготовьте заранее. См. раздел air-gap в `docs/install-ubuntu-ssh.md`.
