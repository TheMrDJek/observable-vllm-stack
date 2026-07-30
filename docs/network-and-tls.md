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

### Выбор имён для прода

`api.vlm.local` и `chat.vlm.local` — значения для лаборатории. Для постоянной эксплуатации замените их на поддомены домена, которым вы владеете, например `api.llm.example.com`.

Суффикс `.local` **зарезервирован под mDNS** (RFC 6762). На системах с Avahi/Bonjour резолвер может перехватывать такие имена и не отдавать их обычному DNS, из-за чего часть клиентов будет ходить не туда или не резолвить вовсе. Публичный CA сертификат на `.local` не выпустит в принципе.

Как клиенты узнают адрес — три варианта:

| Способ | Что требуется | Когда применим |
|---|---|---|
| **Запись во внутреннем DNS** | одна A-запись на имя, у администратора зоны, один раз | рекомендуемый для прода |
| **hosts на каждом клиенте** | правка файла на каждой машине с правами администратора | 1–3 сервера, временный пилот |
| Wildcard-запись | если имена уже покрыты `*.llm.example.com` | ничего делать не нужно |

Записи нужны **на клиентах**, а не на VLM-хосте: имя резолвит тот, кто устанавливает соединение. Сам стек своё имя не разрешает и в DNS ничего не регистрирует.

Отдельно от резолвинга стоит доверие сертификату:

- `gateway internal` — root CA нужно установить в trust store **каждого** клиента. Это вторая операция на каждой машине вдобавок к DNS;
- `gateway external` с сертификатом корпоративного или публичного CA — клиентам не нужно ничего устанавливать, если этот CA уже в их trust store. Для доменных машин это обычно так.

Поэтому связка «имена в корпоративном DNS + сертификат корпоративного CA» — единственный вариант, при котором подключение нового сервера-клиента не требует никаких действий на нём самом.

### Fallback: одно имя с path routing

Если на площадке нельзя создать две DNS-записи, используйте [caddy/Caddyfile.single](../caddy/Caddyfile.single): одно имя `PUBLIC_API_HOST`, где `/v1/*` идёт в LiteLLM, а остальные пути — в Open WebUI.

```bash
CADDY_CONFIG_FILE=./caddy/Caddyfile.single docker compose --profile gateway up -d caddy
```

Это осознанный компромисс, а не рекомендуемый вариант. Что теряется: общие cookies и origin у API и UI, невозможность применить разные firewall/access policies к машинным клиентам и браузерам, привязка WebUI к особенностям API paths. `PUBLIC_CHAT_HOST` в этом режиме не используется. Команда `./model.sh gateway` этот режим не переключает — он задаётся только через `CADDY_CONFIG_FILE`.

## Режимы gateway

```text
model.ps1 gateway internal|migration|external|status
model.sh  gateway internal|migration|external|status
```

- `internal` — Caddy выпускает сертификаты от своей internal CA;
- `migration` — старые `OLD_PUBLIC_*` имена используют internal CA, новые `PUBLIC_*` — готовые внешние certificate/key files;
- `external` — оба `PUBLIC_*` имени используют `${TLS_CERTS_DIR}/${TLS_CERT_FILE}` и `${TLS_CERTS_DIR}/${TLS_KEY_FILE}`;
- `status` — показывает только строку контейнера Caddy из `docker compose ps`.

