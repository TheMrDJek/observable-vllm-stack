# Операции с моделями

## Интерфейс

PowerShell:

```powershell
.\model.ps1 start main -GpuMetrics
.\model.ps1 start alt -GpuMetrics
.\model.ps1 start-many main alt -GpuMetrics
.\model.ps1 stop
.\model.ps1 status
```

Linux:

```bash
./model.sh start main --gpu-metrics
./model.sh start alt --gpu-metrics
./model.sh start-many main alt --gpu-metrics
./model.sh stop
./model.sh status
```

`start` принимает ровно один слот, сначала останавливает `vllm-main` и `vllm-alt`, затем поднимает выбранный Compose profile вместе с базовыми сервисами. `stop` останавливает обе модели, но сохраняет остальные сервисы и volumes. `status` показывает Compose services с профилями `main`, `alt` и `gpu-metrics`.

## Замена модели

Модель — это не только Hugging Face ID. Согласованно меняются:

- repository ID и точная revision;
- публичное `served-model-name`;
- запись LiteLLM `model_name`/upstream;
- tokenizer и trust-remote-code policy;
- vLLM arguments: context, quantization, dtype, parsers, multimodal limits;
- профиль ресурсов и GPU placement;
- smoke/load tests.

Текущая конфигурация связывает `main` с `qwen3.5-4b-awq`, а `alt` с `qwen3-4b-awq`. ID, immutable revision и served name вынесены в `.env`:

```dotenv
MAIN_MODEL_ID=QuantTrio/Qwen3.5-4B-AWQ
MAIN_MODEL_REVISION=32c292e3a73afe1138518180b1b6d2868c980ee2
MAIN_SERVED_MODEL_NAME=qwen3.5-4b-awq
ALT_MODEL_ID=Qwen/Qwen3-4B-AWQ
ALT_MODEL_REVISION=74d4bd2bd4bff9cafc9345221320bffb08b406a3
ALT_SERVED_MODEL_NAME=qwen3-4b-awq
```

LiteLLM routes в `config/litellm.yaml` также должны совпадать с served names. Изменение только model ID оставит несовместимые имя и parsers.

Безопасный порядок:

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

Плавающий model ID или Docker tag не обеспечивает повторяемость. Репозиторий фиксирует модели через `--revision`, а vLLM image — digest:

- точный источник;
- revision;
- checksums скачанных файлов;
- версию vLLM;
- параметры запуска;
- дату и результат теста.

Текущий digest — validated snapshot nightly-сборки, но имя тега не участвует в pull. Обновление image digest и model revision одновременно затрудняет диагностику — меняйте по одному фактору.

## Последовательный запуск

Для одной GPU или ограниченной VRAM используйте один слот:

```powershell
.\model.ps1 start main -GpuMetrics
.\model.ps1 status
.\model.ps1 start alt -GpuMetrics
```

Запуск `alt` останавливает `main`. Это правильно для 12 GiB GPU, где две полноценные модели с рабочим KV-cache обычно не помещаются. Состояние контейнера `running` не означает готовность модели; проверяйте health, логи и реальный inference.

Linux-эквивалент:

```bash
./model.sh start main --gpu-metrics
./model.sh status
./model.sh start alt --gpu-metrics
```

## Одновременный запуск моделей

```powershell
.\model.ps1 start-many main alt -GpuMetrics
```

```bash
./model.sh start-many main alt --gpu-metrics
```

Команда принимает ровно два отдельных аргумента (`main alt`) и требует:

```dotenv
ALLOW_CONCURRENT_MODELS=true
```

Скрипты не выполняют VRAM preflight и прямо предупреждают об этом. Они поднимают оба Compose profiles, не останавливая сначала уже работающий слот.

Перед concurrent launch нужен admission check:

```text
сумма(веса + KV-cache + активации + CUDA overhead)
< сумма доступной VRAM с операционным запасом
```

Проверяйте также host RAM, PCIe bandwidth, CPU, disk I/O и суммарную конкурентность. Успешная загрузка двух моделей не доказывает устойчивость под запросами.

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

Compose каждого слота резервирует `count: 1`, не задаёт device IDs и не передаёт `--tensor-parallel-size`. Поэтому `start-many` — safety-gated concurrent start, а не multi-GPU placement. Tensor parallel этой конфигурацией не включается. Для обоих вариантов нужен отдельный Compose override с явным GPU placement; одного CLI-флага недостаточно.

## Пользовательский alt-слот

`examples/compose.model-slot.yaml` переопределяет `vllm-alt`. POSIX:

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

Override поддерживает `EXAMPLE_SLOT_MODEL_ID`, `EXAMPLE_SLOT_MODEL_REVISION`, `EXAMPLE_SLOT_SERVED_MODEL_NAME`, `EXAMPLE_SLOT_MAX_MODEL_LEN`, `EXAMPLE_SLOT_GPU_MEMORY_UTILIZATION`, `EXAMPLE_SLOT_REASONING_PARSER` и `EXAMPLE_SLOT_PORT`. LiteLLM route автоматически не меняется.

## Проверки перед переключением

- `/health` vLLM отвечает;
- `/v1/models` содержит ожидаемое served name;
- LiteLLM маршрутизирует запрос в правильный слот;
- обычный и streaming completion работают;
- VLM принимает допустимое число изображений;
- tool calling/reasoning parser проверены для конкретной модели;
- запрос максимальной ожидаемой длины не вызывает OOM;
- concurrent test соответствует пилотной нагрузке;
- Grafana показывает latency, queue, KV-cache и ошибки;
- неактивная модель даёт ожидаемую явную ошибку, а не скрытый fallback.

## Rollback

Rollback должен возвращать весь согласованный набор, а не только model ID:

1. остановить новую модель;
2. вернуть предыдущие model revision, image digest, served name, LiteLLM route и параметры;
3. запустить предыдущий слот;
4. пройти smoke tests;
5. проверить API-имя с клиентской стороны;
6. сохранить логи неудачной версии;
7. не удалять новый кэш до разбора причины.

Если API-имя осталось прежним, клиенты переключатся прозрачно, но это не гарантирует совместимость поведения. Если имя меняется, rollback включает конфигурацию клиентов.

Volumes PostgreSQL/Open WebUI/observability к rollback модели не относятся. Не используйте `down -v`.

## Расчёт ресурсов

Нижняя оценка весов:

```text
веса = параметры × битность / 8
```

Для реального планирования берите сумму файлов модели и добавляйте запас. VRAM включает веса, KV-cache, активации, vision encoder и CUDA overhead. `gpu-memory-utilization` — бюджет процесса, не память только под веса. Снижение `max-model-len` не уменьшает веса.

При обновлении держите на диске старую и новую revision одновременно. Для air-gap это обязательно: rollback не должен зависеть от сети.

## Air-gap

До изоляции сохраните image по digest, обе model revisions, tokenizer, custom code, checksums и тестовый набор. Запретите runtime download и проверьте холодный запуск без сети. Gated-модель, однажды скачанная с токеном, всё равно требует соблюдения лицензии; наличие файлов не отменяет ограничений.
