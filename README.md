# Локальный стек LLM/VLM

Один локальный OpenAI-compatible API поверх переключаемых vLLM-моделей:

- LiteLLM — API gateway, ключи, usage и полная история запросов;
- Open WebUI — чат-интерфейс и собственная история диалогов;
- PostgreSQL — данные LiteLLM;
- Prometheus, Loki, Tempo, Alloy и Grafana — метрики, логи и трейсы;
- NVIDIA GPU Exporter — опциональные метрики GPU.

Стек рассчитан на Windows, Docker Desktop с WSL2, 64 ГБ RAM и RTX 4070 Ti 12 ГБ. Одновременно запускается только один vLLM-профиль. Это намеренное ограничение: две полноценные модели с нормальным контекстом в 12 ГБ VRAM стабильно не помещаются.

Редактируемая схема сервисов, хранилищ, API-потока и наблюдаемости находится в [`docs/architecture.excalidraw`](docs/architecture.excalidraw). Файл открывается в Excalidraw напрямую и хранится в репозитории как исходник диаграммы.

## Требования

1. Актуальный NVIDIA Windows Driver с поддержкой WSL2.
2. Docker Desktop с включёнными `Use the WSL 2 based engine` и WSL Integration.
3. Актуальный WSL: `wsl --update`.
4. PowerShell 7 или Windows PowerShell 5.1.

Сначала проверьте доступ GPU из Docker:

```powershell
docker run --rm --gpus all nvidia/cuda:12.9.0-base-ubuntu22.04 nvidia-smi
```

Если эта команда не работает, vLLM тоже не заработает. Установка Linux-драйвера NVIDIA внутрь WSL обычно только ломает GPU passthrough; нужен Windows-драйвер.

### Минимальные ресурсы без моделей

Для базовых сервисов без запущенных профилей `main` и `alt` и без кэша Hugging Face:

- CPU: 4 логических потока с аппаратной виртуализацией;
- RAM: 8 GiB, доступных WSL2/Docker Desktop; 12 GiB оставляют нормальный запас;
- диск: 35 GiB свободного места под Docker-образы и начальные volumes;
- GPU: не требуется, пока не запущен vLLM-профиль.

Это минимум для запуска, а не гарантия под любой трафик. Prometheus ограничен 10 ГБ, но PostgreSQL, Open WebUI, Loki и Tempo также накапливают данные. Для длительной работы к базовым 35 GiB добавьте отдельный запас под историю запросов, чаты, логи и трейсы.

### Как рассчитать ресурсы для новой модели

Сначала возьмите размер всех файлов модели в репозитории Hugging Face. Не оценивайте квантованную модель только по числу параметров: scales, embeddings, vision encoder и неквантованные слои делают фактический размер больше теоретического.

Грубая нижняя граница для весов:

```text
размер весов = число параметров × битность / 8
```

Например, 7 млрд параметров в 4 битах дают 3,5 ГБ только теоретически. Для планирования используйте фактический размер файлов модели и добавляйте 10–20% запаса.

Диск:

```text
свободный диск >= 35 GiB + сумма размеров всех кэшируемых моделей + запас под данные
```

При замене или обновлении модели временно держите свободным ещё один её полный размер: старые и новые файлы могут одновременно находиться в кэше.

VRAM:

```text
бюджет vLLM = объём VRAM × gpu-memory-utilization
бюджет vLLM >= веса в GPU + KV-cache + пиковые активации + служебная память CUDA
```

Размер KV-cache на один токен для обычного Transformer приблизительно равен:

```text
KV bytes/token = 2 × layers × kv_heads × head_dim × bytes_per_element
KV-cache = KV bytes/token × сумма активных токенов всех одновременных запросов
```

