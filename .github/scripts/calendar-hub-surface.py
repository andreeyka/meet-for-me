#!/usr/bin/env python3
# Владелец файла — архитектор (MEE-412).
#
# К58/К59 перечня MEE-347 (calendar-hub, C-005/C-006):
#
#   К58. («Запрещено: импорт EventKit и любых Apple-фреймворков сверх
#   Foundation») Ни один файл `Packages/Core/Sources/CalendarHub/*.swift` не
#   содержит `import`, ведущего на что-либо, кроме `Foundation` и
#   `DomainCore`. — мех.
#
#   К59. («Запрещено: знание о конкретных коннекторах») Исходники
#   `CalendarHub` (вне тестов/фикстур) не содержат литеральных строк
#   `"eventkit"`, `"graph"`, не ветвятся по `ConnectorRecord.type`/
#   `CalendarSourceId.rawValue` содержательно. — мех. + Т (К20 уже проверяет
#   предпочтение по строковому сравнению, не по содержательному имени).
#
# До этого файла оба критерия держались только на ручном grep исполнителя на
# приёмке (находка PR #129, MEE-386) — в CI механизма не было ни одного.
#
# «Содержательно» в К59 — граница, которую этот файл проводит намеренно
# узко: сравнение `.type`/`.rawValue` с ДРУГИМ ДИНАМИЧЕСКИМ значением того же
# поля (например, тай-брейк `lhs.sourceConnectorId < rhs.sourceConnectorId` в
# правиле слияния C-005) законно и К59 не запрещён — это «строковое
# сравнение», не проверка «а какой именно это коннектор». Запрещено сравнение
# с ЛИТЕРАЛОМ: `.type == "eventkit"`, `case "graph":` и подобное — там код
# знает конкретное имя коннектора, а не просто сравнивает две строки.
# Отсюда: проверка ищет `.type`/`.rawValue` рядом с `==`/`!=`/`case` и
# СТРОКОВЫМ ЛИТЕРАЛОМ на другой стороне — не любое употребление этих полей.

import argparse
import glob
import os
import re
import sys
import tempfile

ALLOWED_IMPORTS = {"Foundation", "DomainCore"}

# Допускает необязательные атрибуты (`@preconcurrency`, `@testable`,
# `@_exported`, `@_spi(SomeModule)`, ...) перед `import`, необязательный
# модификатор доступа Swift 6 (`public`/`package`/`internal`/`fileprivate`/
# `private import ...`), необязательное ключевое слово вида импорта
# (`import struct EventKit.EKEvent` и т.п.), хвостовой `;`, произвольное
# число хвостовых блочных комментариев (`/* a */`, в т.ч. без пробела и по
# два подряд) и хвостовой строчный комментарий (`// ...`) после них —
# находки РП по PR #133/#150 (MEE-412): исходная `^\s*import\s+(\S+)\s*$`
# не прощала ни одной из первых трёх форм; хвостовые `;`/`/* */` — правкой
# после того; атрибут БЕЗ пробела перед `import` (`@_spi(A)import ...` —
# legal, скобка сама служит границей токена) и модификатор доступа —
# возвратом РП после #150.
#
# Атрибут без аргумента (`@testable`) требует пробела перед `import` —
# без него имя атрибута и `import` слились бы в один идентификатор что в
# реальном Swift и не компилируется; атрибут С аргументом в скобках
# (`@_spi(A)`) пробела не требует — скобка сама разделяет токены.
_ATTR = r"(?:@\w+\([^)]*\)\s*|@\w+\s+)*"
_ACCESS = r"(?:(?:public|package|internal|fileprivate|private)\s+)?"
_KIND = r"(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?"
_TAIL = r"\s*;?\s*(?:/\*.*?\*/\s*)*(?://.*)?$"
IMPORT_RE = re.compile(
    r"^\s*" + _ATTR + _ACCESS + r"import\s+" + _KIND + r"([A-Za-z0-9_.]+)" + _TAIL
)

# Проверка строгая по умолчанию (возврат РП после #150): строка, ПОХОЖАЯ на
# начало импорта — с той же необязательной шапкой атрибутов/модификатора
# доступа, — но не разобранная `IMPORT_RE` целиком (два импорта в одной
# строке, незакрытый `/*`, любая другая форма, которую не предвидели), это
# сама по себе находка: код, который наш разборщик не понял, а не молчаливый
# пропуск. Раньше `check_imports` такую строку просто пропускала мимо.
LOOSE_IMPORT_RE = re.compile(r"^\s*" + _ATTR + _ACCESS + r"import\b")

