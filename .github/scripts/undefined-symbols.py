#!/usr/bin/env python3
# Владелец файла — архитектор (MEE-191).
#
# Разбор таблицы неопределённых символов таргета — способ, названный самим
# инвариантом 27 C-010 (MEE-18, «Чем проверяется»): «Собственного декодера в
# модуле нет (инвариант 27) — разбор таблицы неопределённых символов таргета
# Storage: JSONDecoder.init и JSONEncoder.init среди них отсутствуют».
#
# До этого файла в ci.yml для такой проверки не было ни одного шага — это
# критерий К44 перечня MEE-189, и единственный существовавший разбор
# (symbol-graph-surface.py) снимает ПУБЛИЧНУЮ ПОВЕРХНОСТЬ таргета: что модуль
# ПОКАЗЫВАЕТ наружу. Здесь — другая таблица и другой вопрос: что сам таргет
# ВЫЗЫВАЕТ у чужого кода. Метод общий для обеих задач (USR/символы из
# object-файлов), а таблица — разная, и путать их означало бы повторить
# ошибку, которую сам MEE-191 называет («контракт называет способ, механизм
# проверяет другое»).
#
# Способ: `nm -u` по object-файлам САМОГО таргета — до линковки, пока вызов
# функции из Foundation ещё виден как неопределённый символ в объектнике
# Storage, а не разрешён в адрес libFoundation. Символы деманглятся
# (`swift demangle`), потому что мангленное имя меняется между версиями ABI,
# а человекочитаемое — нет.
#
# ЧЕГО ЭТОТ СПОСОБ НЕ ЛОВИТ. Косвенный вызов (Storage зовёт свою функцию-
# обёртку, которая зовёт JSONDecoder) не даёт неопределённого символа с
# именем JSONDecoder в объектнике САМОГО Storage — он появится в объектнике
# обёртки. Если такая обёртка когда-нибудь появится вне Storage, но с той же
# целью «обойти DomainJSON», этот шаг её не увидит: он проверяет ровно то,
# что называет инвариант 27, — прямой вызов из таргета, а не транзitivное
# происхождение.

import argparse
import glob
import os
import subprocess
import sys

# Инвариант 27 C-010 запрещает ровно эти два конструктора — цитата дословная.
# Обе формы на каждый: `JSONDecoder()` в вызывающем коде компилируется в вызов
# АЛЛОЦИРУЮЩЕГО инициализатора класса (`__allocating_init`), а не голого
# `init` — назначенный инициализатор сам вызывается уже ВНУТРИ Foundation и
# наружу неопределённым символом не выходит. Прогон 35934656184 нашёл ровно
# `Foundation.JSONDecoder.__allocating_init()`, и подстрока `JSONDecoder.init`
# в нём не встречается (между `.` и `init` стоит `__allocating_`) — первая
# редакция эту форму пропускала молча. Голая `.init`-форма оставлена на
# случай менее обычного пути вызова (например, через протокол-метатип).
FORBIDDEN_CALLS = [
    "Foundation.JSONDecoder.init",
    "Foundation.JSONDecoder.__allocating_init",
    "Foundation.JSONEncoder.init",
    "Foundation.JSONEncoder.__allocating_init",
]


def find_object_files(build_dir, target):
    """Object-файлы одного таргета до линковки.

    Раскладка — легаси-сборка SwiftPM: `<build_dir>/**/<Target>.build/**/*.o`.
    Если раскладка сменится версией тулчейна, шаг обязан упасть явным
    отказом (пустой список ниже), а не молча решить, что проверять нечего.

    Дедуп по `realpath` — несущий, не украшение: `.build/debug` в SwiftPM
    сам есть симлинк на `.build/<triple>/debug` (прогон 35934656184 нашёл
    оба пути на один и тот же файл), и без дедупа отчёт вдвое завышал бы
    число объектников и число символов, не меняя вердикт по существу.
    """
    pattern = os.path.join(build_dir, "**", "%s.build" % target, "**", "*.o")
    seen_real = {}
    for path in glob.glob(pattern, recursive=True):
        seen_real.setdefault(os.path.realpath(path), path)
    return sorted(seen_real.values())


