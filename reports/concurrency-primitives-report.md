# Concurrency Primitives & Patterns for Astra

Comprehensive research report covering channels, mutexes, atomics, deadlock prevention, data race prevention, channel implementation, select/multiplexing, fiber synchronization, shared-state concurrency, and performance characteristics.

---

## 1. Channels: CSP Model for Fibers

### 1.1 Theory: Communicating Sequential Processes

CSP (Hoare, 1978) models concurrency as independent processes communicating through channels. Go adopted this as its core concurrency primitive. Astra should do the same, since channels map naturally to fiber-based M:N scheduling.

**Key principle:** "Do not communicate by sharing memory; instead, share memory by communicating."

### 1.2 Channel Types

#### Unbuffered (Synchronous) Channels

Both sender and receiver block until the other is ready. Provides strong synchronization guarantees — the handshake ensures both fibers are at a known point.

```
# Astra syntax proposal
let ch = channel(Int)        # unbuffered, capacity 0

spawn fn producer() {
    ch.send(42)              # blocks until receiver is ready
}

spawn fn consumer() {
    let value = ch.recv()    # blocks until sender is ready
    println(value)           # 42
}
```

#### Buffered (Asynchronous) Channels

Sender only blocks when the buffer is full. Receiver only blocks when the buffer is empty. Decouples producer/consumer speeds temporarily.

```
let ch = channel(Int, 100)   # buffered, capacity 100

spawn fn producer() {
    for i in 0..1000 {
        ch.send(i)           # blocks only when buffer is full
    }
}

spawn fn consumer() {
    for _ in 0..1000 {
        let value = ch.recv()
        process(value)
    }
}
```

#### Typed vs Untyped Channels

| Approach | Pros | Cons |
|:---------|:-----|:-----|
| **Typed (recommended)** | Compile-time safety, no serialization overhead, type inference works | Must create channel per type |
| **Untyped** | Flexible, can send any message | Runtime type checks, boxing overhead, error-prone |
| **Generic unbounded** | Maximum flexibility | Loses type safety |

**Recommendation for Astra:** Typed channels with type inference. Astra's strong type system makes typed channels natural.

```
let int_ch = channel(Int)          # inferred from usage
let string_ch = channel(String)

# Generics for polymorphic channels
fn fan_in<T>(chs: Array<Receiver<T>>) -> Receiver<T> {
    let merged = channel(T)
    // ... merge logic
    return merged
}
```

### 1.3 Channel Interaction with Fibers

In an M:N scheduler, channels are the primary coordination mechanism between fibers. Critical design considerations:

**Parking/Unparking:** When a fiber sends on a full unbuffered channel (or receives from empty), it must be **parked** (suspended) — not block the OS thread. The scheduler should:
1. Save fiber state to its stack
2. Remove fiber from the run queue
3. Switch to another fiber on the same OS thread
4. When data becomes available, the fiber is **unparked** (moved to ready queue)

**Direct handoff optimization (Go-style):** For unbuffered channels, if a receiver is already waiting, the sender can copy the value directly to the receiver's stack — bypassing the buffer entirely. This is the fast path in Go's `hchan` implementation.

**Go's `hchan` structure** (reference implementation):

```c
// Go's internal channel structure (simplified)
struct hchan {
    qcount   uint           // total data in the queue
    dataqsiz uint           // size of circular queue (buffer capacity)
    buf      unsafe.Pointer // circular buffer (ring buffer)
    elemsize uint16         // size of each element
    closed   uint32
    sendx    uint           // send index in ring buffer
    recvx    uint           // receive index in ring buffer
    recvq    waitq          // linked list of blocked receivers
    sendq    waitq          // linked list of blocked senders
    lock     mutex          // protects all fields
}
```

Each blocked fiber is represented by a `sudog` struct that holds a pointer to the fiber (goroutine), the element being sent/received, and a link to the next waiter.

### 1.4 Channel Patterns

**Fan-out / Fan-in:**

```
fn fan_out(input: Receiver<Int>, workers: Int) -> Array<Sender<Int>> {
    let channels = Array::new()
    for _ in 0..workers {
        let (tx, rx) = channel(Int)
        channels.push(tx)
        spawn fn() {
            for val in input {
                tx.send(expensive_computation(val))
            }
            tx.close()
        }
    }
    return channels
}
```

**Pipeline:**

```
fn pipeline(source: Receiver<Int>) -> Receiver<String> {
    let (tx1, rx1) = channel(Int)
    let (tx2, rx2) = channel(String)

    # Stage 1: filter
    spawn fn() {
        for val in source {
            if val > 0 { tx1.send(val) }
        }
        tx1.close()
    }

    # Stage 2: transform
    spawn fn() {
        for val in rx1 {
            tx2.send(val.to_string())
        }
        tx2.close()
    }

    return rx2
}
```

**Done channel (cancellation):**

```
fn worker(done: Receiver<Void>) {
    loop {
        select {
            case _ = done:
                return          # cancellation received
            case data = work_ch:
                process(data)
        }
    }
}

let done = channel(Void)
spawn fn() { worker(done) }
# ... later
done.send(())   # signal cancellation
```

---

## 2. Mutex Patterns

### 2.1 Mutex Types

#### Standard Mutex (Fiber-Aware)

In a fiber-based runtime, a **standard mutex must be fiber-aware**, not OS-level. When a fiber blocks on a mutex, it must **yield to the scheduler** rather than blocking the OS thread.