Значения `layers`, `kv_heads` и `head_dim` берите из `config.json` модели: обычно это `num_hidden_layers`, `num_key_value_heads` и `head_dim`; если `head_dim` отсутствует, используйте `hidden_size / num_attention_heads`. Множитель `2` — это key и value. Для FP16/BF16 `bytes_per_element = 2`, для FP8 KV-cache — `1`. В активные токены входят prompt, генерируемый ответ и токены изображений. VLM дополнительно требует память под vision encoder и промежуточные активации, поэтому одной формулы KV-cache для неё недостаточно.

`gpu-memory-utilization` — верхний бюджет процесса, а не доля, свободная только для весов. vLLM профилирует модель при запуске и отдаёт оставшуюся память KV-cache. Уменьшение `max-model-len` не уменьшает размер весов; оно снижает требование к длине одного запроса и может повысить допустимую конкурентность.

RAM:

```text
RAM для Docker >= 8 GiB + пиковая RAM загрузки модели + cpu-offload-gb
```

Для первичной оценки заложите под загрузку не меньше фактического размера файлов модели плюс 20%. `cpu-offload-gb` потребляет указанный объём RAM на каждую GPU и снижает скорость, поэтому это аварийный компромисс, а не бесплатное расширение VRAM.

Окончательная проверка всегда практическая:

1. Укажите модель, `max-model-len` и консервативный `gpu-memory-utilization`.
2. Запустите только её профиль и проверьте логи vLLM: там выводятся доступный объём KV-cache, число помещающихся токенов и оценка максимальной конкурентности.
3. Проверьте фактическую VRAM через `nvidia-smi`.
4. Выполните запрос с максимальными ожидаемыми prompt, ответом, числом изображений и конкурентностью. Успешный пустой запуск не доказывает, что рабочая нагрузка помещается.

## Первый запуск

```powershell
Copy-Item .env.example .env
notepad .env
```

Замените все значения `CHANGE_ME`. `LITELLM_MASTER_KEY` и `LITELLM_SALT_KEY` должны начинаться с `sk-`. Salt после первого запуска менять нельзя: существующие зашифрованные данные станут нечитаемыми.

Запуск основной VLM и GPU-метрик:

```powershell
.\model.ps1 start main -GpuMetrics
```

Первый запуск долгий: Docker скачивает образы, vLLM — модель. Скрипт запускает контейнеры в фоне и не ждёт загрузки модели; прогресс смотрите через `docker compose --profile main logs -f vllm-main`.

## Управление моделями

```powershell
# Основная Qwen3.5-4B VLM
.\model.ps1 start main -GpuMetrics

# Альтернативная квантованная текстовая модель
.\model.ps1 start alt -GpuMetrics

# Остановить только модели, сохранив UI и мониторинг
.\model.ps1 stop

# Показать состояние всех сервисов
.\model.ps1 status
```

Перед запуском нового слота скрипт останавливает оба vLLM-контейнера. Это предотвращает случайный OOM. Compose profiles сами по себе предыдущий профиль не останавливают.

Модели задаются в `.env`:

```dotenv
MAIN_MODEL_ID=QuantTrio/Qwen3.5-4B-AWQ
ALT_MODEL_ID=Qwen/Qwen3-4B-AWQ
```

В LiteLLM и Open WebUI модели опубликованы под явными API-именами `qwen3.5-4b-awq` и `qwen3-4b-awq`. `main` и `alt` остались только внутренними именами профилей и контейнеров для управления слотами. После изменения модели синхронно обновите `--served-model-name` в `compose.yaml` и `model_name`/`litellm_params.model` в `config/litellm.yaml`, затем перезапустите соответствующий слот. Для VLM-параметров используется `vllm-main`; у `vllm-alt` намеренно нет multimodal-флага.

Для RTX 4070 Ti 12 ГБ main-профиль использует community-модель `QuantTrio/Qwen3.5-4B-AWQ`, контекст 8192, `gpu-memory-utilization=0.85`, без CPU offload и с `--enforce-eager`. AWQ-веса занимают около 5.63 GiB VRAM вместо 8.61 GiB у BF16 и оставляют место для vision encoder и KV-cache. Автоматический выбор инструментов Open WebUI поддерживается через parser `qwen3_coder`.

