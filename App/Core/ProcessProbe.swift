// App/Core/ProcessProbe.swift
import Foundation
import Darwin

/// Kernel facts about a running process, read with `sysctl` (no `ps` spawn).
enum ProcessProbe {
    /// When `pid` started, or nil when no such process is running. Paired with a
    /// recorded start time it tells a live session apart from a recycled pid.
    static func startTime(of pid: Int32) -> Date? {
        guard let info = kinfo(pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// `/dev/ttysNNN` for the process's controlling terminal, or "" without one.
    static func tty(of pid: Int32) -> String {
        guard let info = kinfo(pid), info.kp_eproc.e_tdev != -1,
              let name = devname(info.kp_eproc.e_tdev, S_IFCHR) else { return "" }
        return "/dev/" + String(cString: name)
    }

    private static func kinfo(_ pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}
