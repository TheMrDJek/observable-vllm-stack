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

Установите Docker Engine и Compose plugin по официальной инструкции Docker для Ubuntu. Не используйте устаревший пакет `docker-compose`. Добавьте пользователя в группу `docker` только если принимаете эквивалентный root-доступ этой группы:

```bash
sudo usermod -aG docker "$USER"
```

Перезайдите по SSH, установите NVIDIA Container Toolkit по официальной инструкции NVIDIA и настройте runtime:

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker run --rm --gpus all nvidia/cuda:12.9.0-base-ubuntu22.04 nvidia-smi
```

Если последняя команда не работает, vLLM тоже не заработает. Сначала исправьте GPU runtime.

## 3. Размещение и секреты

Клонируйте репозиторий в постоянный каталог, например `/opt/ai-vllm-stack`, и ограничьте доступ:

```bash
sudo install -d -o "$USER" -g "$USER" -m 0750 /opt/ai-vllm-stack
git clone <repository-url> /opt/ai-vllm-stack
cd /opt/ai-vllm-stack
cp .env.example .env
chmod 0600 .env
mkdir -p secrets/caddy secrets/remote-ca
chmod 700 secrets secrets/caddy secrets/remote-ca
# шаблоны описаний: secrets.example/caddy и secrets.example/remote-ca
```

Замените каждый `CHANGE_ME` случайным уникальным значением. Не передавайте `.env` в чат, issue, логи или shell history. Требования:

- `LITELLM_MASTER_KEY` и `LITELLM_SALT_KEY` начинаются с `sk-`;
- `LITELLM_SALT_KEY` после первого запуска не меняется;
- `OPEN_WEBUI_LITELLM_KEY` при первом запуске остаётся пустым;
- `WEBUI_SECRET_KEY` — случайная строка из 64 hex-символов;
- `POSTGRES_PASSWORD`, `GRAFANA_ADMIN_PASSWORD` и API-ключи не переиспользуются;
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
./model.sh observability local
./model.sh start main --gpu-metrics
./model.sh gateway internal
./model.sh status
./model.sh gateway status
```

`gateway status` показывает состояние контейнера Caddy через `docker compose ps`; он не выводит активный issuer, имена или срок сертификата. Активный режим определяется последней успешно выполненной командой и смонтированным Caddyfile.

`internal` использует Caddy internal CA. Скопируйте только root certificate:

```bash
docker compose --profile gateway cp \
  caddy:/data/caddy/pki/authorities/local/root.crt \
  ./caddy-local-root.crt
```

Установите его клиентам по инструкции [Быстрый старт HTTPS](quick-start-https.md), затем проверяйте без `-k`.

Запуск модели происходит в фоне. Готовность подтверждайте health/status и логами конкретного vLLM-сервиса, а не только состоянием `running`.

## 7. Ключ Open WebUI

Публичный Caddy route API пропускает только `/v1` и не открывает административный `/key/generate`. Создайте virtual key через loopback LiteLLM после его запуска:

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

- `https://api.vlm.local/v1/models` отвечает только с корректным bearer token;
- `https://chat.vlm.local` открывает Open WebUI;
- сертификат доверен клиентом без `curl -k`;
- HTTP и все внутренние порты недоступны из клиентской сети;
- после перезагрузки хоста стек возвращается в ожидаемое состояние;
- Grafana на `127.0.0.1:3001` показывает данные после генерации тестового трафика;
- остановка модели не удаляет volumes:

```bash
./model.sh stop
./model.sh status
```

Никогда не используйте `docker compose down -v` в штатной остановке: это удаляет состояние сервисов.

## Air-gap

Полностью изолированный запуск требует заранее подготовить:

- все Docker images с точными immutable tags/digests;
- веса, tokenizer, конфиги и custom code модели;
- пакеты Docker/NVIDIA и их зависимости для выбранной Ubuntu;
- корневой и промежуточные сертификаты;
- локальный registry и/или архивы `docker save`;
- контрольные суммы и SBOM/реестр источников.

Загрузите модель в кэш заранее и исключите сетевые обращения Hugging Face. `HF_TOKEN` в air-gap не заменяет локальные артефакты. Репозиторий фиксирует vLLM image по digest и обе модели по revisions; сохраняйте именно эти артефакты. Внешний ACME без сети не работает; текущий external-режим Caddy в любом случае использует заранее предоставленные файлы сертификата и ключа.