# Литералы имени коннектора — точное совпадение "eventkit"/"graph", либо
# префикс "graph:" (module-map называет реальный rawValue `"graph:work"`).
# Регистронезависимо (РП, PR #133): "EventKit"/"Graph" — то же знание.
CONNECTOR_LITERAL_RE = re.compile(r'"(eventkit|graph(:[^"]*)?)"', re.IGNORECASE)

# `.type`/`.rawValue` на одной стороне сравнения со строковым литералом на
# другой — в любом порядке; `case "литерал":` как ветвь switch; и то же
# самое содержательное знание через `.hasPrefix`/`.hasSuffix`/`.contains`/
# `.starts(with:)` над `.type`/`.rawValue` (РП, PR #133 — раньше был учтён
# только `.hasPrefix`).
CONTENT_BRANCH_RES = [
    re.compile(r"\.(type|rawValue)\s*(==|!=)\s*\"[^\"]*\""),
    re.compile(r"\"[^\"]*\"\s*(==|!=)\s*[\w.]*\.(type|rawValue)\b"),
    re.compile(r"\.(type|rawValue)\.(hasPrefix|hasSuffix|contains)\(\s*\""),
    re.compile(r"\.(type|rawValue)\.starts\(with:\s*\""),
    re.compile(r"case\s+\"[^\"]*\"\s*:"),
]


def swift_files(sources_dir):
    """Файлы `*.swift` каталога, не рекурсивно — К58/К59 названы по
    `CalendarHub/*.swift`, а не по дереву; подкаталогов у этого модуля нет,
    но проверка не должна тихо расшириться на тесты/фикстуры, появись они
    когда-нибудь внутри Sources рядом."""
    return sorted(glob.glob(os.path.join(sources_dir, "*.swift")))


def check_imports(path, lines):
    violations = []
    for lineno, line in enumerate(lines, start=1):
        m = IMPORT_RE.match(line)
        if not m:
            if LOOSE_IMPORT_RE.match(line):
                violations.append(
                    (path, lineno, "строка похожа на import, но не разобрана целиком: %s" % line.strip())
                )
            continue
        module_path = m.group(1)
        # `import Foundation.NSDate` / `import struct Foundation.Date` — тот
        # же модуль `Foundation`, member-import; судим по части до первой
        # точки, а не по всей строке (РП, PR #133: без этого — ложный отказ).
        top_level = module_path.split(".", 1)[0]
        if top_level not in ALLOWED_IMPORTS:
            violations.append((path, lineno, "import %s" % module_path))
    return violations


def check_content_branching(path, lines):
    # Построчный текстовый поиск, без разбора комментариев/строк как грамматики
    # Swift — тот же приём, что `scan_exported_imports` в symbol-graph-surface.py.
    # Совпадение внутри `//`-комментария тоже считается находкой: мех. проверка
    # ловит текст, а решение, довод это или запрещённое место, — за исполнителем.
    violations = []
    for lineno, line in enumerate(lines, start=1):
        lit = CONNECTOR_LITERAL_RE.search(line)
        if lit:
            violations.append((path, lineno, "литерал коннектора %s" % lit.group(0)))
        for pattern in CONTENT_BRANCH_RES:
            if pattern.search(line):
                violations.append((path, lineno, "содержательное ветвление: %s" % line.strip()))
                break
    return violations


def scan(sources_dir):
    import_violations = []
    branch_violations = []
    files = swift_files(sources_dir)
    for path in files:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
        import_violations.extend(check_imports(path, lines))
        branch_violations.extend(check_content_branching(path, lines))
    return files, import_violations, branch_violations


