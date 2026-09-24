#!/usr/bin/env python3
# Владелец файла — архитектор (MEE-166, MEE-191).
#
# Шаг снимает символьный граф таргетов и разбирает публичную поверхность каждого.
# Способ назван самими контрактами: инвариант 25 C-004, инвариант 9 C-005,
# инвариант 21 C-006, инвариант 21 C-009, инвариант 19 C-010, инвариант 15 C-011,
# инвариант 23 C-012, инвариант 32 C-014, инварианты 19 и 20 C-015 — и критерием 45
# MEE-74. Полнее всех механизм расписан инвариантом 32 C-014, и код ниже следует ему.
#
# ИЗДАНИЕ MEE-191. До этой правки здесь намеренно не было ни одного разрешённого
# списка типов по таргетам — барьер стоял только по МОДУЛЮ объявления (ниже), и
# это было решением, а не недосмотром (MEE-166): копия списка в репозитории
# разошлась бы с контрактом на первом же издании и разошлась бы молча — зелёный
# шаг при нарушенном контракте. Довод был верным, но цена оказалась практической:
# на приёмке MEE-324 и MEE-317 барьер по модулю пропустил ровно то, что был обязан
# ловить перечень контракта (тип из Foundation/Swift, которого в перечне нет).
#
# Решение MEE-191 — не отменяет довод MEE-166, а меняет сторону, которой он
# дороже: копия списка теперь ЕСТЬ, в `allowed-types/<Target>.json`, и она
# ДОПОЛНЯЕТ барьер по модулю, а не заменяет его. Цена принятого — второй
# источник истины: файл может отстать от следующего издания контракта. Цена
# смягчена, а не снята: файл несёт `_count`, и расхождение `_count` с
# фактическим числом позиций — отказ самого скрипта (`load_allowed_types`
# ниже), а не тихий пропуск. Отставание же в СОСТАВЕ при неизменном счёте
# (контракт заменил одну позицию на другую, не поменяв длину) счётом не
# ловится ничем — это остаточная цена, названная здесь и в отчёте MEE-191,
# а не спрятанная.
#
# Шаг по-прежнему делает то, что не требует копии:
#   1) барьер по МОДУЛЮ объявления: тип в публичной сигнатуре обязан быть объявлен
#      в таргете этого репозитория либо в базовом наборе модулей (ниже);
#   2) выгрузка самой поверхности — по таргету, по модулю, поимённо, — чтобы
#      сверку с разрешённым списком контракта можно было сделать по выводу шага
#      и для таргетов БЕЗ файла в `allowed-types/` — а не по чтению исходников.
# Барьер (1) в одиночку строго слабее списков контрактов: см. --report и раздел
# «Не ловит». Файл (см. `load_allowed_types`) закрывает эту разницу поимённо
# для таргетов, у которых он заведён.

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

