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
#                           Зависимостью считается ЛЮБОЙ ключ `target:` в блоке
#                           таргета, не только под `dependencies:` (MEE-497) —
#                           намеренно с запасом: лишний таргет в обходе грозит разве
#                           что ложным срабатыванием, но не пропуском.
#
#   --app MeetForMe.app     Собранный бандл. Во всех Mach-O внутри бандла (главный
#                           исполняемый, `*.debug.dylib` отладочной сборки Xcode 15+,
#                           XPC-сервисы) ищутся символы модуля `DomainTestKit`
#                           (Swift-манглинг `13DomainTestKit`). Ловит и то, чего текст
#                           спеки не видит: транзитивную зависимость через продукт
#                           пакета (например, `Storage` → `DomainTestKit` в Package.swift).
#                           Вдобавок (MEE-497) — входы линковщика в `Intermediates.noindex`
#                           той же сборки: `DomainTestKit.o` в `*.LinkFileList` таргетов
#                           бандла. Так проверка не зависит от dead-stripping: модуль,
#                           слинкованный, но целиком выброшенный линковщиком, символов в
#                           Mach-O не оставит, а в списке входов останется. Каталог
#                           задаётся `--intermediates` (так зовёт CI) или выводится из
#                           пути бандла (`…/Build/Products/<конф.>/X.app` →
#                           `…/Build/Intermediates.noindex`). Задан явно, а каталога нет
#                           или в нём нет ни одного `*.LinkFileList` таргетов бандла —
#                           отказ: проверка, заказанная явно, молча не пропускается.
#                           Выведен сам и не найден — аннотация `::warning`, не отказ.
#
# ЧЕГО НЕ ЛОВИТ. `--project` не раскрывает `include:`, `targetTemplates` и прочие
# механизмы составления спеки XcodeGen — в project.yml их нет; появятся — этот
# разбор надо будет расширить. Эту дыру закрывает `--app`: он смотрит на результат.
# Разбор комментариев (`strip_comment`) понимает кавычки в начале скаляра, в том числе
# после тега `!…` и якоря `&…`; блочные скаляры (`|`, `>`) и многострочные строки в
# кавычках построчно не отслеживаются — в project.yml их с `#` внутри нет.

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

FORBIDDEN = "DomainTestKit"
ROOT_TARGET = "MeetForMe"
# Мангленное имя модуля в Swift-символах: длина + имя.
MANGLED = f"{len(FORBIDDEN)}{FORBIDDEN}"


# Кавычка открывает строку в кавычках, только когда с неё начинается скаляр: в начале
# строки или после одного из этих знаков (и пробелов). Апостроф внутри значения без
# кавычек (`name: it's # ...`) строкой в кавычках не является (MEE-497).
SCALAR_START = ":-[{,?"


def starts_scalar(before):
    """Кавычка после `before` начинает скаляр: перед ней, за вычетом свойств узла —
    тега `!…` и якоря `&…` (`key: !!str '…'`, `- &a "…"`), — начало строки или
    один из знаков `SCALAR_START`."""
    while True:
        before = before.rstrip(" \t")
        cut = max(before.rfind(" "), before.rfind("\t"))
        if not before[cut + 1:].startswith(("!", "&")):
            break
        before = before[:cut + 1]
    return not before or before[-1] in SCALAR_START


def strip_comment(line):
    """Снимает `# ...` вне кавычек (в YAML комментарий начинается с `#` после пробела)."""
    quote = None
    i = 0
    while i < len(line):
        ch = line[i]
        if quote == "'":
            if ch == "'":
                if line[i + 1:i + 2] == "'":
                    i += 1  # `''` — экранированный апостроф внутри '...'
                else:
                    quote = None
        elif quote == '"':
            if ch == "\\":
                i += 1  # escape внутри "..." (`\"` и прочие)
            elif ch == '"':
                quote = None
        elif ch in "'\"":
            if starts_scalar(line[:i]):
                quote = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
        i += 1
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


def bundle_targets(app):
    """Имена таргетов, чьи Mach-O лежат в бандле: сам App и его XPC-сервисы."""
    names = {os.path.splitext(os.path.basename(os.path.normpath(app)))[0]}
    xpc_dir = os.path.join(app, "Contents", "XPCServices")
    if os.path.isdir(xpc_dir):
        for entry in os.listdir(xpc_dir):
            if entry.endswith(".xpc"):
                names.add(os.path.splitext(entry)[0])
    return names


def default_intermediates(app):
    """`…/Build/Products/<конф.>/X.app` → `…/Build/Intermediates.noindex`, если он есть."""
    build = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(os.path.normpath(app)))))
    candidate = os.path.join(build, "Intermediates.noindex")
    return candidate if os.path.isdir(candidate) else None