def undefined_symbol_names(object_files, run=subprocess.run):
    """Имена неопределённых символов по всем объектникам, без ведущего `_`."""
    names = set()
    for path in object_files:
        result = run(["nm", "-u", path], capture_output=True, text=True)
        for line in result.stdout.splitlines():
            line = line.strip()
            if line:
                names.add(line[1:] if line.startswith("_") else line)
    return names


def demangle(names, run=subprocess.run):
    """Мангленное имя → человекочитаемое, через `swift demangle` одним вызовом."""
    if not names:
        return {}
    ordered = sorted(names)
    proc = run(["swift", "demangle"], input="\n".join(ordered), capture_output=True, text=True)
    pretty = proc.stdout.splitlines()
    # `swift demangle` печатает строку на каждую строку входа, включая имена,
    # которые не размangleились (тогда возвращает их как есть) — счёт строк
    # обязан совпасть, иначе дальнейшая сверка по индексу молча съедет.
    if len(pretty) != len(ordered):
        raise SystemExit(
            "swift demangle вернул %d строк на %d имён — счёт разошёлся, дальше не сверяю"
            % (len(pretty), len(ordered))
        )
    return dict(zip(ordered, pretty))


def find_violations(pretty_by_mangled):
    """Какие из размангленных имён — запрещённый инвариантом 27 вызов."""
    return sorted(
        (mangled, pretty)
        for mangled, pretty in pretty_by_mangled.items()
        if any(forbidden in pretty for forbidden in FORBIDDEN_CALLS)
    )


def run(args):
    objects = find_object_files(args.build_dir, args.target)
    if not objects:
        print(
            "::error title=Неопределённые символы · %s::объектных файлов таргета `%s` не найдено "
            "в `%s` — раскладка сборки могла смениться, проверка не может утверждать ничего"
            % (args.job, args.target, args.build_dir)
        )
        return 1

    raw = undefined_symbol_names(objects)
    pretty_by_mangled = demangle(raw)
    violations = find_violations(pretty_by_mangled)

    print(
        "## Таблица неопределённых символов: %s (инвариант 27 C-010)\n" % args.target
    )
    print("Объектных файлов: **%d**. Неопределённых символов: **%d**.\n" % (len(objects), len(raw)))
    print("<details><summary>Object-файлы и символы поимённо</summary>\n")
    for path in objects:
        print("* `%s`" % path)
    print("")
    for mangled in sorted(pretty_by_mangled):
        print("* `%s`" % pretty_by_mangled[mangled])
    print("\n</details>\n")

    if violations:
        for mangled, pretty in violations:
            print(
                "::error title=Неопределённые символы · %s::`%s` собирает собственный вызов "
                "Foundation-декодера, запрещённый инвариантом 27 C-010 — %s" % (args.job, args.target, pretty)
            )
        print(
            "::notice title=Неопределённые символы · %s::нарушений %d — `%s` зовёт "
            "JSONDecoder.init/JSONEncoder.init напрямую вместо DomainJSON"
            % (args.job, len(violations), args.target)
        )
        print("\n### Отказ: нарушений %d\n" % len(violations))
        for mangled, pretty in violations:
            print("* %s" % pretty)
        return 1

    print(
        "::notice title=Неопределённые символы · %s::нарушений нет — `%s` не зовёт "
        "JSONDecoder.init/JSONEncoder.init напрямую (инвариант 27 C-010)" % (args.job, args.target)
    )
    print("\n### Нарушений нет\n")
    return 0


