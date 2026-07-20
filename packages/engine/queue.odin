package engine

import "core:sync"

Bounded_Queue :: struct($T: typeid, $CAP: int) {
	mutex: sync.Mutex,
	not_empty: sync.Cond,
	not_full: sync.Cond,
	items: [CAP]T,
	head: int,
	tail: int,
	count: int,
	closed: bool,
}

queue_close :: proc(q: ^Bounded_Queue($T, $CAP)) {
	sync.mutex_lock(&q.mutex)
	q.closed = true
	sync.cond_broadcast(&q.not_empty)
	sync.cond_broadcast(&q.not_full)
	sync.mutex_unlock(&q.mutex)
}

queue_try_push :: proc(q: ^Bounded_Queue($T, $CAP), item: T) -> bool {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)

	if q.closed || q.count == CAP {
		return false
	}

	q.items[q.tail] = item
	q.tail = (q.tail + 1) % CAP
	q.count += 1
	sync.cond_signal(&q.not_empty)
	return true
}

queue_push_blocking :: proc(q: ^Bounded_Queue($T, $CAP), item: T) -> bool {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)

	for !q.closed && q.count == CAP {
		sync.cond_wait(&q.not_full, &q.mutex)
	}

	if q.closed {
		return false
	}

	q.items[q.tail] = item
	q.tail = (q.tail + 1) % CAP
	q.count += 1
	sync.cond_signal(&q.not_empty)
	return true
}

// Push while limiting this producer to a smaller in-flight window than the
// queue's physical capacity. Other producers can still use the remaining
// capacity for control-command bursts.
queue_push_blocking_below_count :: proc(q: ^Bounded_Queue($T, $CAP), item: T, max_pending: int) -> bool {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)

	limit := min(max(max_pending, 1), CAP)
	for !q.closed && q.count >= limit {
		sync.cond_wait(&q.not_full, &q.mutex)
	}

	if q.closed {
		return false
	}

	q.items[q.tail] = item
	q.tail = (q.tail + 1) % CAP
	q.count += 1
	sync.cond_signal(&q.not_empty)
	return true
}

queue_try_pop :: proc(q: ^Bounded_Queue($T, $CAP), item: ^T) -> bool {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)

	if q.count == 0 {
		return false
	}

	item^ = q.items[q.head]
	q.head = (q.head + 1) % CAP
	q.count -= 1
	sync.cond_signal(&q.not_full)
	return true
}

queue_pop_blocking :: proc(q: ^Bounded_Queue($T, $CAP), item: ^T) -> bool {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)

	for !q.closed && q.count == 0 {
		sync.cond_wait(&q.not_empty, &q.mutex)
	}

	if q.count == 0 {
		return false
	}

	item^ = q.items[q.head]
	q.head = (q.head + 1) % CAP
	q.count -= 1
	sync.cond_signal(&q.not_full)
	return true
}

queue_len :: proc(q: ^Bounded_Queue($T, $CAP)) -> int {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	return q.count
}