# Аннотация GitHub. В self-test подменяется простым префиксом: ожидаемые там
# предупреждения не должны желтить каждый прогон CI.
WARNING_PREFIX = "::warning title=DomainTestKit вне App (MEE-497)::"


def warn(message):
    print(f"{WARNING_PREFIX}{message}")


def check_link_inputs(intermediates, targets, explicit):
    """Нарушения по `*.LinkFileList` таргетов бандла: входом линковщика был `DomainTestKit.o`.
    `explicit` — каталог задан `--intermediates`: тогда его отсутствие или пустота — отказ."""
    suffix = ".LinkFileList"
    if not os.path.isdir(intermediates):
        return [f"--intermediates {intermediates}: каталога нет — входы линковщика не проверены"]
    lists = []
    for dirpath, _, files in os.walk(intermediates):
        for name in files:
            if name.endswith(suffix) and name[: -len(suffix)] in targets:
                lists.append(os.path.join(dirpath, name))
    if not lists:
        message = (f"в {intermediates} нет *{suffix} таргетов {', '.join(sorted(targets))}"
                   " — входы линковщика не проверены")
        if explicit:
            return [f"--intermediates: {message}"]
        warn(message)
        return []
    violations = []
    for path in sorted(lists):
        with open(path, encoding="utf-8", errors="replace") as f:
            entries = [l.strip() for l in f if l.strip()]
        hits = [e for e in entries
                if os.path.basename(e) == f"{FORBIDDEN}.o" or f"/{FORBIDDEN}.build/" in e]
        rel = os.path.relpath(path, intermediates)
        print(f"{rel}: входов линковщика {len(entries)}, из {FORBIDDEN} — {len(hits)}")
        if hits:
            violations.append(f"`{FORBIDDEN}` во входах линковщика {rel}: {', '.join(hits[:3])}")
    return violations


def check_app(app, intermediates=None, run=subprocess.run):
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
        out = run(["nm", "-j", path], capture_output=True, text=True)
        if out.returncode != 0:
            violations.append(f"nm не прочитал {path}: {out.stderr.strip()}")
            continue
        hits = [s for s in out.stdout.splitlines() if MANGLED in s]
        rel = os.path.relpath(path, app)
        print(f"{rel}: символов {len(out.stdout.splitlines())}, из {FORBIDDEN} — {len(hits)}")
        if hits:
            sample = ", ".join(hits[:3])
            violations.append(f"символы `{FORBIDDEN}` слинкованы в {rel} ({len(hits)} шт.), например: {sample}")
    explicit = intermediates is not None
    intermediates = intermediates if explicit else default_intermediates(app)
    if intermediates is None:
        warn("Intermediates.noindex рядом с бандлом не найден, --intermediates не задан"
             " — входы линковщика не проверены")
    else:
        violations += check_link_inputs(intermediates, bundle_targets(app), explicit)
    return violations