Qwen3.5 пока требует vLLM из main-ветки, поэтому единственный плавающий образ — `vllm/vllm-openai:nightly`. Это риск несовместимых изменений. Когда поддержка появится в стабильном vLLM, закрепите конкретный release tag в `.env`.

Текущий nightly принимает модель первым позиционным аргументом и multimodal-лимит в формате `--limit-mm-per-prompt.image 2`. Старые варианты `--model ...` и `--limit-mm-per-prompt image=2` использовать нельзя.

## Адреса

- Open WebUI: http://localhost:3000
- LiteLLM API: http://localhost:4000/v1
- LiteLLM Admin UI и журналы: http://localhost:4000/ui
- Grafana: http://localhost:3001
- Prometheus: http://localhost:9090
- Alloy: http://localhost:12345
- Прямой `qwen3.5-4b-awq` vLLM: http://localhost:8001/v1
- Прямой `qwen3-4b-awq` vLLM: http://localhost:8002/v1

Порты привязаны к `127.0.0.1` и не публикуются в локальную сеть.

## Проверка API

Для активного main-профиля с моделью `qwen3.5-4b-awq`:

```powershell
$headers = @{
    Authorization = "Bearer $((Get-Content .env | Where-Object { $_ -like 'LITELLM_MASTER_KEY=*' }) -replace '^LITELLM_MASTER_KEY=', '')"
    "Content-Type" = "application/json"
}

$body = @{
    model = "qwen3.5-4b-awq"
    messages = @(
        @{ role = "user"; content = "Ответь одним словом: работает?" }
    )
} | ConvertTo-Json -Depth 5

Invoke-RestMethod `
    -Uri "http://localhost:4000/v1/chat/completions" `
    -Method Post `
    -Headers $headers `
    -Body $body
```

Для alt-профиля замените имя модели на `qwen3-4b-awq`.

LiteLLM всегда публикует оба имени модели. Запрос к неактивному слоту завершится явной ошибкой соединения — автоматического скрытого fallback между разными моделями нет.

Готовые запросы находятся в `examples/api.http`: справочник параметров, system prompt, продолжение диалога с полной историей, обычный и потоковый chat completion, VLM-запрос с изображением, полный цикл tool calling и два ожидаемо ошибочных запроса. Для запуска из Cursor установите расширение REST Client (`humao.rest-client`), откройте файл и замените `sk-REPLACE_WITH_LITELLM_MASTER_KEY` значением `LITELLM_MASTER_KEY` из `.env`. Секрет в репозиторий не коммитьте.

System prompt из Open WebUI соответствует сообщению `{"role": "system"}` в массиве `messages`. Preset в `Workspace -> Models` удобен для ручной работы: администратор может закрепить system prompt, параметры, tools и knowledge для выбранной модели. Но сервисная интеграция не должна зависеть от настроек Open WebUI — backend должен сам передавать system prompt, всю нужную историю и параметры в каждом запросе. LiteLLM и vLLM не хранят состояние диалога между вызовами API.

Основные параметры Open WebUI напрямую соответствуют OpenAI API: `temperature`, `top_p`, `max_tokens`, `stop`, `seed`, `frequency_penalty`, `presence_penalty`, `stream`, `tools` и `tool_choice`. Если администратор задал параметр для модели в `Workspace`, пользовательская настройка этого параметра может быть проигнорирована. Практический смысл и безопасные стартовые значения описаны комментариями в `examples/api.http`.

## История и наблюдаемость

`store_prompts_in_spend_logs: true` сохраняет полные prompts и responses в PostgreSQL LiteLLM. Open WebUI отдельно сохраняет пользовательские чаты в своём volume. Это удобно для личного стенда, но база содержит весь отправленный текст. Не передавайте в модели пароли, токены и другие секреты.

