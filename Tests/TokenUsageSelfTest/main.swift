import Foundation
import TokenUsageCore

var failures: [String] = []
var passedCount = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        passedCount += 1
    } else {
        failures.append(name)
    }
}

func parserParsesFullEnvelope() throws {
    let output = """
    MINIGOOSE_V1
    now=1792421183
    cpu_usage=23.8
    load={ 2.02 2.08 1.98 }
    cores=8
    mem_total=8589934592
    mem_used=6420000000
    mem_wired=1932000000
    mem_compressed=2948000000
    swap_total=5368709120
    swap_used=4423000000
    disk_used=12
    disk_avail=110000000000
    iface=en0
    rx=12500
    tx=3200
    errors=0
    ping_ms=7.954
    health_status=PASS
    health_failures=0
    health_age=18
    uptime=1690380
    """
    let metrics = try MiniGooseMetricsParser.parse(output)
    check(metrics.epochSeconds == 1_792_421_183, "parser epoch")
    check(metrics.cpuUsagePercent == 23.8, "parser cpu")
    check(metrics.load1 == 2.02 && metrics.load5 == 2.08 && metrics.load15 == 1.98, "parser load")
    check(metrics.memoryTotalBytes == 8_589_934_592, "parser memory total")
    check(metrics.memoryUsedBytes == 6_420_000_000, "parser memory used")
    check(metrics.appMemoryUsedBytes == nil, "parser app memory absent")
    check(metrics.healthStatus == "PASS" && metrics.healthAgeSeconds == 18, "parser health")
    check(abs((metrics.memoryUsedPercent ?? 0) - 74.736) < 0.01, "memory percent")
    check(abs((metrics.swapUsedPercent ?? 0) - 82.39) < 0.01, "swap percent")
}

func parserPrefersActivityMonitorMemory() throws {
    let output = """
    MINIGOOSE_V1
    mem_total=8589934592
    mem_used=7551000000
    app_mem_used=6084673536
    health_status=PASS
    health_failures=0
    health_age=5
    """
    let metrics = try MiniGooseMetricsParser.parse(output)
    check(metrics.memoryUsedBytes == 7_551_000_000, "parser keeps cache-inclusive memory")
    check(metrics.appMemoryUsedBytes == 6_084_673_536, "parser activity monitor memory")
    check(abs((metrics.memoryUsedPercent ?? 0) - 70.83) < 0.01, "app memory drives percent")
}

func parserAllowsMissingFields() throws {
    let metrics = try MiniGooseMetricsParser.parse("MINIGOOSE_V1\nnow=1\nhealth_status=FAIL\nhealth_failures=2\n")
    check(metrics.cpuUsagePercent == nil, "missing cpu degrades")
    check(metrics.memoryUsedBytes == nil, "missing memory degrades")
    check(metrics.healthStatus == "FAIL" && metrics.healthFailures == 2, "partial health remains")
}

func parserRejectsWrongEnvelope() {
    do {
        _ = try MiniGooseMetricsParser.parse("cpu_usage=1")
        check(false, "wrong envelope rejected")
    } catch let error as MiniGooseMetricsError {
        check(error == .missingMarker, "wrong envelope error")
    } catch {
        check(false, "wrong envelope error type")
    }
}

func statusFailurePreservesLastSampleAndBecomesCritical() {
    var status = MiniGooseStatus.idle
    var metrics = MiniGooseMetrics()
    metrics.healthStatus = "FAIL"
    metrics.healthFailures = 2
    status = status.success(metrics)
    check(status.severity == .critical, "health FAIL is critical")

    status = status.failure("ssh down")
    check(status.metrics != nil, "failure preserves last sample")
    check(status.history.count == 1, "failure preserves history")
    check(status.severity == .critical, "offline remains critical")
    check(status.shortMenuBarText == "鹅失联", "offline menu-bar text")

    for index in 0..<(MiniGooseStatus.historyLimit + 10) {
        var metrics = MiniGooseMetrics()
        metrics.cpuUsagePercent = Double(index % 100)
        status = status.success(
            metrics,
            at: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }
    check(status.history.count == MiniGooseStatus.historyLimit, "history is capped")
}

final class SwitchableMiniGooseRunner: MiniGooseCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _output = "MINIGOOSE_V1\n"
    private var _error: Error?

    var output: String {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = newValue } }
    }

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    func run(host: String, script: String) throws -> String {
        if let error { throw error }
        return output
    }
}

