import Foundation

// Trailing-edge debouncer for imperative call-sites — i.e. "fire this
// action `delay` seconds after the most recent call, cancelling any
// pending invocation." Use Combine's `.debounce` when the source is
// already a Publisher (see ProjectsManager).
//
// Not thread-safe — confine to a single actor / queue. All current
// callers are main-thread.
class Debouncer {
    private var workItem: DispatchWorkItem?
    private let delay: TimeInterval
    private let queue: DispatchQueue

    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    func schedule(_ action: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Run any pending work synchronously on the current thread, then clear.
    /// Used on app termination to flush a pending save before exit.
    func flush() {
        workItem?.perform()
        workItem?.cancel()
        workItem = nil
    }
}
