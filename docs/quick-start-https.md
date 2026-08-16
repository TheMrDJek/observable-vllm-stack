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

Первая команда делает три вещи по порядку: выпускает сертификат локального CA в `TLS_CERTS_DIR`, прогоняет `nginx -t` в одноразовом контейнере и запускает профиль `gateway` с шаблоном `nginx/templates/gateway.internal.conf.template`.

`gateway status` выполняет только `docker compose --profile gateway ps nginx`: он показывает состояние контейнера, но не issuer, SAN, expiry или сохранённый режим.

Ключ CA переиспользуется между запусками, поэтому повторный `gateway internal` не обесценивает trust store клиентов — в выводе будет `Reusing the existing internal CA`. Leaf перевыпускается автоматически при смене имён в `.env` или за 30 дней до истечения.

## 3. Установка root CA клиентам

Корневой сертификат лежит прямо в `TLS_CERTS_DIR` — копировать из контейнера ничего не нужно:

```bash
openssl x509 -in secrets/tls/internal-ca.crt -noout -fingerprint -sha256 -subject -dates
```

Передайте `internal-ca.crt` клиентам по аутентифицированному каналу и сверьте fingerprint вне канала передачи. Файл `internal-ca.key` — закрытый ключ CA, он не покидает хост.

Ubuntu/Debian-клиент:

```bash
sudo install -m 0644 internal-ca.crt /usr/local/share/ca-certificates/vlm-internal-ca.crt
sudo update-ca-certificates
```

Windows 11, PowerShell от администратора:

```powershell
Import-Certificate `
  -FilePath .\secrets\tls\internal-ca.crt `
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

> **На Windows сначала поставьте root CA в хранилище (шаг 3).** И `curl.exe`, и curl из Git Bash используют Schannel, который берёт доверие только из системного хранилища Windows и **игнорирует `--cacert`**. Попытка проверить с флагом `--cacert`, не установив корень, завершается не понятной ошибкой сертификата, а обрывом рукопожатия: `schannel: failed to receive handshake` и `HTTP 000`.

Откройте `https://chat.vlm.local` в браузере. Проверка считается успешной, только если:

- нет предупреждения сертификата;
- URL использует DNS-имя, а не IP;
- `curl` работает без `-k`/`--insecure`;
- HTTP и внутренние порты недоступны с клиента.

`-k` не является временным исправлением. Он отключает проверку подлинности сервера и делает тест бессмысленным.

## 5. Что дальше

Internal CA — режим пилота. Переход на сертификат заказчика и, при необходимости, одновременная смена DNS-имён описаны одним пошаговым руководством в [network-and-tls.md → Переход на внешний сертификат](network-and-tls.md#переход-на-внешний-сертификат). Там же — правила окна миграции, `curl --resolve` для проверки нового IP и порядок rollback.

Коротко: режимы `migration` и `external` не выпускают и не обновляют сертификат — nginx читает готовые файлы из `TLS_CERTS_DIR`. Скрипт перед запуском проверяет наличие обоих файлов, читаемость ключа под UID 101 и прогоняет `nginx -t`, но не проверяет SAN, срок действия и соответствие ключа сертификату — это делает оператор.

Root CA internal можно удалить с клиентов только после подтверждения внешней цепочки и окончания rollback-окна.
