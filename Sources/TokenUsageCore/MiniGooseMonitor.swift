import Foundation

public protocol MiniGooseCommandRunning: Sendable {
    func run(host: String, script: String) throws -> String
}

/// Runs a short, read-only metrics script through the user's existing SSH
/// config. The app stores no SSH credentials and never installs a remote agent.
public struct ProcessMiniGooseCommandRunner: MiniGooseCommandRunning {
    public init() {}

    public func run(host: String, script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            // Two failure modes must both fit inside the 90s deadline below:
            // healthy direct path completes in ~2s; the Tailscale DERP relay
            // path (office double-NAT, no port mapping possible) needs 60-70s
            // for banner + the remote script. Only a genuinely dead host should
            // time out — a slow relay must still yield data.
            "-o", "ConnectTimeout=60",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            host,
            "/bin/zsh", "-s",
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        guard let inputData = script.data(using: .utf8) else {
            throw MiniGooseRunnerError.scriptEncodingFailed
        }
        stdin.fileHandleForWriting.write(inputData)
        try? stdin.fileHandleForWriting.close()

        do {
            try process.run()
        } catch {
            throw MiniGooseRunnerError.executionFailed(error.localizedDescription)
        }

        let deadline = DispatchTime.now() + .seconds(90)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw MiniGooseRunnerError.timeout
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MiniGooseRunnerError.executionFailed(message.isEmpty ? "SSH exit \(process.terminationStatus)" : message)
        }
        return output
    }
}

public enum MiniGooseRunnerError: LocalizedError {
    case scriptEncodingFailed
    case executionFailed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .scriptEncodingFailed:
            return "迷你鹅采集脚本编码失败"
        case .executionFailed(let message):
            return "SSH 采集失败：\(message)"
        case .timeout:
            return "迷你鹅 SSH 采集超时（90 秒）"
        }
    }
}

