# AI vLLM Stack

OpenAI-compatible стек для локальных vLLM-моделей:

- LiteLLM — API gateway, ключи и usage;
- Open WebUI — чат-интерфейс;
- PostgreSQL — данные LiteLLM;
- Caddy — единственный внешний HTTPS-вход на TCP/443;
- Alloy + локальный или удалённый LGTM — метрики, логи и трейсы;
- NVIDIA GPU Exporter — опциональные GPU-метрики.

Основной стенд — Ubuntu по SSH. Windows 11 + Docker Desktop/WSL2 — локальный пилот. Клиентам публикуются только `PUBLIC_API_HOST` и `PUBLIC_CHAT_HOST` на порту `443`.

## Документация

| Документ | Назначение |
|----------|------------|
| [docs/install-ubuntu-ssh.md](docs/install-ubuntu-ssh.md) | Установка Ubuntu по SSH |
| [docs/install-windows.md](docs/install-windows.md) | Локальная установка Windows 11 |
| [docs/quick-start-https.md](docs/quick-start-https.md) | Быстрый старт с internal CA |
| [docs/network-and-tls.md](docs/network-and-tls.md) | DNS, TLS, migration, external cert |
| [docs/remote-observability.md](docs/remote-observability.md) | Local/remote observability |
| [docs/model-operations.md](docs/model-operations.md) | Замена и переключение моделей |
| [docs/security-checklist.md](docs/security-checklist.md) | ИБ-чеклист перед данными заказчика |
| [docs/verification.md](docs/verification.md) | Команды приёмки, которые выполняет оператор |
| [docs/architecture.excalidraw](docs/architecture.excalidraw) | Схемы local и remote |

## Быстрый старт

```powershell
Copy-Item .env.example .env
# замените CHANGE_ME; OPEN_WEBUI_LITELLM_KEY оставьте пустым
.\model.ps1 observability local
.\model.ps1 start main -GpuMetrics
.\model.ps1 gateway internal
.\model.ps1 status
```

```bash
cp .env.example .env
chmod 600 .env
# замените CHANGE_ME; OPEN_WEBUI_LITELLM_KEY оставьте пустым
./model.sh observability local
./model.sh start main --gpu-metrics
./model.sh gateway internal
./model.sh status
```

После старта LiteLLM создайте ограниченный virtual key для Open WebUI, запишите в `OPEN_WEBUI_LITELLM_KEY` и пересоздайте только `open-webui`. Master key в WebUI не передавайте. Подробности — в инструкциях установки и [ИБ-чеклисте](docs/security-checklist.md).

Сертификаты заказчика кладите по образцу [secrets.example/caddy](secrets.example/caddy/README.md). Каталог `secrets/` в Git не хранится.

## Управление

PowerShell:

```powershell
.\model.ps1 start main -GpuMetrics
.\model.ps1 start-many main alt -GpuMetrics
.\model.ps1 stop
.\model.ps1 status
.\model.ps1 gateway internal|migration|external|status
.\model.ps1 observability local|remote
```

Linux:

```bash
./model.sh start main --gpu-metrics
./model.sh start-many main alt --gpu-metrics
./model.sh stop
./model.sh status
./model.sh gateway internal|migration|external|status
./model.sh observability local|remote
```

- `start` останавливает оба vLLM-слота перед запуском выбранного.
- `start-many` требует `ALLOW_CONCURRENT_MODELS=true` и не проверяет VRAM.
- `migration`/`external` требуют файлы из `TLS_CERTS_DIR`.
- `observability remote` требует заполненные `REMOTE_*` URL и токены; локальные LGTM останавливаются, volumes сохраняются.

## Важные ограничения

- Одновременно одна модель — безопасный default для 12 GB VRAM.
- Плавающий nightly заменён pinned digest в `.env.example`; обновляйте digest и model revision осознанно.
- Развёртывание, firewall, DNS, trust stores и приёмку выполняет оператор по [docs/verification.md](docs/verification.md).
- `LITELLM_SALT_KEY` после первого запуска не меняйте.
- Не используйте `docker compose down -v`, если нужны данные.
