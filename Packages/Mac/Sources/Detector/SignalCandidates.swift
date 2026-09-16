//  SignalCandidates — какие сигналы описывают снимок: по одному на пару «вид + источник».
//
//  C-009 §1 (источник пары), §4.1, §«Поведение»; инварианты 11, 12, 17, 18.
//
//  * Группа — все процессы снимка с одним ключом приложения (`AudioProcess.appKey`), `pids` по
//    возрастанию и без повторов, `observedAt` — момент снимка.
//  * `clientRunning` и `clientAudioOutput` — только у группы, чей ключ совпал по §4.1 со строкой
//    `browsers` или `clients[].bundleIds` (инвариант 17). Источник пары — `group.appKey`.
//  * `microphoneInUse` — у всякого процесса с открытым входом: с группой, если ключ приложения
//    есть, и без неё, если нет (инвариант 17 это допускает). Источник — `group.appKey` либо `pid`.
//  * `pid` сигнала — наименьший `pid` группы, у которого есть то, о чём сигнал; `bundleId` —
//    собственный bundle id этого процесса, а не ключ приложения.
//  * `calendarWindow` порт не публикует никогда: окна события у модуля нет.

import DomainCore
import Foundation

/// Источник пары «вид + источник» (§1): ключ приложения у сигнала с группой, `pid` — без неё.
enum SignalSource: Hashable, Comparable {
    case application(String)
    case process(Int32)
}

struct PairKey: Hashable {
    let kind: MeetingSignalKind
    let source: SignalSource
}

struct SignalCandidate {
    let key: PairKey
    let signal: MeetingSignal
}

enum SignalCandidates {

    /// Сигналы снимка в порядке публикации: по виду, затем по источнику.
    static func make(from snapshot: [AudioProcess], tables: RuleTables, values: ReceivedValues,
                     at moment: Date) -> [SignalCandidate] {
        var result: [SignalCandidate] = []
        let keyed = snapshot.compactMap { process in process.appKey.map { (key: $0, process: process) } }
        let groups = Dictionary(grouping: keyed, by: \.key)
        for appKey in groups.keys.sorted() {
            let members = (groups[appKey] ?? []).map(\.process).sorted { $0.pid < $1.pid }
            result += groupSignals(appKey: appKey, members: members, tables: tables, values: values, at: moment)
        }
        for process in snapshot where process.appKey == nil && process.isRunningInput {
            let signal = MeetingSignal(kind: .microphoneInUse, weight: values.weight(for: .microphoneInUse),
                                       pid: process.pid, bundleId: process.bundleId, group: nil,
                                       provider: nil, meetingId: nil, observedAt: moment)
            result.append(SignalCandidate(key: PairKey(kind: .microphoneInUse, source: .process(process.pid)),
                                          signal: signal))
        }
        return result.sorted(by: publicationOrder)
    }

    /// Пары снимка при подписке — в том же порядке, каким они ушли бы в поток одним шагом
    /// (инвариант 26). Очерёдности внутри снимка контракт не требует; порядок взят один и тот
    /// же затем, чтобы он не зависел от того, как легло отображение пар.
    static func inPublicationOrder(_ pairs: [PairKey: MeetingSignal]) -> [MeetingSignal] {
        pairs.map { SignalCandidate(key: $0.key, signal: $0.value) }
            .sorted(by: publicationOrder)
            .map(\.signal)
    }

    private static func groupSignals(appKey: String, members: [AudioProcess], tables: RuleTables,
                                     values: ReceivedValues, at moment: Date) -> [SignalCandidate] {
        guard let first = members.first else { return [] }
        let group = ProcessGroup(appKey: appKey, pids: members.map(\.pid), observedAt: moment)
        let provider = tables.provider(forAppKey: appKey)
        var sources: [(kind: PublishedKind, process: AudioProcess)] = []
        if tables.isKnownApplication(appKey: appKey) {
            sources.append((.clientRunning, first))
            if let sounding = members.first(where: \.isRunningOutput) {
                sources.append((.clientAudioOutput, sounding))
            }
        }
        if let listening = members.first(where: \.isRunningInput) {
            sources.append((.microphoneInUse, listening))
        }
        return sources.map { kind, process in
            SignalCandidate(key: PairKey(kind: kind.signalKind, source: .application(appKey)),
                            signal: MeetingSignal(kind: kind.signalKind, weight: values.weight(for: kind),
                                                  pid: process.pid, bundleId: process.bundleId, group: group,
                                                  provider: provider, meetingId: nil, observedAt: moment))
        }
    }

    private static func publicationOrder(_ lhs: SignalCandidate, _ rhs: SignalCandidate) -> Bool {
        let order = MeetingSignalKind.allCases
        let left = order.firstIndex(of: lhs.key.kind) ?? order.count
        let right = order.firstIndex(of: rhs.key.kind) ?? order.count
        return left != right ? left < right : lhs.key.source < rhs.key.source
    }
}

extension MeetingSignal {

    /// Одно и то же состояние пары: всё значение, кроме моментов. Состав `group.pids` в него
    /// входит — «состояние группы — её значение целиком, а не ключ» (§«Поведение»).
    func hasSameState(as other: MeetingSignal) -> Bool {
        kind == other.kind && weight == other.weight && pid == other.pid && bundleId == other.bundleId
            && group?.appKey == other.group?.appKey && group?.pids == other.group?.pids
            && provider == other.provider && meetingId == other.meetingId
    }
}
