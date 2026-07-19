//
//  MessageCacheIOServicing.swift
//  Clawline
//
//  Serialization seam for message-cache file mutations.
//
//  Every ChatViewModel persists to the SAME Application Support cache path, so
//  write/delete ordering is a process-wide property, not a per-instance one. A
//  history barrier (spec §T-A) deletes a stream's cache file; if a retired or
//  overlapping view model could write afterwards, cleared history would come
//  back on the next launch. Routing all cache mutations through one serial
//  executor makes the barrier's delete strictly ordered after any previously
//  enqueued write, whichever instance enqueued it.
//
//  This is a protocol so the dependency is injected (tests substitute a
//  synchronous double and drain deterministically) rather than reached for as
//  global state from the view model.
//

import Foundation

protocol MessageCacheIOServicing: Sendable {
    /// Run `work` on the shared serial cache executor, preserving submission order.
    func perform(_ work: @escaping @Sendable () -> Void)
}

/// Production implementation. The queue is an INSTANCE property, not static:
/// the composition root creates exactly ONE `MessageCacheIO` and injects that
/// same instance into every `ChatViewModel`, so all instances serialize against
/// one executor without any global/static state (COMMON.md). Constructing a
/// second instance (previews/tests) yields an independent queue by design.
final class MessageCacheIO: MessageCacheIOServicing {
    private let queue = DispatchQueue(label: "co.clicketyclacks.Clawline.messageCacheIO")

    func perform(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}