```
let m = Mutex()

m.lock()
# critical section
m.unlock()

# Or with scope-based unlocking (RAII-style)
m.synchronize(fn() {
    # critical section — automatically unlocked on exit
})
```

**Internal behavior (fiber-aware mutex):**

```
# Pseudocode for fiber-aware mutex
fn lock(self: *Mutex, current_fiber: Fiber) {
    if self.state == UNLOCKED {
        self.state = LOCKED
        self.owner = current_fiber
    } else {
        self.waiters.push_back(current_fiber)
        current_fiber.suspend()   # yield to scheduler, NOT block OS thread
    }
}

fn unlock(self: *Mutex) {
    if self.waiters.empty() {
        self.state = UNLOCKED
    } else {
        let next = self.waiters.pop_front()
        self.owner = next
        next.resume()             # put fiber back on run queue
    }
}
```

**Critical insight:** The mutex is **held per-fiber, not per-thread**. In an M:N scheduler, thousands of fibers share a single OS thread. If a mutex blocked the OS thread, all other fibers on that thread would be starved. This is the "thread-blocking anomaly" described in the literature.

**Ruby/Crystal precedent:** Ruby 3.x made `Mutex` fiber-aware (per-fiber instead of per-thread). Crystal's `Mutex` has always been fiber-aware. Both require a scheduler hook that suspends the fiber and resumes the lock owner.

#### TryLock

Non-blocking attempt to acquire the lock. Returns immediately with success/failure.

```
if m.try_lock() {
    # got the lock
    defer { m.unlock() }
    # critical section
} else {
    # lock is held, do something else
}
```

**Use cases:**
- Avoiding deadlock when acquiring multiple locks
- Optimistic concurrency patterns
- Time-limited operations

**Fiber-aware TryLock with FIFO fairness:**

```
# TryLock should not jump ahead of queued waiters
fn try_lock(self: *Mutex) -> Bool {
    if self.waiters.not_empty() {
        return false    # respect FIFO ordering
    }
    if self.state == UNLOCKED {
        self.state = LOCKED
        self.owner = current_fiber
        return true
    }
    return false
}
```

#### RwLock (Reader-Writer Lock)

Multiple readers can hold the read lock simultaneously. Only one writer can hold the write lock (exclusive).

```
let rw = RwLock()

# Reading (shared)
rw.read_lock()
# read shared data
rw.read_unlock()

# Writing (exclusive)
rw.write_lock()
# modify shared data
rw.write_unlock()
```

**When to use:** Read-heavy workloads where reads vastly outnumber writes. Cache lookups, configuration tables, routing tables.

**Performance note:** RwLock has higher per-operation overhead than Mutex. Only beneficial when the read:write ratio is > 10:1 approximately.

#### Spinlock

Busy-waits (spins) for a short period before yielding. Useful for very short critical sections where the overhead of suspending a fiber is greater than spinning.

```
let spin = Spinlock()

spin.lock()
# very short critical section (< 1μs)
spin.unlock()
```

**When to use:**
- Critical sections < 100ns
- When the lock is expected to be available very quickly
- In low-level runtime code (scheduler internals)

**When NOT to use:**
- Long critical sections (wastes CPU cycles)
- When contention is high (other fibers could be doing useful work)
- In application code (Mutex is almost always better)

**Fiber-aware spinlock:** Must yield after a spin budget is exhausted:

```
fn lock(self: *Spinlock) {
    let mut spins = SPIN_BUDGET    # e.g., 100 iterations
    loop {
        if self.try_lock() { return }
        spins -= 1
        if spins == 0 {
            self.waiters.push(current_fiber)
            current_fiber.suspend()
            spins = SPIN_BUDGET     # retry after wakeup
        }
    }
}
```

### 2.2 Mutex Comparison Table

| Primitive | Blocking Behavior | Overhead | Best For |
|:----------|:------------------|:---------|:---------|
| **Mutex** | Fiber suspends | Medium (~20-50ns) | General mutual exclusion |
| **RwLock** | Fiber suspends | Higher (~50-100ns) | Read-heavy workloads |
| **Spinlock** | Busy-wait then suspend | Low if uncontended (~5-10ns) | Very short critical sections |
| **TryLock** | Non-blocking | Lowest (~10ns) | Optimistic patterns |
| **Channel** | Fiber suspends | Higher (~100-200ns) | Communication + synchronization |

### 2.3 When to Use Each

| Scenario | Recommendation |
|:---------|:---------------|
| Protecting a single shared counter | Mutex |
| Read-heavy cache (100:1 read:write) | RwLock |
| Very short critical section (<100ns), low contention | Spinlock |
| Avoiding deadlock when acquiring multiple locks | TryLock |
| Passing ownership of data between fibers | Channel |
| Protecting a complex data structure | Mutex (or channels for ownership transfer) |

---

## 3. Atomic Operations

### 3.1 Atomic Types

```
# Atomic integer
let counter = AtomicInt(0)
counter.fetch_add(1)                     # returns old value
counter.store(42, Ordering.Release)
let val = counter.load(Ordering.Acquire)

# Atomic reference (shared pointer)
let shared_ref = AtomicRef(my_object)
shared_ref.store(new_object, Ordering.Release)
let current = shared_ref.load(Ordering.Acquire)

# Atomic boolean (for flags)
let ready = AtomicBool(false)
ready.store(true, Ordering.Release)
if ready.load(Ordering.Acquire) {
    # data is ready
}
```

