#!/bin/zsh
# Печатает источник модели GigaAM v3 e2e_ctc (записка MEE-426, §2) и ничего не скачивает
# без --yes — согласие на загрузку модели даёт пользователь, не скрипт (постановка MEE-426:
# «Скачивание модели — только с согласия пользователя»).
#
#   scripts/download-model.sh                     # только печать источника и файлов
#   scripts/download-model.sh --yes                # печать + curl в <корень стенда>/models/...
#   scripts/download-model.sh --yes --dest DIR      # то же, в свой каталог
#
# Размер в байтах и sha256 модели — из приёмки РП (MEE-426, комментарий #158, 07:25 UTC):
# сняты через API Hugging Face (метаданные, не полная загрузка) на реальной сети, эта сессия их
# подтвердить сама не могла (huggingface.co недоступен из песочницы, где написан этот скрипт).
# После загрузки скрипт сверяет байты и sha256 модели сам — расхождение обрывает скрипт.
set -euo pipefail

# Источник — sherpa-onnx-экспорт (записка MEE-426, §2, кандидат А; приёмка РП подтвердила его же):
# https://huggingface.co/Smirnov75/GigaAM-v3-sherpa-onnx — «~305 МБ» из docs/architecture.md
# это ровно int8-вариант (305 МиБ), не fp32 (885 950 432 Б, ошибочно стоял здесь до приёмки #158).
REPO_URL="https://huggingface.co/Smirnov75/GigaAM-v3-sherpa-onnx"
MODEL_FILE="gigaam_v3_e2e_ctc_int8.onnx"
MODEL_SIZE=319869121
MODEL_SHA256="0aacb41f70f0f5aaac4b45dd430337b9e16b180f22c72af04db8516e7609c3c0"
TOKENS_FILE="gigaam_v3_e2e_ctc_tokens.txt"
TOKENS_SIZE=2006
LICENSE="MIT (наследуется от salute-developers/GigaAM, апстрим — github.com/salute-developers/GigaAM)"

# Абсолютный путь от корня стенда (на уровень выше scripts/), а не от текущего каталога вызова —
# `./models/...` зависел бы от того, откуда запущен скрипт, и молча писал бы не туда.
STAND_ROOT="${0:A:h}/.."
DEST="$STAND_ROOT/models/gigaam-v3-e2e-ctc"
DO_DOWNLOAD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) DO_DOWNLOAD=1; shift ;;
    --dest) DEST="$2"; shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

echo "Источник (записка MEE-426, §2 + приёмка РП, #158):"
echo "  репозиторий: $REPO_URL"
echo "  файлы:       $MODEL_FILE ($MODEL_SIZE Б), $TOKENS_FILE ($TOKENS_SIZE Б)"
echo "  лицензия:    $LICENSE"
echo "  назначение:  $DEST"
echo

if [[ "$DO_DOWNLOAD" -eq 0 ]]; then
  echo "Ничего не скачано — передай --yes, чтобы разрешить загрузку."
  exit 0
fi

mkdir -p "$DEST"

url="$REPO_URL/resolve/main/$MODEL_FILE"
echo "curl: $url -> $DEST/$MODEL_FILE"
curl -fL --progress-bar "$url" -o "$DEST/$MODEL_FILE"

actual_size=$(wc -c < "$DEST/$MODEL_FILE" | tr -d ' ')
if [[ "$actual_size" != "$MODEL_SIZE" ]]; then
  echo "СТОП: $MODEL_FILE — $actual_size Б, ожидалось $MODEL_SIZE Б" >&2
  exit 1
fi
actual_sha256=$(shasum -a 256 "$DEST/$MODEL_FILE" | awk '{print $1}')
if [[ "$actual_sha256" != "$MODEL_SHA256" ]]; then
  echo "СТОП: $MODEL_FILE — sha256 $actual_sha256, ожидался $MODEL_SHA256" >&2
  exit 1
fi
echo "sha256 сошёлся: $MODEL_FILE"

url="$REPO_URL/resolve/main/$TOKENS_FILE"
echo "curl: $url -> $DEST/$TOKENS_FILE"
curl -fL --progress-bar "$url" -o "$DEST/$TOKENS_FILE"

actual_size=$(wc -c < "$DEST/$TOKENS_FILE" | tr -d ' ')
if [[ "$actual_size" != "$TOKENS_SIZE" ]]; then
  echo "СТОП: $TOKENS_FILE — $actual_size Б, ожидалось $TOKENS_SIZE Б" >&2
  exit 1
fi

echo "Готово: $DEST"