def run(args):
    files, import_violations, branch_violations = scan(args.sources)
    if not files:
        print(
            "::error title=К58/К59 calendar-hub · %s::в `%s` не найдено ни одного `*.swift` — "
            "проверка не может утверждать ничего" % (args.job, args.sources)
        )
        return 1

    print("## К58/К59 (MEE-347): поверхность calendar-hub\n")
    print("Файлов проверено: **%d**.\n" % len(files))
    for path in files:
        print("* `%s`" % path)
    print("")

    violations = import_violations + branch_violations
    if violations:
        for path, lineno, why in import_violations:
            print(
                "::error title=К58 calendar-hub · %s::%s:%d — %s (разрешены только Foundation и DomainCore)"
                % (args.job, path, lineno, why)
            )
        for path, lineno, why in branch_violations:
            print(
                "::error title=К59 calendar-hub · %s::%s:%d — %s"
                % (args.job, path, lineno, why)
            )
        print("\n### Отказ: нарушений %d (К58: %d, К59: %d)\n" % (
            len(violations), len(import_violations), len(branch_violations)
        ))
        for path, lineno, why in violations:
            print("* `%s:%d` — %s" % (path, lineno, why))
        return 1

    print(
        "::notice title=К58/К59 calendar-hub · %s::нарушений нет — %d файлов, "
        "импорты только Foundation/DomainCore, знания о конкретных коннекторах не найдено"
        % (args.job, len(files))
    )
    print("\n### Нарушений нет\n")
    return 0


