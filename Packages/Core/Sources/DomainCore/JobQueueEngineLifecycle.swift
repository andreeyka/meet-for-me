//  JobQueueEngine — `start()`/`stop()`, восстановление по инвариантам 10 и 11, и триггеры
//  пересмотра из «Поведения» C-013 v8 (событие `PowerPort`, старт/остановка записи, таймер).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import Foundation

extension JobQueueEngine {

    // MARK: - §2, `start()` (инварианты 10, 17)

    /// Восстановление — прежде, чем принять новую работу: ни одна строка не должна остаться
    /// `running` при перезапуске (инвариант 10), после — таймер и подписка на `PowerPort`,
    /// и один немедленный пересмотр, чтобы готовые `pending`-задачи не ждали 60 секунд.
    public func start() async {
        await recoverInterruptedJobs()
        isRunning = true
        startTimer()
        startPowerEventsSubscription()
        await runRevisitPass()
    }

    private func recoverInterruptedJobs() async {
        guard let running = try? await jobs(status: .running) else { return }
        let now = clock()
        for job in running {
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
            if restored.status == .failed {
                broadcaster.publish(.failed(
                    jobId: restored.id, type: restored.type, error: "interrupted", willRetry: false
                ))
            }
        }
    }

    // MARK: - §2, `stop()` (инвариант 12)

    /// Не начинает новых задач, дожидается исполняемых, возвращает в `pending` кандидата,
    /// взятого текущим пересмотром и ещё не переданного обработчику. Повторный `stop()` —
    /// без эффекта: `isRunning` уже `false`, `runningTasks` уже пуст.
    public func stop() async {
        isRunning = false
        timerTask?.cancel()
        timerTask = nil
        powerEventsTask?.cancel()
        powerEventsTask = nil

        let executing = Array(runningTasks.values)
        for entry in executing {
            await entry.task.value
        }
        // Даёт пересмотру, зависшему между `claimNext` и передачей обработчику в момент
        // вызова `stop()`, шанс самому заметить `isRunning == false` и вернуть кандидата
        // (см. `JobQueueEngineReview.swift`) прежде, чем этот метод сам досмотрит таблицу.
        await Task.yield()
        await Task.yield()

        guard let listing = try? await repository.jobs(status: .running) else { return }
        let now = clock()
        for job in listing.jobs where runningTasks[job.id] == nil {
            try? await repository.update(job.returningUnstartedCandidate(updatedAt: now))
        }
    }

    /// Дождаться, пока осядут все фактические исполнения — их `Task` не ждёт ни `submit`,
    /// ни `start`, ни пересмотр (§7: «исполнение идёт отдельной Task, которую пересмотр не
    /// ждёт»). Не часть протокола `JobQueue` — оснастка теста, детерминизм способа И плана
    /// MEE-311: без него утверждение сразу после `start()`/`submit()` гонится с фоновой
    /// задачей, которую они запустили и не ждут. Цикл — не разовое ожидание: исполнение,
    /// закончившись, само может запустить следующее (пересмотр по завершении).
    public func waitUntilIdle() async {
        while !runningTasks.isEmpty {
            let tasks = Array(runningTasks.values)
            for entry in tasks {
                await entry.task.value
            }
        }
    }

    // MARK: - Сигнал записи (см. `// СТРОКА:` в шапке `JobQueueEngine.swift`)

    public func recordingDidStart() async {
        isRecordingInProgress = true
        if isRunning {
            await runRevisitPass()
        }
    }

    public func recordingDidStop() async {
        isRecordingInProgress = false
        if isRunning {
            await runRevisitPass()
        }
    }

    // MARK: - Таймер и события `PowerPort`

    /// «По таймеру не реже раза в 60 секунд» — реальное время: инъецированные часы существуют
    /// для детерминизма отката и лизинга, а не для управления периодом этого таймера, который
    /// ни один критерий не проверяет напрямую.
    private func startTimer() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.runRevisitPass()
            }
        }
    }

    private func startPowerEventsSubscription() {
        let stream = powerPort.events()
        powerEventsTask = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                await self.runRevisitPass()
            }
        }
    }
}