### 3.2 Memory Ordering

Memory ordering controls how operations on atomic variables are ordered with respect to other memory operations. The five orderings (from weakest to strongest):

#### Relaxed

No ordering constraints. Only guarantees atomicity — no tearing, no data races. Operations can be reordered freely with respect to other memory operations.

```
let counter = AtomicInt(0)

# Multiple fibers can increment without ordering guarantees
counter.fetch_add(1, Ordering.Relaxed)

# Use case: Statistics counters, where exact order doesn't matter
# Performance: Same as a plain increment on most architectures
```

**When to use:** Counters, statistics, anything where you only need atomicity but not ordering.

#### Release (Store side)

When a fiber does a Release store, all previous memory operations (reads and writes) in that fiber are guaranteed to be visible to any fiber that does an Acquire load of the same atomic.

```
# Producer fiber:
data = prepare_data()
flag.store(true, Ordering.Release)   # data writes happen-before this store

# Consumer fiber:
if flag.load(Ordering.Acquire) {     # reads data written before the Release store
    use(data)                         # guaranteed to see all of data's writes
}
```

#### Acquire (Load side)

When a fiber does an Acquire load, all subsequent memory operations in that fiber are guaranteed to see writes that happened before a Release store by another fiber.

```
# This is the symmetric pair to Release
flag.load(Ordering.Acquire)   # subsequent reads see Release-stored data
```

#### AcqRel (Acquire + Release)

For read-modify-write operations (like `fetch_add`, `compare_exchange`). The load part has Acquire semantics, the store part has Release semantics.

```
counter.fetch_add(1, Ordering.AcqRel)
# Guarantees: sees all previous Release stores, and makes this modification
# visible to subsequent Acquire loads
```

#### SeqCst (Sequentially Consistent)

The strongest ordering. All fibers see all SeqCst operations in the same total order. Provides a global synchronization point.

```
flag.store(true, Ordering.SeqCst)    # all fibers see this in the same order
# ... vs
flag.store(true, Ordering.Release)   # only guarantees visibility to Acquire loaders
```

### 3.3 Ordering Comparison

| Ordering | Atomicity | Ordering | Use Case |
|:---------|:----------|:---------|:---------|
| **Relaxed** | Yes | None | Statistics counters |
| **Release** | Yes | Store → later loads | Publishing data |
| **Acquire** | Yes | Earlier stores → load | Consuming data |
| **AcqRel** | Yes | Both | Read-modify-write |
| **SeqCst** | Yes | Global total order | Complex synchronization |

### 3.4 Performance Characteristics (Approximate, x86-64)

| Operation | Relaxed | Acquire/Release | SeqCst |
|:----------|:--------|:----------------|:-------|
| Atomic load | MOV (1ns) | MOV + MFENCE (~10ns) | MOV + MFENCE (~10ns) |
| Atomic store | MOV (1ns) | MOV + MFENCE (~10ns) | XCHG (~20ns) |
| fetch_add | LOCK ADD (~5ns) | LOCK ADD (~5ns) | LOCK ADD + MFENCE (~15ns) |
| compare_exchange | LOCK CMPXCHG (~5ns) | ~5ns | ~15ns |

**ARM64 note:** Acquire/Release are cheap on ARM (load-acquire/store-release instructions). SeqCst requires DMB barriers.

### 3.5 Astra Design Recommendation

```
# Default ordering for safety: SeqCst (like Rust's default)
counter.store(42)                       # defaults to SeqCst

# Explicit ordering for performance-critical code
counter.store(42, Ordering.Release)     # explicit

# The type system should enforce valid orderings:
# store() accepts: Relaxed, Release, SeqCst
# load() accepts: Relaxed, Acquire, SeqCst
# fetch_add() accepts: Relaxed, Acquire, Release, AcqRel, SeqCst
```

---

## 4. Deadlock Prevention

### 4.1 Classic Deadlock Conditions (Coffman)

1. **Mutual exclusion** — at least one resource is non-sharable
2. **Hold and wait** — a process holds resources while waiting for more
3. **No preemption** — resources cannot be forcibly taken
4. **Circular wait** — a cycle exists in the wait graph

Breaking any one condition prevents deadlock.

### 4.2 Prevention Strategies

#### Lock Ordering (Break Circular Wait)

Assign a total order to all locks. Always acquire locks in ascending order.

```
# BAD: Deadlock possible
spawn fn transfer(a: Account, b: Account, amount: Int) {
    a.lock()
    b.lock()        # if another fiber locks b first → deadlock
    a.balance -= amount
    b.balance += amount
    b.unlock()
    a.unlock()
}

# GOOD: Lock ordering
fn transfer(a: Account, b: Account, amount: Int) {
    let (first, second) = if a.id < b.id {
        (a, b)
    } else {
        (b, a)
    }
    first.lock()
    second.lock()
    a.balance -= amount
    b.balance += amount
    second.unlock()
    first.unlock()
}
```

#### TryLock Pattern (Break Hold-and-Wait)

Acquire locks optimistically. If any lock fails, release all and retry.

