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
    ///
    /// Снимает прежние `timerTask`/`powerEventsTask`, если они есть, — контракт не запрещает
    /// повторный `start()` без промежуточного `stop()` (тест К54/К67 зовёт его так намеренно,
    /// проверяя «на каждом пересмотре»), и без явной отмены каждый такой вызов копил бы ещё
    /// одну never-ending подписку/таймер на том же акторе.
    public func start() async {
        await recoverInterruptedJobs()
        isRunning = true
        timerTask?.cancel()
        startTimer()
        powerEventsTask?.cancel()
        startPowerEventsSubscription()
        await runRevisitPass()
    }

    // Находка по возврату РП на MEE-350 (не тестовая — производственная): здесь не было
    // `where runningTasks[job.id] == nil`, которым `reclaimExpiredLeases` (тот же файл,
    // соседний предохранитель) уже отличает строку, оставленную МЁРТВЫМ процессом
    // (инвариант 10 — ровно про это), от строки, которую эта же живая очередь исполняет
    // прямо сейчас. Без фильтра повторный `start()` без промежуточного `stop()` (сам
    // контракт разрешает — см. заголовок `start()`) находил чужую же, ещё бегущую задачу,
    // «интерпретировал» её как прерванную, увеличивал `attempts` и публиковал поддельный
    // `failed(error: "interrupted")` — гоняясь с настоящим исходом той же строки, который
    // вот-вот напишет её же собственная исполняющая `Task`. Обнаружено К68 (способ И,
    // MEE-311): три сценария подряд без `stop()` между ними — второй `submit()` уже видит
    // `isRunning == true` и сам заводит пересмотр, так что последующий `start()` в тесте
    // избыточен, но не безобиден — он и попал на эту гонку. Фикс — тот же фильтр, что у
    // `reclaimExpiredLeases`.
    private func recoverInterruptedJobs() async {
        guard let running = try? await jobs(status: .running) else { return }
        let now = clock()
        for job in running where runningTasks[job.id] == nil {
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

    // MARK: - Сигнал записи (C-013 v9 — часть протокола `JobQueue`, см. шапку `JobQueueEngine.swift`)

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
