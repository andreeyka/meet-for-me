//  JobQueueEngine — пересмотр очереди, §7 C-013 v8: перебор кандидатов с растущим
//  множеством исключённых, готовность к запуску (инвариант 4) и предикат профиля (§1.1).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import Foundation

extension JobQueueEngine {

    /// §7 целиком: `reclaimExpiredLeases` — сперва, как второй предохранитель (см. «Поведение»
    /// C-013: лизинг «не ждёт перезапуска приложения»), затем перебор `claimNext` с растущим
    /// `skipped`, пока не вернётся `nil` либо не кончатся свободные слоты (§7, шаги 1—5).
    func runRevisitPass() async {
        guard isRunning else { return }
        activeRevisitPasses += 1
        defer {
            activeRevisitPasses -= 1
            notifyIdleIfNeeded()
        }
        await reclaimExpiredLeases()
        guard isRunning else { return }

        var skipped: Set<UUID> = []
        var profileReadyCache: [String: Bool] = [:]

        while isRunning {
            // Инвариант 28, §7 шаг 4: «слоты кончились — пересмотр окончен». Глобальный
            // предел исчерпан — ЛЮБОЙ следующий кандидат уйдёт тем же `concurrencyLimit`
            // независимо от типа; дальше не смотрим вовсе, а не звоним `claimNext` на
            // каждого оставшегося ради того же самого `blocked`. Предел ТИПА сюда не
            // входит — другой тип ещё может пройти, для него `hasFreeSlot` решает сама.
            guard runningTasks.count < globalConcurrencyLimit else { return }
            guard await claimAndDispatchOneCandidate(skipped: &skipped, profileReadyCache: &profileReadyCache) else {
                return
            }
        }
    }

    /// Одно тело цикла §7 шагов 1—5: взять кандидата, заблокировать или передать
    /// обработчику. `true` — пересмотр продолжается (кандидат обработан или пропущен
    /// блокировкой); `false` — пересмотр окончен (`claimNext` вернул `nil`, ремонт
    /// невозможен, или `isRunning` стал `false` в процессе).
    private func claimAndDispatchOneCandidate(
        skipped: inout Set<UUID>, profileReadyCache: inout [String: Bool]
    ) async -> Bool {
        let claimed: Job?
        do {
            claimed = try await performWithRepair {
                try await self.repository.claimNext(
                    types: JobType.allCases, excluding: skipped, now: self.clock(),
                    leaseSeconds: self.leaseSeconds
                )
            }
        } catch {
            return false   // §6, п. 4: ремонт невозможен — пересмотр прекращён, попробует снова позже
        }
        guard let job = claimed else { return false }   // claimNext вернул nil — пересмотр окончен

        guard isRunning else {
            try? await repository.update(job.returningUnstartedCandidate(updatedAt: clock()))
            return false
        }

        if let reason = await firstBlockingReason(for: job, profileReadyCache: &profileReadyCache) {
            try? await repository.update(job.returningUnstartedCandidate(updatedAt: clock()))
            broadcaster.publish(.blocked(jobId: job.id, type: job.type, reason: reason))
            skipped.insert(job.id)
            return true
        }

        guard isRunning else {
            try? await repository.update(job.returningUnstartedCandidate(updatedAt: clock()))
            return false
        }

        let now = clock()
        let started = job.startingAttempt(now: now, leaseSeconds: leaseSeconds)
        try? await repository.update(started)
        beginExecuting(started)
        // Слот, который эта задача заняла, учтёт следующая итерация через
        // `hasFreeSlot(for:)` — `skipped` при старте не растёт: задача не отвергнута.
        return true
    }

    /// Второй предохранитель лизинга (инвариант 11): решение по истёкшему лизингу
    /// принимает очередь — репозиторий отдал строки как есть (C-013 v7, IR-111, К89).
    private func reclaimExpiredLeases() async {
        let stale: [Job]
        do {
            stale = try await performWithRepair {
                try await self.repository.reclaimExpiredLeases(now: self.clock())
            }
        } catch {
            return
        }
        let now = clock()
        for job in stale where runningTasks[job.id] == nil {
            let restored: Job
            if job.attemptStartedAt != nil {
                restored = job.afterConsumedAttempt(
                    attemptsNew: job.attempts + 1, lastError: "interrupted",
                    now: now, explicitDelaySeconds: nil
                )
            } else {
                restored = job.returningUnstartedCandidate(updatedAt: now)
            }
            try? await repository.update(restored)
        }
    }

    /// Инвариант 4, в порядке случаев `JobBlockReason` (инварианты 20, 21). `profileReadyCache`
    /// живёт один пересмотр — не чаще одного вызова каталога на различный `profileId`
    /// (инвариант 20).
    private func firstBlockingReason(
        for job: Job, profileReadyCache: inout [String: Bool]
    ) async -> JobBlockReason? {
        let now = clock()
        guard job.runAfter <= now else { return .notYetDue }

        let snapshot = await powerPort.snapshot()
        guard !job.conditions.requiresACPower || snapshot.source == .ac else { return .waitingForACPower }
        guard !job.conditions.forbidWhileRecording || !isRecordingInProgress else { return .recordingInProgress }
        guard snapshot.thermalPressure <= job.conditions.maxThermalPressure else { return .thermalPressure }
        guard hasFreeSlot(for: job.type) else { return .concurrencyLimit }
        guard handlers[job.type] != nil else { return .noHandler }

        if let profileId = job.conditions.requiresProfileReady {
            let ready = await isProfileReady(profileId, cache: &profileReadyCache)
            guard ready else { return .profileNotReady }
        }
        return nil
    }

    private func isProfileReady(_ profileId: String, cache: inout [String: Bool]) async -> Bool {
        if let cached = cache[profileId] { return cached }
        let ready: Bool
        do {
            ready = try await modelCatalog.missingModels(profileId: profileId).isEmpty
        } catch {
            ready = true   // §1.1: любой брошенный отказ каталога — «выполнено»
        }
        cache[profileId] = ready
        return ready
    }

    private func hasFreeSlot(for type: JobType) -> Bool {
        guard runningTasks.count < globalConcurrencyLimit else { return false }
        let sameType = runningTasks.values.filter { $0.type == type }.count
        return sameType < perTypeConcurrencyLimit
    }
}
