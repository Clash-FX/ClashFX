import Darwin
import Foundation

/// Names the process that holds a local port so a port conflict can be
/// attributed in diagnostics. Read-only: it inspects descriptors through
/// libproc and never signals or modifies a process. Sockets of other users'
/// processes, including the root-owned Enhanced Mode core, are not visible to
/// an unprivileged caller and are reported as `unreadableProcessCount`.
enum PortOwnerProbe {
    struct Owner: Equatable {
        let pid: Int32
        let name: String
        let proto: String
    }

    struct Result: Equatable {
        let owners: [Owner]
        let unreadableProcessCount: Int

        var summary: String {
            if owners.isEmpty {
                return unreadableProcessCount > 0
                    ? "no visible owner (\(unreadableProcessCount) processes not inspectable; likely another user or root)"
                    : "no owner found"
            }
            return owners.map { "pid=\($0.pid) name=\($0.name) proto=\($0.proto)" }.joined(separator: "; ")
        }
    }

    static func owners(ofLocalPort port: Int, maxProcesses: Int = 4096) -> Result {
        guard (1 ... 65535).contains(port) else { return Result(owners: [], unreadableProcessCount: 0) }
        var pids = [pid_t](repeating: 0, count: maxProcesses)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(maxProcesses * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return Result(owners: [], unreadableProcessCount: 0) }
        let count = Int(bytes) / MemoryLayout<pid_t>.size

        var found: [Owner] = []
        var unreadable = 0
        for pid in pids.prefix(count) where pid > 0 {
            switch matches(pid: pid, port: port) {
            case .unreadable: unreadable += 1
            case let .owner(protos):
                let name = processName(pid)
                found.append(contentsOf: protos.map { Owner(pid: pid, name: name, proto: $0) })
            case .none: break
            }
        }
        return Result(owners: found, unreadableProcessCount: unreadable)
    }

    private enum Match { case none, unreadable, owner([String]) }

    private static func matches(pid: pid_t, port: Int) -> Match {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return size == 0 ? .none : .unreadable }
        let capacity = Int(size) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard filled > 0 else { return .unreadable }

        var protos: [String] = []
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size)
            where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let read = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info,
                                      Int32(MemoryLayout<socket_fdinfo>.size))
            guard read == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            let socket = info.psi
            let localPort: Int
            let proto: String
            switch Int(socket.soi_kind) {
            case SOCKINFO_TCP:
                // Only a listening or bound TCP socket blocks a new bind.
                localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
                proto = "tcp"
            case SOCKINFO_IN:
                localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.soi_proto.pri_in.insi_lport)))
                proto = "udp"
            default:
                continue
            }
            if localPort == port, !protos.contains(proto) { protos.append(proto) }
        }
        return protos.isEmpty ? .none : .owner(protos)
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "unknown" }
        return String(cString: buffer)
    }
}
