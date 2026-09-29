#!/usr/bin/env python3
# Владелец файла — архитектор (MEE-495, п. 1; правило MEE-430, §3).
#
# «DomainTestKit не тянется в релизный App» до этого файла держалось только на
# комментарии в project.yml и на ревью. Проверка — двумя независимыми способами:
#
#   --project project.yml   Текст спеки XcodeGen. Берётся блок таргета `MeetForMe`
#                           и всех таргетов, на которые он зависит через `target:`
#                           (XPC-сервис `TranscriptionEngine` ложится в бандл App —
#                           это тоже релизный App), и в каждом ищется имя
#                           `DomainTestKit` вне комментариев. Сборки не требует.
#
#   --app MeetForMe.app     Собранный бандл. Во всех Mach-O внутри бандла (главный
#                           исполняемый, `*.debug.dylib` отладочной сборки Xcode 15+,
#                           XPC-сервисы) ищутся символы модуля `DomainTestKit`
#                           (Swift-манглинг `13DomainTestKit`). Ловит и то, чего текст
#                           спеки не видит: транзитивную зависимость через продукт
#                           пакета (например, `Storage` → `DomainTestKit` в Package.swift).
#
# ЧЕГО НЕ ЛОВИТ. `--project` не раскрывает `include:`, `targetTemplates` и прочие
# механизмы составления спеки XcodeGen — в project.yml их нет; появятся — этот
# разбор надо будет расширить. Эту дыру закрывает `--app`: он смотрит на результат.

import argparse
import os
import re
import subprocess
import sys
import tempfile

FORBIDDEN = "DomainTestKit"
ROOT_TARGET = "MeetForMe"
# Мангленное имя модуля в Swift-символах: длина + имя.
MANGLED = f"{len(FORBIDDEN)}{FORBIDDEN}"


def strip_comment(line):
    """Снимает `# ...` вне кавычек (в YAML комментарий начинается с `#` после пробела)."""
    quote = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
    return line


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def target_blocks(text):
    """{имя таргета: [строки блока без комментариев]} из секции `targets:` верхнего уровня."""
    lines = [strip_comment(l).rstrip() for l in text.splitlines()]
    blocks = {}
    in_targets = False
    targets_indent = None
    current = None
    for line in lines:
        if not line.strip():
            continue
        ind = indent_of(line)
        if ind == 0:
            in_targets = line.strip() == "targets:"
            targets_indent = None
            current = None
            continue
        if not in_targets:
            continue
        if targets_indent is None:
            targets_indent = ind
        if ind == targets_indent:
            m = re.match(r"^\s*['\"]?([^'\":]+)['\"]?\s*:\s*$", line)
            current = m.group(1).strip() if m else None
            if current is not None:
                blocks[current] = []
            continue
        if current is not None and ind > targets_indent:
            blocks[current].append(line)
    return blocks


def target_deps(block):
    deps = []
    for line in block:
        for m in re.finditer(r"(?:^|[\s{,-])target\s*:\s*['\"]?([A-Za-z0-9_.-]+)", line):
            deps.append(m.group(1))
    return deps


def check_project(text):
    """Список нарушений (пустой — чисто)."""
    blocks = target_blocks(text)
    if ROOT_TARGET not in blocks:
        return [f"таргет `{ROOT_TARGET}` не найден в секции targets: — разбор project.yml устарел"]
    violations = []
    seen = []
    queue = [ROOT_TARGET]
    while queue:
        name = queue.pop(0)
        if name in seen or name not in blocks:
            continue
        seen.append(name)
        for line in blocks[name]:
            if re.search(rf"\b{FORBIDDEN}\b", line):
                via = "" if name == ROOT_TARGET else f" (через таргет `{name}`, он входит в бандл {ROOT_TARGET})"
                violations.append(f"`{FORBIDDEN}` в зависимостях `{name}`{via}: {line.strip()}")
        queue.extend(target_deps(blocks[name]))
    print(f"project.yml: проверены таргеты {', '.join(seen)}")
    return violations


