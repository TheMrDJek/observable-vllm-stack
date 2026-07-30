# Быстрый старт HTTPS

Клиентский вход в стек — только TCP/443:

- `https://api.vlm.local` → LiteLLM/OpenAI-compatible API;
- `https://chat.vlm.local` → Open WebUI.

Внутренние сервисы остаются на Docker networks или loopback. Прямой доступ к LiteLLM, vLLM, Grafana и хранилищам извне запрещён.

## 1. DNS

Создайте обе записи на IP хоста. Для временного пилота допустимы внутренний DNS или hosts-файлы:

```text
<server-ip> api.vlm.local
<server-ip> chat.vlm.local
```

Это значения `PUBLIC_API_HOST` и `PUBLIC_CHAT_HOST` из `.env`; при изменении используйте новые имена во всех командах. Проверьте с каждого клиента, что оба имени разрешаются именно в ожидаемый IP. Не тестируйте HTTPS по IP: сертификат выпускается на DNS-имена.

## 2. Internal CA

Ubuntu:

```bash
./model.sh gateway internal
./model.sh gateway status
```

Windows:

```powershell
.\model.ps1 gateway internal
.\model.ps1 gateway status
```

Первая команда монтирует `caddy/Caddyfile.internal` и запускает профиль `gateway`. `gateway status` выполняет только `docker compose --profile gateway ps caddy`: он показывает состояние контейнера, но не issuer, SAN, expiry или сохранённый режим.

## 3. Установка root CA клиентам

Скопируйте root certificate из volume Caddy:

```bash
docker compose --profile gateway cp \
  caddy:/data/caddy/pki/authorities/local/root.crt \
  ./caddy-local-root.crt
openssl x509 -in ./caddy-local-root.crt -noout -fingerprint -sha256
```

Передайте сертификат клиентам по аутентифицированному каналу и сверьте fingerprint вне канала передачи. Закрытый ключ CA никогда не копируйте.

Ubuntu/Debian-клиент:

```bash
sudo install -m 0644 caddy-local-root.crt /usr/local/share/ca-certificates/caddy-local-root.crt
sudo update-ca-certificates
```

Windows 11, PowerShell от администратора:

```powershell
Import-Certificate `
  -FilePath .\caddy-local-root.crt `
  -CertStoreLocation Cert:\LocalMachine\Root
```

Firefox может использовать собственное хранилище сертификатов — проверьте корпоративную настройку `security.enterprise_roots.enabled` либо импортируйте CA штатным способом Firefox.

Internal root CA даёт право выпускать доверенные сертификаты для установившего его клиента. Устанавливайте его только на управляемые устройства и удаляйте после окончания пилота.

## 4. Проверка без `-k`

```bash
curl --fail --show-error \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  https://api.vlm.local/v1/models
```

PowerShell:

```powershell
$headers = @{ Authorization = "Bearer $env:LITELLM_MASTER_KEY" }
Invoke-RestMethod -Uri "https://api.vlm.local/v1/models" -Headers $headers
```

Откройте `https://chat.vlm.local` в браузере. Проверка считается успешной, только если:

- нет предупреждения сертификата;
- URL использует DNS-имя, а не IP;
- `curl` работает без `-k`/`--insecure`;
- HTTP и внутренние порты недоступны с клиента.

`-k` не является временным исправлением. Он отключает проверку подлинности сервера и делает тест бессмысленным.

## 5. Что дальше

Internal CA — режим пилота. Переход на сертификат заказчика и, при необходимости, одновременная смена DNS-имён описаны одним пошаговым руководством в [network-and-tls.md → Переход на внешний сертификат](network-and-tls.md#переход-на-внешний-сертификат). Там же — правила окна миграции, `curl --resolve` для проверки нового IP и порядок rollback.

Коротко: режимы `migration` и `external` не выпускают и не обновляют сертификат — Caddy читает готовые файлы из `TLS_CERTS_DIR`. Скрипт перед запуском проверяет наличие обоих файлов и валидирует Caddyfile, но не проверяет SAN, срок действия и соответствие ключа сертификату — это делает оператор.

Root CA internal можно удалить с клиентов только после подтверждения внешней цепочки и окончания rollback-окна.