final class CountingMiniGooseRunner: MiniGooseCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var callCount = 0
    private(set) var maxConcurrentCalls = 0

    func run(host: String, script: String) throws -> String {
        lock.lock()
        active += 1
        callCount += 1
        maxConcurrentCalls = max(maxConcurrentCalls, active)
        lock.unlock()

        Thread.sleep(forTimeInterval: 0.05)

        lock.lock()
        active -= 1
        lock.unlock()
        return "MINIGOOSE_V1\nhealth_status=PASS\nhealth_failures=0\nhealth_age=1\n"
    }
}

func timeProgressFractionClampsAndRejects() {
    let hour: TimeInterval = 3600
    // 5h window, 1h elapsed → 0.2 (创始人举例的标线在 1/5 处)
    check(QuotaTimeProgress.fraction(elapsed: hour, duration: 5 * hour) == 0.2, "fraction 1/5 of 5h")
    check(QuotaTimeProgress.fraction(elapsed: 0, duration: 5 * hour) == 0, "fraction start is 0")
    check(QuotaTimeProgress.fraction(elapsed: 5 * hour, duration: 5 * hour) == 1, "fraction end is 1")
    // 上溢（now 已过 reset）钳到 1，不得外溢
    check(QuotaTimeProgress.fraction(elapsed: 6 * hour, duration: 5 * hour) == 1, "fraction clamps above 1")
    // 下溢（时钟回拨等）钳到 0
    check(QuotaTimeProgress.fraction(elapsed: -hour, duration: 5 * hour) == 0, "fraction clamps below 0")
    // negative-control：非法时长必须拦成 nil，不得返回数值伪装成功
    check(QuotaTimeProgress.fraction(elapsed: hour, duration: 0) == nil, "zero duration rejected")
    check(QuotaTimeProgress.fraction(elapsed: hour, duration: -hour) == nil, "negative duration rejected")
    check(QuotaTimeProgress.fraction(elapsed: hour, duration: .nan) == nil, "NaN duration rejected")
    // 服务端滚动窗口描述 → 秒：实测样本 300 + TIME_UNIT_MINUTE = 5 小时
    check(QuotaTimeProgress.windowDuration(duration: 300, timeUnit: "TIME_UNIT_MINUTE") == 18000, "window 300min = 18000s")
    check(QuotaTimeProgress.windowDuration(duration: 5, timeUnit: "TIME_UNIT_HOUR") == 18000, "window 5hour = 18000s")
    check(QuotaTimeProgress.windowDuration(duration: 1, timeUnit: "TIME_UNIT_DAY") == 86400, "window 1day = 86400s")
    // negative-control：非正时长 / 未知单位必须拦成 nil
    check(QuotaTimeProgress.windowDuration(duration: 0, timeUnit: "TIME_UNIT_MINUTE") == nil, "window zero duration rejected")
    check(QuotaTimeProgress.windowDuration(duration: 5, timeUnit: "TIME_UNIT_WEEK") == nil, "window unknown unit rejected")
    check(QuotaTimeProgress.windowDuration(duration: 5, timeUnit: nil) == nil, "window nil unit rejected")
}

// MARK: Cursor weekly included usage (new pricing endpoint /api/dashboard/v2/usage-status)

