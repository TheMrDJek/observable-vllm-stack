# Сеть и TLS

## Граница доступа

Единственная клиентская точка входа — Caddy на `443/tcp`.

```text
клиент ── HTTPS/443 ── Caddy
                        ├── api.vlm.local  ── LiteLLM:4000
                        └── chat.vlm.local ── Open WebUI:8080
```

PostgreSQL, vLLM, Prometheus, Loki, Tempo и Alloy не являются клиентскими endpoints. Grafana также не публикуется наружу без отдельного решения по аутентификации и доступу. Docker-сети не считаются самостоятельной защитной границей, если сервис публикует host port.

Compose публикует Caddy на `${PUBLIC_BIND_ADDRESS:-0.0.0.0}:${PUBLIC_HTTPS_PORT:-443}`. Диагностические порты LiteLLM, Open WebUI, vLLM, Grafana, Prometheus и Alloy привязаны к `127.0.0.1`.

## Имена

Используйте два стабильных имени:

- `PUBLIC_API_HOST=api.vlm.local` — машинные OpenAI-compatible клиенты;
- `PUBLIC_CHAT_HOST=chat.vlm.local` — браузерный UI.

Не объединяйте их path routing на одном имени без необходимости: отдельные имена упрощают политики, сертификаты, логи и будущий перенос. Сертификат может быть единым SAN или отдельным на каждое имя.

Для internal CA имена должны разрешаться внутренним DNS/hosts. Для external-режима готовый сертификат должен покрывать оба имени. Сертификат на IP не заменяет сертификат на DNS-имя.

## Режимы gateway

```text
model.ps1 gateway internal|migration|external|status
model.sh  gateway internal|migration|external|status
```

- `internal` — Caddy выпускает сертификаты от своей internal CA;
- `migration` — старые `OLD_PUBLIC_*` имена используют internal CA, новые `PUBLIC_*` — готовые внешние certificate/key files;
- `external` — оба `PUBLIC_*` имени используют `${TLS_CERTS_DIR}/${TLS_CERT_FILE}` и `${TLS_CERTS_DIR}/${TLS_KEY_FILE}`;
- `status` — показывает только строку контейнера Caddy из `docker compose ps`.

Для `migration`/`external` скрипт проверяет наличие файлов, но не проверяет SAN, expiry, соответствие ключа сертификату или цепочку. Файлы кладите по образцу [`secrets.example/caddy`](../secrets.example/caddy/README.md) в gitignored `secrets/caddy/`. `GATEWAY_MODE` не читается Caddy напрямую; скрипт выбирает `Caddyfile.<mode>` через `CADDY_CONFIG_FILE`.

## Internal CA

Плюсы: быстрый запуск, не нужен публичный DNS или интернет. Минусы: root CA нужно безопасно доставить каждому клиенту; компрометация CA критична.

- храните private key CA только на gateway-host;
- резервируйте его как секрет с шифрованием и контролем доступа;
- передавайте клиентам только root certificate;
- сверяйте fingerprint по независимому каналу;
- ведите перечень устройств, куда установлен root;
- планируйте отзыв доверия и удаление root после пилота.

Клиенты обязаны проходить обычную TLS-проверку. Запретите `-k`, отключение hostname verification и самописные trust callbacks.

## External certificate

Перед включением проверьте:

- сертификат покрывает оба имени;
- сервер отдаёт полную цепочку без root;
- часы хоста синхронизированы;
- renewal организован отдельно от этого репозитория;
- ключ имеет права только у gateway;
- есть alert на expiry и ошибку renew.

Текущие Caddyfiles отключают HTTP redirect и не выполняют ACME. Порт 80 стек не публикует. Получение и renewal внешнего сертификата выполняются внешним процессом. При первом переключении используйте `gateway external` либо `gateway migration`; после замены файлов в уже активном режиме явно перечитайте их:

```bash
docker compose --profile gateway restart caddy
```

## Одновременная смена DNS и TLS

Главный риск — часть клиентов идёт на старый IP, часть на новый, а сертификат/режим уже отключён на одном из них. Поэтому:

1. заранее снизьте TTL;
2. задайте старые имена в `OLD_PUBLIC_*`, новые — в `PUBLIC_*`;
3. положите внешний certificate/key pair в `TLS_CERTS_DIR`;
4. выполните `gateway migration` и проверьте оба набора имён;
5. измените DNS/настройки клиентов;
6. наблюдайте оба набора имён не меньше старого TTL;
7. выполните `gateway external` после исчезновения трафика на старые имена.

Одновременная смена без параллельного окна делает rollback ненадёжным.

## Firewall и Docker

На Ubuntu разрешайте `443/tcp` и ограниченный `22/tcp`. Не публикуйте внутренние сервисы на `0.0.0.0`. Docker создаёт собственные iptables rules и может обходить ожидаемую политику UFW; контролируйте published ports и при необходимости `DOCKER-USER`.

Проверки:

```bash
ss -lntp
docker compose ps
docker compose config
sudo ufw status verbose
```

С другой машины просканируйте только согласованные адреса:

```bash
nmap -Pn -p 22,80,443,3000,3001,4000,8001,8002,9090,12345 <server-ip>
```

Ожидаемо открыт 443 и, только для управляющей сети, 22. Порт 80 зависит от выбранного ACME challenge. Остальные должны быть закрыты.

## Фактическая маршрутизация

- API-host пропускает только `/v1` и `/v1/*` в LiteLLM; остальные пути, включая `/key/generate` и LiteLLM UI, получают `404`;
- chat-host целиком проксируется в Open WebUI;
- `flush_interval -1` используется для streaming;
- dial timeout равен 10 секундам, остальные proxy timeouts — 10 минут;
- HTTP redirect отключён, Caddy слушает HTTPS внутри контейнера на 8443;
- контейнер Caddy read-only, с `cap_drop: ALL` и `no-new-privileges`.

Удалённые `image_url` по умолчанию заблокированы фиктивным allowlist `media.invalid`, redirects выключены. `data:` URL продолжают работать. Если изменить `VLLM_ALLOWED_MEDIA_DOMAINS`, владелец конфигурации принимает SSRF-риск разрешённых доменов и их DNS.

## Диагностика

```bash
openssl s_client -connect api.vlm.local:443 -servername api.vlm.local -showcerts
curl -v https://api.vlm.local/v1/models
```

Не добавляйте `-k`. Ошибка должна быть исправлена в DNS, SAN, цепочке или trust store, а не скрыта.
