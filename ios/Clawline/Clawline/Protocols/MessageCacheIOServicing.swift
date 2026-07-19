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

/// Production implementation. The queue is `static` *inside this type* on
/// purpose: it guards a single process-global resource (the on-disk cache), so
/// every instance must serialize against the same executor for the ordering
/// guarantee to mean anything. Callers still receive it by injection.
final class MessageCacheIO: MessageCacheIOServicing {
    private static let queue = DispatchQueue(label: "co.clicketyclacks.Clawline.messageCacheIO")

    func perform(_ work: @escaping @Sendable () -> Void) {
        Self.queue.async(execute: work)
    }
}