private let cursorWeeklyRealResponse = """
{"availability":"available",
 "monthlyUsage":{"usedCents":0,"limitCents":null,"additionalUsageOff":false,"creditsUsedCents":0,"periodStart":"2026-10-01T00:00:00.000Z","resetsAt":"2026-11-01T00:00:00.000Z"},
 "weeklyIncludedStatus":{"status":"metered"},
 "weeklyIncludedUsage":{"usedCents":483,"budgetCents":4615,"resetCounter":2,"periodStart":"2026-10-30T23:33:34.774Z","resetsAt":"2026-11-06T23:33:34.774Z"}}
"""

func cursorWeeklyParsesRealResponse() {
    guard let card = CursorWeeklyUsageParser.parse(cursorWeeklyRealResponse.data(using: .utf8)!) else {
        check(false, "weekly parses real response")
        return
    }
    check(abs(card.percentUsed - 10.4637) < 0.01, "weekly percent 10.46")
    check(abs(card.resetTime.timeIntervalSince(card.windowStart) - 7 * 24 * 3600) < 1, "weekly window is 7 days")
    check(card.resetTime > card.windowStart, "weekly reset after start")
}

func cursorWeeklyRejectsNonMeteredAndBadData() {
    func variant(_ patch: String) -> Data {
        ("""
        {"availability":"available","weeklyIncludedStatus":{"status":"\(patch)"}}
        """).data(using: .utf8)!
    }
    check(CursorWeeklyUsageParser.parse(variant("not_applicable")) == nil, "weekly rejects not_applicable")
    check(CursorWeeklyUsageParser.parse(variant("unavailable")) == nil, "weekly rejects unavailable")
    check(CursorWeeklyUsageParser.parse(Data("{\"availability\":\"identity_unlinked\"}".utf8)) == nil, "weekly rejects identity_unlinked")
    check(CursorWeeklyUsageParser.parse(Data("not json".utf8)) == nil, "weekly rejects garbage")
}

func cursorWeeklyRejectsInvalidNumbersAndDates() {
    func fixture(_ used: String, _ budget: String, _ start: String, _ resets: String) -> Data {
        ("""
        {"availability":"available","weeklyIncludedStatus":{"status":"metered"},
         "weeklyIncludedUsage":{"usedCents":\(used),"budgetCents":\(budget),"periodStart":"\(start)","resetsAt":"\(resets)"}}
        """).data(using: .utf8)!
    }
    check(CursorWeeklyUsageParser.parse(fixture("0", "0", "2026-10-30T23:33:34.774Z", "2026-11-06T23:33:34.774Z")) == nil, "weekly rejects zero budget")
    check(CursorWeeklyUsageParser.parse(fixture("-5", "4615", "2026-10-30T23:33:34.774Z", "2026-11-06T23:33:34.774Z")) == nil, "weekly rejects negative used")
    check(CursorWeeklyUsageParser.parse(fixture("483", "4615", "2026-11-06T23:33:34.774Z", "2026-10-30T23:33:34.774Z")) == nil, "weekly rejects reset before start")
    check(CursorWeeklyUsageParser.parse(fixture("483", "4615", "bad-date", "2026-11-06T23:33:34.774Z")) == nil, "weekly rejects bad date")
    check(CursorWeeklyUsageParser.parse(Data("{\"availability\":\"available\",\"weeklyIncludedStatus\":{\"status\":\"metered\"}}".utf8)) == nil, "weekly rejects missing usage block")
}

func cursorWeeklyClampsOverrun() {
    let json = """
    {"availability":"available","weeklyIncludedStatus":{"status":"metered"},
     "weeklyIncludedUsage":{"usedCents":5000,"budgetCents":4615,"periodStart":"2026-10-30T23:33:34.774Z","resetsAt":"2026-11-06T23:33:34.774Z"}}
    """
    guard let card = CursorWeeklyUsageParser.parse(json.data(using: .utf8)!) else {
        check(false, "weekly clamps overrun")
        return
    }
    check(card.percentUsed == 100, "weekly caps at 100%")
}

