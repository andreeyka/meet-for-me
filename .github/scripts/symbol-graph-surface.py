#!/usr/bin/env python3
# Владелец файла — разработчик CI (MEE-166).
#
# Шаг снимает символьный граф таргетов и разбирает публичную поверхность каждого.
# Способ назван самими контрактами: инвариант 25 C-004, инвариант 9 C-005,
# инвариант 21 C-006, инвариант 21 C-009, инвариант 19 C-010, инвариант 15 C-011,
# инвариант 23 C-012, инвариант 32 C-014, инварианты 19 и 20 C-015 — и критерием 45
# MEE-74. Полнее всех механизм расписан инвариантом 32 C-014, и код ниже следует ему.
#
# ЧЕГО ЗДЕСЬ НЕТ НАМЕРЕННО — разрешённых списков типов по таргетам.
# Списки выведены каждым контрактом из его раздела «Определение» и меняются вместе
# с ним. Копия списка в репозитории разошлась бы с оригиналом на первом же издании,
# и разошлась бы молча — то есть дала бы зелёный шаг при нарушенном контракте.
# Поэтому список остаётся в контракте, а шаг делает две вещи, которые выводятся
# из самого дерева и копии не требуют:
#   1) барьер по МОДУЛЮ объявления: тип в публичной сигнатуре обязан быть объявлен
#      в таргете этого репозитория либо в базовом наборе модулей (ниже);
#   2) выгрузка самой поверхности — по таргету, по модулю, поимённо, — чтобы
#      сверку с разрешённым списком контракта можно было сделать по выводу шага,
#      а не по чтению исходников.
# Барьер (1) строго слабее списков контрактов: см. --report и раздел «Не ловит».

import argparse
import json
import os
import re
import sys
from collections import defaultdict

# Базовый набор модулей. Это НЕ разрешённый список типов какого-либо контракта и не
# его замена: это модули, объявления которых не являются macOS-фреймворком и живут
# в любой из двух работ CI. Пополнять его — решение владельца CI, и каждая строка
# здесь обязана иметь довод.
BASELINE_MODULES = {
    "Swift",                            # стандартная библиотека
    "_Concurrency",                     # AsyncStream, Actor — часть поставки Swift
    "_StringProcessing",                # поставляется со стандартной библиотекой
    "Foundation",                       # URL, Date, UUID, Data — есть на обеих платформах
    "FoundationEssentials",             # раскладка Foundation в swift-foundation
    "FoundationInternationalization",   # то же
    "FoundationNetworking",             # Linux-половина Foundation; C-014 §6 её и называет
}

# Единственное место, где шаг называет таргет по имени. Основание — инвариант 32
# C-014 дословно: «`@_exported import` любого модуля … запрещён здесь дословно»,
# и там же: «запрет обязан проверяться чтением строк `import`, потому что графом
# он не проверяется». Ни один другой контракт такого запрета не делает, поэтому для
# остальных таргетов находка выводится замечанием, а не отказом.
EXPORTED_IMPORT_FORBIDDEN_IN = {"ModelManager"}

PUBLIC_LEVELS = {"public", "open"}
MODULE_PREFIX = re.compile(r"^(\d+)")


def module_of(usr):
    """Модуль объявления по USR. Возвращает имя модуля либо None, если не разобран.

    В USR закодирован модуль объявления: `s:11DomainCore9ModelRoleO` — DomainCore,
    `s:10Foundation3URLV` — Foundation (инвариант 32 C-014). Число перед именем —
    его длина в байтах, и читается она буквально. Односимвольные
    подстановки (`Si`, `SS`, `Sa`, `s5Int32V`) принадлежат стандартной библиотеке.
    """
    if not usr:
        return None
    if usr.startswith("c:"):
        # Символ, импортированный из C/Objective-C: EKEventStore, NSXPCConnection и т. п.
        return "<C/ObjC>"
    if not usr.startswith("s:"):
        return None
    rest = usr[2:]
    while rest.startswith("e:"):   # граф расширения
        rest = rest[2:]
    match = MODULE_PREFIX.match(rest)
    if match:
        length = int(match.group(1))
        name = rest[match.end():match.end() + length]
        return name or None
    if rest.startswith("s"):       # подстановка модуля Swift: s5Int32V, s8SendableP
        return "Swift"
    if rest.startswith("Sc"):      # подстановка модуля _Concurrency: ScS, ScA
        return "_Concurrency"
    if rest.startswith("S"):       # Si, SS, Sa, Sb, Sd, Sq, SD, SH, SQ, SL …
        return "Swift"
    return None


