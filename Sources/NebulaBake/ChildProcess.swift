// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// A bake subprocess (Siril, a StarNet command) started in its OWN process
/// group, with a deadline, so stopping it stops everything it started.
///
/// `Foundation.Process` can't do that: `terminate()` signals only the direct
/// child, so for a shell template (`bash -c "starnet … | …"`) it killed bash
/// and left the actual worker running, still writing into a scratch dir that
/// was about to be deleted. Here the child is spawned with
/// `POSIX_SPAWN_SETPGROUP` and every stop signals the whole group
/// (SIGTERM, then SIGKILL after a grace period), and nothing returns until the
/// leader has been reaped — so cleanup can never race a writer.
final class ChildProcess {
    enum Ending: Equatable {
        case exited(Int32)
        case signalled(Int32)
        case timedOut
        case cancelled
    }

    enum SpawnError: Error, CustomStringConvertible {
        case spawnFailed(String, Int32)
        var description: String {
            switch self {
            case .spawnFailed(let exe, let code):
                return "couldn't start \(exe): \(String(cString: strerror(code)))"
            }
        }
    }

    let pid: pid_t
    private var reaped: Ending?

    /// Start `executable` with `arguments`, stdout + stderr appended to `log`
    /// and stdin from /dev/null, optionally in `workingDirectory`.
    init(executable: String, arguments: [String], workingDirectory: URL? = nil,
         log: URL) throws {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New process group (pgid = child's pid); default signal dispositions
        // and an empty mask, so an ignored SIGTERM in the parent can't leak in.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
                                              | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        if let workingDirectory {
            // The `_np` form exists in every SDK. The unsuffixed name is only
            // declared in the macOS 26 SDK, so it would not compile on CI's
            // Xcode 16 even behind `#available`.
            posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
        }

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { for p in argv { free(p) } }
        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &actions, &attr, argv, environ)
        guard rc == 0 else { throw SpawnError.spawnFailed(executable, rc) }
        pid = child
    }

    deinit {
        // Never leave a running group behind, whatever path dropped us.
        if reaped == nil { _ = stop() }
    }

    /// Wait until the child exits, `deadline` passes, or the current task is
    /// cancelled. On timeout or cancel the whole group is stopped and reaped
    /// before this returns.
    func wait(until deadline: Date, poll: TimeInterval = 0.2) -> Ending {
        while true {
            if let ending = reapIfExited() { return ending }
            if Task.isCancelled { _ = stop(); reaped = .cancelled; return .cancelled }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { _ = stop(); reaped = .timedOut; return .timedOut }
            Thread.sleep(forTimeInterval: min(poll, remaining))
        }
    }

    /// SIGTERM the group, give it `grace` seconds, then SIGKILL whatever is
    /// left, and reap the leader. Returns how the leader ended.
    @discardableResult
    func stop(grace: TimeInterval = 3) -> Ending {
        if let reaped { return reaped }
        kill(-pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        var leader: Ending?
        while Date() < deadline {
            if leader == nil { leader = reapIfExited() }
            if leader != nil && !groupAlive() { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Members that ignored SIGTERM (or outlived their leader) go now.
        if groupAlive() { kill(-pid, SIGKILL) }
        if leader == nil { leader = reapBlocking() }
        // The kill is asynchronous; let the stragglers actually go (bounded).
        let settle = Date().addingTimeInterval(2)
        while groupAlive() && Date() < settle { Thread.sleep(forTimeInterval: 0.02) }
        reaped = leader
        return leader!
    }

    private func groupAlive() -> Bool {
        kill(-pid, 0) == 0 || errno == EPERM
    }

    private func reapIfExited() -> Ending? {
        if let reaped { return reaped }
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid { let e = Self.decode(status); reaped = e; return e }
        if r == -1 && errno == ECHILD { reaped = .exited(-1); return reaped }
        return nil
    }

    private func reapBlocking() -> Ending {
        var status: Int32 = 0
        while true {
            let r = waitpid(pid, &status, 0)
            if r == pid { return Self.decode(status) }
            if r == -1 && errno != EINTR { return .exited(-1) }
        }
    }

    /// `WIFEXITED`/`WEXITSTATUS`/`WTERMSIG` are macros Swift can't import.
    static func decode(_ status: Int32) -> Ending {
        let signal = status & 0x7f
        return signal == 0 ? .exited((status >> 8) & 0xff) : .signalled(signal)
    }
}
