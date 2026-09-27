import Foundation
import CoreServices

/// Watches a vault folder recursively (FSEvents) and fires `onChange` on the
/// main queue, debounced, when anything inside changes — so external edits
/// (Finder, git, sync) show up in the file tree without reopening the vault.
public final class VaultWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let debounce: TimeInterval
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "io.hanji.vaultwatcher")

    public init(root: URL, debounce: TimeInterval = 0.2, onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.debounce = debounce

        // FSEvents calls back on `queue` with this context pointer. It points at a
        // relay the stream owns (released with the stream), which holds the
        // watcher weakly — not at the watcher itself: a callback racing the
        // watcher's deinit would take a strong reference to an object mid-
        // deallocation, which the runtime traps. The work hops to main, where
        // `pending` lives.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(Relay(self)).toOpaque(), retain: nil,
            release: { info in if let info { Unmanaged<Relay>.fromOpaque(info).release() } },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let relay = Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { relay.watcher?.scheduleNotify() }
        }
        stream = FSEventStreamCreate(nil, callback, &context,
                                     [root.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                     0.1,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    private func scheduleNotify() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit { stop() }

    private final class Relay {
        weak var watcher: VaultWatcher?
        init(_ watcher: VaultWatcher) { self.watcher = watcher }
    }
}
