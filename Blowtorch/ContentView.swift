import SwiftUI
import Combine

// MARK: - Connection Step Model
enum ConnectionStatus {
    case pending
    case inProgress
    case success
    case failed
    case needsAuth
}

struct ConnectionStep: Identifiable {
    let id: String
    let label: String
    var status: ConnectionStatus = .pending
    var detail: String? = nil
}

// MARK: - Queue Job Models
struct JobPriority {
    var priority: String = ""
    var age: String = ""
    var fairShare: String = ""
    var jobSize: String = ""
    var partition: String = ""
    var qos: String = ""
}

struct QueueJob: Identifiable {
    var id: String { jobId }
    let jobId: String
    let partition: String
    let name: String
    let state: String
    let timeUsed: String
    let timeLimit: String
    let nodes: String
    let cpus: String
    let memory: String
    let reason: String
    let startTime: String
    var priority: JobPriority? = nil
    
    var stateColor: Color {
        switch state {
        case "RUNNING": return .green
        case "PENDING": return .orange
        case "COMPLETING": return .blue
        default: return .secondary
        }
    }
    
    var stateIcon: String {
        switch state {
        case "RUNNING": return "play.circle.fill"
        case "PENDING": return "clock.fill"
        case "COMPLETING": return "checkmark.circle"
        default: return "questionmark.circle"
        }
    }
}

// MARK: - Cluster Load Model
struct ClusterPartitionInfo: Identifiable {
    var id: String { partition }
    let partition: String
    let totalNodes: Int
    let allocatedNodes: Int
    let idleNodes: Int
    let downNodes: Int
    let totalCPUs: Int
    let allocatedCPUs: Int
    let idleCPUs: Int
    let runningJobs: Int
    let pendingJobs: Int
}

// MARK: - Resource Usage Model
struct ResourceUsage {
    let memoryCurrentBytes: Int64
    let memoryMaxBytes: Int64
    let cpuUsageUsec: Int64
    let cpuUserUsec: Int64
    let cpuSystemUsec: Int64
    let nrThrottled: Int64

    var memoryCurrentFormatted: String {
        ByteCountFormatter.string(fromByteCount: memoryCurrentBytes, countStyle: .memory)
    }

    var memoryMaxFormatted: String {
        if memoryMaxBytes == Int64.max { return "Unlimited" }
        return ByteCountFormatter.string(fromByteCount: memoryMaxBytes, countStyle: .memory)
    }

    var memoryUsageFraction: Double {
        guard memoryMaxBytes > 0, memoryMaxBytes != Int64.max else { return 0 }
        return Double(memoryCurrentBytes) / Double(memoryMaxBytes)
    }

    var cpuUsageFormatted: String { formatUsec(cpuUsageUsec) }
    var cpuUserFormatted: String { formatUsec(cpuUserUsec) }
    var cpuSystemFormatted: String { formatUsec(cpuSystemUsec) }

    private func formatUsec(_ usec: Int64) -> String {
        let seconds = usec / 1_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 { return String(format: "%dh %02dm %02ds", hours, minutes, secs) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, secs) }
        return String(format: "%ds", secs)
    }
}

// MARK: - SSH Auth Manager
// Shared authentication helper. Establishes a ControlMaster session to the
// torch login node, surfacing the browser PIN and URL for the UI to display.
class SSHAuthManager: ObservableObject {
    @Published var authRequired = false
    @Published var authPIN: String = ""
    @Published var authURL: String = "https://login.microsoft.com/device"
    @Published var isAuthenticating = false
    @Published var errorMessage: String = ""

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var onReady: (() -> Void)?

    /// Returns true if a ControlMaster session to torch is already active.
    func isConnected() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-O", "check", "torch"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Ensures a ControlMaster session exists, triggering auth if needed.
    /// Calls `onReady` on the main queue when connected, or sets `errorMessage` on failure.
    func ensureConnected(onReady: @escaping () -> Void) {
        if isConnected() {
            onReady()
            return
        }

        DispatchQueue.main.async {
            self.isAuthenticating = true
            self.authRequired = false
            self.authPIN = ""
            self.errorMessage = ""
        }

        // Run ssh -NM (foreground) via PTY so the process stays alive and we can
        // capture the auth PIN. The process exits only after the ControlMaster closes.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", "/usr/bin/ssh", "-NM", "torch"]

        let out = Pipe()
        let inp = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = inp

        process = p
        inputPipe = inp
        outputPipe = out

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            DispatchQueue.main.async {
                if text.contains("NEEDS_AUTH") || text.contains("NEEDS_COMPUTE_AUTH") || text.contains("browser") || text.contains("microsoft.com") {
                    self.authRequired = true
                    self.isAuthenticating = false
                }
                // Extract PIN — typically "Enter code XXXXXXXX"
                if let range = text.range(of: #"[A-Z0-9]{8,9}"#, options: .regularExpression) {
                    let candidate = String(text[range])
                    if candidate != self.authPIN {
                        self.authPIN = candidate
                    }
                }
                // Extract URL
                if let range = text.range(of: #"https://\S+"#, options: .regularExpression) {
                    self.authURL = String(text[range])
                }
            }
        }