История API-запросов доступна по адресу http://localhost:4000/ui в разделе `Logs`. По умолчанию имя пользователя — `admin`, пароль — значение `LITELLM_MASTER_KEY` из `.env`. В карточке запроса доступны модель, статус, latency, токены, prompt и response.

Политика хранения:

- LiteLLM раз в сутки удаляет spend logs, prompts и responses старше 30 дней;
- Prometheus хранит не больше 30 дней и не больше 10 ГБ;
- Loki хранит Docker-логи 30 дней;
- Tempo хранит трейсы 30 дней;
- локальные JSON-логи Docker ограничены тремя файлами по 10 МБ на контейнер;
- чаты Open WebUI автоматически не удаляются — штатной 30-дневной retention-настройки у него нет;
- кэш моделей `data/huggingface` автоматически не очищается.

Если `.env` был создан из старой версии примера, обновите в нём:

```dotenv
PROMETHEUS_RETENTION_TIME=30d
PROMETHEUS_RETENTION_SIZE=10GB
DOCKER_LOG_MAX_SIZE=10m
DOCKER_LOG_MAX_FILES=3
```

Grafana автоматически получает:

- Prometheus — vLLM, LiteLLM, Alloy, контейнерные и GPU-метрики;
- Loki — stdout/stderr всех контейнеров;
- Tempo — OpenTelemetry traces Open WebUI и LiteLLM.

В папке `Local LLM` автоматически создаются два дашборда:

- `Local LLM stack` — доступность сервисов, очередь vLLM, KV-cache, throughput, GPU, VRAM, CPU контейнеров и общие логи;
- `LLM API performance` — трафик и ошибки LiteLLM, TTFT, inter-token latency, фазы queue/prefill/decode, причины завершения, токены в секунду, очередь и отфильтрованные ошибки.

У `LLM API performance` есть фильтр по модели. Графики на основе histogram и rate появятся только после нескольких запросов и накопления хотя бы пары интервалов scrape; пустой новый дашборд сразу после запуска не означает поломку.

У неактивного vLLM-профиля и выключенного GPU exporter target в Prometheus будет `DOWN`. Это ожидаемо.

GPU exporter под Docker Desktop/WSL2 менее надёжен, чем сам CUDA passthrough. Если профиль `gpu-metrics` падает, сначала проверьте `nvidia-smi` в тестовом CUDA-контейнере. Метрики latency, throughput, очереди и KV-cache vLLM работают независимо от GPU exporter.

## Остановка

Остановить контейнеры без удаления данных:

```powershell
docker compose --profile main --profile alt --profile gpu-metrics down
```

Команда с `down -v` необратимо удалит историю чатов Open WebUI, данные LiteLLM/PostgreSQL, настройки Grafana, метрики Prometheus, логи Loki и трейсы Tempo. Не используйте `-v`, если данные нужны.

## Полный сброс и чистый запуск

Сначала удалите все контейнеры и именованные volumes этого Compose-проекта. Файл `.env` и bind-mounted кэш моделей `data/huggingface` сохранятся:

```powershell
docker compose --profile main --profile alt --profile gpu-metrics down -v --remove-orphans
```

Если нужно удалить ещё и скачанные модели, отдельно удалите bind-mounted каталог. Следующий запуск заново скачает веса:

```powershell
if (Test-Path .\data) {
    Remove-Item -Recurse -Force .\data
}
```

Запустите чистый стек с основной моделью:

```powershell
.\model.ps1 start main -GpuMetrics
docker compose --profile main logs -f vllm-main
```

Дождитесь в логах сообщения о запуске API-сервера, затем выйдите из просмотра через `Ctrl+C`. Это не остановит контейнер.

Проверка состояния:

```powershell
docker compose --profile main --profile gpu-metrics ps
```

После удаления volumes Open WebUI снова потребует создать первого администратора. Секреты из `.env` останутся прежними.
