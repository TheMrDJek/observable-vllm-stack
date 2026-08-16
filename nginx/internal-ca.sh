#!/bin/sh
# Выпуск сертификата локального CA для режимов gateway internal/migration.
#
# Заменяет директиву 'tls internal' прежнего Caddy: у nginx встроенного CA нет.
# Скрипт выполняется внутри одноразового контейнера с openssl, а не на хосте,
# поэтому Windows и Ubuntu получают побайтово одинаковый результат и от
# оператора не требуется установленный openssl. Запускают его model.sh и
# model.ps1 — вручную вызывать не нужно.
#
# Вход — переменные окружения, выход — файлы в /certs (смонтированный
# ${TLS_CERTS_DIR}):
#   internal-ca.crt  корневой сертификат, его ставят в trust store клиентов
#   internal-ca.key  приватный ключ CA, не покидает этот хост
#   internal.crt     leaf-сертификат шлюза со всеми именами в SAN
#   internal.key     приватный ключ шлюза
#   internal.san     список имён последнего выпуска, только для сравнения
#
# Ключ CA переживает перевыпуск leaf: иначе каждая правка имён требовала бы
# заново обойти trust store всех клиентов.
set -eu

: "${SAN_NAMES:?SAN_NAMES is required}"
: "${CERT_FILE:=internal.crt}"
: "${KEY_FILE:=internal.key}"
: "${OWNER_GID:=101}"

CA_CERT="internal-ca.crt"
CA_KEY="internal-ca.key"
SAN_STATE="internal.san"
CA_DAYS=3650
CERT_DAYS=825
# 30 суток. Leaf перевыпускается заранее, чтобы срок не истёк между запусками.
RENEW_WITHIN=2592000

cd /certs

# SAN_NAMES намеренно без кавычек: значение приходит списком имён через пробел
# и должно разделиться на слова. sort -u убирает дубли и делает порядок
# устойчивым, иначе перестановка имён в .env выглядела бы как смена набора.
# shellcheck disable=SC2086
desired="$(printf '%s\n' $SAN_NAMES | sort -u | tr '\n' ' ')"
desired="${desired% }"
[ -n "$desired" ] || { echo "SAN_NAMES resolved to an empty list." >&2; exit 1; }

reissue=0

if [ ! -f "$CA_CERT" ] || [ ! -f "$CA_KEY" ]; then
    echo "Creating a new internal CA. Every client trust store must be updated."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 \
        -days "$CA_DAYS" -nodes -keyout "$CA_KEY" -out "$CA_CERT" \
        -subj "/CN=observable-vllm-stack internal CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
    reissue=1
else
    echo "Reusing the existing internal CA ($CA_CERT)."
fi

if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    reissue=1
elif [ ! -f "$SAN_STATE" ] || [ "$(cat "$SAN_STATE")" != "$desired" ]; then
    echo "The hostname set changed since the last issue; reissuing the leaf."
    reissue=1
elif ! openssl x509 -in "$CERT_FILE" -noout -checkend "$RENEW_WITHIN" >/dev/null 2>&1; then
    echo "The leaf certificate expires within 30 days; reissuing."
    reissue=1
fi

if [ "$reissue" -eq 1 ]; then
    san=""
    for name in $desired; do
        san="${san}${san:+,}DNS:${name}"
    done

    cat > /tmp/leaf.ext <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${san}
EOF

    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -keyout "$KEY_FILE" -out /tmp/leaf.csr \
        -subj "/CN=${desired%% *}" >/dev/null 2>&1
    openssl x509 -req -in /tmp/leaf.csr -CA "$CA_CERT" -CAkey "$CA_KEY" \
        -CAcreateserial -days "$CERT_DAYS" -sha256 \
        -extfile /tmp/leaf.ext -out "$CERT_FILE" >/dev/null 2>&1
    rm -f /tmp/leaf.csr /tmp/leaf.ext

    printf '%s' "$desired" > "$SAN_STATE"
    echo "Issued $CERT_FILE for: $desired"
else
    echo "$CERT_FILE is current for: $desired"
fi

# nginx в контейнере работает под UID 101 и обязан прочитать ключ шлюза.
# Ключ CA он не читает — тот остаётся доступным только root.
# На bind mount из Windows chown/chmod не применяются; это не ошибка, права
# там определяет host filesystem, поэтому неудача подавляется.
chmod 0600 "$CA_KEY" 2>/dev/null || true
chmod 0644 "$CA_CERT" 2>/dev/null || true
chmod 0640 "$KEY_FILE" 2>/dev/null || true
chmod 0644 "$CERT_FILE" 2>/dev/null || true
chown "0:${OWNER_GID}" "$KEY_FILE" 2>/dev/null || true

echo "Root certificate for clients: $CA_CERT"
