# Операции с моделями

## Интерфейс

Linux:

```bash
./model.sh start main --gpu-metrics
./model.sh start alt --gpu-metrics
./model.sh start-many main alt --gpu-metrics
./model.sh stop
./model.sh status
```

PowerShell:

```powershell
.\model.ps1 start main -GpuMetrics
.\model.ps1 start alt -GpuMetrics
.\model.ps1 start-many main alt -GpuMetrics
.\model.ps1 stop
.\model.ps1 status
```

`start` принимает ровно один слот, сначала останавливает все остальные слоты, затем поднимает выбранный Compose profile вместе с базовыми сервисами. `stop` останавливает все модели, но сохраняет остальные сервисы и volumes. `status` показывает все слоты плюс профили `gpu-metrics`, `gateway`, `local-observability` и `telemetry`.

## Сколько слотов есть

Из коробки настроены два слота — `main` и `alt`. Это не предел: скрипты определяют слоты по профилям Compose, поэтому добавление третьего и последующих требует правки только `compose.yaml` и `config/litellm.yaml`.

Начать с одной модели — штатный сценарий: `start main` не трогает остальные слоты.

| Задача | Раздел |
|---|---|
| Поменять модель в существующем слоте | [Рецепт 1](#рецепт-1-заменить-модель-в-слоте) |
| Поднять вторую модель рядом с первой | [Рецепт 2](#рецепт-2-задействовать-второй-слот) |
| Нужен третий и далее слот | [Рецепт 3](#рецепт-3-добавить-третий-и-последующие-слоты) |
| Модель не из семейства Qwen | [Флаги под модель](#флаги-под-конкретную-модель) |
| Сколько моделей поднимать одновременно | [Одна, две, три и больше](#сколько-моделей-поднимать-одна-две-три-и-больше) |

## Рецепт 1: заменить модель в слоте

Пример: в слоте `alt` вместо `Qwen/Qwen3-4B-AWQ` нужна другая модель.

**1. Узнать точную revision.** Плавающий тег не воспроизводим:

```bash
git ls-remote https://huggingface.co/<org>/<model> HEAD
```

**2. Правки в `.env`** — все три значения меняются согласованно:

```dotenv
ALT_MODEL_ID=<org>/<model>
ALT_MODEL_REVISION=<commit-sha>
ALT_SERVED_MODEL_NAME=<новое-api-имя>
ALT_MAX_MODEL_LEN=8192
ALT_EXTRA_ARGS=<флаги модели; пусто = без дополнительных флагов>
```

**3. Правка [config/litellm.yaml](../config/litellm.yaml).** Это обязательный шаг, о котором забывают чаще всего. `model_name` и суффикс в `model:` должны совпадать с `ALT_SERVED_MODEL_NAME`:

```yaml
  - model_name: <новое-api-имя>
    litellm_params:
      model: openai/<новое-api-имя>
      api_base: http://vllm-alt:8000/v1
      api_key: os.environ/VLLM_API_KEY
      timeout: 600
```

**4. Применить:**

```bash
docker compose up -d --force-recreate litellm
./model.sh start alt --gpu-metrics
docker compose --profile alt logs -f vllm-alt      # ждать healthy, 10-30 мин на первом запуске
```

**5. Проверить:**

```bash
curl -fsS http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

Новое имя должно появиться в списке. Если не появилось — расходятся `--served-model-name` и `model_name` в LiteLLM.

**6. Раздать клиентам** новое имя модели либо оставить прежнее `served-model-name`, если хотите переключить модель прозрачно для клиентов.

## Рецепт 2: задействовать второй слот

Оба слота настроены изначально, поэтому «добавление» второй модели — это просто её запуск.

**Последовательно (одна GPU, безопасно):**

```bash
./model.sh start alt --gpu-metrics    # main будет остановлен автоматически
```

**Одновременно (только при доказанном запасе VRAM):**

```dotenv
ALLOW_CONCURRENT_MODELS=true
```

```bash
./model.sh start-many main alt --gpu-metrics
```

Роуты LiteLLM для обеих моделей уже прописаны — править ничего не нужно.

## Рецепт 3: добавить третий и последующие слоты

Скрипты определяют слоты по профилям Compose, поэтому **править их не нужно**. Требуется два файла.

**1. [compose.yaml](../compose.yaml)** — новый сервис по образцу существующих. Имя сервиса обязано быть `vllm-<профиль>`: по этому соглашению скрипты находят слот.

```yaml
  vllm-ocr:
    <<: *vllm-common
    profiles: [ocr]
    command: >-
      ${OCR_MODEL_ID}
      --revision ${OCR_MODEL_REVISION}
      --served-model-name ${OCR_SERVED_MODEL_NAME:-ocr-model}
      --max-model-len ${OCR_MAX_MODEL_LEN:-4096}
      --gpu-memory-utilization ${OCR_GPU_MEMORY_UTILIZATION:-0.25}
      ${OCR_EXTRA_ARGS-}
    ports:
      - "127.0.0.1:${OCR_VLLM_PORT:-8003}:8000"
```

**2. [config/litellm.yaml](../config/litellm.yaml)** — маршрут на `http://vllm-ocr:8000/v1`.

Дальше всё работает само:

```bash
docker compose up -d --force-recreate litellm
./model.sh start ocr          # слот виден скриптам сразу
./model.sh status             # новый слот в выводе
```

Проверить, какие слоты видит скрипт:

```bash
docker compose config --profiles      # минус gateway, telemetry, local-observability, gpu-metrics
```

Опционально: блок `prometheus.scrape` в [config.alloy](../observability/config.alloy) и [config.remote.alloy](../observability/config.remote.alloy) с `model_slot = "ocr"`, если нужны метрики этого слота.

## Флаги под конкретную модель

Флаги, зависящие от семейства модели, вынесены в одну переменную на слот.

```dotenv
# Qwen с reasoning и tool calling
MAIN_EXTRA_ARGS=--enforce-eager --reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder --limit-mm-per-prompt.image 2

# OCR-модель без reasoning и без tool calling — пустое значение
OCR_EXTRA_ARGS=
```

Почему это важно. Раньше `--reasoning-parser` был жёстко зашит в команду, а запись `${VAR:-default}` подставляет значение по умолчанию **и при пустой переменной тоже** — отключить флаг через `.env` было невозможно в принципе. Сейчас используется `${VAR-default}` без двоеточия: пустое значение означает «никаких дополнительных флагов», а закомментированная строка возвращает дефолт.

Проверить, что реально уйдёт в контейнер, не запуская его:

```bash
docker compose --profile alt config --format json   | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin)['services']['vllm-alt']['command']))"
```

## Сколько моделей поднимать: одна, две, три и больше

Ограничение всегда одно — **VRAM**, а не число слотов. Слотов можно завести сколько угодно; одновременно работают те, что помещаются в карту.

### Как считать

```text
на одну модель ≈ веса + KV-cache + активации + ~1 GiB overhead CUDA
сумма по всем одновременным моделям < VRAM с запасом 10-15 %
```

`gpu-memory-utilization` — это доля **всей карты**, которую резервирует процесс. Значения всех одновременно работающих слотов в сумме не должны превышать ~0.9. Дефолт 0.85 рассчитан на **одну** модель: два слота с 0.85 гарантированно столкнутся.

### Типовые конфигурации

| Моделей одновременно | VRAM | Пример распределения | Комментарий |
|---|---|---|---|
| 1 | 12 GB | `MAIN=0.85` | дефолт, самый предсказуемый |
| 2 (чат + маленькая OCR) | 12 GB | `MAIN=0.55`, `OCR=0.30` | реально при OCR-модели ~1 GiB весов |
| 2 равных 4B | 12 GB | `MAIN=0.45`, `ALT=0.45` | KV-cache у обеих будет тесным |
| 3 | 12 GB | — | практически не помещаются, переключайте |
| 3 | 24-48 GB | `0.30 / 0.30 / 0.28` | реально, проверяйте под нагрузкой |
| 3 на 3 GPU | любая | по `0.85` на своей карте | лучший вариант, см. ниже |

Числа — отправная точка, а не готовая настройка. Обязательно проверьте под ожидаемой конкурентностью: успешная загрузка моделей не означает, что они выдержат нагрузку.

### Управление: что включено, что выключено

```bash
./model.sh start main                  # ровно один слот, остальные останавливаются
./model.sh start-many main ocr         # несколько слотов, требует ALLOW_CONCURRENT_MODELS=true
./model.sh stop                        # остановить все слоты, стек оставить
./model.sh status                      # что сейчас поднято
```

`start` — безопасный режим по умолчанию: он всегда сначала останавливает все слоты. `start-many` принимает **любое число** слотов и ничего не останавливает.

Комбинация «две модели постоянно, третья по требованию»:

```bash
./model.sh start-many main ocr         # рабочий набор
./model.sh start-many main ocr heavy   # добавить третью под задачу
docker compose --profile heavy stop vllm-heavy   # убрать только её
```

Остановленный слот остаётся зарегистрированным в LiteLLM: запрос к нему вернёт явную ошибку соединения, а не молчаливый переход на другую модель. Клиенты видят полный список в `/v1/models` независимо от того, что запущено, — планируйте это в клиентском коде.

### Несколько GPU

Предпочтительный вариант для трёх и более моделей: каждой своя карта. Compose по умолчанию резервирует `count: 1` без указания устройства, поэтому нужен override с явными device IDs:

```yaml
services:
  vllm-ocr:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ["1"]
              capabilities: [gpu]
```

Не путайте это с tensor parallel: там одна модель занимает несколько карт и нужен `--tensor-parallel-size`, равный их числу. Подробнее — в разделе ниже.

## Что меняется вместе с моделью

Модель — это согласованный набор, а не только Hugging Face ID:

- repository ID и точная revision;
- публичное `served-model-name`;
- запись LiteLLM `model_name`/upstream;
- tokenizer и trust-remote-code policy;
- vLLM arguments: context, quantization, dtype, parsers, multimodal limits;
- профиль ресурсов и GPU placement;
- smoke/load tests.

Текущая конфигурация связывает `main` с `qwen3.5-4b-awq`, а `alt` — с `qwen3-4b-awq`:

```dotenv
MAIN_MODEL_ID=QuantTrio/Qwen3.5-4B-AWQ
MAIN_MODEL_REVISION=32c292e3a73afe1138518180b1b6d2868c980ee2
MAIN_SERVED_MODEL_NAME=qwen3.5-4b-awq
ALT_MODEL_ID=Qwen/Qwen3-4B-AWQ
ALT_MODEL_REVISION=74d4bd2bd4bff9cafc9345221320bffb08b406a3
ALT_SERVED_MODEL_NAME=qwen3-4b-awq
```

Безопасный порядок замены на боевом стенде:

1. зафиксировать текущие image digest, model revision и параметры;
2. проверить лицензию и provenance новой модели;
3. скачать новую revision, не удаляя старую;
4. оценить disk/RAM/VRAM и KV-cache;
5. запустить в свободном слоте;
6. выполнить smoke и нагрузочный тест;
7. переключить клиентов/alias;
8. сохранить rollback-окно;
9. очистить старый кэш только после приёмки.

## Revision и воспроизводимость

Репозиторий фиксирует модели через `--revision`, а vLLM image — по digest. Для каждого развёртывания записывайте: точный источник, revision, checksums файлов, версию vLLM, параметры запуска, дату и результат теста.

Текущий digest — validated snapshot nightly-сборки; имя тега в pull не участвует. Обновляйте image digest и model revision **по одному фактору за раз**: одновременное изменение обоих затрудняет диагностику.

Практическое следствие: если на хосте уже лежит `vllm/vllm-openai:nightly`, он **не будет переиспользован** — тег `nightly` со временем указывает на другой digest, и Docker скачает закреплённый образ заново (19.7 GiB). Это не ошибка, а цена воспроизводимости. Сравнить, что у вас есть, с тем, что требует compose:

```bash
docker image inspect vllm/vllm-openai:nightly --format '{{index .RepoDigests 0}}'
grep '^VLLM_IMAGE=' .env
```

Планируйте место и время на первую загрузку соответственно.

## Клиенты и несколько моделей

Сервер не хранит состояние диалога. Каждый запрос самодостаточен, модель выбирается полем `model`.

```bash
# какие имена доступны прямо сейчас
curl -fsS https://vlm.rpa.local/v1/models -H "Authorization: Bearer $CLIENT_VIRTUAL_KEY"
```

```json
{ "model": "qwen3.5-4b-awq", "messages": [ ... ] }
```

Что важно знать клиенту:

- **под master-ключом видны все зарегистрированные модели**, включая те, чей слот сейчас остановлен. Это админский взгляд на конфигурацию, а не то, что видит клиент;
- **клиент видит только модели из allowlist своего ключа.** Это и есть штатный способ не показывать потребителям слоты, которые вы держите про запас: список фильтруется, а запрос к запрещённой модели отклоняется с `403` сразу, без ожидания таймаута от неподнятого слота;
- запрос к модели, которая разрешена ключом, но чей слот не запущен, даёт явную ошибку соединения. Молчаливого fallback на другую модель нет и быть не должно: клиент должен узнать, что обращается не туда, а не получить ответ чужой модели;
- разным клиентам можно выдать разные virtual keys с разным набором моделей, лимитами RPM/TPM и бюджетом;
- при переключении слота история диалога на сервере не сохраняется — клиент присылает её целиком в `messages`.

Один процесс vLLM может иметь несколько API-alias, но это по-прежнему **одна загруженная модель**. Несколько alias не дают несколько разных моделей.

Примеры запросов, tool calling и ожидаемых ошибок — в [examples/api.http](../examples/api.http).

## Последовательный запуск

Для одной GPU или ограниченной VRAM используйте один слот:

```bash
./model.sh start main --gpu-metrics
./model.sh status
./model.sh start alt --gpu-metrics
```

Запуск `alt` останавливает `main`. Это правильно для 12 GiB GPU, где две полноценные модели с рабочим KV-cache обычно не помещаются.

Состояние контейнера `running` не означает готовность модели. Готовность подтверждает `healthy` и ответ на реальный запрос:

```bash
docker compose --profile main ps vllm-main
curl -fsS http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

## Одновременный запуск моделей

```bash
./model.sh start-many main alt --gpu-metrics
```

Команда принимает ровно два отдельных аргумента (`main alt`) и требует `ALLOW_CONCURRENT_MODELS=true`.

Скрипты **не выполняют VRAM preflight** и прямо предупреждают об этом. Они поднимают оба Compose profiles, не останавливая сначала уже работающий слот.

Перед concurrent launch нужен admission check:

```text
сумма(веса + KV-cache + активации + CUDA overhead)
    < доступная VRAM с операционным запасом
```

Два процесса с `gpu-memory-utilization=0.85` на одной GPU конфликтуют почти гарантированно: каждый пытается зарезервировать 85 % карты. Проверяйте также host RAM, PCIe bandwidth, CPU, disk I/O и суммарную конкурентность — под нагрузкой конфигурация может отказать даже после успешной загрузки обеих моделей.

## Несколько GPU и tensor parallel

Есть два разных режима:

1. независимые модели на разных GPU — каждой задаётся собственный набор устройств;
2. одна модель на нескольких GPU — vLLM запускается с tensor parallel size, равным числу выделенных GPU.

Не смешивайте их. Для независимых моделей нужны непересекающиеся device IDs. Для tensor parallel:

- число GPU соответствует `--tensor-parallel-size`;
- GPU совместимы по архитектуре и памяти;
- модель и vLLM поддерживают разбиение;
- межсоединение достаточно быстро;
- health/readiness охватывает весь distributed process.

Compose каждого слота резервирует `count: 1`, не задаёт device IDs и не передаёт `--tensor-parallel-size`. Поэтому `start-many` — safety-gated concurrent start, а не multi-GPU placement. Для обоих вариантов нужен отдельный Compose override с явным GPU placement; одного CLI-флага недостаточно.

## Пользовательский alt-слот через override

[examples/compose.model-slot.yaml](../examples/compose.model-slot.yaml) **заменяет** конфигурацию `vllm-alt`, не добавляя новый слот. POSIX:

```bash
export COMPOSE_FILE=compose.yaml:examples/compose.model-slot.yaml
export EXAMPLE_SLOT_MODEL_REVISION=<immutable-revision>
./model.sh start alt
```

PowerShell:

```powershell
$env:COMPOSE_FILE = "compose.yaml;examples/compose.model-slot.yaml"
$env:EXAMPLE_SLOT_MODEL_REVISION = "<immutable-revision>"
.\model.ps1 start alt
```

Override поддерживает `EXAMPLE_SLOT_MODEL_ID`, `EXAMPLE_SLOT_MODEL_REVISION`, `EXAMPLE_SLOT_SERVED_MODEL_NAME`, `EXAMPLE_SLOT_MAX_MODEL_LEN`, `EXAMPLE_SLOT_GPU_MEMORY_UTILIZATION`, `EXAMPLE_SLOT_REASONING_PARSER` и `EXAMPLE_SLOT_PORT`.

**Route LiteLLM при этом не меняется автоматически.** Если `EXAMPLE_SLOT_SERVED_MODEL_NAME` отличается от `qwen3-4b-awq`, добавьте соответствующий блок в [config/litellm.yaml](../config/litellm.yaml) (шаг 3 из [Рецепта 1](#рецепт-1-заменить-модель-в-слоте)) и пересоздайте `litellm`.

## Проверки перед переключением клиентов

- `/health` vLLM отвечает;
- `/v1/models` содержит ожидаемое served name;
- LiteLLM маршрутизирует запрос в правильный слот;
- обычный и streaming completion работают;
- VLM принимает допустимое число изображений;
- tool calling/reasoning parser проверены для конкретной модели;
- запрос максимальной ожидаемой длины не вызывает OOM;
- concurrent test соответствует пилотной нагрузке;
- Grafana показывает latency, queue, KV-cache и ошибки;
- неактивная модель даёт явную ошибку, а не скрытый fallback.

## Rollback

Rollback возвращает весь согласованный набор, а не только model ID:

1. остановить новую модель;
2. вернуть предыдущие model revision, image digest, served name, LiteLLM route и параметры;
3. запустить предыдущий слот;
4. пройти smoke tests;
5. проверить API-имя с клиентской стороны;
6. сохранить логи неудачной версии;
7. не удалять новый кэш до разбора причины.

Если API-имя осталось прежним, клиенты переключатся прозрачно — но совместимость поведения это не гарантирует. Если имя меняется, rollback включает конфигурацию клиентов.

Volumes PostgreSQL и observability к rollback модели не относятся. Не используйте `down -v`.

## Расчёт ресурсов

Нижняя оценка весов:

```text
веса = параметры × битность / 8
```

### Пример: `Qwen3.5-4B-AWQ` на карте 12 GiB

| Составляющая | Оценка | Откуда |
|---|---|---|
| Веса (4B параметров, AWQ 4 бита) | ~2 GiB | `4e9 × 4 / 8` |
| Неквантованные части: embeddings, vision encoder, нормировки | ~1 GiB | сумма файлов модели минус веса |
| CUDA context и активации | ~1 GiB | практическое наблюдение |
| **Занято до KV-cache** | **~4 GiB** | |
| Бюджет процесса при `gpu-memory-utilization=0.85` | ~10.2 GiB | `12 × 0.85` |
| **Остаётся на KV-cache** | **~6 GiB** | |

KV-cache при 8192 токенах контекста для модели этого класса — порядка 1 GiB на одну последовательность. То есть запас примерно на 5–6 одновременных запросов максимальной длины. Увеличение `MAIN_VLLM_MAX_MODEL_LEN` до 16384 сокращает это число вдвое.

Проверить фактические цифры вместо оценки:

```bash
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
docker compose --profile main logs vllm-main | grep -i "KV cache\|GPU blocks"
du -sh data/huggingface
```

Важные оговорки:

- `gpu-memory-utilization` — это бюджет всего процесса, а не память только под веса;
- снижение `max-model-len` уменьшает KV-cache, но **не уменьшает веса**;
- для реального планирования берите сумму фактических файлов модели, а не формулу.

При обновлении держите на диске старую и новую revision одновременно. Для air-gap это обязательно: rollback не должен зависеть от сети.

## Air-gap

Требования к изолированному запуску общие для всего стека и описаны один раз в [install-ubuntu-ssh.md → Air-gap](install-ubuntu-ssh.md#air-gap).

Специфика моделей: сохраните обе model revisions, tokenizer, custom code и checksums; запретите runtime download; проверьте холодный запуск без сети. Gated-модель, однажды скачанная с токеном, остаётся под своей лицензией — наличие файлов не отменяет её ограничений.