def load_graphs(graph_dir):
    """Читает *.symbols.json. Возвращает (графы по таргетам, множество таргетов репозитория)."""
    graphs = defaultdict(list)
    if not os.path.isdir(graph_dir):
        return graphs, set()
    for name in sorted(os.listdir(graph_dir)):
        if not name.endswith(".symbols.json"):
            continue
        owner = name[: -len(".symbols.json")].split("@", 1)[0]
        with open(os.path.join(graph_dir, name), encoding="utf-8") as handle:
            graphs[owner].append((name, json.load(handle)))
    return graphs, set(graphs.keys())


def surface_of(graph_files):
    """Публичная поверхность одного таргета.

    Возвращает (число публичных объявлений, {USR: имя}, [объявляемые символы]).
    Идентификатор самого объявляемого символа исключается — иначе публичный тип
    модуля-реализатора даёт ложный красный на собственном имени (критерий 45 MEE-74,
    те же две оговорки стоят в инварианте 10 C-007 и в допуске (в) инварианта 32 C-014).
    """
    declared = []
    referenced = {}
    public_usrs = set()

    for _, graph in graph_files:
        for symbol in graph.get("symbols", []):
            if symbol.get("accessLevel") not in PUBLIC_LEVELS:
                continue
            own = symbol.get("identifier", {}).get("precise")
            public_usrs.add(own)
            declared.append({
                "usr": own,
                "kind": symbol.get("kind", {}).get("identifier", "?"),
                "path": ".".join(symbol.get("pathComponents", [])) or "?",
            })
            for fragment in symbol.get("declarationFragments", []):
                precise = fragment.get("preciseIdentifier")
                if not precise or precise == own:
                    continue
                referenced.setdefault(precise, fragment.get("spelling", precise))

    # Списки наследования и соответствия приезжают отдельно (инвариант 32 C-014).
    for _, graph in graph_files:
        for relation in graph.get("relationships", []):
            if relation.get("kind") not in ("conformsTo", "inheritsFrom"):
                continue
            if relation.get("source") not in public_usrs:
                continue
            target = relation.get("target")
            if not target or target in public_usrs:
                continue
            fallback = relation.get("targetFallback") or target
            referenced.setdefault(target, fallback.split(".")[-1])

    return len(declared), referenced, declared


def scan_exported_imports(sources_dirs):
    """Чтение строк import: `@_exported import` графом не проверяется (инвариант 32 C-014)."""
    found = []
    pattern = re.compile(r"^\s*@_exported\s+import\s+(\S+)")
    for root_dir in sources_dirs:
        for root, _, files in os.walk(root_dir):
            for name in sorted(files):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(root, name)
                with open(path, encoding="utf-8", errors="replace") as handle:
                    for number, line in enumerate(handle, 1):
                        match = pattern.match(line)
                        if match:
                            found.append((path, number, match.group(1)))
    return found


def target_of_path(path):
    parts = path.replace("\\", "/").split("/")
    if "Sources" in parts:
        index = parts.index("Sources")
        if index + 1 < len(parts):
            return parts[index + 1]
    return "?"


