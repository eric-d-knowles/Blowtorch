import SwiftUI

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
    
    private var currentJobId: String?
    private var process: Process?
    private var inputPipe: Pipe?
    
    func start(account: String, hours: Int, partition: String, cpus: Int, ram: Int, gpu: Bool, project: String, ide: String) {
        // Reset state
        steps = [
            ConnectionStep(id: "auth", label: "Authenticating"),
            ConnectionStep(id: "submit", label: "Submitting job"),
            ConnectionStep(id: "allocate", label: "Waiting for compute node"),
            ConnectionStep(id: "tunnel", label: "Starting tunnel"),
            ConnectionStep(id: "ssh", label: "Connecting to node"),
            ConnectionStep(id: "ide", label: "Launching \(ide == "positron" ? "Positron" : "VS Code")")
        ]
        logOutput = ""
        isRunning = true
        authRequired = false
        authPIN = ""
        completedSuccessfully = false
        failed = false
        isWaitingForNode = false
        currentJobId = nil
        
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
        if let jobId = currentJobId {
            let scancelProcess = Process()
            scancelProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            scancelProcess.arguments = ["torch", "scancel \(jobId) 2>/dev/null || true"]
            try? scancelProcess.run()
            currentJobId = nil
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
            echo "=== SQUEUE ===" && \
            squeue -u $USER -o '%i|%P|%j|%T|%M|%l|%D|%C|%m|%r|%S' 2>/dev/null && \
            echo "=== SPRIO ===" && \
            sprio -u $USER -o '%i|%Y|%A|%F|%J|%P|%Q' 2>/dev/null
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
            echo "=== SINFO ===" && \
            sinfo -o '%P|%a|%D|%A|%C' --noheader 2>/dev/null && \
            echo "=== SQUEUE_SUMMARY ===" && \
            squeue -o '%T' --noheader 2>/dev/null | sort | uniq -c
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
            // Check for auth needed
            if line.contains("NEEDS_AUTH") {
                authRequired = true
                updateStep("auth", status: .needsAuth, detail: "Browser sign-in required")
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
                    currentJobId = jobId
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
            
            // Launching IDE or CLI not found (connection succeeded either way)
            if line.contains("Launching VS Code") || line.contains("Launching Positron") {
                updateStep("ssh", status: .success)
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
                            .onChange(of: manager.logOutput) { _ in
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
                } else {
                    Button(manager.completedSuccessfully ? "Done" : "Close") {
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
    
    @State private var checks: [SSHCheck] = []
    @State private var isRunning = false
    @State private var log: String = ""
    @State private var showLog = false
    
    // Auth UI state (for key upload)
    @State private var authRequired = false
    @State private var authPIN: String = ""
    @State private var authURL: String = "https://login.microsoft.com/device"
    @State private var pendingFixAfterAuth: String? = nil
    @State private var inputPipe: Pipe? = nil
    
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
            if authRequired {
                GroupBox {
                    VStack(spacing: 12) {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.blue)
                        
                        Text("Sign in Required")
                            .font(.headline)
                        
                        if !authPIN.isEmpty {
                            VStack(spacing: 4) {
                                Text("Enter this code:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                HStack(spacing: 8) {
                                    Text(authPIN)
                                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                                        .textSelection(.enabled)
                                    
                                    Button(action: {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(authPIN, forType: .string)
                                    }) {
                                        Image(systemName: "doc.on.doc")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Copy to clipboard")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        
                        Button(action: {
                            if let url = URL(string: authURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            HStack {
                                Image(systemName: "safari")
                                Text("Open Browser")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        
                        Button(action: continueAfterAuth) {
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
                    .padding(8)
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
            if keyExists {
                let result = runCommand("/usr/bin/ssh", args: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "torch", "echo", "ok"])
                DispatchQueue.main.async {
                    if result.success {
                        updateCheck("key_on_server", status: .ok, description: "Key is authorized on server")
                        appendLog("✓ Key is authorized on torch")
                    } else {
                        updateCheck("key_on_server", status: .needsFix, description: "Key not authorized or connection failed")
                        appendLog("✗ Key not authorized: \(result.output)")
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
                // Upload key: first check if SSH is connected
                appendLog("\n→ Checking SSH connection...")
                let authCheck = runCommand("/usr/bin/ssh", args: ["-O", "check", "torch"])
                
                if authCheck.success {
                    // Already connected — upload key directly
                    uploadKeyToServer()
                } else {
                    // Need to authenticate first — run ssh -fNM via PTY to get the PIN
                    appendLog("→ SSH not connected, starting authentication...")
                    DispatchQueue.main.async {
                        pendingFixAfterAuth = "key_on_server"
                        updateCheck("key_on_server", status: .fixing, description: "Authenticating...")
                    }
                    startSSHAuth()
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
        let installCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(pubKey)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo 'KEY_INSTALLED'"
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
    
    private func startSSHAuth() {
        // Run ssh -fNM torch via PTY using 'script' to capture the auth PIN output
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/usr/bin/ssh", "-fNM", "torch"]
        
        let outputPipe = Pipe()
        let input = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = input
        
        DispatchQueue.main.async {
            inputPipe = input
        }
        
        outputPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                DispatchQueue.main.async {
                    // Look for auth PIN
                    if output.contains("Authenticate with PIN") || output.contains("NEEDS_AUTH") {
                        authRequired = true
                        
                        if let pinMatch = output.range(of: "PIN\\s+([A-Z0-9]+)", options: .regularExpression) {
                            let pinSubstring = output[pinMatch]
                            authPIN = pinSubstring.replacingOccurrences(of: "PIN ", with: "").trimmingCharacters(in: .whitespaces)
                        }
                        
                        if let urlMatch = output.range(of: "https://[^\\s]+", options: .regularExpression) {
                            authURL = String(output[urlMatch])
                        }
                    }
                }
            }
        }
        
        process.terminationHandler = { [self] proc in
            DispatchQueue.main.async {
                authRequired = false
                authPIN = ""
                outputPipe.fileHandleForReading.readabilityHandler = nil
                
                // Check if auth succeeded
                let check = runCommand("/usr/bin/ssh", args: ["-O", "check", "torch"])
                if check.success {
                    appendLog("✓ Authenticated successfully")
                    // Now run the pending fix
                    if pendingFixAfterAuth == "key_on_server" {
                        pendingFixAfterAuth = nil
                        DispatchQueue.global(qos: .userInitiated).async {
                            uploadKeyToServer()
                        }
                    }
                } else {
                    updateCheck(pendingFixAfterAuth ?? "key_on_server", status: .needsFix, description: "Authentication failed — try again")
                    appendLog("✗ Authentication failed")
                    pendingFixAfterAuth = nil
                }
            }
        }
        
        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                updateCheck("key_on_server", status: .needsFix, description: "Failed to start SSH")
                appendLog("✗ Failed to start SSH: \(error)")
            }
        }
    }
    
    private func continueAfterAuth() {
        // Send Enter to the ssh process to proceed after browser auth
        if let data = "\n".data(using: .utf8) {
            inputPipe?.fileHandleForWriting.write(data)
        }
        authRequired = false
        authPIN = ""
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
    
    @State private var showingProgress = false
    @State private var showingSSHSetup = false
    @State private var showingSSHTroubleshoot = false
    @State private var showingRemoteSetup = false
    @State private var showingCondaSetup = false
    @State private var showingCondaEnvSetup = false
    @State private var showingSetupAlert = false
    @State private var setupAlertMessage = ""
    
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
                            .onChange(of: hours) { _ in hours = max(1, min(24, hours)) }
                    }
                    
                    HStack {
                        Text("CPUs")
                        Spacer()
                        TextField("", value: $cpus, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: cpus) { _ in cpus = max(1, min(100, cpus)) }
                    }
                    
                    HStack {
                        Text("RAM (GB)")
                        Spacer()
                        TextField("", value: $ram, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: ram) { _ in ram = max(1, min(500, ram)) }
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
                    }
                    .pickerStyle(.segmented)
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
        .sheet(isPresented: $showingProgress) {
            ConnectionProgressView(manager: connectionManager)
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
            ide: ide
        )
    }
    
    private func setupRemoteServers() {
        showingRemoteSetup = true
    }
}

// MARK: - Setup Item Status (shared)
enum SetupItemStatus {
    case pending, checking, ok, needsAction, error, skipped
}

// MARK: - Remote Setup View
struct RemoteSetupView: View {
    @Environment(\.dismiss) private var dismiss
    
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
                            if isRunning {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Text("Start Setup")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)
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
        .frame(width: 400, height: 420)
    }
    
    private func runSetup() {
        isRunning = true
        currentStep = 1
        log = ""
        errorMessage = ""
        vscodeStatus = .checking
        
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
            let result = runSSHCommand("rm '\(homePath)' && mkdir -p '\(scratchPath)' && ln -s '\(scratchPath)' '\(homePath)'")
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
                mkdir -p '\(scratchPath)' && \
                cp -r '\(homePath)/'* '\(scratchPath)/' 2>/dev/null || true && \
                rm -rf '\(homePath)' && \
                ln -s '\(scratchPath)' '\(homePath)'
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
            let result = runSSHCommand("mkdir -p '\(scratchPath)' && ln -s '\(scratchPath)' '\(homePath)'")
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
    
    private func runSSHCommand(_ command: String) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["torch", command]
        
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
    
    @State private var currentStep = 0       // 0=splash, 1=running, 2=done
    @State private var isRunning = false
    @State private var log: String = ""
    @State private var errorMessage: String = ""
    @State private var detectedCondaVersion: String = ""
    
    @State private var discoverStatus: SetupItemStatus = .pending
    @State private var loadModuleStatus: SetupItemStatus = .pending
    @State private var condaInitStatus: SetupItemStatus = .pending
    @State private var scratchDirsStatus: SetupItemStatus = .pending
    @State private var condarcStatus: SetupItemStatus = .pending
    
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
                    SetupItemRow(title: "Initialize Shell",
                                 path: "~/.bashrc",
                                 status: condaInitStatus)
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
                }
                .frame(maxHeight: .infinity)
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
                    Button("Start Setup") { runSetup() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else if currentStep == 2 {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 400, height: 480)
    }
    
    // MARK: - Setup Logic
    
    private func runSetup() {
        isRunning = true
        currentStep = 1
        log = ""
        errorMessage = ""
        
        discoverStatus = .checking
        loadModuleStatus = .pending
        condaInitStatus = .pending
        scratchDirsStatus = .pending
        condarcStatus = .pending
        
        DispatchQueue.global(qos: .userInitiated).async {
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
                    condaInitStatus = .checking
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
            
            // Step 3: conda init
            appendLog("Checking conda init status...\n")
            let initCheck = runSSHCommand("grep -q '>>> conda initialize >>>' ~/.bashrc 2>/dev/null && echo ALREADY_INIT || echo NEEDS_INIT")
            
            if initCheck.output.contains("ALREADY_INIT") {
                appendLog("conda init already configured.\n")
                DispatchQueue.main.async { condaInitStatus = .ok }
            } else {
                appendLog("Running conda init...\n")
                let initResult = runSSHCommand("bash -lc 'module load \(version!) && conda init bash 2>&1'")
                appendLog(initResult.output)
                DispatchQueue.main.async {
                    condaInitStatus = initResult.success ? .ok : .error
                    if !initResult.success {
                        errorMessage = "conda init failed."
                    }
                }
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
            
            DispatchQueue.main.async {
                isRunning = false
                currentStep = 2
            }
        }
    }
    
    private func parseLatestCondaModule(from output: String) -> String? {
        let tokens = output.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "(D)")) }
            .filter { !$0.isEmpty }
        let pattern = #"^anaconda3/\d{4}\.\d{2}$"#
        let versions = tokens.filter { $0.range(of: pattern, options: .regularExpression) != nil }
        return versions.sorted().last
    }
    
    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            log += text
        }
    }
    
    private func runSSHCommand(_ command: String) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["torch", command]
        
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
            return (false, "Failed to run command: \(error.localizedDescription)")
        }
    }
}

// MARK: - Conda Environment Setup View (Per-Project)
struct CondaEnvSetupView: View {
    let username: String
    @Environment(\.dismiss) private var dismiss
    
    // User inputs
    @State private var envName: String = ""
    @State private var language: Language = .python
    @State private var selectedVersion: String = ""
    @State private var projectFolder: String = ""
    
    // Available versions (fetched via conda search)
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
                        .onChange(of: language) { _ in
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
                            Button("Retry") { fetchVersions() }
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
                        .disabled(!isValidConfig)
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 520)
        .onAppear {
            discoverCondaModule()
        }
    }
    
    // MARK: - Version Discovery
    
    private func discoverCondaModule() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runSSHCommand("bash -lc 'module avail conda 2>&1'")
            let version = parseLatestCondaModule(from: result.output)
            DispatchQueue.main.async {
                condaModule = version ?? "anaconda3"
                fetchVersions()
            }
        }
    }
    
    private func fetchVersions() {
        isLoadingVersions = true
        versionError = ""
        availableVersions = []
        selectedVersion = ""
        
        let mod = condaModule
        guard !mod.isEmpty else {
            versionError = "Conda module not yet discovered."
            isLoadingVersions = false
            return
        }
        
        let lang = language
        // Use conda search with a version filter to limit output size
        let searchExpr = lang == .python ? "\"python>=3.8\"" : "\"r-base>=4.0\""
        let packageName = lang == .python ? "python" : "r-base"
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Use plain-text output (much smaller than JSON) and extract version column
            let result = runSSHCommand("bash -lc 'module load \(mod) 2>/dev/null && conda search \(searchExpr) 2>/dev/null'")
            
            if result.success {
                // Plain-text output has lines like:
                //   python   3.11.5   h7a1cb2a_0   conda-forge
                // First line(s) may be headers. Extract version from column 2.
                var versionSet = Set<String>()
                let lines = result.output.components(separatedBy: .newlines)
                for line in lines {
                    let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                            .map { String($0).trimmingCharacters(in: .whitespaces) }
                    // Expect: name version build channel
                    guard cols.count >= 3,
                          cols[0] == packageName else { continue }
                    let ver = cols[1]
                    let parts = ver.split(separator: ".")
                    if parts.count >= 2 {
                        let majorMinor = "\(parts[0]).\(parts[1])"
                        versionSet.insert(majorMinor)
                    }
                }
                
                if !versionSet.isEmpty {
                    let sorted = versionSet.sorted { v1, v2 in
                        v1.compare(v2, options: .numeric) == .orderedAscending
                    }.reversed().map { String($0) }
                    
                    DispatchQueue.main.async {
                        availableVersions = Array(sorted)
                        selectedVersion = availableVersions.first ?? ""
                        isLoadingVersions = false
                    }
                    return
                }
            }
            
            appendLog("Version fetch failed. Output:\n\(result.output.prefix(500))\n")
            DispatchQueue.main.async {
                versionError = "Could not fetch available versions."
                isLoadingVersions = false
            }
        }
    }
    
    // MARK: - Setup Logic
    
    private func runSetup() {
        isRunning = true
        currentStep = 1
        log = ""
        errorMessage = ""
        
        createEnvStatus = .checking
        verifyLangStatus = .pending
        registerKernelStatus = .pending
        projectFolderStatus = projectFolder.isEmpty ? .skipped : .pending
        
        let mod = condaModule
        let name = envName.trimmingCharacters(in: .whitespaces)
        let ver = selectedVersion
        let lang = language
        let folder = projectFolder.trimmingCharacters(in: .whitespaces)
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Create environment (with idempotency check)
            appendLog("Checking if environment '\(name)' exists...\n")
            let envCheck = runSSHCommand("bash -lc 'module load \(mod) && conda env list 2>/dev/null | grep -q \"^\\s*\(name) \" && echo EXISTS || echo MISSING'")
            
            if envCheck.output.contains("EXISTS") {
                appendLog("Environment '\(name)' already exists.\n")
                DispatchQueue.main.async { createEnvStatus = .ok }
            } else {
                appendLog("Creating environment '\(name)'...\n")
                let packageSpec = lang == .python ? "python=\(ver)" : "r-base=\(ver)"
                let createResult = runSSHCommand("bash -lc 'module load \(mod) && conda create -n \(name) \(packageSpec) -y 2>&1'")
                appendLog(createResult.output)
                if createResult.success {
                    DispatchQueue.main.async {
                        envWasCreated = true
                        createEnvStatus = .ok
                    }
                } else {
                    DispatchQueue.main.async {
                        createEnvStatus = .error
                        errorMessage = "Failed to create environment."
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
                ? "bash -lc 'module load \(mod) && conda run -n \(name) python --version 2>&1'"
                : "bash -lc 'module load \(mod) && conda run -n \(name) Rscript --version 2>&1'"
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
            let kernelCheck = runSSHCommand("bash -lc 'module load \(mod) && conda run -n \(name) jupyter kernelspec list 2>/dev/null | grep -q \"\(name)\" && echo KERNEL_EXISTS || echo KERNEL_MISSING'")
            
            if kernelCheck.output.contains("KERNEL_EXISTS") {
                appendLog("Kernel '\(name)' already registered.\n")
                DispatchQueue.main.async { registerKernelStatus = .ok }
            } else {
                appendLog("Registering kernel...\n")
                let kernelCmd: String
                if lang == .python {
                    kernelCmd = "bash -lc 'module load \(mod) && conda run -n \(name) pip install ipykernel 2>&1 && conda run -n \(name) python -m ipykernel install --user --name \(name) --display-name \"Python (\(name))\" 2>&1'"
                } else {
                    kernelCmd = "bash -lc 'module load \(mod) && conda run -n \(name) Rscript -e \"install.packages(\\\"IRkernel\\\", repos=\\\"https://cloud.r-project.org\\\")\" 2>&1 && conda run -n \(name) Rscript -e \"IRkernel::installspec(name=\\\"\(name)\\\", displayname=\\\"R (\(name))\\\")\" 2>&1'"
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
    
    private func parseLatestCondaModule(from output: String) -> String? {
        let tokens = output.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "(D)")) }
            .filter { !$0.isEmpty }
        let pattern = #"^anaconda3/\d{4}\.\d{2}$"#
        let versions = tokens.filter { $0.range(of: pattern, options: .regularExpression) != nil }
        return versions.sorted().last
    }
    
    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            log += text
        }
    }
    
    private func runSSHCommand(_ command: String) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["torch", command]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        DispatchQueue.main.async { currentProcess = process }
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async { currentProcess = nil }
            return (process.terminationStatus == 0, output)
        } catch {
            DispatchQueue.main.async { currentProcess = nil }
            return (false, "Failed to run command: \(error.localizedDescription)")
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
                let _ = runSSHCommand("bash -lc 'module load \(mod) && conda env remove -n \(name) -y 2>&1'")
            }
        }
        
        dismiss()
    }
    
    private func cleanupFailedEnv() {
        let mod = condaModule
        let name = envName.trimmingCharacters(in: .whitespaces)
        appendLog("Cleaning up partial environment '\(name)'...\n")
        DispatchQueue.global(qos: .utility).async {
            let result = runSSHCommand("bash -lc 'module load \(mod) && conda env remove -n \(name) -y 2>&1'")
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
