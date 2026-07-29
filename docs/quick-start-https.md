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

## 5. Переход на внешний сертификат

До переключения:

1. получите сертификат и private key от публичного или корпоративного CA;
2. убедитесь, что сертификат покрывает `PUBLIC_API_HOST` и `PUBLIC_CHAT_HOST`;
3. уменьшите DNS TTL заранее;
4. поместите файлы в `TLS_CERTS_DIR` под именами `TLS_CERT_FILE` и `TLS_KEY_FILE`;
5. убедитесь, что клиентам доверена полная цепочка;
6. подготовьте rollback на internal CA.

Режимы `migration` и `external` не выпускают и не обновляют сертификат: Caddy читает готовые файлы. Скрипт перед запуском проверяет только наличие обоих файлов.

Команды:

```bash
./model.sh gateway migration
./model.sh gateway status
./model.sh gateway external
./model.sh gateway status
```

В `migration` значения `OLD_PUBLIC_API_HOST` и `OLD_PUBLIC_CHAT_HOST` обслуживаются сертификатами internal CA, а `PUBLIC_API_HOST` и `PUBLIC_CHAT_HOST` — внешним certificate/key pair. Старые и новые имена должны различаться и одновременно разрешаться в gateway. Пустые `OLD_PUBLIC_*` делают migration-конфигурацию некорректной.

После переключения повторите проверки API и UI с нескольких клиентских сетей. Root CA internal можно удалить с клиентов только после подтверждения внешней цепочки и окончания rollback-окна.

## 6. Одновременная смена DNS и сертификата

Не меняйте обе сущности без заранее проверенного окна миграции:

1. за 24–48 часов снизьте TTL старых имён;
2. запишите старые имена в `OLD_PUBLIC_API_HOST`/`OLD_PUBLIC_CHAT_HOST`, новые — в `PUBLIC_API_HOST`/`PUBLIC_CHAT_HOST`;
3. положите внешний сертификат и ключ в `TLS_CERTS_DIR`;
4. выполните `gateway migration`;
5. проверьте старые имена с internal trust и новые с external trust;
6. измените DNS новых имён или настройки клиентов;
7. контролируйте оба набора имён минимум весь прежний TTL плюс запас;
8. выполните `gateway external`, когда старые имена больше не нужны.

Пример проверки нового IP с правильными SNI и Host:

```bash
curl --resolve api.example.com:443:<new-ip> \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  https://api.example.com/v1/models
```

Rollback во время окна — снова выполнить `gateway migration` либо `gateway internal` и вернуть клиентам старые имена. Переменные режима в `.env` скрипт не переписывает: команда задаёт `CADDY_CONFIG_FILE` только для своего вызова Compose. Зафиксируйте фактически выбранный режим в `.env`, если последующие прямые команды `docker compose` должны его сохранять.