Перед запуском скрипт выполняет `caddy validate` для выбранного Caddyfile, а для `migration`/`external` дополнительно проверяет наличие и читаемость cert/key. Он **не** проверяет SAN, expiry, соответствие ключа сертификату и цепочку — это делает оператор командами из раздела [Переход на внешний сертификат](#переход-на-внешний-сертификат).

Файлы кладите по образцу [`secrets.example/caddy`](../secrets.example/caddy/README.md) в gitignored `secrets/caddy/`.

Caddy не читает `GATEWAY_MODE` — он читает смонтированный файл из `CADDY_CONFIG_FILE`. Скрипт записывает обе переменные в `.env` после успешного переключения, поэтому последующий прямой `docker compose up -d` не откатит режим. Значение `GATEWAY_MODE` носит справочный характер.

## Internal CA

Плюсы: быстрый запуск, не нужен публичный DNS или интернет. Минусы: root CA нужно безопасно доставить каждому клиенту; компрометация CA критична.

- храните private key CA только на gateway-host;
- резервируйте его как секрет с шифрованием и контролем доступа;
- передавайте клиентам только root certificate;
- сверяйте fingerprint по независимому каналу;
- ведите перечень устройств, куда установлен root;
- планируйте отзыв доверия и удаление root после пилота.

Клиенты обязаны проходить обычную TLS-проверку. Запретите `-k`, отключение hostname verification и самописные trust callbacks.

## Переход на внешний сертификат

Это единственное место, где описана процедура целиком. Остальные документы ссылаются сюда.

### Подготовка (общая для обоих сценариев)

Перед включением проверьте:

- сертификат покрывает оба имени (единый SAN или подходящий wildcard);
- сервер отдаёт полную цепочку без root;
- ключ соответствует сертификату;
- часы хоста синхронизированы;
- renewal организован отдельно от этого репозитория;
- ключ имеет права только у gateway;
- есть alert на expiry и ошибку renew.

Проверить файлы до переключения:

```bash
openssl x509 -in secrets/caddy/server.crt -noout -subject -issuer -dates -ext subjectAltName
# отпечатки должны совпадать: ключ соответствует сертификату
openssl x509 -in secrets/caddy/server.crt -noout -pubkey | openssl sha256
openssl pkey -in secrets/caddy/server.key -pubout | openssl sha256
```

Текущие Caddyfiles отключают HTTP redirect и не выполняют ACME. Порт 80 стек не публикует. Получение и renewal внешнего сертификата — внешний процесс.

### Сценарий A: имена не меняются, меняется только сертификат

Самый простой случай. Client base URL не меняется, данные и активная модель сохраняются, перезапускается только Caddy.

```bash
# файлы уже в secrets/caddy/ под именами из TLS_CERT_FILE и TLS_KEY_FILE
./model.sh gateway external
./model.sh gateway status
```

Проверить с клиента и подготовить rollback:

```bash
curl -fsS https://api.vlm.local/v1/models -H "Authorization: Bearer $CLIENT_VIRTUAL_KEY"
# откат при ошибке
./model.sh gateway internal
```

### Сценарий B: одновременно меняются DNS-имена и сертификат

Главный риск — часть клиентов идёт на старые имена, часть на новые, а один из наборов уже не обслуживается. Поэтому нужен параллельный режим `migration`, где Caddy на одном 443 обслуживает обе пары имён и различает их по SNI.

1. За 24–48 часов снизьте TTL старых имён.
2. Запишите старые имена в `OLD_PUBLIC_API_HOST`/`OLD_PUBLIC_CHAT_HOST`, новые — в `PUBLIC_API_HOST`/`PUBLIC_CHAT_HOST`. Пустые `OLD_PUBLIC_*` делают migration-конфигурацию некорректной, и скрипт откажется её запускать.
3. Положите внешний certificate/key pair в `TLS_CERTS_DIR`; сертификат должен покрывать **новые** имена.
4. Выполните `./model.sh gateway migration`.
5. Проверьте оба набора: старые имена — с internal trust, новые — с внешней цепочкой. Новый IP проверяется принудительно, без правки клиентского DNS:

   ```bash
   curl --resolve api.example.com:443:<new-ip> \
     -H "Authorization: Bearer $CLIENT_VIRTUAL_KEY" \
     https://api.example.com/v1/models
   ```

6. Обновите API base URLs у клиентов, настройки Open WebUI/OAuth/CORS и предупредите пользователей: browser cookies и сессии между hostnames не переносятся, потребуется повторный вход.
7. Наблюдайте оба набора имён не меньше старого TTL плюс запас.
8. Выполните `./model.sh gateway external`, когда трафик на старые имена прекратился.
9. Удалите старые DNS/hosts-записи и только после этого — internal root CA из trust stores клиентов.

**Rollback внутри окна:** снова `gateway migration` либо `gateway internal` и возврат клиентов на старые имена. Не рассчитывайте на мгновенный DNS rollback — клиентские и резолверные кэши держат старые ответы. Поэтому старые DNS-записи и migration-конфигурация сохраняются до конца окна.

Одновременная смена без параллельного окна делает rollback ненадёжным.

### После замены файлов в уже активном режиме

Caddy читает cert/key при загрузке конфигурации. Подмена файлов на диске сама по себе перечитывания не вызывает:

```bash
docker compose --profile gateway restart caddy
```

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
