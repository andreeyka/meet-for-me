//  JobQueueEngine — исполнение обработчика (§7, шаг 4), продление лизинга (инвариант 11)
//  и применение исхода по правилу §5 (инварианты 6, 7, 15).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import Foundation

extension JobQueueEngine {

    /// Спускает задачу обработчику отдельной `Task`, которую пересмотр не ждёт (§7). Событие
    /// `started` публикуется здесь же, до передачи — начало последовательности инварианта 15.
    ///
    /// MEE-370: обязательство «на завершении этой задачи предстоит пересмотр» заводится
    /// (`activeRevisitPasses += 1`) уже ЗДЕСЬ, в момент постановки, — не в момент, когда
    /// `executeAndFinish` фактически дойдёт до звонка `runRevisitPass()`. Между этими двумя
    /// моментами исполнение идёт отдельной `Task`, которую внешний вызов (`start()`,
    /// `submit()`) не ждёт: без учёта здесь тот внешний вызов мог уже вернуться (и его
    /// СОБСТВЕННЫЙ `activeRevisitPasses` — уже обнулиться), пока эта задача ещё не решила,
    /// понадобится ли пересмотр заново её соседям — тот же класс окна, что MEE-363 закрыл
    /// одним уровнем выше (между `runningTasks[job.id] = nil` и звонком `runRevisitPass()`).
    func beginExecuting(_ job: Job) {
        guard let handler = handlers[job.type] else { return }
        broadcaster.publish(.started(jobId: job.id, type: job.type))
        activeRevisitPasses += 1
        let task = Task { [weak self] in
            // `self?.executeAndFinish(...)` типом был бы `Void?`, не `Void` —
            // `RunningEntry.task` объявлен `Task<Void, Never>` и такого не принял бы.
            guard let self else { return }
            await self.executeAndFinish(job: job, handler: handler)
        }
        runningTasks[job.id] = RunningEntry(type: job.type, task: task)
    }

    private func executeAndFinish(job: Job, handler: JobHandler) async {
        let broadcaster = broadcaster
        let progress: @Sendable (Double) -> Void = { fraction in
            let clamped = min(max(fraction, 0), 1)
            broadcaster.publish(.progressed(jobId: job.id, fraction: clamped))
        }

        // Сторож лизинга — отдельная НЕструктурная `Task`, а не дочерняя задача
        // `withTaskGroup`: та требовала бы от сторожа, изолированного тем же актором, что и
        // этот метод, самому влиться в актор из дочерней задачи группы, пока родитель ждёт
        // `group.next()` на том же акторе, — при высокой конкуренции `beginExecuting`/
        // `runRevisitPass` за исполнение актора такая форма наблюдалась зависающей (не
        // дошло ни одного продвижения на CI, «Core (Linux)», прогон MEE-350). Явные
        // `cancel()` + `await .value` дают тот же результат — сторож остановлен и досмотрен —
        // без дочерней задачи, которой нужен тот же актор, что родителю.
        let renewal = Task { [weak self] in
            guard let self else { return }
            await self.renewLeaseWhileRunning(jobId: job.id)
        }
        let outcome = await handler.run(job, progress: progress)
        renewal.cancel()
        await renewal.value

        await applyOutcome(outcome, to: job)
        runningTasks[job.id] = nil
        // Обязательство заведено `beginExecuting` — закрывается здесь, но НЕ через
        // `runRevisitPass()` (та завела бы своё, второе, обязательство): исполняется тем
        // же заходом-мьютексом (`performRevisitSweep()`), что и любой другой триггер.
        // Пересмотр по завершении либо сходит прямо сейчас (`isRunning`), либо не
        // запускается вовсе (`stop()` уже прошёл) — в обоих случаях `defer` ниже закрывает
        // обязательство и может застать очередь идле именно тут.
        defer {
            activeRevisitPasses -= 1
            notifyIdleIfNeeded()
        }
        if isRunning {
            await performRevisitSweep()
        }
    }

    /// Опрос — раз в реальные 0.2 секунды, дёшево и для продакшена, и для теста с
    /// `ManualClock`: продление считается по инъецированным часам, а не по реальному времени,
    /// опрос лишь даёт часам шанс быть прочитанными достаточно часто.
    private func renewLeaseWhileRunning(jobId: UUID) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            guard let current = try? await repository.job(id: jobId), let lease = current.leaseExpiresAt else {
                continue
            }
            let now = clock()
            let elapsedSinceLastRenewal = Double(leaseSeconds) - lease.timeIntervalSince(now)
            guard elapsedSinceLastRenewal >= 30 else { continue }
            try? await repository.update(current.renewingLease(now: now, leaseSeconds: leaseSeconds))
        }
    }

    /// §5 целиком, плюс отмена (инвариант 8) и инвариант 15 — ровно одна финальная
    /// последовательность на исполненную задачу.
    private func applyOutcome(_ outcome: JobOutcome, to job: Job) async {
        let now = clock()
        if cancellationRequested.remove(job.id) != nil {
            try? await repository.update(job.cancelling(now: now))
            broadcaster.publish(.cancelled(jobId: job.id, type: job.type))
            return
        }
        switch outcome {
        case .success:
            try? await repository.update(job.succeeding(now: now))
            broadcaster.publish(.succeeded(jobId: job.id, type: job.type))
        case .retry(let after, let error):
            let finished = job.afterConsumedAttempt(
                attemptsNew: job.attempts + 1, lastError: error, now: now, explicitDelaySeconds: after
            )
            try? await repository.update(finished)
            broadcaster.publish(.failed(
                jobId: job.id, type: job.type, error: error, willRetry: finished.status == .pending
            ))
        case .permanentFailure(let error):
            let finished = job.permanentlyFailing(attemptsNew: job.attempts + 1, lastError: error, now: now)
            try? await repository.update(finished)
            broadcaster.publish(.failed(jobId: job.id, type: job.type, error: error, willRetry: false))
        }
    }
}