def run(args):
    graphs, own_modules = load_graphs(args.graph_dir)
    lines = []
    violations = []
    notices = []

    lines.append("## Символьный граф: публичная поверхность — %s" % args.job)
    lines.append("")
    if not graphs:
        lines.append("Граф пуст: файлов `*.symbols.json` в `%s` нет ни одного." % args.graph_dir)
        lines.append("")
        lines.append("Это не отказ: граф есть артефакт сборки, и на таргете без "
                     "публичных объявлений он пуст (инвариант 32 C-014).")
    else:
        lines.append("Таргетов с графом: **%d**. Модули репозитория, известные шагу: %s."
                     % (len(graphs), ", ".join("`%s`" % m for m in sorted(own_modules))))
        lines.append("")
        lines.append("| Таргет | Публичных объявлений | Типов в сигнатурах | Модули объявления |")
        lines.append("| -- | -- | -- | -- |")

    for target in sorted(graphs):
        count, referenced, _ = surface_of(graphs[target])
        by_module = defaultdict(set)
        for usr, spelling in referenced.items():
            by_module[module_of(usr) or "<не разобран: %s>" % usr].add(spelling)
        for module in sorted(by_module):
            if module in own_modules or module in BASELINE_MODULES:
                continue
            for spelling in sorted(by_module[module]):
                violations.append((target, module, spelling))
        shown = ", ".join(
            "`%s`%s" % (module, "" if module in own_modules or module in BASELINE_MODULES else " ❌")
            for module in sorted(by_module)
        ) or "—"
        lines.append("| `%s` | %d | %d | %s |" % (target, count, len(referenced), shown))

    if graphs:
        lines.append("")
        lines.append("<details><summary>Поверхность поимённо</summary>")
        lines.append("")
        for target in sorted(graphs):
            count, referenced, declared = surface_of(graphs[target])
            lines.append("**`%s`** — публичных объявлений %d." % (target, count))
            if count == 0:
                lines.append("")
                lines.append("* объявлений нет; на пустом таргете граф пуст, и это не отказ.")
            else:
                own_named = ", ".join("`%s`" % d["path"] for d in declared[:40])
                lines.append("")
                lines.append("* объявляет: %s%s" % (own_named, " …" if count > 40 else ""))
                by_module = defaultdict(set)
                for usr, spelling in referenced.items():
                    by_module[module_of(usr) or "<не разобран>"].add(spelling)
                for module in sorted(by_module):
                    lines.append("* из `%s`: %s"
                                 % (module, ", ".join("`%s`" % s for s in sorted(by_module[module]))))
            lines.append("")
        lines.append("</details>")

    exported = scan_exported_imports(args.sources)
    lines.append("")
    if exported:
        for path, number, module in exported:
            target = target_of_path(path)
            record = (target, "@_exported import %s" % module, "%s:%d" % (path, number))
            if target in EXPORTED_IMPORT_FORBIDDEN_IN:
                violations.append(record)
            else:
                notices.append(record)
        lines.append("Строк `@_exported import` найдено: **%d**." % len(exported))
    else:
        lines.append("Строк `@_exported import` в исходниках нет ни одной (проверено чтением "
                     "строк `import`: графом этот запрет не проверяется — инвариант 32 C-014).")

    lines.append("")
    lines.append("**Чего этот шаг не ловит** — сказано здесь, а не подразумевается:")
    lines.append("")
    lines.append("* **разрешённые списки типов контрактов.** Шаг сверяет модуль объявления, "
                 "а не позицию в списке: `Data` и `Process` из `Foundation` он пропускает "
                 "везде, хотя список инварианта 9 C-005 их не содержит. Сверку списка делает "
                 "приёмка — по выгрузке выше, а не по чтению исходников;")
    lines.append("* **псевдоним системного типа.** `OSStatus` есть `Int32`, `pid_t` есть "
                 "`Int32`, `TimeInterval` есть `Double` — разбор графа псевдоним от своего "
                 "типа не отличает. Это граница способа, названная самими C-005, C-009, "
                 "C-010 и C-015;")
    lines.append("* **условную компиляцию за пределами двух работ.** Граф снимается на одной "
                 "платформе за прогон. Объявление под `#if os(iOS)` не увидит ни одна из двух "
                 "работ; объявление под `#if os(macOS)` видит только `Core + Mac`;")
    lines.append("* **внутреннее устройство модуля.** Граф снимается на публичном уровне "
                 "доступа; `internal`-объявлений в нём нет вовсе;")
    lines.append("* **«у таргета есть хотя бы одно собственное публичное объявление».** Число "
                 "выведено в таблице, но отказом ноль не является: на сегодняшнем дереве "
                 "реализаций нет, и требование красно по построению, пока модуль не написан "
                 "(так это и записано в инварианте 9 C-005 и в допуске (в) инварианта 32 C-014).")

    if notices:
        lines.append("")
        lines.append("**Замечания (не отказ):**")
        lines.append("")
        for target, what, where in notices:
            lines.append("* `%s`: %s — %s. Запрета на это у контракта таргета нет; "
                         "строка выведена, чтобы находка не прошла молча." % (target, what, where))

    lines.append("")
    if violations:
        lines.append("### Отказ: нарушений %d" % len(violations))
        lines.append("")
        for target, what, where in violations:
            lines.append("* `%s`: %s — %s" % (target, what, where))
    else:
        lines.append("### Нарушений нет")

    report = "\n".join(lines) + "\n"
    sys.stdout.write(report)
    if args.report:
        with open(args.report, "w", encoding="utf-8") as handle:
            handle.write(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(report)
    return 1 if violations else 0


def self_test():
    """Разбор USR проверяется здесь, а не предполагается."""
    cases = [
        # Дословный пример инварианта 32 C-014 и постановки MEE-166 —
        # `s:11DomainCore9ModelRoleO` — разбирается НЕ в `DomainCore`: длина имени
        # модуля там записана как 11, а в `DomainCore` десять букв. Соседние числа в
        # том же примере верны (`10Foundation`, `3URL`, `9ModelRole`), то есть это
        # описка в одной цифре, а не другой способ кодирования. Механизм от неё не
        # меняется; проверяются оба написания, чтобы описка не уехала в код.
        ("s:10DomainCore9ModelRoleO", "DomainCore"),
        ("s:11DomainCore9ModelRoleO", "DomainCore9"),
        ("s:10Foundation3URLV", "Foundation"),
        ("s:10Foundation4DateV", "Foundation"),
        ("s:s5Int32V", "Swift"),
        ("s:s8SendableP", "Swift"),
        ("s:SS", "Swift"),
        ("s:Sb", "Swift"),
        ("s:Sa", "Swift"),
        ("s:Sq", "Swift"),
        ("s:SQ", "Swift"),
        ("s:ScS", "_Concurrency"),
        ("s:ScA", "_Concurrency"),
        ("c:objc(cs)EKEventStore", "<C/ObjC>"),
        ("c:objc(cs)NSXPCConnection", "<C/ObjC>"),
        ("s:7Capture13AudioCaptureC", "Capture"),
        ("", None),
    ]
    failures = [(usr, expected, module_of(usr)) for usr, expected in cases if module_of(usr) != expected]
    for usr, expected, got in failures:
        print("ОТКАЗ self-test: %r ожидалось %r, получено %r" % (usr, expected, got))
    print("self-test разбора USR: случаев %d, отказов %d" % (len(cases), len(failures)))
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description="Разбор символьного графа таргетов")
    parser.add_argument("--graph-dir", help="каталог -emit-symbol-graph-dir")
    parser.add_argument("--sources", action="append", default=[], help="каталог Sources для чтения строк import")
    parser.add_argument("--job", default="", help="имя работы CI, для заголовка отчёта")
    parser.add_argument("--report", help="куда записать отчёт")
    parser.add_argument("--self-test", action="store_true", help="проверить разбор USR и выйти")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.graph_dir:
        parser.error("--graph-dir обязателен")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
