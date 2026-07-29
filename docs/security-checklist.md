# ИБ-чеклист пилотного VLM-стенда

Выполняет оператор стенда. Это не автоматический hardening и не замена корпоративного ИБ-аудита.

## До запуска

- [ ] Ubuntu обновлён, NVIDIA driver и `nvidia-smi` работают.
- [ ] Docker Engine + Compose plugin + NVIDIA Container Toolkit проверены `docker run --gpus all ... nvidia-smi`.
- [ ] SSH: отключён password login, запрещён root login, доступ только из admin-сети/VPN.
- [ ] Пользователи в группе `docker` минимизированы и осознают root-эквивалентность.
- [ ] `.env` создан из `.env.example`, права `0600`, все `CHANGE_ME` заменены.
- [ ] `LITELLM_SALT_KEY` сохранён отдельно: после первого запуска его нельзя менять.
- [ ] `OPEN_WEBUI_LITELLM_KEY` пуст до создания отдельного virtual key.
- [ ] `STORE_PROMPTS_IN_SPEND_LOGS=false`, если нет согласованного хранения prompts.
- [ ] `VLLM_ALLOWED_MEDIA_DOMAINS=media.invalid`, если не нужен контролируемый URL-fetch изображений.
- [ ] `secrets/` и `.env` не попадают в Git, чаты, тикеты и логи.

## Периметр

- [ ] С пользовательской сети открыт только `443/tcp`.
- [ ] `22/tcp` открыт только admin-сети.
- [ ] LiteLLM, Open WebUI, Grafana, Prometheus, Alloy, PostgreSQL и vLLM не опубликованы наружу.
- [ ] UFW/firewall и `DOCKER-USER` проверены: Docker published ports не обходят политику.
- [ ] Неизвестный Host/SNI на Caddy не обслуживает API/UI.

## TLS

- [ ] Клиенты проверяют цепочку без `-k` / `verify=false`.
- [ ] SAN сертификата содержит `PUBLIC_API_HOST` и `PUBLIC_CHAT_HOST`.
- [ ] Для internal CA клиентам выдан только root certificate; private key CA не копировался.
- [ ] Для external/migration cert/key лежат в `secrets/caddy` с минимальными правами.
- [ ] HSTS включается только после окончательного перехода на сертификат заказчика.

## Идентификация и приложения

- [ ] После старта LiteLLM создан отдельный virtual key для Open WebUI с allowlist моделей.
- [ ] `OPEN_WEBUI_LITELLM_KEY` записан в `.env`, контейнер `open-webui` пересоздан.
- [ ] Master key LiteLLM используется только через SSH tunnel к admin UI, не раздаётся клиентам.
- [ ] Каждому внешнему клиенту выдан свой virtual key, RPM/TPM/budget и срок действия.
- [ ] Первый администратор Open WebUI создан, `WEBUI_ENABLE_SIGNUP=false`.
- [ ] Tools/functions/plugins Open WebUI выключены, пока нет отдельного threat model.
- [ ] Произвольные внешние `image_url` запрещены или ограничены allowlist.

## Контейнеры и supply chain

- [ ] Наружу опубликован только Caddy.
- [ ] Сети `edge` и `backend` разделены: Caddy не видит PostgreSQL/Alloy/Docker socket.
- [ ] Образы закреплены digest/тегом из `.env.example`, модели — revision.
- [ ] Alloy privileged принят осознанно; входящий доступ к Alloy отсутствует.
- [ ] `HF_TOKEN` имеет минимальный scope или пуст.

## Observability

- [ ] Remote endpoints проверяют TLS; credentials write-only.
- [ ] Labels содержат только `deployment` / `environment` / `site` / `instance` / `service` / `model_slot`.
- [ ] Тестовый запрос не оставляет Authorization, cookies, prompts или responses в Loki/Tempo.
- [ ] Dashboards импортированы; фильтры стенда работают.

## Данные и приёмка

- [ ] Backup `.env`, PostgreSQL, Open WebUI и Caddy CA защищён так же, как прод-секреты.
- [ ] Если данные объявлены сохраняемыми — выполнен хотя бы один restore test.
- [ ] Запрос без key / с отозванным key получает 401/403.
- [ ] Превышение RPM/TPM блокируется.
- [ ] Прямые vLLM/Prometheus/Alloy/PostgreSQL недоступны из пользовательской сети.
- [ ] Secret scan репозитория и vulnerability scan закреплённых images не имеют необработанных critical findings.

## Остаточный риск

Alloy с Docker socket и `privileged` остаётся самой большой локальной поверхностью компрометации.
Если ИБ это не принимает, отключите privileged host metrics/Docker discovery и пересмотрите telemetry-архитектуру отдельно.