public actor MiniGooseMonitor {
    private let runner: MiniGooseCommandRunning
    private var pollingTask: Task<Void, Never>?
    private var isFetching = false
    private var currentStatus = MiniGooseStatus.idle

    /// The script deliberately emits an unstable-command-proof `key=value`
    /// envelope; individual commands may fail without losing the other fields.
    nonisolated static let remoteScript = """
#!/bin/zsh
set -u
now=$(date +%s)
top_out=$(top -l 1 -n 0)
cpu_idle=$(printf '%s\\n' "$top_out" | awk '/^CPU usage:/ {for(i=1;i<=NF;i++) if($(i) ~ /idle/) {gsub("%","",$(i-1)); print $(i-1)}}' | tail -1)
cpu_usage=${cpu_idle:+$(awk -v v="$cpu_idle" 'BEGIN {printf "%.1f", 100-v}')}
mem_used_text=$(printf '%s\\n' "$top_out" | sed -n 's/^PhysMem: \\([0-9][0-9.]*[KMGT]\\) used.*/\\1/p')
phys_used=$(awk -v raw="${mem_used_text:-}" 'BEGIN { if (raw == "") exit; scale=1048576; if (raw ~ /K$/) scale=1024; else if (raw ~ /G$/) scale=1073741824; else if (raw ~ /T$/) scale=1099511627776; sub(/[KMGT]$/, "", raw); printf "%.0f", raw*scale}')
load=$(sysctl -n vm.loadavg)
cores=$(sysctl -n hw.ncpu)
mem_total=$(sysctl -n hw.memsize)
vm=$(vm_stat)
page_size=$(vm_stat | awk -F'page size of ' 'NF>1 {gsub("[^0-9].*","",$2); print $2; exit}')
pg() { printf '%s\\n' "$vm" | awk -v pattern="$1" '$0 ~ pattern {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+[.]$/) {gsub("[.]","",$i); print $i; exit}}'; }
active_pages=$(pg 'Pages active:')
wired_pages=$(pg 'Pages wired down:')
compressed_pages=$(pg 'Pages occupied by compressor:')
throttled_pages=$(pg 'Pages throttled:')
if [[ -n "$page_size" && -n "$active_pages" && -n "$wired_pages" && -n "$compressed_pages" ]]; then
  app_mem_used=$(( (active_pages + wired_pages + compressed_pages + throttled_pages) * page_size ))
  mem_wired=$((wired_pages * page_size))
  mem_compressed=$((compressed_pages * page_size))
else
  app_mem_used=""; mem_wired=""; mem_compressed=""
fi
swap=$(sysctl vm.swapusage)
swap_total=$(printf '%s\\n' "$swap" | awk '{gsub("M","",$4); printf "%.0f", $4*1048576}')
swap_used=$(printf '%s\\n' "$swap" | awk '{gsub("M","",$7); printf "%.0f", $7*1048576}')
disk=$(df -k / | awk 'NR==2 {gsub("%","",$5); print $5, $4*1024}')
disk_used=${disk%% *}
disk_avail=${disk##* }
iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')
net_sample() { netstat -ibn | awk -v i="${iface:-}" '$1==i && $3 ~ /^<Link/ {print $7, $10, $6+$9}'; }
sample0=(${(s: :)$(net_sample)})
t0=$(date +%s)
sleep 1
sample1=(${(s: :)$(net_sample)})
t1=$(date +%s)
elapsed=$((t1-t0))
if [[ ${#sample0} -eq 3 && ${#sample1} -eq 3 && $elapsed -gt 0 && -n "$iface" ]]; then
  rx=$(( (sample1[1]-sample0[1])/elapsed ))
  tx=$(( (sample1[2]-sample0[2])/elapsed ))
  errors=$((sample1[3]))
else
  rx=""; tx=""; errors=""
fi
ping_ms=$(ping -c 1 -t 1 223.5.5.5 2>/dev/null | awk -F'time=' '/time=/ {gsub(/ ms.*/,"",$2); print $2; exit}')
hb=$(cat "$HOME/Claude/data/health-check-heartbeat" 2>/dev/null)
health_epoch=$(printf '%s\\n' "$hb" | sed -n 's/.*epoch=\\([0-9][0-9]*\\).*/\\1/p')
health_status=$(printf '%s\\n' "$hb" | sed -n 's/.*status=\\([^ ]*\\).*/\\1/p')
health_failures=$(printf '%s\\n' "$hb" | sed -n 's/.*failures=\\([0-9][0-9]*\\).*/\\1/p')
if [[ -n "$health_epoch" ]]; then health_age=$((now-health_epoch)); else health_age=""; fi
boot=$(sysctl -n kern.boottime | awk -F'sec = ' '{split($2,a,","); print a[1]; exit}')
if [[ -n "$boot" ]]; then uptime=$((now-boot)); else uptime=""; fi
print -- 'MINIGOOSE_V1'
print -- "now=$now"
print -- "cpu_usage=${cpu_usage:-}"
print -- "load=$load"
print -- "cores=${cores:-}"
print -- "mem_total=${mem_total:-}"
print -- "mem_used=${phys_used:-}"
print -- "app_mem_used=${app_mem_used:-}"
print -- "mem_wired=${mem_wired:-}"
print -- "mem_compressed=${mem_compressed:-}"
print -- "swap_used=${swap_used:-}"
print -- "swap_total=${swap_total:-}"
print -- "disk_used=${disk_used:-}"
print -- "disk_avail=${disk_avail:-}"
print -- "iface=${iface:-}"
print -- "rx=${rx:-}"
print -- "tx=${tx:-}"
print -- "errors=${errors:-}"
print -- "ping_ms=${ping_ms:-}"
print -- "health_status=${health_status:-}"
print -- "health_failures=${health_failures:-}"
print -- "health_age=${health_age:-}"
print -- "uptime=${uptime:-}"
"""

    public init(runner: MiniGooseCommandRunning = ProcessMiniGooseCommandRunner()) {
        self.runner = runner
    }

    public func startPolling(
        host: String,
        intervalSeconds: TimeInterval,
        onUpdate: @escaping @MainActor @Sendable (MiniGooseStatus) -> Void
    ) {
        stopPolling()
        let clamped = min(max(intervalSeconds, 10), 300)
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let before = await self.currentStatusForUI()
                await onUpdate(before.markingFetching())
                let updated = await self.refresh(host: host)
                await onUpdate(updated)
                try? await Task.sleep(for: .seconds(clamped))
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func refresh(host: String) async -> MiniGooseStatus {
        guard !isFetching else { return currentStatus }
        isFetching = true
        defer { isFetching = false }

        do {
            let output = try runner.run(host: host, script: Self.remoteScript)
            let metrics = try MiniGooseMetricsParser.parse(output)
            currentStatus = currentStatus.success(metrics)
        } catch {
            currentStatus = currentStatus.failure(error.localizedDescription)
        }
        return currentStatus
    }

    private func currentStatusForUI() -> MiniGooseStatus {
        currentStatus
    }
}
