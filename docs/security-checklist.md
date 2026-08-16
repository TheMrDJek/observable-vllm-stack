# ИБ-чеклист пилотного VLM-стенда

Выполняет оператор стенда. Это не автоматический hardening и не замена корпоративного ИБ-аудита.

## До запуска

- [ ] `./model.sh preflight` пройден без `[FAIL]`.
- [ ] Ubuntu обновлён, NVIDIA driver и `nvidia-smi` работают.
- [ ] Docker Engine + Compose plugin + NVIDIA Container Toolkit проверены `docker run --gpus all ... nvidia-smi`.
- [ ] SSH: отключён password login, запрещён root login, доступ только из admin-сети/VPN.
- [ ] Пользователи в группе `docker` минимизированы и осознают root-эквивалентность.
- [ ] `.env` создан из `.env.example`, права `0600`, все `CHANGE_ME` заменены.
- [ ] `LITELLM_SALT_KEY` сохранён отдельно: после первого запуска его нельзя менять.
- [ ] `LITELLM_UI_PASSWORD` задан отдельным значением, не равным master-ключу.
- [ ] `STORE_PROMPTS_IN_SPEND_LOGS=false`, если нет согласованного хранения prompts.
- [ ] `VLLM_ALLOWED_MEDIA_DOMAINS=media.invalid`, если не нужен контролируемый URL-fetch изображений.
- [ ] `secrets/` и `.env` не попадают в Git, чаты, тикеты и логи.

## Периметр

- [ ] С пользовательской сети открыт только `443/tcp`.
- [ ] `22/tcp` открыт только admin-сети.
- [ ] Grafana, Prometheus, Alloy, PostgreSQL и vLLM не опубликованы наружу; LiteLLM доступен только через шлюз.
- [ ] UFW/firewall и `DOCKER-USER` проверены: Docker published ports не обходят политику.
- [ ] Неизвестный Host/SNI на nginx обрывается на рукопожатии (`ssl_reject_handshake`), а не отдаёт сертификат.

## TLS

- [ ] Клиенты проверяют цепочку без `-k` / `verify=false`.
- [ ] SAN сертификата содержит `PUBLIC_HOST` и `DNS_ZONE`.
- [ ] Для internal CA клиентам выдан только root certificate; private key CA не копировался.
- [ ] Для external/migration cert/key лежат в `secrets/tls` с минимальными правами.
- [ ] HSTS включается только после окончательного перехода на сертификат заказчика.

## Идентификация и приложения

- [ ] Каждому клиенту выдан отдельный virtual key с allowlist моделей и бюджетом.
- [ ] Master-ключ не выдан ни одному клиенту и не введён ни в одну форму, кроме админки при пустом `LITELLM_UI_PASSWORD`.
- [ ] Master key LiteLLM используется только через SSH tunnel к admin UI, не раздаётся клиентам.
- [ ] Каждому внешнему клиенту выдан свой virtual key, RPM/TPM/budget и срок действия.
- [ ] Административные пути закрыты `ADMIN_ALLOW_CIDR` для всех, кроме рабочих подсетей.
- [ ] Произвольные внешние `image_url` запрещены или ограничены allowlist.

## Контейнеры и supply chain

- [ ] Наружу опубликован только nginx на 443.
- [ ] `ADMIN_ALLOW_CIDR` сужен до рабочих подсетей: за административными путями стоит управление ключами, лимитами и бюджетами всего стека.
- [ ] `LITELLM_UI_PASSWORD` задан. При пустом значении вход в админку идёт по master-ключу, и тот оседает в браузерах.
- [ ] Сети `edge` и `backend` разделены: nginx не видит PostgreSQL, Alloy, Docker socket и vLLM.
- [ ] Образы закреплены digest/тегом из `.env.example`, модели — revision.
- [ ] Alloy privileged принят осознанно; входящий доступ к Alloy отсутствует.
- [ ] `HF_TOKEN` имеет минимальный scope или пуст.

## Observability

- [ ] Remote endpoints проверяют TLS; credentials write-only.
- [ ] Labels содержат только `deployment` / `environment` / `site` / `instance` / `service` / `model_slot`.
- [ ] Тестовый запрос не оставляет Authorization, cookies, prompts или responses в Loki/Tempo.
- [ ] Проверено, что внутренний ключ vLLM не попал в Loki. vLLM печатает при старте дамп `non-default args`, поэтому ключ, переданный аргументом `--api-key`, попадал в Docker-логи и далее в Loki. Ключ передаётся только переменной `VLLM_API_KEY` — в дамп аргументов она не входит. Дополнительно конвейер `loki.process "redact"` в обоих конфигах Alloy маскирует `sk-*` и пары `authorization/api_key/bearer` как вторая линия защиты. Проверка:

```bash
# из сети backend; ожидание — ни одной строки с фактическим ключом
docker run --rm --network ai-vllm-stack_backend curlimages/curl -sS -G \
  'http://loki:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={service="vllm-main"} |= "sk-"'
```
- [ ] Dashboards импортированы; фильтры стенда работают.

## Данные и приёмка

- [ ] Backup `.env`, PostgreSQL и ключа локального CA защищён так же, как прод-секреты.
- [ ] Если данные объявлены сохраняемыми — выполнен хотя бы один restore test.
- [ ] Запрос без key / с отозванным key получает 401/403.
- [ ] Превышение RPM/TPM блокируется.
- [ ] Прямые vLLM/Prometheus/Alloy/PostgreSQL недоступны из пользовательской сети.
- [ ] Secret scan репозитория и vulnerability scan закреплённых images не имеют необработанных critical findings.

## Остаточный риск

Alloy с Docker socket и `privileged` остаётся самой большой локальной поверхностью компрометации.
Если ИБ это не принимает, отключите privileged host metrics/Docker discovery и пересмотрите telemetry-архитектуру отдельно.