def self_test():
    import_cases = [
        ("import Foundation\n", []),
        ("import DomainCore\n", []),
        ("import GRDB\n", ["import GRDB"]),
        ("import EventKit\n", ["import EventKit"]),
        ("    import Foundation\n", []),  # отступ внутри #if — тоже импорт
        ("// import GRDB\n", []),  # закомментированный импорт — не совпадает с ^\\s*import
        ("importantThing = 1\n", []),  # не строка import вовсе
        ("@preconcurrency import EventKit\n", ["import EventKit"]),  # РП, PR #133
        ("@testable import EventKit\n", ["import EventKit"]),  # РП, PR #133
        ("@_exported import EventKit\n", ["import EventKit"]),  # РП, PR #133
        ("import struct EventKit.EKEvent\n", ["import EventKit.EKEvent"]),  # РП, PR #133
        ("import EventKit // комментарий\n", ["import EventKit"]),  # РП, PR #133
        ("import Foundation.NSDate\n", []),  # РП, PR #133: ложный отказ до фикса
        ("import struct Foundation.Date\n", []),  # РП, PR #133
        ("@_spi(SomeModule) import EventKit\n", ["import EventKit"]),  # РП, возврат по PR #133
        ("import EventKit;\n", ["import EventKit"]),  # РП, возврат по PR #133: хвостовой `;`
        ("import EventKit; // комментарий\n", ["import EventKit"]),  # `;` и `//` вместе
        ("import EventKit /* комментарий */\n", ["import EventKit"]),  # РП: хвостовой `/* */`
        ("import EventKit; /* комментарий */\n", ["import EventKit"]),  # `;` и `/* */` вместе
        ("internal import EventKit\n", ["import EventKit"]),  # РП, возврат после #150: модификатор доступа Swift 6
        ("public import EventKit\n", ["import EventKit"]),  # РП, возврат после #150
        ("internal import Foundation\n", []),  # модификатор доступа + разрешённый модуль
        ("import EventKit /* a */ // b\n", ["import EventKit"]),  # РП: блочный и строчный комментарий вместе
        ("import Foundation /* x */\n", []),  # РП: разрешённая форма из примера
        ("@_spi(A)import EventKit\n", ["import EventKit"]),  # РП: без пробела перед import — скобка сама граница
        ("@_spi(X) import Foundation;\n", []),  # РП: разрешённая форма из примера
        ("import EventKit /* a *//* b */\n", ["import EventKit"]),  # РП: два блочных комментария подряд
        (
            "import EventKit /* unclosed\n",
            ["строка похожа на import, но не разобрана целиком: import EventKit /* unclosed"],
        ),  # РП: незакрытый /* — строгая проверка ловит, а не молчит
        (
            "import EventKit; import Foundation\n",
            ["строка похожа на import, но не разобрана целиком: import EventKit; import Foundation"],
        ),  # РП: два импорта в одной строке
    ]
    failures = 0
    for line, expected_modules in import_cases:
        got = [v[2] for v in check_imports("t.swift", [line])]
        if got != expected_modules:
            print("ОТКАЗ self-test: check_imports(%r) вернул %r, ожидалось %r" % (line, got, expected_modules))
            failures += 1
    print("self-test check_imports: случаев %d, отказов %d" % (len(import_cases), failures))

    branch_cases = [
        ('let x = CalendarSourceId(rawValue: "eventkit")\n', True),  # литерал коннектора
        ('let x = CalendarSourceId(rawValue: "graph:work")\n', True),  # литерал с префиксом
        ('if record.type == "eventkit" {\n', True),  # содержательное сравнение с литералом
        ("switch source.rawValue {\n", False),  # заголовок switch сам по себе безобиден
        ('case "graph":\n', True),  # а вот ветвь case с литералом — да
        ("lhs.sourceConnectorId < rhs.sourceConnectorId\n", False),  # тай-брейк C-005 — два динамических значения
        ('newSource.sourceConnectorId == existing.sourceConnectorId\n', False),  # сравнение двух полей, не литерала
        ("record.type, pluginId: record.pluginId\n", False),  # копирование поля, не сравнение (CalendarPortImpl.swift:388)
        ('source.rawValue.hasPrefix("graph")\n', True),  # содержательная проверка префикса
        ('source.type.hasSuffix("Kit")\n', True),  # РП, PR #133
        ('source.rawValue.contains("graph")\n', True),  # РП, PR #133
        ('source.type.starts(with: "eventkit")\n', True),  # РП, PR #133
        ('if record.type == "EventKit" {\n', True),  # РП, PR #133: литерал регистронезависимо
        ("lhs.rawValue.hasPrefix(rhs.rawValue)\n", False),  # префикс двух динамических значений — не литерал
    ]
    branch_failures = 0
    for line, expect_violation in branch_cases:
        got = bool(check_content_branching("t.swift", [line]))
        if got != expect_violation:
            print("ОТКАЗ self-test: check_content_branching(%r) вернул нарушение=%r, ожидалось %r"
                  % (line, got, expect_violation))
            branch_failures += 1
    print("self-test check_content_branching: случаев %d, отказов %d" % (len(branch_cases), branch_failures))

    # Настоящая файловая система: заведомо нарушающая фикстура должна дать
    # отказ той же функцией `run`, которую вызывает CI, — не только сверка
    # регулярных выражений по отдельности, но и весь путь «каталог → отчёт →
    # код возврата», как в self-test'ах symbol-graph-surface.py/undefined-symbols.py.
    scan_failures = 0
    with tempfile.TemporaryDirectory() as sources_dir:
        clean = os.path.join(sources_dir, "Clean.swift")
        with open(clean, "w", encoding="utf-8") as f:
            f.write("import Foundation\nimport DomainCore\n\nlet x = lhs.sourceConnectorId < rhs.sourceConnectorId\n")
        dirty = os.path.join(sources_dir, "Dirty.swift")
        with open(dirty, "w", encoding="utf-8") as f:
            f.write('import Foundation\nimport EventKit\n\nif record.type == "eventkit" { }\n')

        files, imp_v, branch_v = scan(sources_dir)
        if len(files) != 2:
            print("ОТКАЗ self-test: scan нашёл %d файлов, ожидалось 2" % len(files))
            scan_failures += 1
        if not any("EventKit" in v[2] for v in imp_v):
            print("ОТКАЗ self-test: scan не поймал `import EventKit` в заведомо нарушающей фикстуре")
            scan_failures += 1
        if not any('"eventkit"' in v[2] for v in branch_v):
            print("ОТКАЗ self-test: scan не поймал содержательное сравнение в заведомо нарушающей фикстуре")
            scan_failures += 1

        clean_only = os.path.join(sources_dir, "clean_only")
        os.makedirs(clean_only)
        with open(os.path.join(clean_only, "Clean.swift"), "w", encoding="utf-8") as f:
            f.write("import Foundation\nimport DomainCore\n")
        files2, imp_v2, branch_v2 = scan(clean_only)
        if imp_v2 or branch_v2:
            print("ОТКАЗ self-test: scan нашёл нарушения %r/%r в заведомо чистой фикстуре" % (imp_v2, branch_v2))
            scan_failures += 1
    print("self-test scan (файловая фикстура, чистая и нарушающая): отказов %d" % scan_failures)

    return 1 if failures or branch_failures or scan_failures else 0


def main():
    parser = argparse.ArgumentParser(
        description="К58/К59 перечня MEE-347 — импорты и знание о коннекторах в calendar-hub"
    )
    parser.add_argument("--sources", help="каталог Packages/Core/Sources/CalendarHub")
    parser.add_argument("--job", default="", help="имя работы CI, для заголовка отчёта и аннотаций")
    parser.add_argument("--self-test", action="store_true", help="проверить сверку находок и выйти")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.sources:
        parser.error("--sources обязателен без --self-test")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