```
fn transfer(a: Account, b: Account, amount: Int) {
    loop {
        if a.try_lock() {
            if b.try_lock() {
                a.balance -= amount
                b.balance += amount
                b.unlock()
                a.unlock()
                return
            }
            a.unlock()
        }
        yield()    # yield to scheduler, retry later
    }
}
```

#### Deadlock Detection

Build a wait-for graph. When a cycle is detected, break it by aborting one transaction.

```
# Runtime-level detection (debug mode)
fn detect_deadlock() -> Option<DeadlockInfo> {
    # Build wait-for graph from mutex wait queues
    # Detect cycles using DFS
    # Report: "Fiber A waiting for lock held by Fiber B, which waits for lock held by A"
}
```

#### Lock-Free Data Structures (Eliminate Locks Entirely)

Use atomic operations instead of locks. immune to deadlock, priority inversion, and convoying.

```
# Lock-free stack (Treiber stack)
struct LockFreeStack<T> {
    head: AtomicPtr<Node<T>>
}

fn push(&self, value: T) {
    let new_node = Box::new(Node { value, next: null })
    loop {
        let old_head = self.head.load(Acquire)
        new_node.next = old_head
        if self.head.compare_exchange_weak(
            old_head, new_node, Release, Relaxed
        ).is_ok() {
            break
        }
    }
}
```

### 4.3 Astra-Specific Deadlock Prevention

Astra's fiber model has an advantage: **cooperative scheduling** means a fiber can only be preempted at yield points. This makes deadlocks more predictable and easier to detect.

**Fiber-aware strategies:**
1. **Structured concurrency** — child fibers inherit parent's cancellation scope
2. **Context cancellation** — propagate timeouts through channels
3. **TryLock with yield** — `try_lock()` + `yield()` pattern avoids blocking
4. **Debug-mode deadlock detection** — the runtime can track lock ownership per-fiber

```
# Context-based timeout prevents indefinite blocking
fn with_timeout<T>(dur: Duration, action: fn() -> T) -> Result<T, TimeoutError> {
    let timer = channel(Void)
    spawn fn() { sleep(dur); timer.send(()) }

    select {
        result = action() => Ok(result),
        _ = timer => Err(TimeoutError),
    }
}
```

---

## 5. Data Race Prevention

### 5.1 How ARC/ORC + Fibers Prevent Data Races

Astra's memory model combines several mechanisms:

#### Immutability by Default (`val`)

```
val x = 42                # immutable — safe to share between fibers
val names = ["a", "b"]    # deep immutable — no synchronization needed

spawn fn worker1() {
    println(x)            # read-only — always safe
}

spawn fn worker2() {
    println(x)            # read-only — always safe
}
```

**Key insight:** Immutable data requires no synchronization. This is the cheapest form of data race prevention. Astra enforces this through `val`.

#### Move Semantics for Mutable Data (`var`)

```
var data = [1, 2, 3]      # mutable

# To transfer to another fiber, must explicitly move
spawn fn worker() {
    # 'data' is now owned by this fiber
    data.push(4)
    # data is dropped here
}

# Original fiber can no longer access 'data'
# The compiler enforces this
```

#### Atomic Types for Shared Mutable Data

```
let counter = AtomicInt(0)

spawn fn worker1() {
    counter.fetch_add(1)   # atomic — no data race
}

spawn fn worker2() {
    counter.fetch_add(1)   # atomic — no data race
}
```

### 5.2 Send/Sync Traits (Rust-Style)

Astra should adopt a trait system similar to Rust's `Send` and `Sync`:

| Trait | Meaning | Example |
|:------|:--------|:--------|
| **Send** | Can be transferred between fibers | `Int`, `String`, `Array<T>`, `Arc<T>` |
| **Sync** | Can be shared between fibers (`&T` is Send) | `Int`, `String`, `Arc<T>`, `Mutex<T>` |
| **!Send** | Cannot be transferred | `FiberLocal<T>`, raw pointers |
| **!Sync** | Cannot be shared | `Cell<T>`, `RefCell<T>`, `Rc<T>` |

```
# Astra trait definitions (pseudo-code)
trait Send {}
trait Sync {}

# Automatic derivation: if all fields are Send, the struct is Send
struct Message {
    id: Int          # Send
    data: String     # Send
}
# Message is automatically Send

# Non-Send type
struct FiberLocal<T> {
    value: T
}
impl<T> !Send for FiberLocal<T> {}
# Cannot transfer FiberLocal between fibers

# Usage: the compiler enforces Send/Sync bounds
fn spawn_worker(data: impl Send) {
    spawn fn() {
        use(data)     # OK: data is Send
    }
}

fn share_ref(data: &impl Sync) {
    spawn fn() {
        println(data) # OK: &T is safe because T is Sync
    }
}
```

### 5.3 SC-DRF Memory Model

Astra uses **Sequentially Consistent for Data-Race-Free** programs (SC-DRF):

- If the program has no data races, it behaves as if all operations executed in a single sequential order.
- Data races are **undefined behavior** — the compiler/runtime can assume they never happen.
- This is the same model as C++11 and Rust.

**How this works in practice:**

```
# No data race: SC-DRF guarantees sequential consistency
val x = 0
val flag = AtomicBool(false)

spawn fn writer() {
    x = 42                            # plain write
    flag.store(true, Ordering.Release) # publish
}

spawn fn reader() {
    if flag.load(Ordering.Acquire) {   # synchronize
        assert(x == 42)               # guaranteed to see 42
    }
}
```