def is_macho(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except OSError:
        return False
    return magic in (
        b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",  # thin 64/32, little-endian
        b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
        b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",  # fat
    )


def check_app(app):
    if not os.path.isdir(app):
        return [f"бандл не найден: {app}"]
    binaries = []
    for dirpath, _, files in os.walk(app):
        for name in files:
            path = os.path.join(dirpath, name)
            if not os.path.islink(path) and is_macho(path):
                binaries.append(path)
    if not binaries:
        return [f"в {app} нет ни одного Mach-O — проверять нечего, это отказ, а не чистота"]
    violations = []
    for path in sorted(binaries):
        out = subprocess.run(["nm", "-j", path], capture_output=True, text=True)
        if out.returncode != 0:
            violations.append(f"nm не прочитал {path}: {out.stderr.strip()}")
            continue
        hits = [s for s in out.stdout.splitlines() if MANGLED in s]
        rel = os.path.relpath(path, app)
        print(f"{rel}: символов {len(out.stdout.splitlines())}, из {FORBIDDEN} — {len(hits)}")
        if hits:
            sample = ", ".join(hits[:3])
            violations.append(f"символы `{FORBIDDEN}` слинкованы в {rel} ({len(hits)} шт.), например: {sample}")
    return violations


SELF_TEST_OK = """
targets:
  MeetForMe:
    # DomainTestKit нельзя — комментарий не считается
    dependencies:
      - package: Core
        product: DomainCore
      - target: Engine
  Engine:
    dependencies:
      - package: Core
        product: EngineKit
  Other:
    dependencies:
      - package: Core
        product: DomainTestKit
"""

SELF_TEST_BAD_DIRECT = SELF_TEST_OK.replace("product: DomainCore", "product: DomainTestKit")
SELF_TEST_BAD_INLINE = SELF_TEST_OK.replace(
    "- package: Core\n        product: DomainCore", "- {package: Core, product: DomainTestKit}"
)
SELF_TEST_BAD_VIA_TARGET = SELF_TEST_OK.replace("product: EngineKit", "product: DomainTestKit")


def self_test():
    cases = [
        ("чисто (DomainTestKit только в комментарии и у несвязанного таргета)", SELF_TEST_OK, 0),
        ("прямая зависимость", SELF_TEST_BAD_DIRECT, 1),
        ("строчная запись словаря", SELF_TEST_BAD_INLINE, 1),
        ("через зависимый таргет", SELF_TEST_BAD_VIA_TARGET, 1),
        ("нет таргета MeetForMe", SELF_TEST_OK.replace("MeetForMe:", "App:"), 1),
    ]
    failed = 0
    for title, text, expected in cases:
        got = len(check_project(text))
        ok = got == expected
        failed += 0 if ok else 1
        print(f"self-test {'ok' if ok else 'FAIL'}: {title} — нарушений {got}, ожидалось {expected}")
    with tempfile.TemporaryDirectory() as tmp:
        got = len(check_app(tmp))
        ok = got == 1
        failed += 0 if ok else 1
        print(f"self-test {'ok' if ok else 'FAIL'}: пустой бандл — отказ ({got})")
    return failed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project")
    parser.add_argument("--app")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        sys.exit(1 if self_test() else 0)
    if not args.project and not args.app:
        parser.error("нужен --project и/или --app")

    violations = []
    if args.project:
        with open(args.project, encoding="utf-8") as f:
            violations += check_project(f.read())
    if args.app:
        violations += check_app(args.app)

    for v in violations:
        print(f"::error title=DomainTestKit в App (MEE-430 §3)::{v}")
    if violations:
        sys.exit(1)
    print(f"{FORBIDDEN} в {ROOT_TARGET} не попадает")


if __name__ == "__main__":
    main()
