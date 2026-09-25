#!/bin/zsh
# Печатает источник модели GigaAM v3 e2e_ctc (записка MEE-426, §2) и ничего не скачивает
# без --yes — согласие на загрузку модели даёт пользователь, не скрипт (постановка MEE-426:
# «Скачивание модели — только с согласия пользователя»).
#
#   scripts/download-model.sh                     # только печать источника и файлов
#   scripts/download-model.sh --yes                # печать + curl в ./models/gigaam-v3-e2e-ctc/
#   scripts/download-model.sh --yes --dest DIR      # то же, в свой каталог
#
# ВАЖНО, прочитать перед --yes: точный размер в байтах и sha256 обеих ссылок ниже эта сессия
# проверить не смогла — huggingface.co недоступен из песочницы, где писалась записка MEE-426
# (сетевая политика блокирует сам домен, не только TLS). Открой ссылку в браузере и сверь
# размер/хэш с тем, что покажет страница Hugging Face, ПРЕЖДЕ чем подтверждать --yes на
# незнакомой сети — правило записки MEE-426 №5 то же самое, просто здесь оно снова, на
# сáмом месте, где решение реально принимается.
set -euo pipefail

# Кандидат по умолчанию — sherpa-onnx-экспорт (записка MEE-426, §2, источник А):
# https://huggingface.co/Smirnov75/GigaAM-v3-sherpa-onnx — назван там же как более вероятное
# соответствие «~305 МБ, sherpa-onnx, e2e_ctc» из docs/architecture.md, чем экспорты
# csukuangfj (те — без punctuation/capitalization, судя по именам файлов, не e2e-вариант).
REPO_URL="https://huggingface.co/Smirnov75/GigaAM-v3-sherpa-onnx"
MODEL_FILE="gigaam_v3_e2e_ctc.onnx"
TOKENS_FILE="gigaam_v3_e2e_ctc_tokens.txt"
LICENSE="MIT (наследуется от salute-developers/GigaAM, апстрим — github.com/salute-developers/GigaAM)"

DEST="./models/gigaam-v3-e2e-ctc"
DO_DOWNLOAD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) DO_DOWNLOAD=1; shift ;;
    --dest) DEST="$2"; shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

echo "Источник (записка MEE-426, §2, кандидат А — sherpa-onnx-экспорт):"
echo "  репозиторий: $REPO_URL"
echo "  файлы:       $MODEL_FILE, $TOKENS_FILE"
echo "  лицензия:    $LICENSE"
echo "  точный размер в байтах и sha256 — НЕ подтверждены этой сессией (huggingface.co"
echo "  недоступен из песочницы); сверь на странице репозитория перед --yes."
echo "  назначение:  $DEST"
echo

if [[ "$DO_DOWNLOAD" -eq 0 ]]; then
  echo "Ничего не скачано — передай --yes, чтобы разрешить загрузку."
  exit 0
fi

mkdir -p "$DEST"
for f in "$MODEL_FILE" "$TOKENS_FILE"; do
  url="$REPO_URL/resolve/main/$f"
  echo "curl: $url -> $DEST/$f"
  curl -fL --progress-bar "$url" -o "$DEST/$f"
done
echo "Готово: $DEST"