func monitorTransitionsFromFailureToSuccess() async {
    let runner = SwitchableMiniGooseRunner()
    runner.output = ""
    runner.error = MiniGooseRunnerError.executionFailed("host unreachable")
    let monitor = MiniGooseMonitor(runner: runner)

    let failed = await monitor.refresh(host: "bad")
    check(failed.lastError == "SSH 采集失败：host unreachable", "monitor surfaces SSH failure")

    runner.output = "MINIGOOSE_V1\ncpu_usage=12\nmem_total=100\nmem_used=50\nhealth_status=PASS\nhealth_failures=0\nhealth_age=5\n"
    runner.error = nil
    let succeeded = await monitor.refresh(host: "minigoose")
    check(succeeded.lastError == nil, "monitor clears error after recovery")
    check(succeeded.metrics?.cpuUsagePercent == 12, "monitor parses recovery cpu")
    check(succeeded.metrics?.memoryUsedPercent == 50, "monitor parses recovery memory")
}

func monitorDoesNotRunConcurrentCommands() async {
    let runner = CountingMiniGooseRunner()
    let monitor = MiniGooseMonitor(runner: runner)
    async let first = monitor.refresh(host: "minigoose")
    async let second = monitor.refresh(host: "minigoose")
    let statuses = await [first, second]
    check(statuses.allSatisfy { $0.lastError == nil }, "serial monitor refreshes both succeed")
    check(runner.callCount == 2, "serial monitor refreshes both run")
    check(runner.maxConcurrentCalls == 1, "SSH runner never overlaps")
}

do {
    if CommandLine.arguments.contains("--live") {
        let status = await MiniGooseMonitor().refresh(host: "minigoose")
        if let error = status.lastError {
            print("LIVE FAIL: \(error)")
            exit(1)
        }
        guard let metrics = status.metrics else {
            print("LIVE FAIL: no metrics")
            exit(1)
        }
        let cpu = metrics.cpuUsagePercent.map { String(format: "%.1f", $0) } ?? "--"
        let memory = metrics.memoryUsedPercent.map { String(format: "%.1f", $0) } ?? "--"
        let disk = metrics.diskUsedPercent.map { String(format: "%.0f", $0) } ?? "--"
        let age = metrics.healthAgeSeconds.map(String.init) ?? "--"
        let rx = metrics.rxBytesPerSecond.map(String.init) ?? "--"
        let tx = metrics.txBytesPerSecond.map(String.init) ?? "--"
        let ping = metrics.publicPingMilliseconds.map { String(format: "%.1f", $0) } ?? "--"
        let swapUsed = metrics.swapUsedBytes.map { String(format: "%.0fGB", Double($0) / 1_073_741_824) } ?? "--"
        print("LIVE PASS: cpu=\(cpu) memory=\(memory) swap=\(swapUsed) disk=\(disk) health=\(metrics.healthStatus ?? "--") age=\(age) rx=\(rx) tx=\(tx) ping=\(ping)")
        exit(0)
    }

    try parserParsesFullEnvelope()
    try parserPrefersActivityMonitorMemory()
    try parserAllowsMissingFields()
    parserRejectsWrongEnvelope()
    statusFailurePreservesLastSampleAndBecomesCritical()
    timeProgressFractionClampsAndRejects()
    cursorWeeklyParsesRealResponse()
    cursorWeeklyRejectsNonMeteredAndBadData()
    cursorWeeklyRejectsInvalidNumbersAndDates()
    cursorWeeklyClampsOverrun()
    await monitorTransitionsFromFailureToSuccess()
    await monitorDoesNotRunConcurrentCommands()

    if failures.isEmpty {
        print("TokenUsageSelfTest: \(passedCount) checks passed")
    } else {
        print("TokenUsageSelfTest: \(passedCount) passed, \(failures.count) FAILED")
        failures.forEach { print("FAIL: \($0)") }
        exit(1)
    }
} catch {
    print("TokenUsageSelfTest unexpected error: \(error)")
    exit(1)
}