---

## 6. Channel Implementation for M:N Scheduling

### 6.1 Core Data Structure

```
struct Channel<T> {
    # Circular buffer for buffered channels
    buffer: RingBuffer<T>,

    # Waiting fibers
    send_waiters: DoublyLinkedList<Fiber>,
    recv_waiters: DoublyLinkedList<Fiber>,

    # State
    closed: AtomicBool,
    capacity: usize,

    # Lock (fiber-aware, NOT OS mutex)
    lock: FiberMutex,
}
```

### 6.2 Send Operation

```
fn send(self: *Channel<T>, value: T) -> Result<(), SendError<T>> {
    self.lock.lock()

    if self.closed {
        self.lock.unlock()
        return Err(SendError(value))
    }

    # Fast path 1: Direct handoff to waiting receiver
    if let Some(receiver_fiber) = self.recv_waiters.pop_front() {
        # Copy value directly to receiver's stack
        receiver_fiber.write_value(value)
        self.lock.unlock()
        receiver_fiber.unpark()    # put receiver on run queue
        return Ok(())
    }

    # Fast path 2: Buffer has space
    if self.buffer.len() < self.capacity {
        self.buffer.push(value)
        self.lock.unlock()
        return Ok(())
    }

    # Slow path: Buffer full, must park
    let sender_fiber = current_fiber()
    sender_fiber.write_value(value)
    self.send_waiters.push_back(sender_fiber)
    self.lock.unlock()
    sender_fiber.park()            # suspend fiber, yield to scheduler
    # ... fiber resumes here when buffer has space
    Ok(())
}
```

### 6.3 Receive Operation

```
fn recv(self: *Channel<T>) -> Result<T, RecvError> {
    self.lock.lock()

    # Fast path 1: Direct handoff from waiting sender
    if let Some(sender_fiber) = self.send_waiters.pop_front() {
        let value = sender_fiber.read_value()
        self.lock.unlock()
        sender_fiber.unpark()
        return Ok(value)
    }

    # Fast path 2: Buffer has data
    if self.buffer.len() > 0 {
        let value = self.buffer.pop()
        self.lock.unlock()
        return Ok(value)
    }

    # Check closed
    if self.closed {
        self.lock.unlock()
        return Err(RecvError)
    }

    # Slow path: Buffer empty, must park
    let recv_fiber = current_fiber()
    self.recv_waiters.push_back(recv_fiber)
    self.lock.unlock()
    recv_fiber.park()
    # ... fiber resumes here when data is available
    recv_fiber.read_value()
}
```

### 6.4 Performance Optimizations

| Optimization | Description | Impact |
|:-------------|:------------|:-------|
| **Direct handoff** | Bypass buffer when receiver is waiting | ~50% faster than buffered path |
| **Lock-free fast paths** | Check conditions without acquiring lock | Reduces contention |
| **Memory ordering** | Acquire/Release instead of SeqCst where safe | ~2-3x faster on ARM |
| **Buffered → unbuffered optimization** | When capacity=0, only use handoff path | Simpler code, same performance |
| **Element pooling** | Reuse `sudog`/waiter structs | Reduces allocation |

### 6.5 Benchmark Comparison (Go-style channels)

From the `rust-channel-benchmarks` project and Go runtime analysis:

| Operation | Go channel | Rust crossbeam | Rust kanal |
|:----------|:-----------|:---------------|:-----------|
| SPSC send/recv (buffered) | ~30ns | ~15ns | ~8ns |
| SPSC send/recv (unbuffered) | ~80ns | ~50ns | ~25ns |
| MPMC send/recv (buffered) | ~100ns | ~60ns | ~35ns |
| MPMC send/recv (unbuffered) | ~200ns | ~120ns | ~70ns |

**Key insight:** Unbuffered channels are slower because they require a handoff (context switch). Buffered channels are faster because the sender doesn't block if space is available.

---

## 7. Select/Multiplexing

### 7.1 Go-Style Select

`select` allows a fiber to wait on multiple channel operations simultaneously. Exactly one case is chosen when ready.

```
select {
    case msg = channel1:
        handle(msg)
    case msg = channel2:
        handle(msg)
    case <-timeout:
        println("timed out")
    default:
        # no channel ready, continue immediately
}
```

### 7.2 Implementation Strategy

1. **Register on all channels** — add the current fiber as a waiter on each channel
2. **Park the fiber** — suspend until one channel is ready
3. **Wake on first ready** — when any channel has data/is ready, wake the fiber
4. **Cancel other registrations** — remove the fiber from all other channel wait queues
5. **Execute the chosen case** — run the handler for the ready channel

```
fn select(cases: Array<SelectCase>) -> usize {
    let fiber = current_fiber()

    # Register on all channels
    for (i, case) in cases.iter().enumerate() {
        match case {
            Recv(ch) => ch.register_recv_waiter(fiber),
            Send(ch, _) => ch.register_send_waiter(fiber),
        }
    }

    # Park until one is ready
    fiber.park()

    # The first channel to become ready will wake us
    # and set the selected index
    let chosen = fiber.get_select_result()

    # Cancel other registrations
    for (i, case) in cases.iter().enumerate() {
        if i != chosen {
            match case {
                Recv(ch) => ch.remove_recv_waiter(fiber),
                Send(ch, _) => ch.remove_send_waiter(fiber),
            }
        }
    }

    return chosen
}
```

