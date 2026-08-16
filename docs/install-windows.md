# Установка на Windows 11

Windows 11 — локальный сценарий разработки и проверки, не production-like пилот. Используются Docker Desktop, WSL2 и Windows NVIDIA Driver.

## Требования

- Windows 11 с включённой аппаратной виртуализацией;
- актуальные WSL2 и Docker Desktop;
- Windows NVIDIA Driver с поддержкой CUDA в WSL2;
- PowerShell 7 или Windows PowerShell 5.1;
- минимум 8 GiB RAM для базовых сервисов плюс память модели; практически нужен больший запас;
- **минимум 60 GiB свободно.** Измеренные размеры: образы ~28.5 GiB, из них один только vLLM — 19.7 GiB; кэш дефолтной модели ~4 GiB; остальное на volumes телеметрии и вторую revision модели при обновлении. Разбивка по слоям — в [architecture.md](architecture.md#потребление-ресурсов).

Обновите WSL:

```powershell
wsl --update
wsl --shutdown
```

В Docker Desktop включите `Use the WSL 2 based engine` и WSL Integration. Linux-драйвер NVIDIA внутрь WSL не устанавливайте: GPU passthrough обеспечивает Windows-драйвер.

Проверьте GPU:

```powershell
docker run --rm --gpus all nvidia/cuda:12.9.0-base-ubuntu22.04 nvidia-smi
```

Если проверка падает, не переходите к vLLM.

## Подготовка

```powershell
Set-Location C:\path\to\ai-vllm-stack
Copy-Item .env.example .env
notepad .env
```

Замените каждый `CHANGE_ME`. Используйте разные случайные секреты. `LITELLM_MASTER_KEY` и `LITELLM_SALT_KEY` должны начинаться с `sk-`; salt нельзя менять после появления зашифрованных данных. При первом запуске оставьте `OPEN_WEBUI_LITELLM_KEY=` пустым.

Не храните репозиторий в общедоступной папке и не синхронизируйте `.env` через облачный диск. Проверьте, что `.env` исключён из Git.

## Локальный запуск

```powershell
.\model.ps1 preflight
.\model.ps1 observability local
.\model.ps1 start main -GpuMetrics
.\model.ps1 gateway internal
.\model.ps1 status
docker compose --profile main logs -f vllm-main
```

`preflight` проверяет Docker, GPU из контейнера, диск, занятость публичного порта и разрешение hostnames. `observability local` поднимает не только телеметрию, но и PostgreSQL, LiteLLM, Open WebUI и Alloy — это первый шаг развёртывания, а не опция.

**Первый запуск модели занимает 10–30 минут**: качается ~4 GiB весов, затем модель грузится в VRAM. Состояние `health: starting` в это время нормально. `Ctrl+C` прекращает просмотр логов, но не контейнер.

Переключение на `alt` останавливает оба модельных контейнера перед запуском выбранного слота:

```powershell
.\model.ps1 start alt -GpuMetrics
.\model.ps1 stop
```

Для одновременного старта ровно двух слотов установите `ALLOW_CONCURRENT_MODELS=true` и передавайте имена отдельными аргументами:

```powershell
.\model.ps1 start-many main alt -GpuMetrics
```

Скрипт не проверяет VRAM. На одной RTX 4070 Ti 12 GiB этот режим с текущими профилями, вероятнее всего, закончится OOM.

## Ключ Open WebUI

После запуска LiteLLM создайте отдельный virtual key через loopback. Публичный HTTPS route намеренно не пропускает `/key/generate`:

```powershell
$masterKey = Read-Host "LiteLLM master key"
$body = @{
    key_alias = "open-webui"
    models = @("qwen3.5-4b-awq", "qwen3-4b-awq")
} | ConvertTo-Json

$virtualKey = Invoke-RestMethod `
    -Uri "http://127.0.0.1:4000/key/generate" `
    -Method Post `
    -Headers @{ Authorization = "Bearer $masterKey" } `
    -ContentType "application/json" `
    -Body $body

$virtualKey.key
Remove-Variable masterKey
```

Запишите выведенный ключ в `OPEN_WEBUI_LITELLM_KEY` файла `.env`, затем:

```powershell
docker compose up -d --force-recreate open-webui
```

Не используйте `LITELLM_MASTER_KEY` как ключ Open WebUI.

## HTTPS на локальной машине

```powershell
.\model.ps1 gateway internal
.\model.ps1 gateway status
```

Назначьте значения `PUBLIC_API_HOST` и `PUBLIC_CHAT_HOST` адресу локального хоста через внутренний DNS или hosts-файл. Для значений по умолчанию:

```text
127.0.0.1 api.vlm.local
127.0.0.1 chat.vlm.local
```

Корневой сертификат локального центра выпускается командой `gateway internal` и лежит файлом — копировать из контейнера нечего:

```powershell
Import-Certificate -FilePath .\secrets\tls\internal-ca.crt `
  -CertStoreLocation Cert:\LocalMachine\Root
```

Команда требует прав администратора. **Без этого шага проверки через `curl.exe` работать не будут**: и встроенный curl, и curl из Git Bash используют Schannel, который доверяет только хранилищу Windows и игнорирует `--cacert`.

Устанавливайте root CA в хранилище `Trusted Root Certification Authorities` только на доверенных тестовых машинах. Не используйте `-k`/`--insecure`: это скрывает ошибки DNS, цепочки доверия и подмену сервера. Подробности — в [быстром старте HTTPS](quick-start-https.md).

## Ограничения Windows

- Docker Desktop и WSL2 добавляют слой виртуализации и отличаются от Linux production по сети, I/O и lifecycle;
- GPU exporter под WSL2 может не работать, хотя CUDA и vLLM работают;
- bind mounts через Windows filesystem медленнее; кэш моделей лучше держать на быстром локальном SSD;
- `localhost`-порты предназначены только для диагностики. Не меняйте привязку на `0.0.0.0`, чтобы «быстро открыть доступ»;
- Windows Firewall должен запрещать внутренние порты и разрешать 443 только для нужного профиля сети;
- Alloy в `privileged` режиме с Docker socket имеет чрезмерные права и на Windows остаётся доверенным административным компонентом.

## Остановка и данные

```powershell
.\model.ps1 stop
.\model.ps1 status
```

Не используйте `docker compose down -v`, если нужны чаты, журнал LiteLLM, настройки Grafana, метрики, логи или трейсы. Кэш `data\huggingface` является bind-mounted каталогом и удаляется отдельно.

## Локальный air-gap

Общий перечень артефактов — в [install-ubuntu-ssh.md → Air-gap](install-ubuntu-ssh.md#air-gap). Специфика Windows: для HTTPS используйте internal CA и заранее установите его root в `Trusted Root Certification Authorities`, либо предоставьте external-режиму готовые certificate/key files.
