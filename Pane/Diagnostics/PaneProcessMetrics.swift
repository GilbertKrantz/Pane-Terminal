import Darwin
import Foundation

struct PaneProcessMetricsSnapshot: Codable, Equatable, Sendable {
    let residentMemoryBytes: UInt64
    let virtualMemoryBytes: UInt64
    let threadCount: Int
    let fileDescriptorCount: Int
    let cumulativeCPUSeconds: Double
}

enum PaneProcessMetrics {
    static func snapshot(processID: pid_t = getpid()) -> PaneProcessMetricsSnapshot {
        var taskInfo = proc_taskinfo()
        let taskInfoSize = MemoryLayout<proc_taskinfo>.stride
        let taskInfoBytes = withUnsafeMutablePointer(to: &taskInfo) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTASKINFO,
                0,
                pointer,
                Int32(taskInfoSize)
            )
        }
        let descriptorBytes = proc_pidinfo(
            processID,
            PROC_PIDLISTFDS,
            0,
            nil,
            0
        )
        let descriptorCount = descriptorBytes > 0
            ? Int(descriptorBytes) / MemoryLayout<proc_fdinfo>.stride
            : 0
        guard Int(taskInfoBytes) == taskInfoSize else {
            return PaneProcessMetricsSnapshot(
                residentMemoryBytes: 0,
                virtualMemoryBytes: 0,
                threadCount: 0,
                fileDescriptorCount: descriptorCount,
                cumulativeCPUSeconds: 0
            )
        }
        let cpuNanoseconds = taskInfo.pti_total_user + taskInfo.pti_total_system
        return PaneProcessMetricsSnapshot(
            residentMemoryBytes: taskInfo.pti_resident_size,
            virtualMemoryBytes: taskInfo.pti_virtual_size,
            threadCount: Int(taskInfo.pti_threadnum),
            fileDescriptorCount: descriptorCount,
            cumulativeCPUSeconds: Double(cpuNanoseconds) / 1_000_000_000
        )
    }
}

actor PaneProcessMetricSampler {
    private var priorMetrics: PaneProcessMetricsSnapshot?
    private var priorTimestamp: Date?

    func sample(blockCount: Int) -> PaneSoakSample {
        let timestamp = Date()
        let current = PaneProcessMetrics.snapshot()
        let cpuPercent: Double
        if let priorMetrics, let priorTimestamp {
            let wall = timestamp.timeIntervalSince(priorTimestamp)
            let cpu = current.cumulativeCPUSeconds
                - priorMetrics.cumulativeCPUSeconds
            cpuPercent = wall > 0 ? max(0, cpu / wall * 100) : 0
        } else {
            cpuPercent = 0
        }
        priorMetrics = current
        self.priorTimestamp = timestamp
        let resources = PaneResourceCounters.snapshot
        return PaneSoakSample(
            timestamp: timestamp,
            residentMemoryBytes: current.residentMemoryBytes,
            virtualMemoryBytes: current.virtualMemoryBytes,
            threadCount: current.threadCount,
            fileDescriptorCount: current.fileDescriptorCount,
            liveSessionCount: resources.liveSessions,
            livePTYCount: resources.livePTYs,
            completionTaskCount: resources.completionTaskCount,
            blockCount: max(0, blockCount),
            idleCPUPercent: cpuPercent
        )
    }
}
