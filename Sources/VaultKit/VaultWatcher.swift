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

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue().scheduleNotify()
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
}
