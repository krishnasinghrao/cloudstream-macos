package com.lagradost.cloudstream3.utils

import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized

/**
 * A thread-safe list backed by [SynchronizedObject].
 *
 * For iteration, wrap block in [withLock] to hold the lock for the duration:
 *   list.withLock { list.forEach { ... } }
 */
open class AtomicList<T>(
    private val delegate: List<T> = emptyList(),
) : List<T>, SynchronizedObject() {
    internal var lock: SynchronizedObject = SynchronizedObject()

    internal constructor(delegate: List<T>, lock: SynchronizedObject) : this(delegate) {
        this.lock = lock
    }

    fun <R> withLock(block: () -> R): R = synchronized(lock) { block() }

    fun filter(predicate: (T) -> Boolean): AtomicList<T> = synchronized(lock) { AtomicList(delegate.filter(predicate), lock) }
    fun distinctBy(selector: (T) -> Any?): AtomicList<T> = synchronized(lock) { AtomicList(delegate.distinctBy(selector), lock) }

    override val size: Int get() = synchronized(lock) { delegate.size }
    override fun isEmpty(): Boolean = synchronized(lock) { delegate.isEmpty() }
    override fun contains(element: T): Boolean = synchronized(lock) { delegate.contains(element) }
    override fun containsAll(elements: Collection<T>): Boolean = synchronized(lock) { delegate.containsAll(elements) }
    override fun get(index: Int): T = synchronized(lock) { delegate[index] }
    override fun indexOf(element: T): Int = synchronized(lock) { delegate.indexOf(element) }
    override fun lastIndexOf(element: T): Int = synchronized(lock) { delegate.lastIndexOf(element) }

    // Iterators intentionally NOT synchronized, callers must use withLock { } for safe iteration.
    override fun iterator(): Iterator<T> = delegate.iterator()
    override fun listIterator(): ListIterator<T> = delegate.listIterator()
    override fun listIterator(index: Int): ListIterator<T> = delegate.listIterator(index)
    override fun subList(fromIndex: Int, toIndex: Int): List<T> = delegate.subList(fromIndex, toIndex)

    operator fun plus(element: T): AtomicList<T> = synchronized(lock) { AtomicList(delegate + element, lock) }
    operator fun plus(elements: Collection<T>): AtomicList<T> = synchronized(lock) { AtomicList(delegate + elements, lock) }
}

class AtomicMutableList<T>(
    private val mutableDelegate: MutableList<T> = mutableListOf(),
) : AtomicList<T>(mutableDelegate), MutableList<T> {
    internal constructor(mutableDelegate: MutableList<T>, lock: SynchronizedObject) : this(mutableDelegate) {
        this.lock = lock
    }

    override fun add(element: T): Boolean = synchronized(lock) { mutableDelegate.add(element) }
    override fun add(index: Int, element: T) = synchronized(lock) { mutableDelegate.add(index, element) }
    override fun addAll(elements: Collection<T>): Boolean = synchronized(lock) { mutableDelegate.addAll(elements) }
    override fun addAll(index: Int, elements: Collection<T>): Boolean = synchronized(lock) { mutableDelegate.addAll(index, elements) }
    override fun remove(element: T): Boolean = synchronized(lock) { mutableDelegate.remove(element) }
    override fun removeAt(index: Int): T = synchronized(lock) { mutableDelegate.removeAt(index) }
    override fun removeAll(elements: Collection<T>): Boolean = synchronized(lock) { mutableDelegate.removeAll(elements) }
    override fun retainAll(elements: Collection<T>): Boolean = synchronized(lock) { mutableDelegate.retainAll(elements) }
    override fun set(index: Int, element: T): T = synchronized(lock) { mutableDelegate.set(index, element) }
    override fun clear() = synchronized(lock) { mutableDelegate.clear() }

    // Iterators intentionally NOT synchronized, callers must use withLock { } for safe iteration.
    override fun iterator(): MutableIterator<T> = mutableDelegate.iterator()
    override fun listIterator(): MutableListIterator<T> = mutableDelegate.listIterator()
    override fun listIterator(index: Int): MutableListIterator<T> = mutableDelegate.listIterator(index)
    override fun subList(fromIndex: Int, toIndex: Int): MutableList<T> = mutableDelegate.subList(fromIndex, toIndex)
}