# Решение архитектора — IR-124 (MEE-367): разрешены ГЛОБАЛЬНО, для всех таргетов и
# контрактов, а не только для того, у которого нашлись первым. Это не выбор автора
# модуля, который список контракта обязан ловить, а неотделимый довесок компилятора
# к любому `public actor`: конформанс `Actor`/`AnyActor` и три метода проверки
# изоляции по умолчанию из stdlib (`assumeIsolated`/`assertIsolated`/
# `preconditionIsolated`), несущие `file: StaticString`/`line: UInt`, — появляются у
# ЛЮБОГО публичного актора в ЛЮБОМ модуле детерминированно, без исключения и без
# способа отказаться, оставшись актором. Список контракта существует, чтобы ловить
# чужой тип, который автор мог не заметить в своей сигнатуре, — этих четырёх там
# заметить нечего: они не в исходниках модуля ни одной строкой.
ACTOR_BASELINE_TYPES = {
    ("_Concurrency", "Actor"),
    ("_Concurrency", "AnyActor"),
    ("Swift", "StaticString"),
    ("Swift", "UInt"),
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


def load_allowed_types(allowed_dir):
    """Разрешённые списки типов по таргетам — MEE-191, `allowed-types/<Target>.json`.

    Каждый файл — построчная копия перечня из раздела «Определение» контракта-
    владельца: `_source` называет контракт, издание, инвариант и ссылку на
    задачу, `_count` — число позиций, которое контракт называет сам, `types` —
    сам список, КАЖДАЯ позиция парой `Модуль.Имя` (возврат РП 24.09, п.2 —
    см. `parse_allowed_type` и docstring `type_allowed`). Копия — решение
    MEE-191, а не молчаливое допущение: довод и цена (второй источник истины)
    — в комментарии в начале файла и в отчёте MEE-191. Список ДОПОЛНЯЕТ барьер
    по модулю, а не заменяет его: тип из СОБСТВЕННОГО модуля таргета разрешён
    всегда, независимо от этого файла (см. `type_allowed`).

    `_count`, разошедшийся с фактической длиной списка, — отказ шага, а не
    предупреждение: транскрипция обязана быть точной, и опечатка, стёршая
    одну позицию без изменения счёта, тем самым исключена по построению —
    хотя обратное (контракт поменял позицию, не тронув счёт) этим не ловится,
    и это названо прямо, а не спрятано (см. шапку файла).
    """
    allowed = {}
    if not allowed_dir or not os.path.isdir(allowed_dir):
        return allowed
    for name in sorted(os.listdir(allowed_dir)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(allowed_dir, name), encoding="utf-8") as handle:
            data = json.load(handle)
        allowed[name[: -len(".json")]] = validate_allowed_data(name, data)
    return allowed


def parse_allowed_type(entry):
    """`"Модуль.Имя"` файла → пара `(модуль, имя)`.

    Разбор по ПЕРВОЙ точке: имя модуля точек не содержит никогда (USR это и
    предполагает — `module_of`), а вложенный тип справа может («модуль.Имя.
    Вложенный», например `DomainCore.SpeakerAssignment.Candidate`) — `split(1)`
    оставляет вложенность в имени и не путает её с границей модуля.
    """
    module, _, spelling = entry.partition(".")
    return module, spelling


def validate_allowed_data(name, data):
    """Проверка одного файла `allowed-types/`, вынесена отдельно ради self-test.

    Обе проверки — отказ, не предупреждение: список, который сам с собой не
    сходится, доверия не заслуживает, и молчаливо пропущенная позиция здесь
    страшнее остановленного прогона.
    """
    pairs = [parse_allowed_type(entry) for entry in data["types"]]
    types = set(pairs)
    if len(types) != len(pairs):
        raise SystemExit(
            "allowed-types/%s: список несёт повторяющуюся позицию — "
            "%d строк, %d различных" % (name, len(pairs), len(types))
        )
    if len(types) != data["_count"]:
        raise SystemExit(
            "allowed-types/%s: заявлено %d позиций (_count), в списке %d — "
            "файл разошёлся сам с собой, транскрипция неверна" % (name, data["_count"], len(types))
        )
    return {"source": data["_source"], "count": data["_count"], "types": types}


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


def type_allowed(module, spelling, target, repo_modules, allowed_entry):
    """Разрешён ли тип на границе таргета.

    Возврат РП 24.09, два пункта:

    1. **Собственный модуль ТАРГЕТА** (`module == target`) разрешён всегда,
       без сверки. До этой правки здесь стоял `module in own_modules`, где
       `own_modules` было множеством ВСЕХ модулей репозитория (аргумент
       `repo_modules` ниже) — поэтому любой repo-модуль, включая `DomainCore`,
       проходил без сверки со списком, даже когда список для таргета заведён.
       На приёмке это читалось буквально: 38 из 56 позиций списка `Storage` и
       20 из 35 позиций списка `Capture` не проверяли ничего, потому что
       ссылающийся на них `DomainCore` (а не сам таргет) проходил раньше, чем
       список успевал решить. Теперь без сверки проходит только `module ==
       target`; всё остальное — включая `DomainCore` — сверяется списком
       наравне с `Foundation`/`Swift`, если список для таргета заведён.
    2. **Пара «модуль, имя», не голое имя.** Раньше `spelling in
       allowed_entry["types"]` сравнивал только имя — `GRDB.Data` совпадал с
       разрешённым именем `Data`, хотя разрешён был только `Foundation.Data`
       (тот же возврат). Файлы `allowed-types/*.json` несут теперь пары
       `Модуль.Имя` (`parse_allowed_type`), и сверяется пара целиком.

    Без списка (`allowed_entry is None`) действует прежний барьер по модулю
    (MEE-166), этой правкой не тронутый: любой модуль ЭТОГО репозитория
    (`repo_modules`) или базовый набор (`BASELINE_MODULES`) — возврат РП
    указывал находку только для таргетов со списком, не для непокрытых.

    IR-124 (MEE-367): пары из `ACTOR_BASELINE_TYPES` разрешены раньше и списка,
    и барьера по модулю — они не пример решения автора, который список обязан
    ловить, а компиляторный довесок к `public actor`, одинаковый для всех.
    """
    if module == target:
        return True
    if (module, spelling) in ACTOR_BASELINE_TYPES:
        return True
    if allowed_entry is not None:
        return (module, spelling) in allowed_entry["types"]
    return module in repo_modules or module in BASELINE_MODULES


def run(args):
    graphs, repo_modules = load_graphs(args.graph_dir)
    allowed_types = load_allowed_types(args.allowed_types_dir)
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
        covered = sorted(t for t in allowed_types if t in graphs)
        lines.append("Таргетов с графом: **%d**. Модули репозитория, известные шагу: %s. "
                     "Точный список типов (MEE-191) заведён для: %s."
                     % (len(graphs), ", ".join("`%s`" % m for m in sorted(repo_modules)),
                        ", ".join("`%s`" % t for t in covered) or "ни одного — везде барьер по модулю"))
        lines.append("")
        lines.append("| Таргет | Публичных объявлений | Типов в сигнатурах | Модули объявления | Список MEE-191 |")
        lines.append("| -- | -- | -- | -- | -- |")

    for target in sorted(graphs):
        count, referenced, _ = surface_of(graphs[target])
        allowed_entry = allowed_types.get(target)
        by_module = defaultdict(set)
        for usr, spelling in referenced.items():
            by_module[module_of(usr) or "<не разобран: %s>" % usr].add(spelling)
        for module in sorted(by_module):
            for spelling in sorted(by_module[module]):
                if not type_allowed(module, spelling, target, repo_modules, allowed_entry):
                    violations.append((target, module, spelling))
        shown = ", ".join(
            "`%s`%s" % (
                module,
                "" if all(type_allowed(module, s, target, repo_modules, allowed_entry) for s in by_module[module])
                else " ❌",
            )
            for module in sorted(by_module)
        ) or "—"
        list_note = ("`%s`, %d поз." % (allowed_entry["source"], allowed_entry["count"])
                     if allowed_entry else "нет — барьер по модулю")
        lines.append("| `%s` | %d | %d | %s | %s |" % (target, count, len(referenced), shown, list_note))

    if graphs:
        lines.append("")
        lines.append("<details><summary>Поверхность поимённо</summary>")
        lines.append("")
        for target in sorted(graphs):
            count, referenced, declared = surface_of(graphs[target])
            allowed_entry = allowed_types.get(target)
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
                    if allowed_entry is None:
                        spellings = ", ".join("`%s`" % s for s in sorted(by_module[module]))
                    else:
                        # Список заведён — метка у каждого типа, а не только у модуля:
                        # модуль сам по себе больше не решает (см. type_allowed).
                        spellings = ", ".join(
                            "`%s`%s" % (s, "" if type_allowed(module, s, target, repo_modules, allowed_entry) else " ❌")
                            for s in sorted(by_module[module])
                        )
                    lines.append("* из `%s`: %s" % (module, spellings))
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
    covered_targets = sorted(t for t in allowed_types if t in graphs)
    uncovered_targets = sorted(t for t in graphs if t not in allowed_types)
    covered_note = (", ".join("`%s`" % t for t in covered_targets)
                    if covered_targets else "ни одного таргета сегодня")
    if not uncovered_targets:
        uncovered_note = "нет ни одного таргета без него"
    else:
        uncovered_note = "нет для %s" % ", ".join("`%s`" % t for t in uncovered_targets)
    lines.append("* **разрешённые списки типов контрактов — только там, где список заведён.** "
                 "Для %s список MEE-191 сверяет каждый тип поимённо; %s, и там шаг по-прежнему "
                 "сверяет только модуль объявления: `Data` и `Process` из `Foundation` он "
                 "пропускает всегда, хотя список инварианта 9 C-005 их не содержит. Сверку по "
                 "непокрытым таргетам делает приёмка — по выгрузке выше, а не по чтению "
                 "исходников;"
                 % (covered_note, uncovered_note))
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
    annotate(args.job, sorted(graphs), violations)
    if args.report:
        with open(args.report, "w", encoding="utf-8") as handle:
            handle.write(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(report)
    return 1 if violations else 0


def annotate(job, targets, violations):
    """Вердикт прогона — аннотацией работы.

    Довод тот же, что у шага SwiftLint: «шаг отработал» должно подтверждаться,
    не открывая журнал работы. Вердикт выносит сам скрипт, а не оболочка шага:
    один прогон — одна аннотация, и вердикт по второму пакету не теряется за
    первым, как это вышло на прогоне 32e5681.
    """
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return
    label = job or "символьный граф"
    for target, what, where in violations:
        print("::error title=Символьный граф · %s::`%s`: %s — %s" % (label, target, what, where))
    print("::notice title=Символьный граф · %s::таргетов с графом %d (%s); нарушений %d"
          % (label, len(targets), ", ".join(targets) or "—", len(violations)))


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

    repo_modules = {"Storage", "DomainCore"}
    entry = {
        "source": "тест",
        "count": 3,
        "types": {("Foundation", "Date"), ("Swift", "OpaquePointer"), ("DomainCore", "RecordingManifest")},
    }
    type_cases = [
        # (модуль, тип, target, allowed_entry, ожидание)
        ("Storage", "PrivateHelper", "Storage", None, True),          # свой модуль таргета, без списка — всегда да
        ("DomainCore", "RecordingManifest", "Storage", None, True),   # без списка — старый барьер: любой repo-модуль
        ("Foundation", "Date", "Storage", None, True),                # без списка — тот же барьер: базовый модуль
        ("GRDB", "Connection", "Storage", None, False),                # без списка — GRDB не repo-модуль и не базовый
        # Возврат РП 24.09, п.1: список заведён — DomainCore (чужой repo-модуль) сверяется
        # ИМ, а не проходит по одной принадлежности репозиторию. Раньше `own_modules` было
        # множеством ВСЕХ repo-модулей, и обе строки ниже проходили бы одинаково — «да» —
        # что и было находкой (38 из 56 позиций Storage не проверяли ничего).
        ("DomainCore", "RecordingManifest", "Storage", entry, True),   # DomainCore, тип В списке — да
        ("DomainCore", "NotListed", "Storage", entry, False),          # DomainCore, тип НЕ в списке — нет
        # Возврат РП 24.09, п.2: сверка — пара «модуль, имя», не голое имя. `GRDB.Data`
        # не должен совпасть с разрешённым `Foundation.Data` только по имени `Data`.
        ("Foundation", "Date", "Storage", entry, True),                # пара совпадает — да
        ("GRDB", "Date", "Storage", entry, False),                     # имя совпадает, модуль — нет: отказ
        ("Storage", "PrivateOwnType", "Storage", entry, True),         # свой модуль таргета — список ни при чём
        # IR-124 (MEE-367): довесок `public actor` разрешён раньше списка — не в
        # `entry["types"]` (см. `entry` выше) ни одной из четырёх пар, а ожидание всё
        # равно «да».
        ("_Concurrency", "Actor", "Storage", entry, True),
        ("_Concurrency", "AnyActor", "Storage", entry, True),
        ("Swift", "StaticString", "Storage", entry, True),
        ("Swift", "UInt", "Storage", entry, True),
    ]
    type_failures = [
        (module, spelling, expected, type_allowed(module, spelling, target, repo_modules, allowed_entry))
        for module, spelling, target, allowed_entry, expected in type_cases
        if type_allowed(module, spelling, target, repo_modules, allowed_entry) != expected
    ]
    for module, spelling, expected, got in type_failures:
        print("ОТКАЗ self-test: type_allowed(%r, %r) ожидалось %r, получено %r"
              % (module, spelling, expected, got))
    print("self-test type_allowed: случаев %d, отказов %d" % (len(type_cases), len(type_failures)))

    validation_failures = 0
    try:
        validate_allowed_data("Fake.json", {"_source": "т", "_count": 3, "types": ["Foundation.A", "Swift.B"]})
        print("ОТКАЗ self-test: validate_allowed_data не остановил расхождение _count со списком")
        validation_failures += 1
    except SystemExit:
        pass
    try:
        validate_allowed_data("Fake.json", {"_source": "т", "_count": 1, "types": ["Foundation.A", "Foundation.A"]})
        print("ОТКАЗ self-test: validate_allowed_data не остановил повторяющуюся позицию")
        validation_failures += 1
    except SystemExit:
        pass
    good = validate_allowed_data(
        "Fake.json", {"_source": "т", "_count": 2, "types": ["Foundation.A", "DomainCore.B.Nested"]}
    )
    if good != {"source": "т", "count": 2, "types": {("Foundation", "A"), ("DomainCore", "B.Nested")}}:
        print("ОТКАЗ self-test: validate_allowed_data исказил корректный файл: %r" % (good,))
        validation_failures += 1
    print("self-test validate_allowed_data: случаев 3, отказов %d" % validation_failures)

    parse_cases = [
        ("Foundation.Date", ("Foundation", "Date")),
        ("DomainCore.SpeakerAssignment.Candidate", ("DomainCore", "SpeakerAssignment.Candidate")),
        ("<C/ObjC>.NSError", ("<C/ObjC>", "NSError")),
    ]
    parse_failures = [(entry, expected, parse_allowed_type(entry)) for entry, expected in parse_cases
                      if parse_allowed_type(entry) != expected]
    for entry, expected, got in parse_failures:
        print("ОТКАЗ self-test: parse_allowed_type(%r) ожидалось %r, получено %r" % (entry, expected, got))
    print("self-test parse_allowed_type: случаев %d, отказов %d" % (len(parse_cases), len(parse_failures)))

    return 1 if failures or type_failures or validation_failures or parse_failures else 0


def main():
    parser = argparse.ArgumentParser(description="Разбор символьного графа таргетов")
    parser.add_argument("--graph-dir", help="каталог -emit-symbol-graph-dir")
    parser.add_argument("--sources", action="append", default=[], help="каталог Sources для чтения строк import")
    parser.add_argument("--job", default="", help="имя работы CI, для заголовка отчёта")
    parser.add_argument("--report", help="куда записать отчёт")
    parser.add_argument("--allowed-types-dir", default="",
                        help="каталог с `<Target>.json` — точные разрешённые списки типов (MEE-191)")
    parser.add_argument("--self-test", action="store_true", help="проверить разбор USR и выйти")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.graph_dir:
        parser.error("--graph-dir обязателен")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