### 7.3 Fairness

Go's select chooses randomly among ready cases to prevent starvation. Astra should do the same:

```
# If channel1 and channel2 are both ready
select {
    case msg = channel1:    # 50% chance
        handle(msg)
    case msg = channel2:    # 50% chance
        handle(msg)
}
```

### 7.4 Select with Timeout

```
select {
    case data = work_ch:
        process(data)
    case _ = timer_channel(5.seconds):
        println("timeout")
}
```

### 7.5 Select vs Go's Select Differences

| Feature | Go | Astra Recommendation |
|:--------|:---|:---------------------|
| Random case selection | Yes | Yes (prevent starvation) |
| Default case (non-blocking) | Yes | Yes |
| Timeout via time.After | Yes | Yes, via timer_channel |
| Priority (weighted selection) | No | Consider adding |
| Closed channel detection | Yes (zero value + ok) | Yes, via Result type |

---

## 8. Fiber Synchronization Primitives

### 8.1 WaitGroup

A counting semaphore for waiting on multiple fibers to complete.

```
let wg = WaitGroup()

for i in 0..10 {
    wg.add(1)
    spawn fn() {
        defer { wg.done() }
        process(i)
    }
}

wg.wait()   # blocks until counter reaches 0
```

**Internal implementation:**

```
struct WaitGroup {
    counter: AtomicInt,
    waiter_count: AtomicInt,
    waiters: Condvar,
}

fn add(self: *WaitGroup, delta: Int) {
    let old = self.counter.fetch_add(delta, AcqRel)
    if old + delta < 0 {
        panic("WaitGroup counter went negative")
    }
}

fn done(self: *WaitGroup) {
    self.add(-1)
}

fn wait(self: *WaitGroup) {
    if self.counter.load(Acquire) == 0 {
        return    # fast path: already done
    }
    self.waiter_count.fetch_add(1, AcqRel)
    # Park until counter reaches 0
    while self.counter.load(Acquire) > 0 {
        self.waiters.wait()    # suspend fiber
    }
    self.waiter_count.fetch_add(-1, AcqRel)
}
```

### 8.2 Semaphore

Controls access to a resource with a limited number of permits.

```
let sem = Semaphore(10)    # 10 concurrent permits

for i in 0..100 {
    spawn fn() {
        sem.acquire()       # blocks if 10 permits taken
        defer { sem.release() }
        limited_resource_access(i)
    }
}
```

**Fiber-aware semaphore:**

```
struct Semaphore {
    permits: AtomicInt,
    waiters: DoublyLinkedList<Fiber>,
    lock: FiberMutex,
}

fn acquire(self: *Semaphore) {
    self.lock.lock()
    if self.permits.load(Relaxed) > 0 {
        self.permits.fetch_sub(1, Relaxed)
        self.lock.unlock()
    } else {
        self.waiters.push_back(current_fiber())
        self.lock.unlock()
        current_fiber().suspend()    # park fiber
    }
}

fn release(self: *Semaphore) {
    self.lock.lock()
    if let Some(fiber) = self.waiters.pop_front() {
        self.lock.unlock()
        fiber.unpark()               # wake a waiting fiber
    } else {
        self.permits.fetch_add(1, Relaxed)
        self.lock.unlock()
    }
}
```

### 8.3 Barrier

A synchronization point where N fibers must all arrive before any can proceed.

```
let barrier = Barrier(4)    # 4 fibers must arrive

spawn fn() {
    compute_phase1()
    barrier.wait()          # wait for all 4 fibers
    compute_phase2()        # all fibers proceed together
}
```

**Implementation:**

```
struct Barrier {
    count: AtomicInt,
    generation: AtomicUsize,
    total: usize,
    lock: FiberMutex,
    waiters: DoublyLinkedList<Fiber>,
}

fn wait(self: *Barrier) -> Bool {
    let gen = self.generation.load(Acquire)
    let old = self.count.fetch_add(1, AcqRel) + 1

    if old == self.total {
        # Last fiber to arrive — wake everyone
        self.count.store(0, Release)
        self.generation.fetch_add(1, Release)
        for fiber in self.waiters.drain() {
            fiber.unpark()
        }
        return true    # last fiber returns true
    } else {
        # Park until all fibers arrive
        self.waiters.push_back(current_fiber())
        current_fiber().suspend()
        # Wait for generation to change
        while self.generation.load(Acquire) == gen {
            yield()
        }
        return false
    }
}
```

**Warning:** Barriers are tricky with fiber lifespans. If a fiber dies before reaching the barrier, all other fibers are stuck forever. Use with structured concurrency (cancellation scopes).

### 8.4 Once

Executes a function exactly once, even across multiple fibers.

```
static INIT: Once = Once::new()

fn initialize() {
    INIT.call_once(|| {
        # expensive initialization
        global_resource = expensive_setup()
    })
}
```

**Implementation:**

```
struct Once {
    state: AtomicInt,    # 0 = init, 1 = running, 2 = complete
    fibers: Condvar,     # fibers waiting for completion
}

fn call_once(self: *Once, f: fn()) {
    if self.state.load(Acquire) == 2 {
        return    # fast path: already initialized
    }

    let old = self.state.compare_exchange(0, 1, AcqRel, Acquire)
    match old {
        Ok(_) => {
            f()
            self.state.store(2, Release)
            self.fibers.notify_all()    # wake all waiters
        }
        Err(_) => {
            # Another fiber is initializing, wait
            while self.state.load(Acquire) != 2 {
                self.fibers.wait()    # suspend fiber
            }
        }
    }
}
```