        // If the process exits unexpectedly (e.g. auth rejected), clean up.
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard self.isAuthenticating || self.authRequired else { return }
                self.isAuthenticating = false
                self.authRequired = false
                self.authPIN = ""
                self.errorMessage = "SSH process exited unexpectedly. Please try again."
            }
        }

        do {
            try p.run()
        } catch {
            DispatchQueue.main.async {
                self.isAuthenticating = false
                self.errorMessage = "Failed to start SSH: \(error.localizedDescription)"
            }
        }

        self.onReady = onReady
    }

    /// Send Enter to the SSH process after the user completes browser sign-in,
    /// then poll until the ControlMaster socket appears and call onReady.
    func continueAfterAuth() {
        if let data = "\n".data(using: .utf8) {
            inputPipe?.fileHandleForWriting.write(data)
        }
        authRequired = false
        authPIN = ""
        isAuthenticating = true

        // Poll for ControlMaster socket — ssh -NM stays running as the master,
        // so we can't wait for process exit. Instead poll isConnected().
        pollForConnection()
    }

    private func pollForConnection(attempts: Int = 0) {
        guard attempts < 20 else {
            DispatchQueue.main.async {
                self.isAuthenticating = false
                self.errorMessage = "Timed out waiting for SSH connection. Please try again."
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if self.isConnected() {
                DispatchQueue.main.async {
                    self.isAuthenticating = false
                    self.errorMessage = ""
                    self.onReady?()
                    self.onReady = nil
                }
            } else {
                self.pollForConnection(attempts: attempts + 1)
            }
        }
    }

    func openAuthURL() {
        if let url = URL(string: authURL) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - SSH Auth Card View
// Drop-in card shown whenever SSHAuthManager.authRequired is true.
struct SSHAuthCardView: View {
    @ObservedObject var auth: SSHAuthManager

    var body: some View {
        GroupBox {
            VStack(spacing: 12) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)

                Text("Sign in Required")
                    .font(.headline)

                if !auth.authPIN.isEmpty {
                    VStack(spacing: 4) {
                        Text("Enter this code:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Text(auth.authPIN)
                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                .textSelection(.enabled)

                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(auth.authPIN, forType: .string)
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy to clipboard")
                        }
                    }
                    .padding(.vertical, 8)
                }

                Button(action: { auth.openAuthURL() }) {
                    HStack {
                        Image(systemName: "safari")
                        Text("Open Browser")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button(action: { auth.continueAfterAuth() }) {
                    HStack {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("Continue")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Text("Complete sign-in in browser, then click Continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
        }
    }
}

// MARK: - Shared SSH Utilities

/// Runs a command on the torch login node via the existing ControlMaster session.
/// Must be called from a background thread (blocks until the command completes).
/// The optional `processCallback` is called on the main thread with the Process just before launch,
/// allowing the caller to store it for cancellation.
func runSSHCommand(_ command: String, processCallback: ((Process?) -> Void)? = nil) -> (success: Bool, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = [
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=10",
        "torch", command
    ]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    if let cb = processCallback {
        DispatchQueue.main.async { cb(process) }
    }

    do {
        try process.run()
        // Read output before waitUntilExit to avoid pipe buffer deadlock.
        // If the process produces >64KB of output, waitUntilExit blocks
        // because the pipe is full and the process can't write more.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if let cb = processCallback {
            DispatchQueue.main.async { cb(nil) }
        }
        return (process.terminationStatus == 0, output)
    } catch {
        if let cb = processCallback {
            DispatchQueue.main.async { cb(nil) }
        }
        return (false, error.localizedDescription)
    }
}

/// Removes the conda Machine settings and terminal init script from the cluster.
/// Uses the login node since $HOME is shared across all nodes.
/// Safe to call when no settings exist — rm -f is a no-op.
func cleanupCondaBlock() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = [
        "-o", "ConnectTimeout=3",
        "-o", "ConnectionAttempts=1",
        "torch",
        "rm -f ~/.vscode-server/data/Machine/settings.json 2>/dev/null; " +
        "rm -f ~/.positron-server/data/Machine/settings.json 2>/dev/null; " +
        "rm -f /tmp/torch-conda-init.sh 2>/dev/null; " +
        "echo done"
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

/// Parses `module avail conda` output and returns the latest anaconda3/YYYY.MM module name.
func parseLatestCondaModule(from output: String) -> String? {
    let tokens = output.components(separatedBy: .whitespacesAndNewlines)
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "(D)")) }
        .filter { !$0.isEmpty }
    let pattern = #"^anaconda3/\d{4}\.\d{2}$"#
    let versions = tokens.filter { $0.range(of: pattern, options: .regularExpression) != nil }
    return versions.sorted().last
}

// MARK: - Connection Manager
class ConnectionManager: ObservableObject {
    @Published var steps: [ConnectionStep] = []
    @Published var logOutput: String = ""
    @Published var isRunning = false
    @Published var authRequired = false
    @Published var authPIN: String = ""
    @Published var authURL: String = "https://login.microsoft.com/device"
    @Published var completedSuccessfully = false
    @Published var failed = false
    @Published var isWaitingForNode = false
    @Published var queueJobs: [QueueJob] = []
    @Published var showingQueueStatus = false
    @Published var clusterLoad: [ClusterPartitionInfo] = []
    @Published var showingClusterLoad = false
    @Published var resourceUsage: ResourceUsage?
    @Published var showingResourceUsage = false
    @Published var isLoadingResourceUsage = false
    @Published var resourceUsageError: String?
    @Published var jobId: String?
    @Published var nodeName: String?
    @Published var jobPartition: String = ""
    @Published var jobCPUs: Int = 0
    @Published var jobRAM: Int = 0
    @Published var jobGPU: Bool = false
    @Published var jobHours: Int = 0

    private var process: Process?
    private var inputPipe: Pipe?
    
    func start(account: String, hours: Int, partition: String, cpus: Int, ram: Int, gpu: Bool, project: String, ide: String, condaEnv: String) {
        // Reset state
        var stepList = [
            ConnectionStep(id: "auth", label: "Authenticating"),
            ConnectionStep(id: "submit", label: "Submitting job"),
            ConnectionStep(id: "allocate", label: "Waiting for compute node"),
            ConnectionStep(id: "tunnel", label: "Starting tunnel"),
            ConnectionStep(id: "ssh", label: "Connecting to node"),
        ]
        if !condaEnv.isEmpty {
            stepList.append(ConnectionStep(id: "conda", label: "Configuring \(condaEnv)"))
        }
        stepList.append(ConnectionStep(id: "ide", label: "Launching \(ide == "positron" ? "Positron" : "VS Code")"))
        steps = stepList
        logOutput = ""
        isRunning = true
        authRequired = false
        authPIN = ""
        completedSuccessfully = false
        failed = false
        isWaitingForNode = false
        jobId = nil
        nodeName = nil
        jobPartition = partition
        jobCPUs = cpus
        jobRAM = ram
        jobGPU = gpu
        jobHours = hours
        resourceUsage = nil
        resourceUsageError = nil
        isLoadingResourceUsage = false
        
        // Clean up any stale trigger file from previous runs
        let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/torch")
        let triggerPath = configDir.appendingPathComponent("auth_continue")
        try? FileManager.default.removeItem(at: triggerPath)
        
        // Get script path
        guard let scriptURL = Bundle.main.url(forResource: "torch-dev", withExtension: "sh") else {
            appendLog("Error: Script not found in bundle")
            failed = true
            isRunning = false
            return
        }
        
        // Create wrapper script that sources the main script (avoids execute permission issues)
        let gpuValue = gpu ? "yes" : "no"
        let wrapperScript = """
        #!/bin/bash
        export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
        export TORCH_ACCOUNT="\(account)"
        export TORCH_HOURS="\(hours)"
        export TORCH_PARTITION="\(partition)"
        export TORCH_CPUS="\(cpus)"
        export TORCH_RAM="\(ram)"
        export TORCH_GPU="\(gpuValue)"
        export TORCH_PROJECT="\(project)"
        export TORCH_IDE="\(ide)"
        export TORCH_CONDA_ENV="\(condaEnv)"
        export TORCH_SKIP_PROMPTS="1"
        source "\(scriptURL.path)"
        """
        
        let tempDir = FileManager.default.temporaryDirectory
        let wrapperURL = tempDir.appendingPathComponent("torch-launch.sh")
        
        do {
            try wrapperScript.write(to: wrapperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
        } catch {
            appendLog("Error: Failed to write wrapper script: \(error)")
            failed = true
            isRunning = false
            return
        }
        
        // Run script with a PTY using 'script' command for proper terminal emulation
        process = Process()
        process?.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process?.arguments = ["-q", "/dev/null", "/bin/bash", wrapperURL.path]
        
        let outputPipe = Pipe()
        inputPipe = Pipe()
        process?.standardOutput = outputPipe
        process?.standardError = outputPipe
        process?.standardInput = inputPipe
        
        // Read output asynchronously
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                DispatchQueue.main.async {
                    self?.processOutput(output)
                }
            }
        }
        
        process?.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.isRunning = false
                if process.terminationStatus == 0 {
                    self?.completedSuccessfully = true
                } else if !(self?.authRequired ?? false) {
                    self?.failed = true
                }
            }
        }
        
        do {
            try process?.run()
            updateStep("auth", status: .inProgress)
        } catch {
            appendLog("Error: Failed to start script: \(error)")
            failed = true
            isRunning = false
        }
    }
    
    func cancel() {
        process?.terminate()
        isRunning = false
        failed = true
        appendLog("\n— Cancelled —")
        
        // Cancel the Slurm job if one was submitted
        if let id = jobId {
            let scancelProcess = Process()
            scancelProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            scancelProcess.arguments = ["torch", "bash -lc 'scancel \(id) 2>/dev/null || true'"]
            try? scancelProcess.run()
            jobId = nil
        }
        
        // Clean up conda activation block from shell init files
        DispatchQueue.global(qos: .utility).async {
            cleanupCondaBlock()
        }
    }
    
    func openAuthURL() {
        if let url = URL(string: authURL) {
            NSWorkspace.shared.open(url)
        }
    }
    
    func continueAfterAuth() {
        // Send Enter to the process via stdin
        if let data = "\n".data(using: .utf8) {
            inputPipe?.fileHandleForWriting.write(data)
        }
        
        updateStep("auth", status: .inProgress, detail: "Connecting...")
    }
    
    func checkQueue() {
        // Run squeue with parseable output
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // Get detailed job info in a parseable format
        process.arguments = ["torch", """
            bash -lc 'echo "=== SQUEUE ===" && \
            squeue -u $USER -o "%i|%P|%j|%T|%M|%l|%D|%C|%m|%r|%S" 2>/dev/null && \
            echo "=== SPRIO ===" && \
            sprio -u $USER -o "%i|%Y|%A|%F|%J|%P|%Q" 2>/dev/null'
            """]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        process.terminationHandler = { [weak self] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.parseQueueOutput(output)
                    self?.showingQueueStatus = true
                }
            }
        }
        
        try? process.run()
    }
    
    private func parseQueueOutput(_ output: String) {
        var jobs: [QueueJob] = []
        var priorities: [String: JobPriority] = [:]
        
        let lines = output.components(separatedBy: .newlines)
        var inSqueue = false
        var inSprio = false
        
        for line in lines {
            if line.contains("=== SQUEUE ===") {
                inSqueue = true
                inSprio = false
                continue
            }
            if line.contains("=== SPRIO ===") {
                inSqueue = false
                inSprio = true
                continue
            }
            
            let parts = line.components(separatedBy: "|")
            
            if inSqueue && parts.count >= 10 {
                // Skip header
                if parts[0].trimmingCharacters(in: .whitespaces) == "JOBID" { continue }
                
                let job = QueueJob(
                    jobId: parts[0].trimmingCharacters(in: .whitespaces),
                    partition: parts[1].trimmingCharacters(in: .whitespaces),
                    name: parts[2].trimmingCharacters(in: .whitespaces),
                    state: parts[3].trimmingCharacters(in: .whitespaces),
                    timeUsed: parts[4].trimmingCharacters(in: .whitespaces),
                    timeLimit: parts[5].trimmingCharacters(in: .whitespaces),
                    nodes: parts[6].trimmingCharacters(in: .whitespaces),
                    cpus: parts[7].trimmingCharacters(in: .whitespaces),
                    memory: parts[8].trimmingCharacters(in: .whitespaces),
                    reason: parts[9].trimmingCharacters(in: .whitespaces),
                    startTime: parts.count > 10 ? parts[10].trimmingCharacters(in: .whitespaces) : ""
                )
                jobs.append(job)
            }
            
            if inSprio && parts.count >= 6 {
                // Skip header
                if parts[0].trimmingCharacters(in: .whitespaces) == "JOBID" { continue }
                
                let jobId = parts[0].trimmingCharacters(in: .whitespaces)
                priorities[jobId] = JobPriority(
                    priority: parts[1].trimmingCharacters(in: .whitespaces),
                    age: parts[2].trimmingCharacters(in: .whitespaces),
                    fairShare: parts[3].trimmingCharacters(in: .whitespaces),
                    jobSize: parts[4].trimmingCharacters(in: .whitespaces),
                    partition: parts[5].trimmingCharacters(in: .whitespaces),
                    qos: parts.count > 6 ? parts[6].trimmingCharacters(in: .whitespaces) : ""
                )
            }
        }
        
        // Merge priority info into jobs
        for i in jobs.indices {
            if let prio = priorities[jobs[i].jobId] {
                jobs[i].priority = prio
            }
        }
        
        self.queueJobs = jobs
    }
    
    func checkClusterLoad() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["torch", """
            bash -lc 'echo "=== SINFO ===" && \
            sinfo -o "%P|%a|%D|%A|%C" --noheader 2>/dev/null && \
            echo "=== SQUEUE_SUMMARY ===" && \
            squeue -o "%T" --noheader 2>/dev/null | sort | uniq -c'
            """]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        process.terminationHandler = { [weak self] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.parseClusterLoadOutput(output)
                    self?.showingClusterLoad = true
                }
            }
        }
        
        try? process.run()
    }
    
    private func parseClusterLoadOutput(_ output: String) {
        var partitions: [ClusterPartitionInfo] = []
        var jobCounts: [String: Int] = [:]
        
        let lines = output.components(separatedBy: .newlines)
        var inSinfo = false
        var inSqueueSummary = false
        
        for line in lines {
            if line.contains("=== SINFO ===") {
                inSinfo = true
                inSqueueSummary = false
                continue
            }
            if line.contains("=== SQUEUE_SUMMARY ===") {
                inSinfo = false
                inSqueueSummary = true
                continue
            }
            
            if inSqueueSummary {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2, let count = Int(parts[0]) {
                    jobCounts[parts[1]] = count
                }
            }
            
            if inSinfo {
                let parts = line.components(separatedBy: "|")
                if parts.count >= 5 {
                    let partName = parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
                    let totalNodes = Int(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0
                    
                    // Parse allocated/idle from column 4 (format: "allocated/idle")
                    let nodeParts = parts[3].trimmingCharacters(in: .whitespaces).components(separatedBy: "/")
                    let allocNodes = Int(nodeParts.first ?? "0") ?? 0
                    let idleNodes = nodeParts.count > 1 ? (Int(nodeParts[1]) ?? 0) : 0
                    
                    // Parse CPUs from column 5 (format: "allocated/idle/other/total")
                    let cpuParts = parts[4].trimmingCharacters(in: .whitespaces).components(separatedBy: "/")
                    let allocCPUs = Int(cpuParts.first ?? "0") ?? 0
                    let idleCPUs = cpuParts.count > 1 ? (Int(cpuParts[1]) ?? 0) : 0
                    let totalCPUs = cpuParts.count > 3 ? (Int(cpuParts[3]) ?? 0) : 0
                    
                    let downNodes = totalNodes - allocNodes - idleNodes
                    
                    partitions.append(ClusterPartitionInfo(
                        partition: partName,
                        totalNodes: totalNodes,
                        allocatedNodes: allocNodes,
                        idleNodes: idleNodes,
                        downNodes: max(0, downNodes),
                        totalCPUs: totalCPUs,
                        allocatedCPUs: allocCPUs,
                        idleCPUs: idleCPUs,
                        runningJobs: 0,
                        pendingJobs: 0
                    ))
                }
            }
        }
        
        // Attach global job counts to the first partition for display
        let running = jobCounts["RUNNING"] ?? 0
        let pending = jobCounts["PENDING"] ?? 0
        if !partitions.isEmpty {
            partitions[0] = ClusterPartitionInfo(
                partition: partitions[0].partition,
                totalNodes: partitions[0].totalNodes,
                allocatedNodes: partitions[0].allocatedNodes,
                idleNodes: partitions[0].idleNodes,
                downNodes: partitions[0].downNodes,
                totalCPUs: partitions[0].totalCPUs,
                allocatedCPUs: partitions[0].allocatedCPUs,
                idleCPUs: partitions[0].idleCPUs,
                runningJobs: running,
                pendingJobs: pending
            )
        }
        
        self.clusterLoad = partitions
    }
    
    func checkResourceUsage() {
        guard let jobId = jobId else {
            resourceUsageError = "No job ID available"
            showingResourceUsage = true
            return
        }

        isLoadingResourceUsage = true
        resourceUsageError = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // Dynamically locate the cgroup directory for this job (path varies by node configuration)
        process.arguments = ["torch-compute", """
            CGROUP=$(find /sys/fs/cgroup -type d -name "job_\(jobId)" 2>/dev/null | head -1) && \
            if [ -z "$CGROUP" ]; then echo "CGROUP_NOT_FOUND"; exit 1; fi && \
            echo "=== MEMORY ===" && cat "$CGROUP/memory.current" 2>/dev/null && \
            echo "=== MEMORY_MAX ===" && cat "$CGROUP/memory.max" 2>/dev/null && \
            echo "=== CPU ===" && cat "$CGROUP/cpu.stat" 2>/dev/null
            """]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { [weak self] proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self?.isLoadingResourceUsage = false
                if output.contains("CGROUP_NOT_FOUND") {
                    self?.resourceUsageError = "Could not find cgroup directory for job \(jobId)."
                } else if proc.terminationStatus == 0 {
                    self?.parseResourceUsage(output)
                } else {
                    self?.resourceUsageError = "Failed to read resource usage from compute node."
                }
                self?.showingResourceUsage = true
            }
        }

        try? process.run()
    }

    private func parseResourceUsage(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        var memoryCurrent: Int64 = 0
        var memoryMax: Int64 = 0
        var cpuUsage: Int64 = 0
        var cpuUser: Int64 = 0
        var cpuSystem: Int64 = 0
        var nrThrottled: Int64 = 0

        var section = ""
        for line in lines {
            if line.contains("=== MEMORY ===") { section = "memory"; continue }
            if line.contains("=== MEMORY_MAX ===") { section = "memory_max"; continue }
            if line.contains("=== CPU ===") { section = "cpu"; continue }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            switch section {
            case "memory":
                if let val = Int64(trimmed) { memoryCurrent = val }
            case "memory_max":
                if trimmed == "max" {
                    memoryMax = Int64.max
                } else if let val = Int64(trimmed) {
                    memoryMax = val
                }
            case "cpu":
                let parts = trimmed.components(separatedBy: .whitespaces)
                if parts.count >= 2, let val = Int64(parts[1]) {
                    switch parts[0] {
                    case "usage_usec":   cpuUsage = val
                    case "user_usec":    cpuUser = val
                    case "system_usec":  cpuSystem = val
                    case "nr_throttled": nrThrottled = val
                    default: break
                    }
                }
            default: break
            }
        }

        resourceUsage = ResourceUsage(
            memoryCurrentBytes: memoryCurrent,
            memoryMaxBytes: memoryMax,
            cpuUsageUsec: cpuUsage,
            cpuUserUsec: cpuUser,
            cpuSystemUsec: cpuSystem,
            nrThrottled: nrThrottled
        )
    }

    private func appendLog(_ text: String) {
        // Strip ANSI escape codes for clean display
        let stripped = text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        logOutput += stripped
    }
    
    private func updateStep(_ id: String, status: ConnectionStatus, detail: String? = nil) {
        if let index = steps.firstIndex(where: { $0.id == id }) {
            steps[index].status = status
            if let detail = detail {
                steps[index].detail = detail
            }
        }
    }
    
    private func processOutput(_ output: String) {
        appendLog(output)
        
        // Parse output for status updates
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            // Check for auth needed (login node)
            if line.contains("NEEDS_AUTH") {
                authRequired = true
                updateStep("auth", status: .needsAuth, detail: "Browser sign-in required")
            }

            // Check for auth needed (compute node)
            if line.contains("NEEDS_COMPUTE_AUTH") {
                authRequired = true
                updateStep("ssh", status: .needsAuth, detail: "Browser sign-in required for compute node")
            }
            
            // Check for auth prompt - extract PIN code
            if line.contains("Authenticate with PIN") {
                authRequired = true
                updateStep("auth", status: .needsAuth, detail: "Browser sign-in required")
                
                // Extract PIN using regex
                if let pinMatch = line.range(of: "PIN\\s+([A-Z0-9]+)", options: .regularExpression) {
                    let pinSubstring = line[pinMatch]
                    let pin = pinSubstring.replacingOccurrences(of: "PIN ", with: "").trimmingCharacters(in: .whitespaces)
                    authPIN = pin
                }
                
                // Extract URL if present
                if let urlMatch = line.range(of: "https://[^\\s]+", options: .regularExpression) {
                    authURL = String(line[urlMatch])
                }
            }
            
            // Auth success
            if line.contains("Authenticated successfully") || line.contains("Already authenticated") {
                authRequired = false
                authPIN = ""
                updateStep("auth", status: .success)
                updateStep("submit", status: .inProgress)
            }
            
            // Job submitted
            if line.contains("Submitted job") {
                if let jobId = line.components(separatedBy: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines), !jobId.isEmpty {
                    self.jobId = jobId
                    updateStep("submit", status: .success, detail: "Job \(jobId)")
                }
                updateStep("allocate", status: .inProgress)
                isWaitingForNode = true
            }
            
            // Waiting dots
            if line.contains("Waiting for compute node") {
                updateStep("allocate", status: .inProgress)
                isWaitingForNode = true
            }
            
            // Allocated
            if line.contains("Allocated:") {
                isWaitingForNode = false
                let node = line.replacingOccurrences(of: ".*Allocated:\\s*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
                updateStep("allocate", status: .success, detail: node)
                nodeName = node
                updateStep("tunnel", status: .inProgress)
            }
            
            // Tunnel active
            if line.contains("Tunnel active") {
                updateStep("tunnel", status: .success)
                updateStep("ssh", status: .inProgress)
            }
            
            // SSH ready / Waiting for SSH
            if line.contains("Waiting for SSH") {
                updateStep("ssh", status: .inProgress)
            }
            
            // SSH config updated means SSH is working
            if line.contains("Updating SSH config") {
                updateStep("ssh", status: .inProgress)
            }
            
            // Conda environment activation
            if line.contains("Activating conda environment") {
                updateStep("ssh", status: .success)
                updateStep("conda", status: .inProgress)
            }
            if line.contains("Conda environment configured:") {
                updateStep("conda", status: .success)
            }
            if line.contains("Could not locate conda") || line.contains("failed to write conda settings") {
                updateStep("conda", status: .failed)
            }
            
            // Launching IDE or CLI not found (connection succeeded either way)
            if line.contains("Launching VS Code") || line.contains("Launching Positron") {
                updateStep("ssh", status: .success)
                // Mark conda as success if it was in progress (shouldn't happen but be safe)
                if let idx = steps.firstIndex(where: { $0.id == "conda" }), steps[idx].status == .inProgress {
                    updateStep("conda", status: .success)
                }
                updateStep("ide", status: .success)
            }
            
            // CLI not found - connection worked but IDE not installed locally
            if line.contains("CLI not found") {
                updateStep("ssh", status: .success)
                updateStep("ide", status: .success, detail: "Install CLI to auto-launch")
            }
            
            // Session info indicates full success
            if line.contains("Session info:") {
                updateStep("ssh", status: .success)
                // Mark IDE as success if not already
                if let idx = steps.firstIndex(where: { $0.id == "ide" }), steps[idx].status != .success {
                    updateStep("ide", status: .success)
                }
                completedSuccessfully = true
            }
            
            // Errors
            if line.contains("failed") || line.contains("Error") || line.contains("Timed out") {
                failed = true
            }
        }
    }
}

