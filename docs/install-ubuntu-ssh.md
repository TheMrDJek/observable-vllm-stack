# Установка Ubuntu по SSH

Это основной production-like сценарий пилота: выделенный Ubuntu-хост с NVIDIA GPU, управление только по SSH, клиентский доступ только по HTTPS на TCP/443.

## 1. Требования

- Ubuntu Server 24.04 LTS или согласованная поддерживаемая версия;
- NVIDIA GPU с подходящим объёмом VRAM;
- актуальный NVIDIA Driver на хосте;
- Docker Engine, Compose plugin и NVIDIA Container Toolkit;
- SSH-доступ пользователя с `sudo`;
- два DNS-имени из `PUBLIC_API_HOST` и `PUBLIC_CHAT_HOST` (`api.vlm.local` и `chat.vlm.local` по умолчанию);
- свободный TCP/443; этот стек не слушает TCP/80 и не выполняет ACME.

Ресурсы:

| Ресурс | Минимум | Комментарий |
|---|---|---|
| Диск | **60 GiB свободно** | измерено: ~28.5 GiB образы (из них 19.7 GiB — сам vLLM), ~4 GiB кэш дефолтной модели; остальное — volumes телеметрии и запас на вторую revision при обновлении |
| RAM | 16 GiB | ~2 GiB core-сервисы, +2–3 GiB при `local-observability`, остальное под vLLM |
| VRAM | 12 GiB | для дефолтной `Qwen3.5-4B-AWQ`; расчёт — в [model-operations.md](model-operations.md#расчёт-ресурсов) |

Не устанавливайте CUDA toolkit на хост без реальной необходимости: контейнеру нужны драйвер и NVIDIA Container Toolkit, а не полный CUDA SDK.

## 2. Подготовка хоста

Подключитесь по SSH и обновите систему:

```bash
ssh <user>@<server>
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

После повторного входа проверьте GPU:

```bash
nvidia-smi
```

Если `nvidia-smi` не найден, драйвера нет. Установите его и перезагрузитесь:

```bash
sudo ubuntu-drivers install
sudo reboot
```

### Docker Engine и Compose plugin

Команды ниже — официальный способ установки из репозитория Docker для Ubuntu, приведённый здесь целиком, чтобы не уходить из инструкции. Если они перестанут работать, сверьтесь с [docs.docker.com/engine/install/ubuntu](https://docs.docker.com/engine/install/ubuntu/): порядок шагов у Docker иногда меняется.

Не используйте пакет `docker-compose` из репозитория Ubuntu — это устаревшая v1, стек требует v2 (`docker compose`).

```bash
# 1. убрать конфликтующие пакеты, если они есть
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y "$pkg"
done

# 2. ключ репозитория
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# 3. источник пакетов
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 4. установка
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# 5. проверка
sudo docker run --rm hello-world
docker compose version
```

Добавьте пользователя в группу `docker` только если принимаете, что членство в ней эквивалентно root на этом хосте:

```bash
sudo usermod -aG docker "$USER"
```

Изменение группы применяется только к новой сессии — **перезайдите по SSH**, иначе `docker` продолжит требовать `sudo`.

### NVIDIA Container Toolkit

Драйвер на хосте сам по себе не даёт контейнеру доступ к GPU. Нужен ещё toolkit. Первоисточник — [docs.nvidia.com/datacenter/cloud-native](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).

```bash
# 1. репозиторий
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

# 2. установка
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# 3. прописать runtime в Docker и перезапустить демон
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# 4. контрольная проверка
docker run --rm --gpus all nvidia/cuda:12.9.0-base-ubuntu22.04 nvidia-smi
```

**Последняя команда — точка невозврата этого раздела.** Если она не отдаёт таблицу GPU, vLLM не запустится. Дальше не идите, разбирайтесь здесь: типовые причины в [troubleshooting.md](troubleshooting.md).

Не устанавливайте полный CUDA toolkit на хост: контейнеру нужны только драйвер и Container Toolkit.

## 3. Размещение и секреты

Клонируйте репозиторий в постоянный каталог, например `/opt/ai-vllm-stack`, и ограничьте доступ:

```bash
sudo install -d -o "$USER" -g "$USER" -m 0750 /opt/ai-vllm-stack
git clone <repository-url> /opt/ai-vllm-stack
cd /opt/ai-vllm-stack
cp .env.example .env
chmod 0600 .env
mkdir -p secrets/tls secrets/remote-ca
chmod 700 secrets secrets/tls secrets/remote-ca
# шаблоны описаний: secrets.example/tls и secrets.example/remote-ca
```

Замените каждый `CHANGE_ME` случайным уникальным значением. Скрипты откажутся стартовать, пока хотя бы один placeholder остался. Сгенерировать значения:

```bash
echo "sk-$(openssl rand -hex 24)"   # LITELLM_MASTER_KEY
echo "sk-$(openssl rand -hex 24)"   # LITELLM_SALT_KEY
echo "sk-$(openssl rand -hex 24)"   # VLLM_API_KEY
openssl rand -hex 32                # WEBUI_SECRET_KEY (ровно 64 hex-символа)
openssl rand -base64 24             # POSTGRES_PASSWORD
openssl rand -base64 24             # GRAFANA_ADMIN_PASSWORD
grep -n CHANGE_ME .env              # должно быть пусто перед запуском
```

Не передавайте `.env` в чат, issue, логи или shell history. Требования:

- `LITELLM_MASTER_KEY` и `LITELLM_SALT_KEY` начинаются с `sk-`;
- `LITELLM_SALT_KEY` после первого запуска не меняется — сохраните его отдельно;
- `OPEN_WEBUI_LITELLM_KEY` при первом запуске остаётся **пустым**; это не placeholder;
- каждое значение уникально, ключи не переиспользуются между сервисами;
- `HF_TOKEN` задаётся только для gated-моделей и с минимальными правами.

Для systemd/CI предпочтителен отдельный root-readable env-файл или менеджер секретов. Сам Compose secrets не защищает значение, если источник всё равно лежит открытым файлом.

## 4. Сетевой и ИБ gate

До запуска подтвердите:

1. наружу публикуется только gateway на `443/tcp`;
2. LiteLLM, Open WebUI, Grafana, Prometheus, Loki, Tempo, Alloy, PostgreSQL и vLLM доступны только через loopback или внутренние Docker networks;
3. SSH ограничен доверенными адресами/VPN и вход по паролю выключен;
4. клиент не может обойти LiteLLM и обратиться к vLLM напрямую;
5. резервные копии и retention согласованы со значением `STORE_PROMPTS_IN_SPEND_LOGS` (`false` по умолчанию);
6. удалённые `image_url` по умолчанию заблокированы: `VLLM_ALLOWED_MEDIA_DOMAINS=media.invalid`, а redirects отключены через `VLLM_MEDIA_URL_ALLOW_REDIRECTS=0`. Для разрешения конкретных источников задайте узкий allowlist доменов; не разрешайте внутренние и metadata endpoints;
7. `Alloy` запускается `privileged` и читает Docker socket, `/proc`, `/sys`, корневую FS и `/var/lib/docker`. Это практически host-level trust. Для недоверенного окружения такой режим неприемлем без отдельного hardening.

Проверьте итоговый Compose до запуска:

```bash
docker compose config
```

Если в опубликованных адресах видны `0.0.0.0:3000`, `:4000`, `:8001`, `:8002`, `:9090`, `:12345` или порт базы — gate не пройден.

## 5. UFW

Не включайте UFW вслепую через SSH. Сначала разрешите SSH с управляющей сети:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from <admin-cidr> to any port 22 proto tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status verbose
```

Docker управляет iptables напрямую и может обходить ожидаемую фильтрацию UFW для published ports. UFW не компенсирует ошибочное `0.0.0.0:PORT` в Compose: публикуйте внутренние сервисы только на `127.0.0.1` либо не публикуйте вовсе, а ограничения при необходимости задавайте в цепочке `DOCKER-USER`.

## 6. Первый запуск

```bash
chmod +x ./model.sh
./model.sh preflight
./model.sh observability local
./model.sh start main --gpu-metrics
./model.sh gateway internal
./model.sh status
./model.sh gateway status
```

`preflight` проверяет то, что чаще всего ломает первый запуск: Docker и Compose v2, отсутствие `CHANGE_ME`, GPU из контейнера, свободный диск, занятость публичного порта и разрешение обоих hostnames. Он ничего не чинит автоматически — только сообщает. Расшифровка отказов — в [troubleshooting.md](troubleshooting.md).

`observability local` поднимает не только Prometheus/Loki/Tempo/Grafana, но и PostgreSQL, LiteLLM, Open WebUI и Alloy. Это первый шаг развёртывания, а не опция. Для стенда с удалённым мониторингом вместо неё выполняется `./model.sh observability remote`.

**Первый запуск модели занимает 10–30 минут.** Скачивается около 4 GiB весов в `data/huggingface`, затем модель грузится в VRAM. В это время контейнер находится в состоянии `health: starting` — это нормально, а не отказ. Для vLLM в Compose задан `start_period: 15m` именно поэтому. Следите за прогрессом:

```bash
docker compose --profile main logs -f vllm-main
```

Повторные запуски укладываются в 2–5 минут: веса берутся из кэша. Готовность подтверждайте состоянием `healthy` и реальным ответом `/v1/models`, а не состоянием `running`.

`gateway status` показывает состояние контейнера nginx через `docker compose ps`; он не выводит активный issuer, имена или срок сертификата. Активный режим записывается скриптом в `.env` (`GATEWAY_MODE` и `NGINX_CONFIG_FILE`).

`internal` использует локальный CA: команда сама выпускает сертификат в `TLS_CERTS_DIR` при первом запуске и переиспользует ключ CA при последующих. Клиентам нужен только корневой сертификат:

```bash
openssl x509 -in secrets/tls/internal-ca.crt -noout -subject -dates -fingerprint -sha256
```

Передайте `secrets/tls/internal-ca.crt` по аутентифицированному каналу и установите клиентам по инструкции [Быстрый старт HTTPS](quick-start-https.md), затем проверяйте без `-k`. Файл `internal-ca.key` — закрытый ключ CA, он остаётся на этом хосте.

Запуск модели происходит в фоне. Готовность подтверждайте health/status и логами конкретного vLLM-сервиса, а не только состоянием `running`.

## 7. Ключ Open WebUI

Публичный nginx route API пропускает только `/v1` и не открывает административный `/key/generate`. Создайте virtual key через loopback LiteLLM после его запуска:

```bash
read -rsp "LiteLLM master key: " LITELLM_MASTER_KEY; echo
curl --fail --show-error --silent \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"open-webui","models":["qwen3.5-4b-awq","qwen3-4b-awq"]}' \
  http://127.0.0.1:4000/key/generate
unset LITELLM_MASTER_KEY
```

Скопируйте поле `key` из ответа в `OPEN_WEBUI_LITELLM_KEY` файла `.env`, затем пересоздайте только UI:

```bash
docker compose up -d --force-recreate open-webui
```

Не записывайте master key вместо virtual key и не публикуйте ответ команды.

## 8. Приёмка

Полный набор команд приёмки с ожидаемыми результатами — в [verification.md](verification.md). Минимальный критерий готовности:

- `https://api.vlm.local/v1/models` отвечает только с корректным bearer token;
- `https://chat.vlm.local` открывает Open WebUI;
- сертификат доверен клиентом без `curl -k`;
- HTTP и все внутренние порты недоступны из клиентской сети;
- после перезагрузки хоста стек возвращается в ожидаемое состояние;
- Grafana на `127.0.0.1:3001` показывает данные после генерации тестового трафика.

Штатная остановка моделей не удаляет volumes:

```bash
./model.sh stop
./model.sh status
```

Никогда не используйте `docker compose down -v` в штатной остановке: это удаляет данные LiteLLM, чаты Open WebUI, телеметрию и приватный ключ internal CA.

Если что-то не работает — [troubleshooting.md](troubleshooting.md).

## Air-gap

Полностью изолированный запуск требует заранее подготовить:

- все Docker images с точными immutable tags/digests;
- веса, tokenizer, конфиги и custom code модели;
- пакеты Docker/NVIDIA и их зависимости для выбранной Ubuntu;
- корневой и промежуточные сертификаты;
- локальный registry и/или архивы `docker save`;
- контрольные суммы и SBOM/реестр источников.

Загрузите модель в кэш заранее и исключите сетевые обращения Hugging Face. `HF_TOKEN` в air-gap не заменяет локальные артефакты. Репозиторий фиксирует vLLM image по digest и обе модели по revisions; сохраняйте именно эти артефакты. Внешний ACME без сети не работает; текущий external-режим nginx в любом случае использует заранее предоставленные файлы сертификата и ключа.