SELF_TEST_OK = """
targets:
  MeetForMe:
    # DomainTestKit нельзя — комментарий не считается
    dependencies:
      - package: Core
        product: DomainCore
      - target: Engine
    info:
      properties:
        CFBundleName: it's # DomainTestKit — апостроф в значении без кавычек
        CFBundleDisplayName: 'it''s' # DomainTestKit — экранированный апостроф
        CFBundleSpokenName: !!str it's # DomainTestKit — тег и апостроф без кавычек
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
# `#` внутри строки в кавычках после тега/якоря — не комментарий: имя за ним видно.
SELF_TEST_BAD_TAGGED = SELF_TEST_OK.replace(
    "product: DomainCore", "product: !!str 'Core #1 DomainTestKit'"
)
SELF_TEST_BAD_ANCHORED = SELF_TEST_OK.replace(
    "product: DomainCore", "product: &core \"Core #1 DomainTestKit\""
)


class FakeCompleted:
    def __init__(self, stdout):
        self.returncode = 0
        self.stdout = stdout
        self.stderr = ""


def fake_nm(symbols):
    """Подменный `nm` (как в undefined-symbols.py): отдаёт заданные символы любому файлу."""
    def run(cmd, capture_output, text):
        assert cmd[:2] == ["nm", "-j"], cmd
        return FakeCompleted("\n".join(symbols) + "\n")
    return run


def make_fake_build(tmp, link_inputs):
    """Сборка в миниатюре: бандл с Mach-O-заглушками (App и XPC), LinkFileList рядом."""
    app = os.path.join(tmp, "Build", "Products", "Debug", "MeetForMe.app")
    for exe in (os.path.join(app, "Contents", "MacOS", "MeetForMe"),
                os.path.join(app, "Contents", "XPCServices", "Engine.xpc", "Contents", "MacOS", "Engine")):
        os.makedirs(os.path.dirname(exe))
        with open(exe, "wb") as f:
            f.write(b"\xcf\xfa\xed\xfe" + b"\0" * 28)
    objects = os.path.join(tmp, "Build", "Intermediates.noindex", "MeetForMe.build", "Debug",
                           "MeetForMe.build", "Objects-normal", "arm64")
    os.makedirs(objects)
    with open(os.path.join(objects, "MeetForMe.LinkFileList"), "w", encoding="utf-8") as f:
        f.write("".join(f"{p}\n" for p in link_inputs))
    # Тестовый таргет вправе линковать DomainTestKit — его список не проверяется.
    with open(os.path.join(objects, "MeetForMeTests.LinkFileList"), "w", encoding="utf-8") as f:
        f.write("/dd/Build/Products/Debug/DomainTestKit.o\n")
    return app


def self_test():
    global WARNING_PREFIX
    WARNING_PREFIX = "self-test, ожидаемое предупреждение: "
    cases = [
        ("чисто (DomainTestKit только в комментарии и у несвязанного таргета)", SELF_TEST_OK, 0),
        ("прямая зависимость", SELF_TEST_BAD_DIRECT, 1),
        ("строчная запись словаря", SELF_TEST_BAD_INLINE, 1),
        ("через зависимый таргет", SELF_TEST_BAD_VIA_TARGET, 1),
        ("строка в кавычках после тега !!str", SELF_TEST_BAD_TAGGED, 1),
        ("строка в кавычках после якоря &core", SELF_TEST_BAD_ANCHORED, 1),
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

    clean_symbols = ["_main", "_$s10DomainCore3JobV2id10Foundation4UUIDVvg"]
    bad_symbols = clean_symbols + ["_$s13DomainTestKit21InMemoryJobRepositoryCMa"]
    clean_inputs = ["/dd/Build/Products/Debug/DomainCore.o", "/dd/Build/Products/Debug/Storage.o"]
    bad_inputs = clean_inputs + ["/dd/Build/Products/Debug/DomainTestKit.o"]
    app_cases = [
        # Подменный nm отдаёт символы обоим Mach-O бандла (App и XPC) — нарушений два.
        ("--app: чисто (символы и входы линковщика)", clean_symbols, clean_inputs, 0),
        ("--app: символы DomainTestKit в Mach-O (подменный nm)", bad_symbols, clean_inputs, 2),
        ("--app: DomainTestKit.o во входах линковщика, символы выброшены", clean_symbols, bad_inputs, 1),
    ]
    for title, symbols, inputs, expected in app_cases:
        with tempfile.TemporaryDirectory() as tmp:
            app = make_fake_build(tmp, inputs)
            got = len(check_app(app, run=fake_nm(symbols)))
        ok = got == expected
        failed += 0 if ok else 1
        print(f"self-test {'ok' if ok else 'FAIL'}: {title} — нарушений {got}, ожидалось {expected}")

    # Каталог входов линковщика: явный — обязан быть и содержать списки; выведенный — нет.
    intermediates_cases = [
        ("--app: явный --intermediates, которого нет — отказ", "missing", 1),
        ("--app: явный --intermediates без LinkFileList таргетов бандла — отказ", "empty", 1),
        ("--app: явный --intermediates со списками — чисто", "build", 0),
        ("--app: выведенного Intermediates.noindex нет — ::warning, не отказ", None, 0),
    ]
    for title, mode, expected in intermediates_cases:
        with tempfile.TemporaryDirectory() as tmp:
            app = make_fake_build(tmp, clean_inputs)
            build_dir = os.path.join(tmp, "Build", "Intermediates.noindex")
            empty_dir = os.path.join(tmp, "Empty")
            os.makedirs(empty_dir)
            explicit = {"missing": os.path.join(tmp, "Nope"), "empty": empty_dir,
                        "build": build_dir, None: None}[mode]
            if mode is None:
                shutil.rmtree(build_dir)
            got = len(check_app(app, intermediates=explicit, run=fake_nm(clean_symbols)))
        ok = got == expected
        failed += 0 if ok else 1
        print(f"self-test {'ok' if ok else 'FAIL'}: {title} — нарушений {got}, ожидалось {expected}")
    return failed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project")
    parser.add_argument("--app")
    parser.add_argument("--intermediates",
                        help="Build/Intermediates.noindex сборки бандла (по умолчанию выводится из --app)")
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
        violations += check_app(args.app, intermediates=args.intermediates)

    for v in violations:
        print(f"::error title=DomainTestKit в App (MEE-430 §3)::{v}")
    if violations:
        sys.exit(1)
    print(f"{FORBIDDEN} в {ROOT_TARGET} не попадает")


if __name__ == "__main__":
    main()