// MARK: - SSH Config Manager
class SSHConfigManager: ObservableObject {
    @Published var isConfigured = false
    @Published var currentUsername: String = ""
    
    private let sshConfigPath: URL
    
    init() {
        sshConfigPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        checkConfig()
    }
    
    func checkConfig() {
        guard FileManager.default.fileExists(atPath: sshConfigPath.path),
              let contents = try? String(contentsOf: sshConfigPath, encoding: .utf8) else {
            isConfigured = false
            currentUsername = ""
            return
        }
        
        // Check if Host torch exists with required fields
        let lines = contents.components(separatedBy: .newlines)
        var inTorchBlock = false
        var hasHostname = false
        var hasUser = false
        var hasControlMaster = false
        var username = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("Host ") && !trimmed.contains("*") {
                if trimmed == "Host torch" || trimmed.hasPrefix("Host torch ") {
                    inTorchBlock = true
                } else if inTorchBlock {
                    break // End of torch block
                }
            }
            
            if inTorchBlock {
                if trimmed.lowercased().hasPrefix("hostname") && trimmed.contains("torch.hpc.nyu.edu") {
                    hasHostname = true
                }
                if trimmed.lowercased().hasPrefix("user ") {
                    hasUser = true
                    username = trimmed.components(separatedBy: .whitespaces).last ?? ""
                }
                if trimmed.lowercased().hasPrefix("controlmaster") {
                    hasControlMaster = true
                }
            }
        }
        
        isConfigured = hasHostname && hasUser && hasControlMaster
        currentUsername = username
    }
    
    func setupConfig(username: String) -> Bool {
        let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        
        // Create .ssh directory if needed
        try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        
        // Read existing config or start fresh
        var existingConfig = (try? String(contentsOf: sshConfigPath, encoding: .utf8)) ?? ""
        
        // Remove existing torch block if present
        let lines = existingConfig.components(separatedBy: .newlines)
        var newLines: [String] = []
        var inTorchBlock = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed == "Host torch" || trimmed.hasPrefix("Host torch ") && !trimmed.contains("torch-compute") {
                inTorchBlock = true
                continue
            }
            
            if inTorchBlock && trimmed.hasPrefix("Host ") {
                inTorchBlock = false
            }
            
            if !inTorchBlock {
                newLines.append(line)
            }
        }
        
        // Remove trailing empty lines
        while let last = newLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            newLines.removeLast()
        }
        
        existingConfig = newLines.joined(separator: "\n")
        
        // Add torch config
        let torchConfig = """
        
        Host torch
            HostName login.torch.hpc.nyu.edu
            User \(username)
            ForwardX11 no
            ServerAliveInterval 30
            ServerAliveCountMax 120
            TCPKeepAlive no
            ControlMaster auto
            ControlPersist 30m
            ControlPath ~/.ssh/cm-%r@%h:%p
            ForwardAgent yes
            StrictHostKeyChecking no
            UserKnownHostsFile /dev/null
        """
        
        let finalConfig = existingConfig + torchConfig + "\n"
        
        do {
            // Backup existing config
            if FileManager.default.fileExists(atPath: sshConfigPath.path) {
                let backupPath = sshConfigPath.appendingPathExtension("backup")
                try? FileManager.default.removeItem(at: backupPath)
                try? FileManager.default.copyItem(at: sshConfigPath, to: backupPath)
            }
            
            try finalConfig.write(to: sshConfigPath, atomically: true, encoding: .utf8)
            
            // Set permissions to 600
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sshConfigPath.path)
            
            checkConfig()
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Progress View
struct ConnectionProgressView: View {
    @ObservedObject var manager: ConnectionManager
    @Environment(\.dismiss) var dismiss
    @State private var showLog = false
    
    private var detailCount: Int {
        manager.steps.filter { $0.detail != nil }.count
    }
    