### 8.5 Condvar (Condition Variable)

Used with a Mutex for complex synchronization patterns.

```
let m = Mutex()
let cv = Condvar()
var ready = false

spawn fn() {
    m.synchronize(|| {
        while !ready {
            cv.wait(&m)    # atomically release mutex and suspend
        }
        # proceed when ready == true
    })
}

# In another fiber:
m.synchronize(|| {
    ready = true
    cv.notify_one()    # wake one waiting fiber
})
```

### 8.6 Comparison Table

| Primitive | Purpose | Complexity | Use Case |
|:----------|:--------|:-----------|:---------|
| **WaitGroup** | Wait for N completions | Simple | Parallel fork-join |
| **Semaphore** | Limit concurrency | Simple | Connection pools, rate limiting |
| **Barrier** | Synchronize N fibers at a point | Medium | Phased computation |
| **Once** | One-time initialization | Simple | Lazy singletons |
| **Condvar** | Complex conditions | Complex | When atomic flag isn't enough |
| **Channel** | Communication + sync | Simple | Ownership transfer |

---

## 9. Shared State vs Channels

### 9.1 When to Use Channels

| Pattern | Why Channels |
|:--------|:-------------|
| **Ownership transfer** | "I'm done with this data, you use it now" |
| **Pipeline** | Data flows through stages naturally |
| **Fan-out/fan-in** | Distribute work, collect results |
| **Request/response** | Client-server within the same process |
| **Cancellation** | Signal shutdown via close/heartbeat |

```
# Channel: producer/consumer
let data_ch = channel(Data)

spawn fn producer() {
    for item in source {
        data_ch.send(item)    # transfer ownership
    }
}

spawn fn consumer() {
    for item in data_ch {
        process(item)         # item is now owned by consumer
    }
}
```

### 9.2 When to Use Shared State (Mutex/Atomic)

| Pattern | Why Shared State |
|:--------|:-----------------|
| **Read-heavy cache** | RwLock allows concurrent reads |
| **Simple counters** | Atomic is simpler than channel per increment |
| **Complex data structures** | Graphs, trees where ownership is ambiguous |
| **Configuration** | Read once, write rarely |
| **Performance-critical** | Channels have ~100ns overhead, mutex ~20-50ns |

```
# Shared state: concurrent cache
let cache = RwLock(HashMap())

spawn fn lookup(key: String) {
    cache.read_lock()
    let value = cache.get(&key)
    cache.read_unlock()
    // ... use value
}

spawn fn insert(key: String, value: Data) {
    cache.write_lock()
    cache.insert(key, value)
    cache.write_unlock()
}
```

### 9.3 Trade-offs

| Aspect | Channels | Shared State |
|:-------|:---------|:-------------|
| **Simplicity** | Easier to reason about | Harder (locking discipline) |
| **Performance** | Higher overhead (~100ns) | Lower overhead (~20-50ns) |
| **Deadlock risk** | Low (if structured) | Higher (multiple locks) |
| **Debugging** | Easier (message flow) | Harder (lock contention) |
| **Scalability** | Good (lock-free possible) | Depends on granularity |
| **Composition** | Good (select, pipeline) | Harder (lock ordering) |

### 9.4 Hybrid Approach (Recommended for Astra)

Use **channels for communication** and **shared state for read-heavy data**:

```
# Communication via channels
let request_ch = channel(Request)
let response_ch = channel(Response)

# Shared state for read-heavy data
let config = RwLock(AppConfig::load())

spawn fn worker() {
    for req in request_ch {
        let cfg = config.read_lock()
        let result = process(req, cfg)
        config.read_unlock()
        response_ch.send(result)
    }
}
```

---

## 10. Performance Characteristics

### 10.1 Primitive Performance Comparison

Approximate costs on modern x86-64 (AMD Zen 4 / Intel Raptor Lake):

| Operation | Uncontended | Contended (8 fibers) | Notes |
|:----------|:------------|:---------------------|:------|
| **Fiber spawn** | ~200ns | ~200ns | Allocation + scheduling |
| **Fiber context switch** | ~30-50ns | ~30-50ns | Same OS thread only |
| **OS thread context switch** | ~1-5μs | N/A | Save/restore full register set |
| **Mutex lock/unlock** | ~20-30ns | ~200-500ns | With futex fast path |
| **RwLock read** | ~10-15ns | ~50-100ns | Read-shared |
| **RwLock write** | ~20-30ns | ~300-800ns | Write-exclusive |
| **Spinlock** | ~5-10ns | ~1-10μs | Busy-wait degrades |
| **Channel send/recv (buffered)** | ~30-50ns | ~100-200ns | Ring buffer path |
| **Channel send/recv (unbuffered)** | ~80-100ns | ~200-400ns | Handoff path |
| **Atomic load/store (Relaxed)** | ~1-2ns | ~5-10ns | Same cache line |
| **Atomic fetch_add (SeqCst)** | ~5-10ns | ~20-50ns | LOCK prefix |
| **WaitGroup** | ~30-50ns | ~100-200ns | Atomic + futex |
| **Semaphore** | ~30-50ns | ~100-300ns | Similar to mutex |
| **Once** | ~5ns (after init) | ~5ns | Fast path is atomic load |