def self_test():
    """Сверка находит запрещённый вызов по подстроке в человекочитаемом имени,
    а не по мангленному — self-test проверяет это напрямую, без nm и без
    настоящего object-файла."""
    cases = [
        # Форма __allocating_init — дословно то, что нашёл прогон 35934656184
        # на настоящем `JSONDecoder()` в коде: designated `init` вызывается
        # внутри Foundation и наружу неопределённым символом не выходит,
        # видна только аллоцирующая обёртка. Первая редакция ловила только
        # (никогда не встречающуюся у вызывающей стороны) голую форму ниже и
        # эту, настоящую, пропускала молча — тот самый прогон это и поймал.
        ("$s10Foundation11JSONDecoderC4initACycfC",
         "Foundation.JSONDecoder.__allocating_init() -> Foundation.JSONDecoder", True),
        ("$s10Foundation11JSONEncoderC4initACycfC",
         "Foundation.JSONEncoder.__allocating_init() -> Foundation.JSONEncoder", True),
        # Голая форма — оставлена в списке FORBIDDEN_CALLS на случай менее
        # обычного пути вызова, но сама по себе ни разу не наблюдалась.
        ("$s10Foundation11JSONDecoderC4initACycfc", "Foundation.JSONDecoder.init() -> Foundation.JSONDecoder", True),
        ("$s10Foundation3URLV4initSS-", "Foundation.URL.init(_:)", False),
        ("$s7Storage10DomainJSON6decode", "Storage.DomainJSON.decode(_:from:)", False),
    ]
    pretty_by_mangled = {mangled: pretty for mangled, pretty, _ in cases}
    violations = dict(find_violations(pretty_by_mangled))
    failures = 0
    for mangled, pretty, expected in cases:
        got = mangled in violations
        if got != expected:
            print("ОТКАЗ self-test: %r (%r) ожидалось нарушение=%r, получено %r" % (mangled, pretty, expected, got))
            failures += 1
    print("self-test find_violations: случаев %d, отказов %d" % (len(cases), failures))

    class FakeCompletedProcess:
        def __init__(self, stdout):
            self.stdout = stdout
            self.returncode = 0

    def fake_run(cmd, capture_output, text, input=None):
        if cmd[:2] == ["nm", "-u"]:
            return FakeCompletedProcess("_$s10Foundation11JSONDecoderC4initACycfc\n_$sSS4initySSSgSg_tcfc\n")
        if cmd == ["swift", "demangle"]:
            lines = (input or "").splitlines()
            return FakeCompletedProcess("\n".join("DEMANGLED(%s)" % line for line in lines))
        raise AssertionError("непредвиденный вызов: %r" % (cmd,))

    names = undefined_symbol_names(["/fake/Storage.o"], run=fake_run)
    expected_names = {"$s10Foundation11JSONDecoderC4initACycfc", "$sSS4initySSSgSg_tcfc"}
    demangle_failures = 0
    if names != expected_names:
        print("ОТКАЗ self-test: undefined_symbol_names вернул %r, ожидалось %r" % (names, expected_names))
        demangle_failures += 1
    pretty = demangle(names, run=fake_run)
    if len(pretty) != 2 or any(not v.startswith("DEMANGLED(") for v in pretty.values()):
        print("ОТКАЗ self-test: demangle вернул %r" % (pretty,))
        demangle_failures += 1
    print("self-test undefined_symbol_names/demangle (через фиктивный nm): отказов %d" % demangle_failures)

    return 1 if failures or demangle_failures else 0


def main():
    parser = argparse.ArgumentParser(
        description="Таблица неопределённых символов таргета — инвариант 27 C-010, К44 MEE-189"
    )
    parser.add_argument("--build-dir", help="каталог сборки SwiftPM (например, Packages/Core/.build)")
    parser.add_argument("--target", help="имя таргета, например Storage")
    parser.add_argument("--job", default="", help="имя работы CI, для заголовка отчёта и аннотаций")
    parser.add_argument("--self-test", action="store_true", help="проверить сверку находок и выйти")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.build_dir or not args.target:
        parser.error("--build-dir и --target обязательны без --self-test")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