    private var sheetHeight: CGFloat {
        if showLog {
            return 560
        } else if manager.authRequired {
            return 440
        } else {
            return 380 + CGFloat(detailCount) * 18
        }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Connecting to Torch")
                    .font(.headline)
                Spacer()
                if manager.isRunning && !manager.authRequired {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(.bottom, 8)
            
            // Steps
            VStack(alignment: .leading, spacing: 12) {
                ForEach(manager.steps) { step in
                    HStack(spacing: 12) {
                        stepIcon(for: step.status)
                            .frame(width: 20)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.label)
                                .foregroundStyle(step.status == .pending ? .secondary : .primary)
                            if let detail = step.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        Spacer()
                    }
                }
            }
            
            // Auth card
            if manager.authRequired {
                GroupBox {
                    VStack(spacing: 12) {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.blue)
                        
                        Text("Sign in Required")
                            .font(.headline)
                        
                        if !manager.authPIN.isEmpty {
                            VStack(spacing: 4) {
                                Text("Enter this code:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                HStack(spacing: 8) {
                                    Text(manager.authPIN)
                                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                                        .textSelection(.enabled)
                                    
                                    Button(action: {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(manager.authPIN, forType: .string)
                                    }) {
                                        Image(systemName: "doc.on.doc")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Copy to clipboard")
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        
                        Button(action: { manager.openAuthURL() }) {
                            HStack {
                                Image(systemName: "safari")
                                Text("Open Browser")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        
                        Button(action: { manager.continueAfterAuth() }) {
                            HStack {
                                Image(systemName: "arrow.right.circle.fill")
                                Text("Continue")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        
                        Text("Complete sign-in in browser, then click Continue.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(12)
                }
            }
            
            // Check Queue / Cluster Load buttons (shown when waiting for allocation)
            if manager.isWaitingForNode {
                HStack(spacing: 8) {
                    Button(action: { manager.checkQueue() }) {
                        HStack {
                            Image(systemName: "list.number")
                            Text("Queue Status")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button(action: { manager.checkClusterLoad() }) {
                        HStack {
                            Image(systemName: "gauge.medium")
                            Text("Cluster Load")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            // Log section with toggle
            VStack(spacing: 8) {
                Button(action: { withAnimation { showLog.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: showLog ? "chevron.down" : "chevron.right")
                            .font(.caption)
                        Image(systemName: "terminal")
                        Text("Output")
                            .font(.caption)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                
                if showLog {
                    GroupBox {
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(manager.logOutput.isEmpty ? "Starting..." : manager.logOutput)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id("log")
                            }
                            .onChange(of: manager.logOutput) {
                                proxy.scrollTo("log", anchor: .bottom)
                            }
                        }
                    }
                    .frame(height: 150)
                }
            }
            
            Spacer()
            
            // Buttons
            HStack {
                if manager.isRunning {
                    Button("Cancel") {
                        manager.cancel()
                    }
                    .keyboardShortcut(.cancelAction)
                } else if manager.failed {
                    Button("Close") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 400, height: sheetHeight)
        .animation(.easeInOut(duration: 0.2), value: manager.authRequired)
        .animation(.easeInOut(duration: 0.2), value: showLog)
        .animation(.easeInOut(duration: 0.2), value: detailCount)
        .onChange(of: manager.completedSuccessfully) {
            if manager.completedSuccessfully {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $manager.showingQueueStatus) {
            QueueStatusView(jobs: manager.queueJobs, isPresented: $manager.showingQueueStatus)
        }
        .sheet(isPresented: $manager.showingClusterLoad) {
            ClusterLoadView(partitions: manager.clusterLoad, isPresented: $manager.showingClusterLoad)
        }
    }
    
    @ViewBuilder
    func stepIcon(for status: ConnectionStatus) -> some View {
        Group {
            switch status {
            case .pending:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            case .inProgress:
                ProgressView()
                    .scaleEffect(0.5)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .needsAuth:
                Image(systemName: "person.badge.key.fill")
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: - SSH Setup View
struct SSHSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var configManager: SSHConfigManager
    
    @State private var username: String = ""
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
                Text("SSH Configuration")
                    .font(.title2.bold())
                Text("Configure SSH for Torch HPC access")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            // Status
            if configManager.isConfigured {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("SSH is configured")
                        .font(.headline)
                }
                
                GroupBox {
                    HStack {
                        Text("Username:")
                            .foregroundStyle(.secondary)
                        Text(configManager.currentUsername)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                }
                
                Text("Your SSH config includes the torch host. You can update it below if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("SSH not configured")
                        .font(.headline)
                }
                
                Text("Enter your NYU NetID to configure SSH access to the Torch cluster.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Divider()
            
            // Username input
            VStack(alignment: .leading, spacing: 8) {
                Text("NYU NetID")
                    .font(.headline)
                
                TextField("e.g., abc123", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .onAppear {
                        username = configManager.currentUsername
                    }
                
                Text("This is your NYU username (the part before @nyu.edu)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button(configManager.isConfigured ? "Update" : "Configure") {
                    let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    
                    guard !trimmedUsername.isEmpty else {
                        errorMessage = "Please enter your NYU NetID"
                        showError = true
                        return
                    }
                    
                    guard trimmedUsername.range(of: "^[a-z]{2,3}[0-9]+$", options: .regularExpression) != nil else {
                        errorMessage = "NetID should be 2-3 letters followed by numbers (e.g., abc123)"
                        showError = true
                        return
                    }
                    
                    if configManager.setupConfig(username: trimmedUsername) {
                        dismiss()
                    } else {
                        errorMessage = "Failed to write SSH config. Check file permissions."
                        showError = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360, height: 420)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }
}

// MARK: - Queue Status View
struct QueueStatusView: View {
    let jobs: [QueueJob]
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "list.number")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Queue Status")
                    .font(.headline)
                Spacer()
                Text("\(jobs.count) job\(jobs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            if jobs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No jobs in queue")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(jobs) { job in
                            JobCardView(job: job)
                        }
                    }
                }
            }
            
            Button("Done") {
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 420, height: 360)
    }
}

// MARK: - Cluster Load View
struct ClusterLoadView: View {
    let partitions: [ClusterPartitionInfo]
    @Binding var isPresented: Bool
    
    private var totalRunning: Int {
        partitions.first?.runningJobs ?? 0
    }
    
    private var totalPending: Int {
        partitions.first?.pendingJobs ?? 0
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "gauge.medium")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Cluster Load")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            if partitions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No partition data available")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                // Global job summary
                GroupBox {
                    HStack(spacing: 24) {
                        VStack(spacing: 4) {
                            Text("\(totalRunning)")
                                .font(.title2.bold())
                                .foregroundStyle(.green)
                            Text("Running")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        VStack(spacing: 4) {
                            Text("\(totalPending)")
                                .font(.title2.bold())
                                .foregroundStyle(.orange)
                            Text("Pending")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        VStack(spacing: 4) {
                            Text("\(totalRunning + totalPending)")
                                .font(.title2.bold())
                                .foregroundStyle(.primary)
                            Text("Total Jobs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                
                // Partition details
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(partitions) { partition in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(partition.partition)
                                        .font(.headline)
                                    
                                    HStack(spacing: 16) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Nodes")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            HStack(spacing: 4) {
                                                Text("\(partition.allocatedNodes)/\(partition.totalNodes)")
                                                    .font(.system(.body, design: .monospaced))
                                                Text("used")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("CPUs")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            HStack(spacing: 4) {
                                                Text("\(partition.allocatedCPUs)/\(partition.totalCPUs)")
                                                    .font(.system(.body, design: .monospaced))
                                                Text("used")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Idle")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text("\(partition.idleNodes) nodes")
                                                .font(.system(.body, design: .monospaced))
                                                .foregroundStyle(partition.idleNodes > 0 ? .green : .red)
                                        }
                                    }
                                    
                                    // Usage bar
                                    if partition.totalNodes > 0 {
                                        GeometryReader { geo in
                                            let allocFraction = CGFloat(partition.allocatedNodes) / CGFloat(partition.totalNodes)
                                            ZStack(alignment: .leading) {
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(.gray.opacity(0.2))
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(allocFraction > 0.9 ? .red : allocFraction > 0.7 ? .orange : .green)
                                                    .frame(width: geo.size.width * allocFraction)
                                            }
                                        }
                                        .frame(height: 6)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            
            Button("Done") {
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 420, height: 450)
    }
}

// MARK: - Resource Usage View
struct ResourceUsageView: View {
    let usage: ResourceUsage?
    let error: String?
    @Binding var isPresented: Bool
    let onRefresh: () -> Void

    private let refreshInterval: TimeInterval = 60
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var secondsUntilRefresh: Int = 60

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "memorychip")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Resource Usage")
                    .font(.headline)
                Spacer()
                Text("Refreshing in \(secondsUntilRefresh)s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .onReceive(timer) { _ in
                secondsUntilRefresh -= 1
                if secondsUntilRefresh <= 0 {
                    secondsUntilRefresh = Int(refreshInterval)
                    onRefresh()
                }
            }

            Divider()

            if let error = error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxHeight: .infinity)
            } else if let usage = usage {
                // Memory section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Memory")
                            .font(.headline)

                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Used")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(usage.memoryCurrentFormatted)
                                    .font(.system(.title3, design: .monospaced).bold())
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Limit")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(usage.memoryMaxFormatted)
                                    .font(.system(.title3, design: .monospaced).bold())
                            }

                            Spacer()

                            if usage.memoryMaxBytes != Int64.max && usage.memoryMaxBytes > 0 {
                                Text(String(format: "%.1f%%", usage.memoryUsageFraction * 100))
                                    .font(.system(.title3, design: .monospaced))
                                    .foregroundStyle(
                                        usage.memoryUsageFraction > 0.9 ? .red :
                                        usage.memoryUsageFraction > 0.7 ? .orange : .green
                                    )
                            }
                        }

                        if usage.memoryMaxBytes != Int64.max && usage.memoryMaxBytes > 0 {
                            GeometryReader { geo in
                                let fraction = CGFloat(usage.memoryUsageFraction)
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(.gray.opacity(0.2))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(fraction > 0.9 ? Color.red : fraction > 0.7 ? Color.orange : Color.green)
                                        .frame(width: geo.size.width * fraction)
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // CPU section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CPU Time")
                            .font(.headline)

                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Total")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(usage.cpuUsageFormatted)
                                    .font(.system(.body, design: .monospaced))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("User")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(usage.cpuUserFormatted)
                                    .font(.system(.body, design: .monospaced))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("System")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(usage.cpuSystemFormatted)
                                    .font(.system(.body, design: .monospaced))
                            }

                            Spacer()
                        }

                        if usage.nrThrottled > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                Text("CPU throttled \(usage.nrThrottled) time\(usage.nrThrottled == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No resource data available")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            }

            Spacer()

            Button("Done") {
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 420, height: 380)
    }
}

// MARK: - Session Sheet View
struct SessionSheetView: View {
    @ObservedObject var manager: ConnectionManager
    @Binding var isPresented: Bool

    @State private var secondsUntilRefresh: Int = 60
    @State private var isCancellingJob = false
    @State private var showCancelConfirmation = false
    @State private var jobCancelled = false

    private let refreshInterval = 60
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(.green)
                Text("Active Session")
                    .font(.headline)
                Spacer()
                if let jobId = manager.jobId {
                    Text("Job \(jobId)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Job details
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Job Details")
                        .font(.headline)
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        InfoCell(label: "Partition",
                                 value: manager.jobPartition.isEmpty ? "default" : manager.jobPartition)
                        InfoCell(label: "CPUs", value: "\(manager.jobCPUs)")
                        InfoCell(label: "RAM", value: "\(manager.jobRAM) GB")
                        InfoCell(label: "GPU", value: manager.jobGPU ? "Yes" : "No")
                        InfoCell(label: "Wall Time", value: "\(manager.jobHours)h")
                        InfoCell(label: "Node", value: manager.nodeName ?? "—")
                    }
                }
                .padding(.vertical, 4)
            }

            // Resource usage
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Resource Usage")
                            .font(.headline)
                        Spacer()
                        if !jobCancelled {
                            Text("Refreshing in \(secondsUntilRefresh)s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    if manager.isLoadingResourceUsage {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text("Loading...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = manager.resourceUsageError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let usage = manager.resourceUsage {
                        // Memory
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Memory Used")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(usage.memoryCurrentFormatted)
                                    .font(.system(.body, design: .monospaced).bold())
                            }
                            if usage.memoryMaxBytes != Int64.max && usage.memoryMaxBytes > 0 {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Limit")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(usage.memoryMaxFormatted)
                                        .font(.system(.body, design: .monospaced))
                                }
                                Spacer()
                                Text(String(format: "%.1f%%", usage.memoryUsageFraction * 100))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(
                                        usage.memoryUsageFraction > 0.9 ? .red :
                                        usage.memoryUsageFraction > 0.7 ? .orange : .green
                                    )
                            } else {
                                Spacer()
                            }
                        }
                        if usage.memoryMaxBytes != Int64.max && usage.memoryMaxBytes > 0 {
                            GeometryReader { geo in
                                let fraction = CGFloat(usage.memoryUsageFraction)
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(.gray.opacity(0.2))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(fraction > 0.9 ? Color.red : fraction > 0.7 ? Color.orange : Color.green)
                                        .frame(width: geo.size.width * fraction)
                                }
                            }
                            .frame(height: 6)
                        }

                        Divider()

                        // CPU
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("CPU Total")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(usage.cpuUsageFormatted)
                                    .font(.system(.caption, design: .monospaced))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("User")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(usage.cpuUserFormatted)
                                    .font(.system(.caption, design: .monospaced))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("System")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(usage.cpuSystemFormatted)
                                    .font(.system(.caption, design: .monospaced))
                            }
                            Spacer()
                        }
                        if usage.nrThrottled > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                Text("CPU throttled \(usage.nrThrottled) time\(usage.nrThrottled == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    } else {
                        Text("Loading resource data...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .onReceive(timer) { _ in
                guard !jobCancelled else { return }
                secondsUntilRefresh -= 1
                if secondsUntilRefresh <= 0 {
                    secondsUntilRefresh = refreshInterval
                    manager.checkResourceUsage()
                }
            }

            Spacer()

            // Buttons
            HStack {
                Button(role: .destructive, action: { showCancelConfirmation = true }) {
                    HStack {
                        if isCancellingJob {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "xmark.circle")
                        }
                        Text(jobCancelled ? "Job Cancelled" : "Cancel Job")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isCancellingJob || jobCancelled || manager.jobId == nil)

                Spacer()

                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 520)
        .onAppear {
            manager.checkResourceUsage()
        }
        .alert("Cancel Job?", isPresented: $showCancelConfirmation) {
            Button("Cancel Job", role: .destructive) { cancelJob() }
            Button("Keep Running", role: .cancel) { }
        } message: {
            if let jobId = manager.jobId {
                Text("This will cancel job \(jobId) on the cluster. This cannot be undone.")
            } else {
                Text("This will cancel the job on the cluster. This cannot be undone.")
            }
        }
    }

    private func cancelJob() {
        guard let jobId = manager.jobId else { return }
        isCancellingJob = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runSSHCommand("bash -lc 'scancel \(jobId) 2>/dev/null'; echo done")
            // Clean up conda activation block from shell init files
            cleanupCondaBlock()
            DispatchQueue.main.async {
                isCancellingJob = false
                if result.success {
                    jobCancelled = true
                }
            }
        }
    }
}

// MARK: - Job Card View
struct JobCardView: View {
    let job: QueueJob
    
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Header row: State + Job ID + Name
                HStack {
                    Image(systemName: job.stateIcon)
                        .foregroundStyle(job.stateColor)
                    Text(job.state)
                        .font(.caption.bold())
                        .foregroundStyle(job.stateColor)
                    
                    Spacer()
                    
                    Text("Job \(job.jobId)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                
                // Job name
                Text(job.name)
                    .font(.headline)
                
                Divider()
                
                // Resources grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 8) {
                    InfoCell(label: "Partition", value: job.partition)
                    InfoCell(label: "CPUs", value: job.cpus)
                    InfoCell(label: "Memory", value: job.memory)
                    InfoCell(label: "Nodes", value: job.nodes)
                    InfoCell(label: "Time Used", value: job.timeUsed)
                    InfoCell(label: "Time Limit", value: job.timeLimit)
                }
                
                // Reason (for pending jobs)
                if !job.reason.isEmpty && job.reason != "None" {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text(job.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // Start time (if available)
                if !job.startTime.isEmpty && job.startTime != "N/A" {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(.secondary)
                        Text("Est. start: \(job.startTime)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // Priority info (if available)
                if let priority = job.priority, !priority.priority.isEmpty {
                    Divider()
                    
                    HStack {
                        Text("Priority:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(priority.priority)
                            .font(.system(.caption, design: .monospaced).bold())
                        
                        Spacer()
                        
                        if !priority.age.isEmpty && priority.age != "0" {
                            PriorityBadge(label: "Age", value: priority.age)
                        }
                        if !priority.fairShare.isEmpty && priority.fairShare != "0" {
                            PriorityBadge(label: "Fair", value: priority.fairShare)
                        }
                    }
                }
            }
            .padding(4)
        }
    }
}

struct InfoCell: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(.system(.caption, design: .monospaced))
        }
    }
}

struct PriorityBadge: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(4)
    }
}

// MARK: - SSH Troubleshoot View
struct SSHTroubleshootView: View {
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var auth = SSHAuthManager()
    @State private var checks: [SSHCheck] = []
    @State private var isRunning = false
    @State private var log: String = ""
    @State private var showLog = false
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "stethoscope")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("SSH Troubleshooter")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            // Checks list
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(checks) { check in
                        SSHCheckRow(check: check, onFix: {
                            runFix(for: check)
                        })
                    }
                }
            }
            
            // Auth card (shown when key upload needs SSH auth)
            if auth.authRequired {
                SSHAuthCardView(auth: auth)
            } else if !auth.errorMessage.isEmpty {
                GroupBox {
                    Text(auth.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            
            // Log toggle
            if !log.isEmpty {
                VStack(spacing: 8) {
                    Button(action: { withAnimation { showLog.toggle() } }) {
                        HStack(spacing: 4) {
                            Image(systemName: showLog ? "chevron.down" : "chevron.right")
                                .font(.caption)
                            Text("Details")
                                .font(.caption)
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    
                    if showLog {
                        GroupBox {
                            ScrollView {
                                Text(log)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(height: 100)
                    }
                }
            }
            
            Spacer()
            
            // Buttons
            HStack {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button(action: runChecks) {
                    HStack {
                        if isRunning {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        Text(checks.isEmpty ? "Run Checks" : "Re-check")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
            }
        }
        .padding(20)
        .frame(width: 450, height: 500)
        .onAppear {
            runChecks()
        }
    }
    
    private func runChecks() {
        isRunning = true
        log = ""
        checks = [
            SSHCheck(id: "key", title: "SSH Key", description: "Checking for ed25519 key...", status: .checking),
            SSHCheck(id: "known_hosts", title: "Known Hosts", description: "Checking for stale entries...", status: .pending),
            SSHCheck(id: "key_on_server", title: "Key on Server", description: "Checking if key is authorized...", status: .pending),
            SSHCheck(id: "agent", title: "SSH Agent", description: "Checking if key is in agent...", status: .pending),
        ]
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Check 1: SSH Key exists
            let keyPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519")
            let keyExists = FileManager.default.fileExists(atPath: keyPath.path)
            
            DispatchQueue.main.async {
                if keyExists {
                    updateCheck("key", status: .ok, description: "Key exists at ~/.ssh/id_ed25519")
                    appendLog("✓ SSH key found at ~/.ssh/id_ed25519")
                } else {
                    updateCheck("key", status: .needsFix, description: "No ed25519 key found")
                    appendLog("✗ No SSH key at ~/.ssh/id_ed25519")
                }
                updateCheck("known_hosts", status: .checking)
            }
            
            // Check 2: Stale known_hosts
            let knownHostsPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
            var hasStaleEntries = false
            if let contents = try? String(contentsOf: knownHostsPath, encoding: .utf8) {
                hasStaleEntries = contents.contains("torch.hpc.nyu.edu") || contents.contains("torch ")
            }
            
            DispatchQueue.main.async {
                if hasStaleEntries {
                    updateCheck("known_hosts", status: .needsFix, description: "Found torch entries (may cause warnings)")
                    appendLog("! Found torch entries in known_hosts")
                } else {
                    updateCheck("known_hosts", status: .ok, description: "No stale entries")
                    appendLog("✓ No stale known_hosts entries")
                }
                updateCheck("key_on_server", status: .checking)
            }
            
            // Check 3: Key on server (only if key exists)
            // Read the local public key and check if it's actually in
            // ~/.ssh/authorized_keys on the cluster. A plain "ssh torch echo ok"
            // is unreliable because ControlMaster reuses a password-authenticated
            // session, masking a missing key.
            if keyExists {
                let pubKeyPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519.pub").path
                let pubKey = (try? String(contentsOfFile: pubKeyPath, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // Extract just the key data (type + base64) for matching
                let keyParts = pubKey.components(separatedBy: " ")
                let keyData = keyParts.count >= 2 ? keyParts[1] : pubKey

                let result = runCommand("/usr/bin/ssh", args: [
                    "-o", "ConnectTimeout=5", "torch",
                    "grep -qF '\(keyData)' ~/.ssh/authorized_keys 2>/dev/null && echo KEY_FOUND || echo KEY_MISSING"
                ])
                DispatchQueue.main.async {
                    if result.output.contains("KEY_FOUND") {
                        updateCheck("key_on_server", status: .ok, description: "Key is in authorized_keys")
                        appendLog("✓ Key is authorized on torch")
                    } else {
                        updateCheck("key_on_server", status: .needsFix, description: "Key not in authorized_keys")
                        appendLog("✗ Key not found in ~/.ssh/authorized_keys on torch")
                    }
                    updateCheck("agent", status: .checking)
                }
            } else {
                DispatchQueue.main.async {
                    updateCheck("key_on_server", status: .skipped, description: "Skipped (no key)")
                    updateCheck("agent", status: .checking)
                }
            }
            
            // Check 4: Key in agent
            let agentResult = runCommand("/usr/bin/ssh-add", args: ["-l"])
            DispatchQueue.main.async {
                if agentResult.output.lowercased().contains("ed25519") {
                    updateCheck("agent", status: .ok, description: "Key is loaded in SSH agent")
                    appendLog("✓ Key is in SSH agent")
                } else {
                    updateCheck("agent", status: .needsFix, description: "Key not in agent (may prompt for passphrase)")
                    appendLog("! Key not in SSH agent")
                }
                isRunning = false
            }
        }
    }
    
    private func runFix(for check: SSHCheck) {
        updateCheck(check.id, status: .fixing)
        
        DispatchQueue.global(qos: .userInitiated).async {
            switch check.id {
            case "key":
                // Generate SSH key
                appendLog("\n→ Generating SSH key...")
                let keyPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path
                let result = runCommand("/usr/bin/ssh-keygen", args: ["-t", "ed25519", "-f", keyPath, "-N", ""])
                DispatchQueue.main.async {
                    if result.success {
                        updateCheck("key", status: .ok, description: "Key generated successfully")
                        appendLog("✓ Key generated")
                    } else {
                        updateCheck("key", status: .needsFix, description: "Failed to generate key")
                        appendLog("✗ Failed: \(result.output)")
                    }
                }
                
            case "known_hosts":
                // Clear stale entries
                appendLog("\n→ Clearing stale known_hosts entries...")
                _ = runCommand("/usr/bin/ssh-keygen", args: ["-R", "torch.hpc.nyu.edu"])
                _ = runCommand("/usr/bin/ssh-keygen", args: ["-R", "torch"])
                _ = runCommand("/usr/bin/ssh-keygen", args: ["-R", "login.torch.hpc.nyu.edu"])
                DispatchQueue.main.async {
                    updateCheck("known_hosts", status: .ok, description: "Cleared stale entries")
                    appendLog("✓ Cleared known_hosts entries")
                }
                
            case "key_on_server":
                // Ensure SSH connection (triggers auth UI if needed), then upload key
                appendLog("\n→ Checking SSH connection...")
                DispatchQueue.main.async {
                    updateCheck("key_on_server", status: .fixing, description: "Connecting...")
                    auth.ensureConnected {
                        DispatchQueue.global(qos: .userInitiated).async {
                            uploadKeyToServer()
                        }
                    }
                }
                
            case "agent":
                // Add key to agent with keychain
                appendLog("\n→ Adding key to SSH agent with keychain...")
                
                // First ensure config has the right settings
                let sshConfigPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
                var config = (try? String(contentsOf: sshConfigPath, encoding: .utf8)) ?? ""
                
                if !config.contains("AddKeysToAgent") {
                    let agentConfig = """
                    
                    Host *
                        AddKeysToAgent yes
                        UseKeychain yes
                        IdentityFile ~/.ssh/id_ed25519
                    """
                    config = agentConfig + "\n" + config
                    try? config.write(to: sshConfigPath, atomically: true, encoding: .utf8)
                    appendLog("→ Added keychain settings to SSH config")
                }
                
                let keyPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path
                let result = runCommand("/usr/bin/ssh-add", args: ["--apple-use-keychain", keyPath])
                
                DispatchQueue.main.async {
                    if result.success || result.output.contains("Identity added") {
                        updateCheck("agent", status: .ok, description: "Key added to agent with keychain")
                        appendLog("✓ Key added to agent")
                    } else {
                        updateCheck("agent", status: .needsFix, description: "Key may have a passphrase — run 'ssh-add' in a terminal")
                        appendLog("✗ Could not add key automatically: \(result.output)")
                    }
                }
                
            default:
                break
            }
        }
    }
    
    private func uploadKeyToServer() {
        let keyPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519.pub").path
        
        guard let pubKey = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            DispatchQueue.main.async {
                updateCheck("key_on_server", status: .needsFix, description: "Could not read public key")
                appendLog("✗ Could not read \(keyPath)")
            }
            return
        }
        
        appendLog("→ Uploading key to server...")
        // Extract key data for dedup check, then append only if not already present
        let keyParts = pubKey.components(separatedBy: " ")
        let keyData = keyParts.count >= 2 ? keyParts[1] : pubKey
        let installCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && (grep -qF '\(keyData)' ~/.ssh/authorized_keys 2>/dev/null || echo '\(pubKey)' >> ~/.ssh/authorized_keys) && chmod 600 ~/.ssh/authorized_keys && echo 'KEY_INSTALLED'"
        let installResult = runCommand("/usr/bin/ssh", args: ["torch", installCmd])
        
        DispatchQueue.main.async {
            if installResult.output.contains("KEY_INSTALLED") {
                updateCheck("key_on_server", status: .ok, description: "Key uploaded to server")
                appendLog("✓ Key installed on torch")
            } else {
                updateCheck("key_on_server", status: .needsFix, description: "Failed to upload key")
                appendLog("✗ Failed: \(installResult.output)")
            }
        }
    }
    
    private func updateCheck(_ id: String, status: SSHCheckStatus, description: String? = nil) {
        if let index = checks.firstIndex(where: { $0.id == id }) {
            checks[index].status = status
            if let desc = description {
                checks[index].description = desc
            }
        }
    }
    
    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            log += text + "\n"
        }
    }
    
    private func runCommand(_ path: String, args: [String]) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            return (process.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }
    

}

// MARK: - SSH Check Model
enum SSHCheckStatus {
    case pending, checking, ok, needsFix, fixing, skipped
}

struct SSHCheck: Identifiable {
    let id: String
    let title: String
    var description: String
    var status: SSHCheckStatus
}

struct SSHCheckRow: View {
    let check: SSHCheck
    let onFix: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            Group {
                switch check.status {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                case .checking, .fixing:
                    ProgressView()
                        .scaleEffect(0.6)
                case .ok:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .needsFix:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .skipped:
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            
            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.headline)
                Text(check.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Fix button
            if check.status == .needsFix {
                Button("Fix") {
                    onFix()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @AppStorage("account") private var account = "torch_pr_217_general"
    @AppStorage("hours") private var hours = 2
    @AppStorage("partition") private var partition = ""
    @AppStorage("cpus") private var cpus = 4
    @AppStorage("ram") private var ram = 32
    @AppStorage("gpu") private var gpu = false
    @AppStorage("project") private var project = ""
    @AppStorage("ide") private var ide = "vscode"
    @AppStorage("condaEnv") private var condaEnv = ""
    

    
    @State private var showingProgress = false
    @State private var showingSession = false
    @State private var showingSSHSetup = false
    @State private var showingSSHTroubleshoot = false
    @State private var showingRemoteSetup = false
    @State private var showingCondaSetup = false
    @State private var showingCondaEnvSetup = false
    @State private var showingSetupAlert = false
    @State private var setupAlertMessage = ""
    @State private var isCancellingJob = false
    @State private var isResettingSSH = false
    
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var sshConfigManager = SSHConfigManager()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Image(systemName: "server.rack")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
                Text("Torch Dev")
                    .font(.title.bold())
                Text("NYU HPC Compute Node")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            Divider()
            
            // Form
            Form {
                Section("Account") {
                    TextField("Account", text: $account)
                        .textFieldStyle(.roundedBorder)
                }
                
                Section("Resources") {
                    HStack {
                        Text("Hours")
                        Spacer()
                        TextField("", value: $hours, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: hours) { hours = max(1, min(24, hours)) }
                    }
                    
                    HStack {
                        Text("CPUs")
                        Spacer()
                        TextField("", value: $cpus, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: cpus) { cpus = max(1, min(100, cpus)) }
                    }
                    
                    HStack {
                        Text("RAM (GB)")
                        Spacer()
                        TextField("", value: $ram, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: ram) { ram = max(1, min(500, ram)) }
                    }
                    
                    Toggle("GPU", isOn: $gpu)
                    
                    TextField("Partition (optional)", text: $partition)
                        .textFieldStyle(.roundedBorder)
                }
                
                Section("Project") {
                    HStack {
                        Text("Root directory")
                        TextField("", text: $project)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                Section("IDE") {
                    Picker("IDE", selection: $ide) {
                        Text("VS Code").tag("vscode")
                        Text("Positron").tag("positron")
                        Text("None").tag("none")
                    }
                    .pickerStyle(.segmented)
                }
                
                Section("Environment") {
                    HStack {
                        Text("Conda")
                            .frame(width: 60, alignment: .leading)
                        TextField("optional", text: $condaEnv)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                Section("Setup") {
                    // SSH Config status
                    Button(action: { showingSSHSetup = true }) {
                        HStack {
                            Image(systemName: sshConfigManager.isConfigured ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(sshConfigManager.isConfigured ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("SSH Configuration")
                                if sshConfigManager.isConfigured {
                                    Text("Configured as \(sshConfigManager.currentUsername)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Not configured - click to set up")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    // SSH Troubleshoot
                    Button(action: { showingSSHTroubleshoot = true }) {
                        HStack {
                            Image(systemName: "stethoscope")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Troubleshoot SSH")
                                Text("Fix key, agent, and connection issues")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: setupRemoteServers) {
                        HStack {
                            Image(systemName: "folder.badge.gearshape")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Setup Remote Servers")
                                Text("Configure /scratch symlinks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!sshConfigManager.isConfigured)
                    
                    // Conda Setup
                    Button(action: { showingCondaSetup = true }) {
                        HStack {
                            Image(systemName: "shippingbox.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Setup Conda")
                                Text("Configure conda on the cluster")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!sshConfigManager.isConfigured)
                    
                    // New Conda Environment
                    Button(action: { showingCondaEnvSetup = true }) {
                        HStack {
                            Image(systemName: "cube.box")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("New Environment")
                                Text("Create a Python or R environment")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!sshConfigManager.isConfigured)
                }
                
                Section("Manage") {
                    if connectionManager.completedSuccessfully && connectionManager.jobId != nil {
                        Button(action: { showingSession = true }) {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Active Session")
                                    Text("Job \(connectionManager.jobId ?? "") on \(connectionManager.nodeName ?? "node")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: cancelExistingJobs) {
                        HStack {
                            if isCancellingJob {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.red)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cancel Jobs")
                                Text("Cancel all your torchdev jobs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!sshConfigManager.isConfigured || isCancellingJob)
                    
                    Button(action: resetSSHConnection) {
                        HStack {
                            if isResettingSSH {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.orange)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reset SSH Connection")
                                Text("Tear down ControlMaster session")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isResettingSSH)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            
            Divider()
            
            // Connect button
            Button(action: connect) {
                Text("Connect")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!sshConfigManager.isConfigured)
            .padding(20)
        }
        .frame(width: 340, height: 680)
        .background(.background)
        .sheet(isPresented: $showingProgress, onDismiss: {
            if connectionManager.completedSuccessfully {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showingSession = true
                }
            }
        }) {
            ConnectionProgressView(manager: connectionManager)
        }
        .sheet(isPresented: $showingSession) {
            SessionSheetView(manager: connectionManager, isPresented: $showingSession)
        }
        .sheet(isPresented: $showingSSHSetup) {
            SSHSetupView(configManager: sshConfigManager)
        }
        .sheet(isPresented: $showingSSHTroubleshoot) {
            SSHTroubleshootView()
        }
        .sheet(isPresented: $showingRemoteSetup) {
            RemoteSetupView()
        }
        .sheet(isPresented: $showingCondaSetup) {
            CondaSetupView(username: sshConfigManager.currentUsername)
        }
        .sheet(isPresented: $showingCondaEnvSetup) {
            CondaEnvSetupView(username: sshConfigManager.currentUsername)
        }
        .alert("Remote Setup", isPresented: $showingSetupAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(setupAlertMessage)
        }
        .onAppear {
            // Show SSH setup if not configured
            if !sshConfigManager.isConfigured {
                showingSSHSetup = true
            }

        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // Best-effort cleanup of conda settings on app quit.
            // Runs synchronously on the main thread — the SSH is fast if the
            // ControlMaster session is alive, and a no-op if the network is gone.
            if !condaEnv.isEmpty {
                cleanupCondaBlock()
            }
        }
    }
    
    private func connect() {
        hours = max(1, min(24, hours))
        cpus = max(1, min(100, cpus))
        ram = max(1, min(500, ram))
        showingProgress = true
        connectionManager.start(
            account: account,
            hours: hours,
            partition: partition,
            cpus: cpus,
            ram: ram,
            gpu: gpu,
            project: project,
            ide: ide,
            condaEnv: condaEnv
        )
    }
    
    
    private func setupRemoteServers() {
        showingRemoteSetup = true
    }
    
    private func cancelExistingJobs() {
        isCancellingJob = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runSSHCommand("bash -lc 'scancel -u $USER --name=torchdev 2>/dev/null'; echo done")
            // Clean up conda activation block from shell init files
            cleanupCondaBlock()
            DispatchQueue.main.async {
                isCancellingJob = false
                if result.success {
                    setupAlertMessage = "All torchdev jobs have been cancelled."
                } else {
                    setupAlertMessage = "Failed to cancel jobs: \(result.output)"
                }
                showingSetupAlert = true
            }
        }
    }
    
    private func resetSSHConnection() {
        isResettingSSH = true
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-O", "exit", "torch"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try? process.run()
            process.waitUntilExit()
            
            // Also clean up tunnel pid/port files
            let configDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/torch")
            try? FileManager.default.removeItem(at: configDir.appendingPathComponent("tunnel.pid"))
            try? FileManager.default.removeItem(at: configDir.appendingPathComponent("tunnel.port"))
            
            DispatchQueue.main.async {
                isResettingSSH = false
                setupAlertMessage = "SSH ControlMaster session has been reset."
                showingSetupAlert = true
            }
        }
    }
}

// MARK: - Setup Item Status (shared)
enum SetupItemStatus {
    case pending, checking, ok, needsAction, error, skipped
}

// MARK: - Remote Setup View
struct RemoteSetupView: View {
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var auth = SSHAuthManager()
    @State private var currentStep = 0
    @State private var isRunning = false
    @State private var vscodeStatus: SetupItemStatus = .pending
    @State private var positronStatus: SetupItemStatus = .pending
    @State private var log: String = ""
    @State private var errorMessage: String = ""
    @State private var remoteUser: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Remote Server Setup")
                    .font(.headline)
                Spacer()
            }
            
            Text("This creates symlinks so VS Code and Positron install to /scratch instead of your home directory (avoids quota issues).")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Divider()
            
            // Auth card (shown when SSH authentication is needed)
            if auth.authRequired {
                SSHAuthCardView(auth: auth)
            } else if auth.isAuthenticating {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Connecting to torch...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !auth.errorMessage.isEmpty {
                GroupBox {
                    Text(auth.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            
            if currentStep == 0 {
                // Step 0: Ready to start
                VStack(spacing: 16) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 50))
                        .foregroundStyle(.blue)
                    
                    Text("Ready to configure remote directories")
                        .font(.headline)
                    
                    Text("This will connect to the Torch cluster and set up the following:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("~/.vscode-server → /scratch/$USER/.vscode-server", systemImage: "link")
                        Label("~/.positron-server → /scratch/$USER/.positron-server", systemImage: "link")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
                
            } else if currentStep == 1 {
                // Step 1: Running
                VStack(spacing: 16) {
                    if !remoteUser.isEmpty {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connected as \(remoteUser)")
                                .font(.subheadline)
                        }
                    }
                    
                    // VS Code status
                    SetupItemRow(
                        title: "VS Code Server",
                        path: "~/.vscode-server",
                        status: vscodeStatus
                    )
                    
                    // Positron status
                    SetupItemRow(
                        title: "Positron Server",
                        path: "~/.positron-server",
                        status: positronStatus
                    )
                    
                    if !errorMessage.isEmpty {
                        GroupBox {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                
            } else {
                // Step 2: Done
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.green)
                    
                    Text("Setup Complete!")
                        .font(.headline)
                    
                    Text("VS Code and Positron will now install their remote components to /scratch instead of your home directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxHeight: .infinity)
            }
            
            // Log (collapsible)
            if !log.isEmpty {
                DisclosureGroup("Details") {
                    ScrollView {
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 80)
                }
                .font(.caption)
            }
            
            Spacer()
            
            // Buttons
            HStack {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                if currentStep == 0 {
                    Button(action: runSetup) {
                        HStack {
                            if isRunning || auth.isAuthenticating {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Text("Start Setup")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || auth.isAuthenticating || auth.authRequired)
                } else if currentStep == 2 {
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 400, height: 480)
    }
    
    private func runSetup() {
        isRunning = true
        log = ""
        errorMessage = ""
        
        // Ensure SSH connection (triggers auth UI if needed) before running setup
        auth.ensureConnected {
            self.currentStep = 1
            self.vscodeStatus = .checking
            self.runSetupSteps()
        }
    }
    
    private func runSetupSteps() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Get remote username
            appendLog("Connecting to torch...")
            let userResult = runSSHCommand("echo $USER")
            
            if !userResult.success {
                DispatchQueue.main.async {
                    errorMessage = "Could not connect to torch. Check your SSH configuration."
                    vscodeStatus = .error
                    positronStatus = .error
                    isRunning = false
                }
                return
            }
            
            let user = userResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                remoteUser = user
                appendLog("Connected as: \(user)")
            }
            
            // Setup VS Code
            DispatchQueue.main.async {
                vscodeStatus = .checking
            }
            setupSymlink(
                name: "VS Code Server",
                homePath: "/home/\(user)/.vscode-server",
                scratchPath: "/scratch/\(user)/.vscode-server",
                statusUpdate: { status in
                    DispatchQueue.main.async { vscodeStatus = status }
                }
            )
            
            // Setup Positron
            DispatchQueue.main.async {
                positronStatus = .checking
            }
            setupSymlink(
                name: "Positron Server",
                homePath: "/home/\(user)/.positron-server",
                scratchPath: "/scratch/\(user)/.positron-server",
                statusUpdate: { status in
                    DispatchQueue.main.async { positronStatus = status }
                }
            )
            
            // Done
            DispatchQueue.main.async {
                isRunning = false
                currentStep = 2
            }
        }
    }
    
    private func setupSymlink(name: String, homePath: String, scratchPath: String, statusUpdate: @escaping (SetupItemStatus) -> Void) {
        appendLog("\nSetting up \(name)...")
        
        // Check current state
        let checkResult = runSSHCommand("""
            if [[ -L '\(homePath)' ]]; then
                target=$(readlink '\(homePath)')
                if [[ "$target" == '\(scratchPath)' ]]; then
                    echo 'OK'
                else
                    echo 'SYMLINK_OTHER'
                fi
            elif [[ -d '\(homePath)' ]]; then
                echo 'DIR_EXISTS'
            else
                echo 'NONE'
            fi
        """)
        
        let state = checkResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch state {
        case "OK":
            appendLog("  ✓ Already configured correctly")
            statusUpdate(.ok)
            
        case "SYMLINK_OTHER":
            appendLog("  → Updating symlink...")
            let result = runSSHCommand("mkdir -p '\(scratchPath)' ; ln -sf '\(scratchPath)' '\(homePath)'")
            if result.success {
                appendLog("  ✓ Updated symlink")
                statusUpdate(.ok)
            } else {
                appendLog("  ✗ Failed: \(result.output)")
                statusUpdate(.error)
            }
            
        case "DIR_EXISTS":
            appendLog("  → Moving existing directory...")
            // Move contents to scratch, then create symlink
            let result = runSSHCommand("""
                mkdir -p '\(scratchPath)' ; \
                cp -r '\(homePath)/'* '\(scratchPath)/' 2>/dev/null || true ; \
                rm -rf '\(homePath)' ; \
                ln -sf '\(scratchPath)' '\(homePath)'
            """)
            if result.success {
                appendLog("  ✓ Moved to scratch and created symlink")
                statusUpdate(.ok)
            } else {
                appendLog("  ✗ Failed: \(result.output)")
                statusUpdate(.error)
            }
            
        case "NONE":
            appendLog("  → Creating symlink...")
            let result = runSSHCommand("mkdir -p '\(scratchPath)' ; ln -sf '\(scratchPath)' '\(homePath)'")
            if result.success {
                appendLog("  ✓ Created symlink")
                statusUpdate(.ok)
            } else {
                appendLog("  ✗ Failed: \(result.output)")
                statusUpdate(.error)
            }
            
        default:
            appendLog("  ✗ Unexpected state: \(state)")
            statusUpdate(.error)
        }
    }
    
    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            log += text + "\n"
        }
    }
}

struct SetupItemRow: View {
    let title: String
    let path: String
    let status: SetupItemStatus
    
    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            Group {
                switch status {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                case .checking:
                    ProgressView()
                        .scaleEffect(0.6)
                case .ok:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .needsAction:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .error:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .skipped:
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Conda Setup View (One-Time Configuration)
struct CondaSetupView: View {
    let username: String
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var auth = SSHAuthManager()
    @State private var currentStep = 0       // 0=splash, 1=running, 2=done
    @State private var isRunning = false
    @State private var log: String = ""
    @State private var errorMessage: String = ""
    @State private var detectedCondaVersion: String = ""
    
    @State private var discoverStatus: SetupItemStatus = .pending
    @State private var loadModuleStatus: SetupItemStatus = .pending
    @State private var scratchDirsStatus: SetupItemStatus = .pending
    @State private var condarcStatus: SetupItemStatus = .pending
    @State private var forceReset = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Setup Conda")
                    .font(.headline)
                Spacer()
            }
            
            if currentStep == 0 {
                // Splash
                VStack(spacing: 16) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                    
                    Text("This will configure conda on the cluster so packages install to /scratch instead of your home directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Find latest conda module", systemImage: "magnifyingglass")
                        Label("Initialize conda for your shell", systemImage: "terminal")
                        Label("Create /scratch/\(username)/.conda/", systemImage: "folder.badge.plus")
                        Label("Configure .condarc paths", systemImage: "doc.text")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
                
            } else if currentStep == 1 {
                // Running
                VStack(alignment: .leading, spacing: 8) {
                    SetupItemRow(title: "Find Conda Module",
                                 path: detectedCondaVersion.isEmpty ? "Searching..." : detectedCondaVersion,
                                 status: discoverStatus)
                    SetupItemRow(title: "Verify Conda Access",
                                 path: "conda --version",
                                 status: loadModuleStatus)
                    SetupItemRow(title: "Create Scratch Directories",
                                 path: "/scratch/\(username)/.conda/",
                                 status: scratchDirsStatus)
                    SetupItemRow(title: "Configure Package Paths",
                                 path: "~/.condarc",
                                 status: condarcStatus)
                }
                
                if !errorMessage.isEmpty {
                    GroupBox {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                
            } else {
                // Done
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    
                    Text("Conda is configured!")
                        .font(.headline)
                    
                    Text("Packages and environments will be stored in /scratch/\(username)/.conda/. Use \"New Environment\" to create your first project environment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button(action: {
                        forceReset = true
                        runSetup()
                    }) {
                        Label("Re-run Setup", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Remove and rewrite .condarc and scratch directories")
                }
                .frame(maxHeight: .infinity)
            }
            
            // Auth card (shown when SSH authentication is needed)
            if auth.authRequired {
                SSHAuthCardView(auth: auth)
            } else if auth.isAuthenticating {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Connecting to torch...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !auth.errorMessage.isEmpty {
                GroupBox {
                    Text(auth.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            
            // Collapsible log
            if !log.isEmpty {
                DisclosureGroup("Details") {
                    ScrollView {
                        Text(log)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 80)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            // Buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if currentStep == 0 {
                    Button(action: runSetup) {
                        HStack {
                            if auth.isAuthenticating {
                                ProgressView().scaleEffect(0.7)
                            }
                            Text("Start Setup")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(auth.isAuthenticating || auth.authRequired)
                } else if currentStep == 2 {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 400, height: 520)
    }
    
    // MARK: - Setup Logic
    
    private func runSetup() {
        isRunning = true
        log = ""
        errorMessage = ""

        auth.ensureConnected {
            self.currentStep = 1
            self.discoverStatus = .checking
            self.loadModuleStatus = .pending
            self.scratchDirsStatus = .pending
            self.condarcStatus = .pending
            self.runSetupSteps()
        }
    }

    private func runSetupSteps() {
        let shouldReset = forceReset
        DispatchQueue.global(qos: .userInitiated).async {
            // Reset existing config if requested
            if shouldReset {
                appendLog("Resetting conda configuration...\n")
                // Remove .condarc
                let _ = runSSHCommand("rm -f ~/.condarc 2>/dev/null; echo RESET_CONDARC_OK")
                appendLog("  Removed .condarc\n")
                appendLog("Reset complete. Running setup...\n\n")
                DispatchQueue.main.async { forceReset = false }
            }
            
            // Step 1: Discover conda module
            appendLog("Searching for conda modules...\n")
            let discoverResult = runSSHCommand("bash -lc 'module avail conda 2>&1'")
            let version = parseLatestCondaModule(from: discoverResult.output)
            
            if let version = version {
                appendLog("Found: \(version)\n")
                DispatchQueue.main.async {
                    detectedCondaVersion = version
                    discoverStatus = .ok
                    loadModuleStatus = .checking
                }
            } else {
                appendLog("No conda module found.\n")
                DispatchQueue.main.async {
                    discoverStatus = .error
                    errorMessage = "Could not find a conda module on the cluster."
                    isRunning = false
                }
                return
            }
            
            // Step 2: Verify conda access
            appendLog("Checking conda access...\n")
            let condaCheck = runSSHCommand("bash -lc 'conda --version 2>/dev/null && echo CONDA_AVAILABLE || (module load \(version!) && conda --version 2>/dev/null && echo CONDA_AVAILABLE || echo CONDA_MISSING)'")
            
            if condaCheck.output.contains("CONDA_AVAILABLE") {
                appendLog("Conda accessible.\n")
                DispatchQueue.main.async {
                    loadModuleStatus = .ok
                }
            } else {
                appendLog("Conda not accessible after module load.\n")
                DispatchQueue.main.async {
                    loadModuleStatus = .error
                    errorMessage = "Could not access conda after loading module."
                    isRunning = false
                }
                return
            }
            
            DispatchQueue.main.async { scratchDirsStatus = .checking }
            
            // Step 4: Create scratch directories
            appendLog("Creating scratch directories...\n")
            let dirsResult = runSSHCommand("mkdir -p /scratch/\(username)/.conda/envs /scratch/\(username)/.conda/pkgs && echo DIRS_OK")
            appendLog(dirsResult.output)
            DispatchQueue.main.async {
                scratchDirsStatus = dirsResult.output.contains("DIRS_OK") ? .ok : .error
                if !dirsResult.output.contains("DIRS_OK") {
                    errorMessage = "Failed to create scratch directories."
                }
                condarcStatus = .checking
            }
            
            // Step 5: Write .condarc
            appendLog("Checking .condarc...\n")
            let condarcCheck = runSSHCommand("grep -q 'envs_dirs' ~/.condarc 2>/dev/null && grep -q '/scratch/\(username)' ~/.condarc 2>/dev/null && echo ALREADY_SET || echo NEEDS_WRITE")
            
            if condarcCheck.output.contains("ALREADY_SET") {
                appendLog(".condarc already configured.\n")
                DispatchQueue.main.async { condarcStatus = .ok }
            } else {
                appendLog("Writing .condarc...\n")
                let writeResult = runSSHCommand("printf 'envs_dirs:\\n  - /scratch/\(username)/.conda/envs\\npkgs_dirs:\\n  - /scratch/\(username)/.conda/pkgs\\n' > ~/.condarc && echo CONDARC_OK")
                appendLog(writeResult.output)
                DispatchQueue.main.async {
                    condarcStatus = writeResult.output.contains("CONDARC_OK") ? .ok : .error
                    if !writeResult.output.contains("CONDARC_OK") {
                        errorMessage = "Failed to write .condarc."
                    }
                }
            }
            
            // Ensure TOS is accepted in .condarc (Anaconda 2024.06+ blocks
            // conda create/install with an interactive prompt without this)
            let tosCheck = runSSHCommand("grep -q 'tos_accepted' ~/.condarc 2>/dev/null && echo TOS_SET || echo TOS_MISSING")
            if tosCheck.output.contains("TOS_MISSING") {
                appendLog("Accepting conda TOS...\n")
                let _ = runSSHCommand("printf '\\ntos_accepted: true\\n' >> ~/.condarc")
            }
            
            DispatchQueue.main.async {
                isRunning = false
                currentStep = 2
            }
        }
    }
    
    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            log += text
        }
    }
}

// MARK: - Conda Environment Setup View (Per-Project)
struct CondaEnvSetupView: View {
    let username: String
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var auth = SSHAuthManager()
    
    // User inputs
    @State private var envName: String = ""
    @State private var language: Language = .python
    @State private var selectedVersion: String = ""
    @State private var projectFolder: String = ""
    
    // Available versions shown in the picker.
    @State private var availableVersions: [String] = []
    @State private var isLoadingVersions = true
    @State private var versionError: String = ""
    
    // Conda module version (discovered on appear)
    @State private var condaModule: String = ""
    
    // Wizard state
    @State private var currentStep = 0       // 0=form, 1=running, 2=done
    @State private var isRunning = false
    @State private var log: String = ""
    @State private var errorMessage: String = ""
    
    // Per-step statuses
    @State private var createEnvStatus: SetupItemStatus = .pending
    @State private var verifyLangStatus: SetupItemStatus = .pending
    @State private var registerKernelStatus: SetupItemStatus = .pending
    @State private var projectFolderStatus: SetupItemStatus = .pending
    
    // Track whether we created the env (for cleanup on failure/cancel)
    @State private var envWasCreated = false
    @State private var currentProcess: Process?
    
    enum Language: String, CaseIterable, Identifiable {
        case python = "Python"
        case r = "R"
        var id: String { rawValue }
    }
    
    private var isValidConfig: Bool {
        let trimmed = envName.trimmingCharacters(in: .whitespaces)
        let nameValid = !trimmed.isEmpty
            && trimmed.range(of: #"^[a-zA-Z][a-zA-Z0-9_-]*$"#, options: .regularExpression) != nil
        return nameValid && !selectedVersion.isEmpty
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "cube.box")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("New Environment")
                    .font(.headline)
                Spacer()
            }
            
            if currentStep == 0 {
                // Configuration form
                VStack(alignment: .leading, spacing: 16) {
                    // Environment name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Environment Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("myproject", text: $envName)
                            .textFieldStyle(.roundedBorder)
                        if !envName.isEmpty && !isValidConfig && selectedVersion.isEmpty == false {
                            Text("Use letters, numbers, hyphens, and underscores. Must start with a letter.")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    
                    // Language picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Language")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Language", selection: $language) {
                            ForEach(Language.allCases) { lang in
                                Text(lang.rawValue).tag(lang)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: language) {
                            selectedVersion = ""
                            availableVersions = []
                            fetchVersions()
                        }
                    }
                    
                    // Version picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(language.rawValue) Version")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isLoadingVersions {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Loading available versions...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if !versionError.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                Text(versionError)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Retry") { discoverCondaModule() }
                                .font(.caption)
                        } else if !availableVersions.isEmpty {
                            Picker("Version", selection: $selectedVersion) {
                                ForEach(availableVersions, id: \.self) { ver in
                                    Text(ver).tag(ver)
                                }
                            }
                        }
                    }
                    
                    // Project folder (optional)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Project Folder (optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("my-project", text: $projectFolder)
                            .textFieldStyle(.roundedBorder)
                        Text("Creates /scratch/\(username)/\(projectFolder.isEmpty ? "<folder>" : projectFolder)/")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
            } else if currentStep == 1 {
                // Running
                VStack(alignment: .leading, spacing: 8) {
                    SetupItemRow(title: "Create Environment",
                                 path: "\(envName) (\(language.rawValue) \(selectedVersion))",
                                 status: createEnvStatus)
                    if createEnvStatus == .checking {
                        Text("This may take a few minutes while packages are downloaded and installed.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 32)
                    }
                    SetupItemRow(title: "Verify \(language.rawValue)",
                                 path: language == .python ? "python --version" : "Rscript --version",
                                 status: verifyLangStatus)
                    SetupItemRow(title: "Register Jupyter Kernel",
                                 path: language == .python ? "ipykernel" : "IRkernel",
                                 status: registerKernelStatus)
                    SetupItemRow(title: "Create Project Folder",
                                 path: projectFolder.isEmpty ? "Skipped" : "/scratch/\(username)/\(projectFolder)/",
                                 status: projectFolderStatus)
                }
                
                if !errorMessage.isEmpty {
                    GroupBox {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                
            } else {
                // Done
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    
                    Text("Environment created!")
                        .font(.headline)
                    
                    VStack(spacing: 4) {
                        Text("Environment: \(envName)")
                            .font(.caption.bold())
                        Text("Kernel: \(language.rawValue) (\(envName))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !projectFolder.isEmpty {
                            Text("Folder: /scratch/\(username)/\(projectFolder)/")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Text("Select this kernel in Jupyter or your IDE to use this environment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxHeight: .infinity)
            }
            
            // Auth card (shown when SSH authentication is needed)
            if auth.authRequired {
                SSHAuthCardView(auth: auth)
            } else if auth.isAuthenticating {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Connecting to torch...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !auth.errorMessage.isEmpty {
                GroupBox {
                    Text(auth.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            
            // Collapsible log
            if !log.isEmpty {
                DisclosureGroup("Details") {
                    ScrollView {
                        Text(log)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 80)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Buttons
            HStack {
                if currentStep == 1 && isRunning {
                    Button("Cancel") { cancelSetup() }
                        .keyboardShortcut(.cancelAction)
                } else if currentStep == 2 {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if currentStep == 0 {
                    Button("Create Environment") { runSetup() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValidConfig || auth.isAuthenticating || auth.authRequired)
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 540)
        .onAppear {
            discoverCondaModule()
        }
    }
    
    // MARK: - Version Discovery
    
    private func discoverCondaModule() {
        auth.ensureConnected {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runSSHCommand("bash -lc 'module avail conda 2>&1'")
                let version = parseLatestCondaModule(from: result.output)
                DispatchQueue.main.async {
                    condaModule = version ?? "anaconda3"
                    fetchVersions()
                }
            }
        }
    }
    
    private func commonVersions(for language: Language) -> [String] {
        switch language {
        case .python:
            return ["3.13", "3.12", "3.11", "3.10", "3.9", "3.8"]
        case .r:
            return ["4.4", "4.3", "4.2", "4.1", "4.0"]
        }
    }

    private func nearestSupportedVersion(to requestedVersion: String, for language: Language) -> String? {
        let available = commonVersions(for: language)
        return available.first { $0.compare(requestedVersion, options: .numeric) != .orderedDescending }
            ?? available.last
    }

    private func createEnvironmentErrorMessage(for language: Language, version: String, output: String) -> String {
        let loweredOutput = output.lowercased()
        let packageName = language == .python ? "python" : "r-base"

        if loweredOutput.contains("packagesnotfounderror")
            || loweredOutput.contains("nothing provides requested")
            || loweredOutput.contains("resolvepackagenotfound")
            || loweredOutput.contains("could not find") && loweredOutput.contains(packageName) {
            if let fallback = nearestSupportedVersion(to: version, for: language), fallback != version {
                return "\(language.rawValue) \(version) is not available on this cluster. Try \(fallback)."
            }
            return "\(language.rawValue) \(version) is not available on this cluster."
        }

        if loweredOutput.contains("unsatisfiableerror") {
            if let fallback = nearestSupportedVersion(to: version, for: language), fallback != version {
                return "Could not resolve \(language.rawValue) \(version). Try \(fallback)."
            }
            return "Could not resolve \(language.rawValue) \(version) in conda."
        }

        return "Failed to create environment."
    }

    private func fetchVersions() {
        isLoadingVersions = true
        versionError = ""
        availableVersions = []
        selectedVersion = ""

        let versions = commonVersions(for: language)
        availableVersions = versions
        selectedVersion = versions.first ?? ""
        isLoadingVersions = false
    }
    
    // MARK: - Setup Logic
    
    private func runSetup() {
        isRunning = true
        log = ""
        errorMessage = ""

        auth.ensureConnected {
            self.currentStep = 1
            self.createEnvStatus = .checking
            self.verifyLangStatus = .pending
            self.registerKernelStatus = .pending
            self.projectFolderStatus = self.projectFolder.isEmpty ? .skipped : .pending
            self.runSetupSteps()
        }
    }

    private func runSetupSteps() {
        let mod = condaModule
        let name = envName.trimmingCharacters(in: .whitespaces)
        let ver = selectedVersion
        let lang = language
        let folder = projectFolder.trimmingCharacters(in: .whitespaces)

        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Create environment (with idempotency check)
            appendLog("Checking if environment '\(name)' exists...\n")
            let envCheck = runSSHCommand("bash -lc 'export CONDA_PLUGINS_AUTO_ACCEPT_TOS=yes; module load \(mod) && conda env list 2>/dev/null | grep -q \"^\\s*\(name) \" && echo EXISTS || echo MISSING'")
            
            if envCheck.output.contains("EXISTS") {
                appendLog("Environment '\(name)' already exists.\n")
                DispatchQueue.main.async { createEnvStatus = .ok }
            } else {
                appendLog("Creating environment '\(name)'...\n")
                let packageSpec: String
                let channelFlag: String
                if lang == .python {
                    packageSpec = "python=\(ver)"
                    channelFlag = ""
                } else {
                    // r-irkernel pulls in r-base, jupyter, and all kernel dependencies
                    packageSpec = "r-base=\(ver) r-irkernel"
                    channelFlag = "-c conda-forge"
                }
                let createResult = runSSHCommand("bash -lc 'export CONDA_PLUGINS_AUTO_ACCEPT_TOS=yes; module load \(mod) && conda create -n \(name) \(channelFlag) \(packageSpec) -y 2>&1'",
                    processCallback: { [self] p in currentProcess = p })
                appendLog(createResult.output)
                if createResult.success {
                    DispatchQueue.main.async {
                        envWasCreated = true
                        createEnvStatus = .ok
                    }
                } else {
                    let createError = createEnvironmentErrorMessage(for: lang, version: ver, output: createResult.output)
                    DispatchQueue.main.async {
                        createEnvStatus = .error
                        errorMessage = createError
                        isRunning = false
                    }
                    // Clean up the partial env
                    cleanupFailedEnv()
                    return
                }
            }
            
            // Step 2: Verify language
            DispatchQueue.main.async { verifyLangStatus = .checking }
            appendLog("Verifying \(lang.rawValue) installation...\n")
            let verifyCmd = lang == .python
                ? "bash -lc 'export CONDA_PLUGINS_AUTO_ACCEPT_TOS=yes; module load \(mod) && conda run -n \(name) python --version 2>&1'"
                : "bash -lc 'export CONDA_PLUGINS_AUTO_ACCEPT_TOS=yes; module load \(mod) && eval \"$(conda shell.bash hook 2>/dev/null)\" && conda activate \(name) && Rscript --version 2>&1'"
            let verifyResult = runSSHCommand(verifyCmd)
            appendLog(verifyResult.output)
            DispatchQueue.main.async {
                verifyLangStatus = verifyResult.success ? .ok : .error
                if !verifyResult.success {
                    errorMessage = "\(lang.rawValue) verification failed."
                }
            }
            
            // Step 3: Register Jupyter kernel
            DispatchQueue.main.async { registerKernelStatus = .checking }
            appendLog("Checking for existing kernel...\n")
            let kernelCheck = runSSHCommand("bash -lc 'export CONDA_PLUGINS_AUTO_ACCEPT_TOS=yes; module load \(mod) && eval \"$(conda shell.bash hook 2>/dev/null)\" && conda activate \(name) && jupyter kernelspec list 2>/dev/null | grep -qi \"\(name)\" && echo KERNEL_EXISTS || echo KERNEL_MISSING'")
            
            if kernelCheck.output.contains("KERNEL_EXISTS") {
                appendLog("Kernel '\(name)' already registered.\n")
                DispatchQueue.main.async { registerKernelStatus = .ok }
            } else {
                appendLog("Registering kernel...\n")
                let kernelCmd: String
                if lang == .python {
                    kernelCmd = "bash -lc 'export CONDA_PLUGINS_AUTO_ACCEPT_TOS=yes; module load \(mod) && conda run -n \(name) pip install ipykernel 2>&1 && conda run -n \(name) python -m ipykernel install --user --name \(name) --display-name \"Python (\(name))\" 2>&1'"
                } else {
                    // IRkernel was installed via conda in Step 1; just register the kernel spec
                    // Use conda activate instead of conda run — conda run doesn't reliably set PATH for R
                    kernelCmd = "bash -lc 'export CONDA_PLUGINS_AUTO_ACCEPT_TOS=yes; module load \(mod) && eval \"$(conda shell.bash hook 2>/dev/null)\" && conda activate \(name) && Rscript -e \"IRkernel::installspec(name=\\\"\(name)\\\", displayname=\\\"R (\(name))\\\")\" 2>&1'"
                }
                let kernelResult = runSSHCommand(kernelCmd)
                appendLog(kernelResult.output)
                DispatchQueue.main.async {
                    registerKernelStatus = kernelResult.success ? .ok : .error
                    if !kernelResult.success {
                        errorMessage = "Failed to register kernel."
                    }
                }
            }
            
            // Step 4: Create project folder (if specified)
            if !folder.isEmpty {
                DispatchQueue.main.async { projectFolderStatus = .checking }
                appendLog("Creating project folder...\n")
                let folderResult = runSSHCommand("mkdir -p /scratch/\(username)/\(folder) && echo FOLDER_OK")
                appendLog(folderResult.output)
                DispatchQueue.main.async {
                    projectFolderStatus = folderResult.output.contains("FOLDER_OK") ? .ok : .error
                    if !folderResult.output.contains("FOLDER_OK") {
                        errorMessage = "Failed to create project folder."
                    }
                }
            }
            
            DispatchQueue.main.async {
                isRunning = false
                currentStep = 2
            }
        }
    }
    
    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            log += text
        }
    }
    
    private func cancelSetup() {
        currentProcess?.terminate()
        currentProcess = nil
        isRunning = false
        
        // Clean up partial environment in the background
        if envWasCreated {
            let mod = condaModule
            let name = envName.trimmingCharacters(in: .whitespaces)
            DispatchQueue.global(qos: .utility).async {
                let _ = runSSHCommand("bash -lc 'export CONDA_PLUGINS_AUTO_ACCEPT_TOS=yes; module load \(mod) && conda env remove -n \(name) -y 2>&1'")
            }
        }
        
        dismiss()
    }
    
    private func cleanupFailedEnv() {
        let mod = condaModule
        let name = envName.trimmingCharacters(in: .whitespaces)
        appendLog("Cleaning up partial environment '\(name)'...\n")
        DispatchQueue.global(qos: .utility).async {
            let result = runSSHCommand("bash -lc 'export CONDA_PLUGINS_AUTO_ACCEPT_TOS=yes; module load \(mod) && conda env remove -n \(name) -y 2>&1'")
            appendLog(result.output)
            DispatchQueue.main.async {
                envWasCreated = false
            }
        }
    }
}

#Preview {
    ContentView()
}