### 10.2 Go vs Rust vs Zig Benchmarks

From published benchmarks and the `rust-channel-benchmarks` project:

**HTTP Server (req/sec at 100k concurrent connections):**

| Language | Throughput | P99 Latency | Memory |
|:---------|:-----------|:------------|:-------|
| Go (net/http) | ~120k req/s | ~9.8ms | ~210MB |
| Rust (Tokio/Axum) | ~142k req/s | ~14.2ms | ~128MB |
| Zig (io_uring) | ~150k req/s | ~8ms | ~95MB |

**Channel benchmarks (SPSC, buffered, ops/sec):**

| Library | Ops/sec |
|:--------|:--------|
| Go channel | ~30M |
| Rust crossbeam | ~60M |
| Rust kanal | ~90M |

**Key observations:**
- Go's goroutine scheduler has higher p99 latency than Tokio for I/O-heavy workloads (31% difference)
- Rust has lower memory usage (39% less) but higher binary overhead
- Go's GC adds ~2% overhead but provides simpler memory management
- Zig is fastest for raw I/O but requires manual concurrency management

### 10.3 Astra Performance Targets

Based on M:N fiber scheduling with ARC/ORC:

| Primitive | Target Cost | Rationale |
|:----------|:------------|:----------|
| Fiber spawn | ~150ns | Stack allocation + scheduler enqueue |
| Fiber context switch | ~30-50ns | Same as Go goroutines |
| Fiber-aware mutex | ~25-40ns | Fiber parking, not OS blocking |
| Channel (buffered) | ~40-60ns | Ring buffer, Acquire/Release ordering |
| Channel (unbuffered) | ~80-100ns | Direct handoff optimization |
| Atomic (Relaxed) | ~1-2ns | Direct hardware instructions |
| WaitGroup | ~30-50ns | Atomic counter + futex |
| ARC increment/decrement | ~5-10ns | Atomic refcount (compare_exchange) |

### 10.4 Optimization Strategies

1. **Fast paths for uncontended cases** — check lock state before acquiring
2. **Work stealing** — balance fiber load across OS threads
3. **Batch operations** — amortize synchronization cost across multiple operations
4. **Memory ordering minimization** — use Relaxed where possible, SeqCst only when needed
5. **Per-CPU local queues** — reduce contention on shared scheduler queues
6. **Direct handoff** — bypass buffer for unbuffered channels when receiver is waiting

---

## 11. Recommended Syntax Summary for Astra

### Channels

```
let ch = channel(Int)              # unbuffered
let ch = channel(Int, 100)         # buffered
ch.send(value)                     # send (blocks if full/empty)
let val = ch.recv()                # receive (Result<T, RecvError>)
ch.close()                         # close channel
```

### Mutex

```
let m = Mutex()
m.lock() / m.unlock()
m.synchronize(|| { ... })          # RAII-style
m.try_lock() -> Bool
```

### RwLock

```
let rw = RwLock(data)
rw.read_lock() / rw.read_unlock()
rw.write_lock() / rw.write_unlock()
```

### Atomics

```
let a = AtomicInt(0)
a.load(Ordering.Acquire)
a.store(42, Ordering.Release)
a.fetch_add(1, Ordering.AcqRel)
a.compare_exchange(expected, desired, Ordering.AcqRel, Ordering.Relaxed)
```

### Synchronization

```
let wg = WaitGroup()
wg.add(1); wg.done(); wg.wait()

let sem = Semaphore(10)
sem.acquire(); sem.release()

let barrier = Barrier(4)
barrier.wait() -> Bool

let once = Once()
once.call_once(|| { ... })
```

### Select

```
select {
    case msg = ch1 => handle(msg),
    case msg = ch2 => handle(msg),
    case _ = timer(5.seconds) => timeout(),
    default => no_data(),
}
```

### Spawn

```
spawn fn worker() { ... }
spawn fn worker_with_args(a: Int, b: String) { ... }
```

---

## 12. Implementation Priority

For the Astra runtime, implement in this order:

1. **Fiber-aware Mutex** — foundational for all other primitives
2. **Atomic types** — needed by Mutex, WaitGroup, channels
3. **Channels** — primary communication primitive
4. **Select** — multiplexing over channels
5. **WaitGroup** — simple fork-join coordination
6. **Semaphore** — concurrency limiting
7. **RwLock** — read-heavy optimization
8. **Once** — one-time initialization
9. **Barrier** — phased computation
10. **Condvar** — complex conditions (may be unnecessary with channels)

---

## References

- Go runtime `src/runtime/chan.go` — hchan struct, direct handoff, gopark/goready
- Go scheduler GMP model — `src/runtime/proc.go`
- Rust `std::sync::atomic::Ordering` — memory ordering documentation
- Rust `Send`/`Sync` traits — `std::marker`
- C++ `memory_order` — `cppreference.com`
- Boost.Fiber — fiber-aware synchronization primitives
- Ruby Fiber Scheduler — per-fiber Mutex design
- Crystal Mutex — fiber-aware implementation
- Kotlin coroutines — dispatch scheduling for task-aware mutex
- Rust crossbeam-channel benchmarks — channel performance data
- Stanford CS149 — lock-free data structures, fine-grained locking
- CMU 15-418 — lock-free programming, CAS patterns
