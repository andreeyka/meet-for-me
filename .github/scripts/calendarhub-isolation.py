#!/usr/bin/env python3
# Владелец файла — архитектор (RP, приёмка #129, п. 1, явное поручение DEV-1
# — до этого возврата CI-механизма не было вовсе, только ручной grep).
#
# К58/К59 перечня MEE-347 (module-map.md, раздел «МОДУЛЬ: calendar-hub»,
# «Запрещено»): исходники `CalendarHub` (вне тестов/фикстур)
#   * К58 — не импортируют ничего, кроме `Foundation` и `DomainCore`;
#   * К59 — не содержат литеральных строк `"eventkit"`/`"graph"` и не
#     ветвятся по `ConnectorRecord.type`/`CalendarSourceId.rawValue`
#     содержательно (эта, третья часть К59 — сравнение по СОДЕРЖАНИЮ веток
#     if/switch — механически не формализуется тем же способом, что первые
#     две; остаётся за К20, уже проверяющим предпочтение строковым
#     сравнением дословно, — тем же разделением, что несёт сам текст К59).
#
# Способ: построчный разбор файла, не полный лексер Swift. Строковый литерал
# ищется ПОСЛЕ вычёркивания комментариев — без этого шаг падал бы на
# собственных же doc-комментариях модуля (они дословно называют
# `calendar-eventkit` как единственного сегодняшнего реализатора
# `CalendarConnector`).
#
# ЧЕГО ЭТОТ СПОСОБ НЕ ЛОВИТ. Литерал, собранный конкатенацией
# (`"event" + "kit"`) или интерполяцией — вне зоны действия построчного
# grep'а; тот же класс ограничения, что `undefined-symbols.py` называет для
# своего способа. `//` внутри строкового литерала (например, в URL) увёл бы
# вычёркивание комментария внутрь литерала — в исходниках `CalendarHub` на
# сегодня такого нет (сверено вручную), и находка такого случая — отказ
# self-test'а на будущее, а не немая порча.

import argparse
import glob
import re
import sys

ALLOWED_IMPORTS = {"Foundation", "DomainCore"}
FORBIDDEN_LITERAL_SUBSTRINGS = ("eventkit", "graph")

IMPORT_RE = re.compile(r"^\s*import\s+(\w+)")
STRING_LITERAL_RE = re.compile(r'"([^"\\]|\\.)*"')


def strip_comments(text):
    """Убирает `//`-комментарии (включая `///`) и `/* ... */` (в т.ч. многострочные)
    ДО поиска строковых литералов — иначе шаг ловил бы слово `eventkit` в
    собственных doc-комментариях модуля, а не в коде.
    """
    without_block = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    lines = []
    for line in without_block.splitlines():
        idx = line.find("//")
        lines.append(line[:idx] if idx != -1 else line)
    return "\n".join(lines)


def find_forbidden_imports(text):
    """Модули из `import X`, не входящие в ALLOWED_IMPORTS — К58."""
    found = []
    for line in strip_comments(text).splitlines():
        match = IMPORT_RE.match(line)
        if match and match.group(1) not in ALLOWED_IMPORTS:
            found.append(match.group(1))
    return found


def find_forbidden_literals(text):
    """Строковые литералы, содержащие `eventkit`/`graph` без учёта регистра — К59."""
    found = []
    for match in STRING_LITERAL_RE.finditer(strip_comments(text)):
        literal = match.group(0)
        lowered = literal.lower()
        for substring in FORBIDDEN_LITERAL_SUBSTRINGS:
            if substring in lowered:
                found.append((literal, substring))
    return found


def violations_for_text(text):
    violations = []
    for module in find_forbidden_imports(text):
        violations.append("import %s запрещён (К58 — только Foundation/DomainCore)" % module)
    for literal, substring in find_forbidden_literals(text):
        violations.append("литерал %s содержит запрещённую подстроку %r (К59)" % (literal, substring))
    return violations


def check_file(path):
    with open(path, "r", encoding="utf-8") as handle:
        return violations_for_text(handle.read())


def run(args):
    paths = sorted(glob.glob(args.sources_glob))
    if not paths:
        print(
            "::error title=Изоляция calendar-hub (К58/К59)::файлов по маске `%s` не найдено — "
            "проверка не может утверждать ничего" % args.sources_glob
        )
        return 1

    total_violations = 0
    print("## Изоляция calendar-hub: К58 (импорты) + К59 (литералы коннекторов)\n")
    for path in paths:
        violations = check_file(path)
        if not violations:
            continue
        total_violations += len(violations)
        for violation in violations:
            print("::error title=Изоляция calendar-hub · %s::%s: %s" % (args.job, path, violation))
        print("* `%s` — %d" % (path, len(violations)))
        for violation in violations:
            print("  * %s" % violation)

    if total_violations:
        print(
            "::notice title=Изоляция calendar-hub · %s::нарушений %d в %d файлах"
            % (args.job, total_violations, len(paths))
        )
        print("\n### Отказ: нарушений %d\n" % total_violations)
        return 1

    print(
        "::notice title=Изоляция calendar-hub · %s::нарушений 0 — %d файлов, "
        "только Foundation/DomainCore, без литералов eventkit/graph"
        % (args.job, len(paths))
    )
    print("\n### Нарушений нет (файлов: %d)\n" % len(paths))
    return 0


def self_test():
    cases = [
        ("import Foundation\nimport DomainCore\n", [], "разрешённые импорты — чисто"),
        ("import EventKit\n", ["import EventKit запрещён (К58 — только Foundation/DomainCore)"], "запрещённый импорт"),
        (
            '// calendar-eventkit — единственный реализатор CalendarConnector\nimport Foundation\n',
            [],
            "слово в комментарии не считается — вычёркивается до поиска",
        ),
        (
            'let type = "eventkit"\n',
            ['литерал "eventkit" содержит запрещённую подстроку \'eventkit\' (К59)'],
            "литерал eventkit — нарушение",
        ),
        (
            'let kind = "Graph"\n',
            ['литерал "Graph" содержит запрещённую подстроку \'graph\' (К59)'],
            "литерал без учёта регистра — нарушение",
        ),
        ('let ok = "shared-uid"\n', [], "литерал без запрещённой подстроки — чисто"),
    ]
    failures = 0
    for text, expected_messages, label in cases:
        violations = violations_for_text(text)
        if violations != expected_messages:
            print(
                "ОТКАЗ self-test (%s): получено %r, ожидалось %r" % (label, violations, expected_messages)
            )
            failures += 1
    print("self-test calendarhub-isolation: случаев %d, отказов %d" % (len(cases), failures))
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(
        description="Изоляция calendar-hub от конкретных коннекторов — К58/К59 перечня MEE-347"
    )
    parser.add_argument(
        "--sources-glob", default="Packages/Core/Sources/CalendarHub/*.swift",
        help="маска исходников (по умолчанию — продуктовые файлы calendar-hub, не тесты/фикстуры)"
    )
    parser.add_argument("--job", default="", help="имя работы CI, для заголовка отчёта и аннотаций")
    parser.add_argument("--self-test", action="store_true", help="проверить сверку находок и выйти")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
