# CPython Internal Architecture: Comprehensive Technical Report

*Research for the Astra Language — Understanding HOW Python Works Internally*

---

## Table of Contents

1. [CPython Interpreter Architecture](#1-cpython-interpreter-architecture)
2. [Object System](#2-object-system)
3. [Memory Management](#3-memory-management)
4. [The GIL Deep Dive](#4-the-gil-deep-dive)
5. [Import System](#5-import-system)
6. [C Extension API](#6-c-extension-api)
7. [Performance Characteristics](#7-performance-characteristics)
8. [What Makes Python's Approach Unique](#8-what-makes-pythons-approach-unique)
9. [Lessons for Astra](#9-lessons-for-astra)

---

## 1. CPython Interpreter Architecture

### 1.1 The Compilation Pipeline

CPython's compilation pipeline has **5 distinct stages**, all driven from a single entry point: `_PyAST_Compile()` in `Python/compile.c`.

```
Source Code
    │
    ▼
[1] Tokenizer (Parser/lexer/lexer.c, Parser/tokenizer/)
    │  Converts raw text → stream of tokens
    ▼
[2] PEG Parser (Parser/parser.c, Grammar/python.gram)
    │  Tokens → Abstract Syntax Tree (mod_ty)
    ▼
[3] AST → Pseudo-Instruction Sequence (Python/codegen.c)
    │  Walks AST, emits intermediate pseudo-instructions
    ▼
[4] Control Flow Graph + Optimization (Python/flowgraph.c)
    │  Builds CFG, applies peephole optimizations
    ▼
[5] Assembly (Python/assemble.c)
    │  Linearizes CFG → PyCodeObject (bytecode)
    ▼
Bytecode Ready for Execution
```

**Key source files:**
- `Python/compile.c` — The compiler driver, orchestrates all stages
- `Python/codegen.c` — AST-to-pseudo-instruction walk
- `Python/flowgraph.c` — CFG construction, optimization, dead-code elimination, jump threading
- `Python/assemble.c` — Final bytecode emission, exception table, location table
- `Python/symtable.c` — Two-pass symbol table analysis
- `Python/ast_preprocess.c` — Constant folding, PEP 649 annotation rewrites

**Memory management during compilation:** All compilation uses a `PyArena` — a bump allocator that lets the compiler skip per-node reference counting. Everything is freed in a single sweep when compilation completes.

### 1.2 The PEG Parser (Since Python 3.9)

Python replaced its LL(1) parser with a **PEG (Parsing Expression Grammar)** parser (PEP 617) in Python 3.9. This was a fundamental architectural change.

**Why PEG over LL(1):**
- PEG parsers support **unlimited lookahead** — LL(1) is restricted to 1 token of lookahead
- PEG eliminates the need for grammar "hacks" to work around LL(1) limitations
- PEG allows **direct AST generation** from grammar rules via actions, eliminating the intermediate concrete syntax tree (CST)
- PEG's memoization (packrat parsing) caches successful rule matches, avoiding exponential backtracking

**Grammar definition:** `Grammar/python.gram` defines Python's syntax. The parser generator (pegen) reads this grammar and generates `Parser/parser.c` — a hand-written recursive descent parser where each grammar rule becomes a C function named `xx_rule()`.

**Grammar actions:** Each rule has an associated action that constructs AST nodes directly:
```
file[mod_ty]: a=[statements] ENDMARKER { _PyPegen_make_module(p, a) }
```

The `EXTRA` macro expands to `(start_lineno, start_col_offset, end_lineno, end_col_offset, p->arena)` — location information automatically injected for every AST node.

**Parser entry points:**
- `_PyParser_ASTFromString()` — parse from a string
- `_PyParser_ASTFromFile()` — parse from a file
- Both call `_PyPegen_parse()` which dispatches to the appropriate start rule (`file_rule`, `interactive_rule`, `eval_rule`, or `func_type_rule`)

### 1.3 AST Node Types

The AST is defined using **ASDL (Abstract Syntax Definition Language)** in `Parser/Python.asdl`. Each node is a C struct with a `kind` enum and a union of variant fields.

**Module-level AST nodes (`mod_ty`):**
- `Module` — a full Python file
- `Interactive` — interactive input (REPL)
- `Expression` — a single expression
- `FunctionType` — a function type annotation

**Statement AST nodes (`stmt_ty`) — 25 variants:**
`FunctionDef`, `AsyncFunctionDef`, `ClassDef`, `Return`, `Delete`, `Assign`, `AugAssign`, `AnnAssign`, `For`, `AsyncFor`, `While`, `If`, `With`, `AsyncWith`, `Match`, `Raise`, `Try`, `TryStar`, `Assert`, `Import`, `ImportFrom`, `Global`, `Nonlocal`, `Expr`, `Pass`, `Break`, `Continue`, `TypeAlias`

**Expression AST nodes (`expr_ty`) — 25 variants:**
`BoolOp`, `NamedExpr`, `BinOp`, `UnaryOp`, `Lambda`, `IfExp`, `Dict`, `Set`, `ListComp`, `SetComp`, `DictComp`, `GeneratorExp`, `Await`, `Yield`, `YieldFrom`, `Compare`, `Call`, `FormattedValue`, `JoinedStr`, `Constant`, `Attribute`, `Subscript`, `Starred`, `Name`, `List`, `Tuple`

**C struct layout (generated from ASDL):**
```c
struct _expr {
    enum _expr_kind kind;
    union {
        struct { expr_ty left; operator_ty op; expr_ty right; } BinOp;
        struct { expr_ty func; asdl_seq *args; asdl_seq *keywords; } Call;
        struct { identifier id; expr_context_ty ctx; } Name;
        // ... 22 more variants
    } v;
    int lineno;
    int col_offset;
};
```

Every node carries `lineno`, `col_offset`, `end_lineno`, `end_col_offset` for precise error reporting and debugging.

### 1.4 Bytecode Format

**Instruction format:** Each instruction is a 16-bit code unit (`_Py_CODEUNIT`):
- First byte: **opcode** (0-255)
- Second byte: **oparg** (0-255)
- Stored in big-endian order regardless of platform (for disk portability)

**EXTENDED_ARG prefix:** For opargs > 255, up to 3 `EXTENDED_ARG` prefixes can precede an instruction, shifting and OR-ing to build a 32-bit oparg:
```
EXTENDED_ARG 1
EXTENDED_ARG 0
LOAD_CONST 2    → oparg = 65538 (0x1_00_02)
```

**Code object (`PyCodeObject`) fields:**
- `co_code` — the bytecode bytes
- `co_consts` — tuple of constants referenced by index
- `co_names` — tuple of names referenced by index
- `co_varnames` — local variable names
- `co_stacksize` — maximum evaluation stack depth
- `co_nlocals` — number of local variables
- `co_flags` — flags (generator, coroutine, etc.)
- `co_exceptiontable` — exception handler metadata
- `co_linetable` — source location mapping

**Opcodes are defined in** `Include/opcode_ids.h` and their implementations in `Python/bytecodes.c` using a custom DSL.

### 1.5 The Evaluation Loop (ceval.c)

The evaluation loop is implemented in `_PyEval_EvalFrameDefault()` in `Python/ceval.c`. It's the single most important function in CPython.

**Core loop structure:**
```c
_Py_CODEUNIT *first_instr = code->co_code_adaptive;
_Py_CODEUNIT *next_instr = first_instr;
while (1) {
    _Py_CODEUNIT word = *next_instr++;
    unsigned char opcode = _Py_OPCODE(word);
    unsigned int oparg = _Py_OPARG(word);
    switch (opcode) {
        // ~150+ cases, one per opcode
    }
}
```

**Three dispatch mechanisms:**

1. **Traditional switch-case** — Supported by all compilers. A single indirect branch shared by all opcodes → poor CPU branch prediction.

2. **Computed gotos** (default on GCC/Clang) — Uses `&&label` (Labels as Values extension) to create a jump table. Each opcode has its own dispatch address → separate branch predictions per opcode → **15-20% faster** than switch.

3. **Tail-calling interpreter** (3.14+) — Uses `__attribute__((musttail))` and `preserve_none` calling convention. Each opcode is a small C function that tail-calls the next → compiler handles dispatch optimization.

**The evaluation stack:**
CPython is a **stack machine**. Instructions push/pop `PyObject *` pointers:
- `PUSH(x)` → `*stack_pointer++ = x`
- `POP()` → `x = *--stack_pointer`
- Stack depth is pre-calculated and pre-allocated in the frame

**Instruction specialization (since 3.11):**
The specializing adaptive interpreter (PEP 659) rewrites generic opcodes with type-specialized versions at runtime:
```
LOAD_ATTR → LOAD_ATTR_INSTANCE_VALUE  (when self.__dict__ lookup applies)
BINARY_OP → BINARY_OP_ADD_INT  (when both operands are compact ints)
```
Each specialized instruction has a family of variants with inline caches. Specialization counters track stability; deoptimization occurs when inputs change.

### 1.6 Frame Objects and Function Calls

**Since 3.11, frames are no longer fully-fledged objects.** The leaner `_PyInterpreterFrame` structure is used instead:

```c
typedef struct _PyInterpreterFrame {
    PyObject *f_func;           // The function object
    PyObject *f_globals;        // Global namespace
    PyObject *f_builtins;       // Builtins namespace
    PyObject *flocals;          // Local variables (may be NULL)
    PyObject *f_trace;          // Tracing function
    _Py_CODEUNIT *prev_instr;   // Previous instruction pointer
    int yield_offset;           // For generators
    int return_offset;          // Where to resume after return
    char owner;                 // Thread owner
    _Py_CODEUNIT first_instr;   // First instruction
    PyObject *stack[1];         // Variable-size: locals + eval stack
} _PyInterpreterFrame;
```

**Frame allocation:** Most frames are allocated contiguously in a **per-thread stack** (`_PyThreadState_PushFrame`). This improves memory locality and reduces malloc overhead. If the current `datastack_chunk` has enough space, `_PyFrame_PushUnchecked` can be used for lightweight allocation.

**Function call flow (since 3.11):**
1. `CALL` instruction special-cases function objects to "inline" the call
2. A new `_PyInterpreterFrame` is pushed onto the call stack
3. The interpreter "jumps" to the start of the callee's bytecode
4. When `RETURN_VALUE` is reached, the frame is popped
5. If `frame->is_entry` is set, the interpreter returns to the C caller

**Generators and async functions:**
- First call executes `RETURN_GENERATOR` opcode, which creates the generator object
- The generator's `_PyInterpreterFrame` is initialized with a copy of the current frame
- On resume, the interpreter pushes the generator's frame back onto the frame stack
- `YIELD_VALUE`/`SEND` handle the suspension/resumption

---

## 2. Object System

### 2.1 PyObject Struct Layout

Every Python object starts with a common header:

```c
// Standard build
struct _object {
    Py_ssize_t ob_refcnt;      // Reference count
    PyTypeObject *ob_type;     // Pointer to type object
};

// Free-threaded build (PEP 703)
struct _object {
    uintptr_t ob_tid;              // Owning thread ID
    uint16_t ob_flags;             // Flags
    PyMutex ob_mutex;              // Per-object lock
    uint8_t ob_gc_bits;            // GC state
    uint32_t ob_ref_local;         // Per-thread refcount (fast path)
    Py_ssize_t ob_ref_shared;      // Cross-thread refcount + state
    PyTypeObject *ob_type;         // Type pointer
};
```

**Variable-length objects** add `ob_size` via `PyVarObject`:
```c
typedef struct {
    PyObject ob_base;
    Py_ssize_t ob_size;  // Number of items
} PyVarObject;
```

**Object layout evolution (3.11→3.13):**
- **3.11:** Pre-header includes `dict` and `values` pointers for attribute storage
- **3.12:** Pre-header simplified: `weakreflist` + `dict_or_values` (tagged pointer). GC headers moved before `ob_refcnt`.
- **3.13:** Values array **embedded directly** in the object. The `dict_or_values` pointer becomes a tagged pointer: low bit 1 = values array inline, low bit 0 = physical dict pointer.

### 2.2 Type Objects (PyTypeObject)

The type object is a massive struct (~400 bytes) that defines everything about a type:

```c
struct _typeobject {
    PyObject_VAR_HEAD
    const char *tp_name;             // "<module>.<name>"
    Py_ssize_t tp_basicsize;         // Size of instances
    Py_ssize_t tp_itemsize;          // Size of each item (for variable-size)

    // Standard operations
    destructor tp_dealloc;
    reprfunc tp_repr, tp_str;
    hashfunc tp_hash;
    ternaryfunc tp_call;

    // Method suites
    PyNumberMethods *tp_as_number;
    PySequenceMethods *tp_as_sequence;
    PyMappingMethods *tp_as_mapping;

    // Attribute access
    getattrofunc tp_getattro;
    setattrofunc tp_setattro;

    // Descriptor protocol
    descrgetfunc tp_descr_get;
    descrsetfunc tp_descr_set;

    // Creation/lifecycle
    initproc tp_init;
    allocfunc tp_alloc;
    newfunc tp_new;
    freefunc tp_free;

    // Type hierarchy
    PyTypeObject *tp_base;
    PyObject *tp_dict;
    PyObject *tp_bases;
    PyObject *tp_mro;              // Method Resolution Order

    // GC support
    traverseproc tp_traverse;
    inquiry tp_clear;

    // Iterators
    getiterfunc tp_iter;
    iternextfunc tp_iternext;

    // Subclass support
    void *tp_subclasses;            // Weakref or index
    PyObject *tp_weaklist;

    // Vectorcall (fast call protocol)
    vectorcallfunc tp_vectorcall;

    // Version tag for specialization
    unsigned int tp_version_tag;
};
```

**Heap types vs static types:**
- **Static types:** Statically allocated `PyTypeObject` (e.g., `PyLong_Type`). Reference count of instances does not count toward the type.
- **Heap types:** Dynamically allocated via `type.__new__()` or class statement. Instances contribute to type's reference count. Support `__module__`, `__qualname__`.

### 2.3 Attribute Lookup

**The attribute lookup chain (`_PyObject_LookupAttr`):**

1. **Check `tp_getattro`** — The type's attribute access function (usually `PyObject_GenericGetAttr`)
2. **MRO search** — Walk the Method Resolution Order looking for a descriptor on the type
3. **Data descriptor found?** — If the descriptor has `tp_descr_set`, call `tp_descr_get` (e.g., `property`, `method`)
4. **Check instance `__dict__`** — Look up the attribute in the instance dictionary
5. **Non-data descriptor found?** — If found on the type and has `tp_descr_get`, call it (e.g., functions, classmethods)
6. **Fall back to type** — Check the type's `tp_dict` directly
7. **Raise `AttributeError`**

**`__slots__` optimization:**
- Classes with `__slots__` skip instance `__dict__` creation
- Each slot is a `PyMemberDef` — a fixed offset into the instance struct
- Attribute access becomes a direct memory offset calculation: `*(PyObject**)((char*)self + offset)`
- **Saves ~40% memory** per instance (no dict overhead)

### 2.4 The Descriptor Protocol

Three methods form the descriptor protocol:

```python
class Descriptor:
    def __get__(self, obj, objtype=None):
        """Called when attribute is accessed via instance.attr or Class.attr"""
    def __set__(self, obj, value):
        """Called when attribute is set via instance.attr = value"""
    def __delete__(self, obj):
        """Called when attribute is deleted via del instance.attr"""
```

**Types of descriptors:**
- **Data descriptors:** Implement both `__get__` AND `__set__` (or `__delete__`). Take priority over instance dict. Examples: `property`, `__slots__`, `super`.
- **Non-data descriptors:** Implement only `__get__`. Lower priority than instance dict. Examples: functions, `classmethod`, `staticmethod`, `functools.cached_property`.

**How methods work:**
1. `instance.method` triggers `tp_getattro`
2. MRO finds `function` type on the class
3. `function` is a non-data descriptor (has `__get__` but not `__set__`)
4. `function.__get__(instance, type)` returns a **bound method** object
5. The bound method captures `self` and the original function
6. Calling the bound method invokes the function with `self` as first argument

**How properties work:**
1. `property` is a data descriptor (has both `__get__` and `__set__`)
2. When accessed, `property.__get__` calls the getter function
3. When set, `property.__set__` calls the setter function
4. Instance dict is bypassed because data descriptors take priority

### 2.5 Reference Counting

**Py_INCREF / Py_DECREF:**
```c
static inline void Py_INCREF(PyObject *op) {
    op->ob_refcnt++;
}

static inline void Py_DECREF(PyObject *op) {
    if (--op->ob_refcnt == 0) {
        _Py_Dealloc(op);  // Calls type's tp_dealloc
    }
}
```

**Free-threaded build — Biased Reference Counting (PEP 703):**
```c
// Fast path: object owned by current thread
if (_Py_IsOwnedByCurrentThread(op)) {
    op->ob_ref_local++;  // Non-atomic, same cost as GIL version
} else {
    // Slow path: atomic operation on shared count
    _Py_atomic_add_ssize(&op->ob_ref_shared, (1 << _Py_REF_SHARED_SHIFT));
}
```

This optimization exploits the fact that most objects are not actually shared between threads. The owning thread uses a non-atomic local count; other threads use an atomic shared count with a "merge" flag.

**Immortal objects (3.12+):** Certain objects (small integers -5 to 256, `None`, `True`, `False`, empty tuples, empty strings, `Ellipsis`) have their reference count set to a sentinel value (`_Py_IMMORTAL_INITIAL_REFCNT`) that never reaches zero. This eliminates refcount operations for these objects.

---

## 3. Memory Management

### 3.1 The Three-Layer Architecture

CPython's memory system has three layers:

```
Layer 3: PyObject_Malloc / PyObject_Free (Object allocator)
    │     Handles objects ≤ 512 bytes via pymalloc
    ▼
Layer 2: PyMem_Malloc / PyMem_Free (General allocator)
    │     Redirectable via PyMem_SetAllocator()
    ▼
Layer 1: PyMem_RawMalloc / PyMem_RawFree (Raw allocator)
    │     Direct malloc/free wrapper, GIL-free safe
    ▼
    OS: malloc / mmap / VirtualAlloc
```

### 3.2 PyMalloc: Arenas, Pools, and Blocks

PyMalloc is optimized for small objects (≤ 512 bytes) with short lifetimes.

**Three-tier hierarchy:**

| Tier | Size | Description |
|------|------|-------------|
| **Arena** | 256 KiB (32-bit) / 1 MiB (64-bit) | Obtained from OS via `mmap()` |
| **Pool** | 4 KiB (one page) | One size class per pool |
| **Block** | 8-512 bytes | Fixed-size, served from pool |

**Size classes:** 64 classes, spaced 8 bytes apart (8, 16, 24, ..., 512). A `szidx` (0-63) indexes into the `usedpools` array.

**Allocation flow (`pymalloc_alloc`):**
1. Compute `szidx` from requested size
2. Look up `usedpools[szidx + szidx]` — the pool list for that size class
3. Pop the first pool from the doubly-linked list
4. Return `pool->freeblock` (a singly-linked list of free blocks)
5. If `freeblock` is exhausted, carve from `pool->nextoffset`
6. If pool is full, unlinked from `usedpools`; take a fresh pool from the arena
7. If arena is exhausted, allocate a new arena from the OS

**Deallocation (`pymalloc_free`):**
1. Return block to pool's `freeblock` list (prepend)
2. If pool was full and now has free blocks, re-link into `usedpools`
3. If arena becomes completely empty, return to `usable_arenas` list (sorted by free pool count)
4. Empty arenas can eventually be returned to the OS

**Arenas are managed via two linked lists:**
- `unused_arena_objects` — Arenas not associated with any memory
- `usable_arenas` — Arenas with at least one free pool, sorted by free pool count (most-used first, to let nearly-empty arenas be freed)

**mimalloc (3.13+, free-threaded builds):**
The free-threaded build replaces pymalloc with mimalloc (from Microsoft). mimalloc is natively thread-safe, uses per-thread heaps, and provides better fragmentation characteristics. It also allows the GC to enumerate live objects without walking CPython's arena list.

### 3.3 Freelists

CPython maintains freelists for frequently allocated/deallocated objects to avoid repeated malloc/free:

| Object Type | Freelist Behavior |
|-------------|-------------------|
| `float` | Up to 100 objects |
| `int` (small) | Static cache for -5 to 256 |
| `tuple` | Up to 200 tuples of ≤ 20 items |
| `list` | Up to 80 empty lists |
| `dict` | Up to 80 empty dicts |
| `frame` | Per-thread frame freelist |
| `slice` | Up to 100 slices |
| `generator` | Up to 64 generators |

In free-threaded builds, freelists are moved to **per-thread state** to avoid contention.

### 3.4 Garbage Collection

**Reference counting is primary.** When `ob_refcnt` reaches zero, `_Py_Dealloc()` is called immediately.

**Cyclic GC (the `gc` module):** Handles reference cycles that refcounting cannot detect. Only scans **container objects** (objects that can hold references to other objects).

**Generational GC (default build):**
- Three generations (0, 1, 2)
- New objects start in generation 0
- Surviving objects are promoted to older generations
- Generation 0 is collected most frequently; generation 2 least frequently
- Uses `tp_traverse` slot to walk references in each container

**Collection algorithm:**
1. Copy `ob_refcnt` → `gc_ref` for all containers in the generation
2. Decrement `gc_ref` for each internal reference (using `tp_traverse`)
3. Objects with `gc_ref > 0` are reachable from outside the candidate set
4. Traverse reachable objects to find all reachable transitively
5. Remaining unreachable objects → cycle detected → call `tp_clear` and finalizers

**Free-threaded GC (PEP 703):**
- **Non-generational** — scans entire heap each time (avoids frequent stop-the-world pauses)
- Uses **stop-the-world pauses** (two per collection cycle) instead of GIL
- "Mark alive" phase: identifies definitely-reachable objects first
- Uses software prefetching for large heaps
- Relies on mimalloc for heap enumeration instead of linked lists

### 3.5 PEP 703: The no-GIL Path

Key changes for free-threaded operation:
1. **Biased reference counting** — local fast path + atomic shared slow path
2. **Immortal objects** — eliminate refcount operations for common singletons
3. **Deferred reference counting** — modules, code objects, top-level functions skip refcount ops on stack push/pop
4. **mimalloc** replaces pymalloc
5. **Per-object locking** for built-in containers (dict, list, set)
6. **Python critical sections** — deadlock-avoiding nested lock suspension
7. **Stop-the-world GC** instead of GIL-protected GC

---

## 4. The GIL Deep Dive

### 4.1 Why the GIL Exists

The GIL was chosen for three fundamental reasons:

1. **Reference counting is not thread-safe.** Without locks, `ob_refcnt++` is a race condition. Making every INCREF/DECREF atomic would be prohibitively expensive (atomic ops are 5-20x slower than regular ops).

2. **C extension compatibility.** The GIL means C extensions don't need to worry about thread safety for most operations. This dramatically lowered the barrier to writing C extensions.

3. **Single-threaded performance.** A single lock is simpler and faster than fine-grained locking. Single-threaded Python (the vast majority of use cases) benefits from zero locking overhead.

### 4.2 How the GIL Works

**GIL acquisition:** A thread must hold the GIL to execute Python bytecode. `PyEval_RestoreThread()` acquires it; `PyEval_SaveThread()` releases it.

**Context switching:**
- The interpreter checks `eval_breaker` every N instructions
- `sys.setswitchinterval()` (default: 5ms) controls how often threads switch
- When the timer fires, one thread releases the GIL and another acquires it
- Switching happens at **bytecode boundaries** — never mid-instruction

**eval_breaker mechanism:**
```c
if (_Py_atomic_load_relaxed(&eval_breaker)) {
    if (*next_instr == SETUP_FINALLY || /* ... */) {
        goto fast_next_opcode;  // Skip pending calls in critical sections
    }
    if (eval_frame_handle_pending(tstate) != 0) {
        goto error;
    }
}
```

The `eval_breaker` is a per-thread flag that signals: signal handlers need execution, async I/O is ready, or a thread switch is pending.

### 4.3 The GIL's Performance Paradox

The GIL **helps** single-threaded performance:
- No atomic operations needed for refcounting
- No cache-line bouncing between cores
- No lock acquisition overhead
- Simple, predictable memory layout

The GIL **hurts** multi-threaded CPU-bound code:
- Only one thread executes Python at a time
- Threads take turns at 5ms intervals
- True parallelism impossible for Python code

However, I/O-bound code works fine because threads release the GIL during I/O waits.

### 4.4 PEP 703: The No-GIL Future

**Timeline:**
- **3.13:** Experimental `--disable-gil` build (PEP 703 accepted)
- **3.14:** Officially supported but not default (PEP 779 criteria met)
- **3.15-3.16:** Stabilization
- **3.17+:** GIL build may become non-default

**Performance impact:**
- Single-threaded: ~5-10% overhead (biased refcounting, mimalloc)
- Multi-threaded: significant speedup for CPU-bound parallel code
- The overhead is expected to decrease with optimization

**C extension compatibility:**
- Extensions must declare `Py_mod_gil_not_used` to opt into free-threaded mode
- Without declaration, CPython re-enables the GIL when the extension is imported
- `PYTHON_GIL=0/1` environment variable for runtime control

---

## 5. Import System

### 5.1 The Import Protocol

The import process (`import foo.bar.baz`) follows this sequence:

```
1. Check sys.modules cache
   │
   ▼ (miss)
2. Search sys.meta_path (list of MetaPathFinders)
   │  BuiltInImporter → frozen/builtin modules
   │  FrozenImporter → frozen modules
   │  PathFinder → filesystem, zip, etc.
   ▼
3. Finder returns a ModuleSpec (name, loader, origin)
   │
   ▼
4. Loader.create_module(spec) — create the module object
   │  (or import machinery creates a bare module)
   ▼
5. Insert into sys.modules (prevents import cycles)
   │
   ▼
6. Loader.exec_module(module) — execute the module code
   │  For .py: compile + exec the code object
   │  For .so: dlopen + call PyInit_<name>
   ▼
7. Module is now fully loaded
```

### 5.2 Finders and Loaders

**MetaPathFinders** (on `sys.meta_path`):
- `BuiltinImporter` — handles `sys.builtin_module_names`
- `FrozenImporter` — handles frozen modules embedded in the interpreter
- `PathFinder` — delegates to PathEntryFinders for filesystem search

**PathEntryFinders** (resolved via `sys.path_hooks`):
- `FileFinder` — searches a directory for `.py`, `.pyc`, `.so` files
- Cached in `sys.path_importer_cache` for performance

**Loader protocol:**
```python
class Loader:
    def create_module(self, spec):
        """Create the module object (or return None for default)"""
    def exec_module(self, module):
        """Execute the module's code"""
```

### 5.3 Bytecode Caching (.pyc files)

**Timestamp-based validation (default):**
- `.pyc` files store source timestamp + size in header
- On import, compare stored metadata against current source
- If stale, recompile from source

**Hash-based validation (PEP 552):**
- `.pyc` stores a hash of source content
- **Checked:** re-hash source and compare (safe but slower)
- **Unchecked:** trust the cache (fast but unsafe)

**Cache location:** `__pycache__/module.cpython-XY.pyc` (PEP 3147)

**Frozen modules:**
- Python source pre-compiled to bytecode and embedded as static C arrays
- Used to bootstrap `importlib` itself (avoids circular dependency)
- Frozen modules are referenced by `PyImport_FrozenModules` table
- Each entry: `{name, code_bytes, size, is_package}`

### 5.4 Namespace Packages vs Regular Packages

**Regular package:** Has `__init__.py` in its directory. The loader sets `__path__`, `__file__`, etc.

**Namespace package (PEP 420):** No `__init__.py`. Multiple directories can contribute portions to the same package. Created automatically by the path-based finder when no regular package is found.

**Import lock:** A recursive mutex (`_PyRecursiveMutex`) serializes imports within an interpreter. This prevents deadlocks from re-entrant imports but limits import parallelism.

---

## 6. C Extension API

### 6.1 The Python.h API

The C API is defined in `Include/Python.h`, which includes:
- `object.h` — `PyObject`, `PyVarObject`, reference counting macros
- `refcount.h` — `Py_INCREF`, `Py_DECREF`
- `objimpl.h` — object creation, type checking
- `pycapsule.h` — capsule mechanism
- `cpython/code.h` — code object internals
- `pyframe.h` — frame object access
- `modsupport.h` — module creation
- `pythonrun.h` — interpreter initialization

**Extension module initialization (multi-phase, PEP 489):**
```c
static PyModuleDef_Slot module_slots[] = {
    {Py_mod_multiple_interpreters, Py_MOD_PER_INTERPRETER_GIL_SUPPORTED},
    {Py_mod_gil, Py_MOD_GIL_NOT_USED},  // For free-threaded builds
    {0, NULL}
};

static struct PyModuleDef module_def = {
    PyModuleDef_HEAD_INIT,
    "mymodule",
    NULL,
    -1,
    NULL,
    module_slots
};

PyMODINIT_FUNC PyInit_mymodule(void) {
    return PyModuleDef_Init(&module_def);
}
```

### 6.2 How C Extensions Are Loaded

**Loading mechanism (Linux):**
```
1. PathFinder locates "mymodule.cpython-312-x86_64-linux-gnu.so"
2. ExtensionFileLoader calls _PyImport_LoadDynamicModuleWithSpec()
3. _PyImport_FindSharedFuncptr() does:
   a. dlopen(pathname, dlopenflags)  → handle
   b. dlsym(handle, "PyInit_mymodule")  → function pointer
4. Call (*exportfunc)()  → PyInit_mymodule()
5. Module object returned and registered in sys.modules
```

**ABI tag:** Extensions include `cpython-312` (or `cpython-312t` for free-threaded) in the filename to ensure ABI compatibility.

### 6.3 Reference Counting Across the C API Boundary

**New references vs borrowed references:**
- **New reference:** Function returns a new reference you must `Py_DECREF` when done
- **Borrowed reference:** Function returns a reference you don't own (don't `Py_DECREF`)
- **Stolen reference:** Function takes ownership of a reference you passed in

**Common patterns:**
```c
// PyList_GetItem returns a BORROWED reference
PyObject *item = PyList_GetItem(list, 0);  // Don't DECREF this

// PyTuple_GetItem returns a BORROWED reference
PyObject *item = PyTuple_GetItem(tuple, 0);

// PyObject_GetItem returns a NEW reference
PyObject *item = PyObject_GetItem(obj, key);  // Must DECREF this

// PyTuple_SetItem STEALS the reference
PyTuple_SetItem(tuple, 0, new_ref);  // Don't DECREF new_ref after this
```

**The critical rule:** `PyObject_SetItem`, `PyDict_SetItem` do NOT steal references. `PyTuple_SetItem` and `PyList_SetItem` DO steal references.

### 6.4 The Capsule Mechanism

Capsules are the primary way to share C function pointers between extension modules:

```c
// Exporting module
static void *PyMyAPI[3];
PyCapsule_New((void *)PyMyAPI, "mymodule._C_API", NULL);

// Importing module
void **api = (void **)PyCapsule_Import("mymodule._C_API", 0);
my_func = (my_func_t)api[0];
```

**Capsule internals:**
```c
typedef struct {
    PyObject_HEAD
    void *pointer;
    const char *name;
    void *context;
    PyCapsule_Destructor destructor;
    traverseproc traverse_func;
    inquiry clear_func;
} PyCapsule;
```

**Name convention:** `"modulename.attributename"` for module-level C APIs. `PyCapsule_Import` splits on `.` and does module import + attribute lookup.

### 6.5 Memory Allocation Across Boundaries

**PyMem_Malloc** should be used for memory allocated by C extensions:
- Ensures the Python memory manager tracks the allocation
- Enables proper GC interaction and memory statistics
- Required for types that support garbage collection

**Mixed allocator dangers:** Using `malloc()` for memory that's later `PyMem_Free()`'d (or vice versa) causes crashes in debug builds and undefined behavior in release builds.

**Debug hooks:** In debug builds, allocators fill freed memory with `0xDD` (dead byte), newly allocated memory with `0xCD` (clean byte), and guard bytes with `0xFD` (forbidden byte). This catches buffer overflows, use-after-free, and double-frees.

---

## 7. Performance Characteristics

### 7.1 Why CPython Is Slow

1. **Interpreter overhead:** Every bytecode instruction requires: decode opcode → decode oparg → switch/computed goto → execute case → dispatch to next. Each step is cheap but cumulative.

2. **Dynamic typing at runtime:** `a + b` must check types of `a` and `b` at runtime, look up `tp_as_number->nb_add`, and dispatch. C just adds two integers.

3. **Reference counting overhead:** Every object access requires incrementing/decrementing reference counts. Even reading a value from a list and storing it in a local variable involves 2 refcount operations.

4. **The GIL:** Prevents true parallelism for CPU-bound Python code.

5. **Boxed values:** Every integer is a heap-allocated `PyLongObject` (28+ bytes), not a raw 8-byte `int64_t`.

6. **Dictionary-based attribute access:** `instance.attr` typically does a dictionary lookup on `instance.__dict__`, then on the type's `tp_dict`.

### 7.2 The Specializing Adaptive Interpreter (PEP 659)

Added in Python 3.11, this is the single biggest performance improvement in CPython's history:

- At runtime, generic opcodes are replaced with type-specialized versions
- Example: `LOAD_ATTR` → `LOAD_ATTR_INSTANCE_VALUE` (direct `__dict__` offset access)
- Inline caches store type information, version tags, and offsets
- Deoptimization occurs when assumptions are violated
- 25-30% of instructions can be usefully specialized
- Measured speedup: **25-50%** depending on workload

### 7.3 The Copy-and-Patch JIT (PEP 744/PEP 836)

**Architecture:**
```
Bytecode → [Tier 1: Specializing Interpreter]
              │ (detects hot traces)
              ▼
         [Tier 2: Micro-op Executor]
              │ (lowers to micro-ops, optimizes)
              ▼
         [Tier 3: JIT Compiler]
              (copy-and-patch → machine code)
```

**Copy-and-patch compilation:**
1. At build time: LLVM compiles micro-op implementations into "stencils" (template machine code with holes)
2. At runtime: JIT "patches" stencils by filling holes with runtime constants (opargs, addresses, type info)
3. Compiled code is stored in executable memory and called directly

**Performance (CPython 3.15):**
| Platform | Speedup over interpreter |
|----------|-------------------------|
| macOS (M3 Pro) | 12.6% |
| Linux aarch64 (AmpereOne) | 7.3% |
| Linux x86_64 (i5-8400) | 6.9% |
| Windows (Ryzen 5) | 4.7% |

**PEP 836 targets:** 20% geometric mean improvement on pyperformance for JIT + free-threaded vs interpreter alone, by Python 3.17.

**Memory overhead:** ~10-20% more memory than base interpreter (executable code pages).

### 7.4 CPython vs PyPy vs Cython

| Feature | CPython | PyPy | Cython |
|---------|---------|------|--------|
| **Language** | C (reference impl) | RPython → C | Python → C |
| **Execution** | Bytecode interpreter | Tracing JIT | Compiled C code |
| **GIL** | Yes (3.13: optional) | Yes (no-GIL effort) | No (runs as C) |
| **Single-thread perf** | Baseline | 2-10x faster | 10-100x faster |
| **Multi-thread** | GIL-limited | GIL-limited | True parallelism |
| **Startup time** | Fastest | Slow (JIT warmup) | Fastest (compiled) |
| **Memory usage** | Moderate | Higher (JIT + tracing) | Lower |
| **C extension compat** | Native | CPyExt (slow) | Native (IS the C) |
| **Best for** | General use | Long-running servers | CPU-intensive code |

### 7.5 What Makes Python "Good Enough" Despite Being Slow

1. **Startup time:** CPython starts in milliseconds; JVM/Graal.js take seconds
2. **"Batteries included":** The standard library is enormous and mature
3. **C extension ecosystem:** NumPy, pandas, etc. handle performance-critical work in C
4. **Developer productivity:** Dynamic typing + concise syntax = faster development
5. **I/O-bound workloads:** For web servers, APIs, file processing — the interpreter overhead is negligible compared to I/O latency
6. **Good enough is good enough:** Most Python programs are not CPU-bound

---

## 8. What Makes Python's Approach Unique

### 8.1 Dynamism as Strength

- **Late binding:** Names are resolved at runtime, enabling monkey-patching, metaclasses, decorators
- **Duck typing:** No need for formal interface declarations
- **Dynamic attribute access:** `__getattr__`, `__getattribute__`, `__setattr__` allow arbitrary behavior
- **Eval/exec:** Code can generate and execute code at runtime
- **`importlib`:** The import system itself is extensible in Python

### 8.2 The "Batteries Included" Philosophy

Python's standard library covers:
- Networking (asyncio, http, email, xmlrpc)
- Data structures (collections, heapq, bisect)
- Serialization (json, pickle, marshal)
- File systems (pathlib, shutil, tempfile)
- Text processing (re, unicodedata, difflib)
- Scientific computing (math, decimal, fractions, statistics)
- Cryptography (hashlib, hmac, secrets)
- Testing (unittest, doctest, test.support)

This is a **moat** — no new language can match it quickly.

### 8.3 The GIL Paradox

The GIL **helps** single-threaded performance by:
- Eliminating atomic operation overhead for reference counting
- Preventing cache-line contention between cores
- Keeping the memory allocator simple (no locking needed)
- Making C extensions easy to write (no thread-safety concerns)

The GIL **hurts** only CPU-bound multi-threaded code, which is a small fraction of Python programs.

### 8.4 The C Extension Ecosystem as a Moat

- **NumPy** — the foundation of scientific Python, with 20+ years of optimization
- **pandas** — data analysis, used everywhere
- **Django/Flask/FastAPI** — web frameworks with massive ecosystems
- **TensorFlow/PyTorch** — ML frameworks with Python frontends
- **SQLite, OpenSSL, libxml2** — wrapped C libraries

Any new language must either be **Python-compatible** (requiring the entire C extension ecosystem) or build its own ecosystem from scratch.

---

## 9. Lessons for Astra

### 9.1 What Python Got RIGHT — Adopt These

1. **The PEG parser approach:** Grammar-driven, AST generation from actions, memoization. This is clean, maintainable, and extensible. Astra should use a similar approach.

2. **The descriptor protocol:** `__get__`, `__set__`, `__delete__` is elegant and extensible. Properties, methods, classmethods, staticmethods, slots — all built on one mechanism.

3. **The import system's extensibility:** `sys.meta_path`, `sys.path_hooks`, finder/loader protocol. This is one of Python's most well-designed systems.

4. **The "batteries included" philosophy:** A comprehensive standard library is essential for adoption.

5. **Dynamic typing as default, not as a limitation:** Python's dynamism is a feature. Astra should keep this but add optional static typing.

6. **Reference counting for immediacy:** Objects are freed immediately when unreleased. No GC pauses for non-cyclic data.

### 9.2 What Python Got WRONG — Fix These

1. **The GIL:** The single biggest design limitation. Astra should be free-threaded from the start, using:
   - Biased reference counting (proven in PEP 703)
   - Per-object locking for containers
   - Immortal objects for singletons
   - Stop-the-world GC for cycle collection

2. **No optional static typing at the language level:** Python's type hints (PEP 484) are bolted on. Astra should have first-class optional types that enable compile-time optimization.

3. **Boxed numeric types:** Every `int` is a heap-allocated object. Astra should have unboxed numeric types for performance (like Java's `int` vs `Integer`).

4. **Dictionary-only attribute access:** `__dict__` lookup for every attribute access is slow. Astra should default to slot-based (offset) attribute access like `__slots__`, with dict-based access as an opt-in.

5. **Global mutable state everywhere:** `sys.modules`, `sys.path`, `sys.meta_path` — global mutable state makes multi-interpreter and multi-threading harder. Astra should use per-thread or per-context state.

6. **No value types:** Everything in Python is a heap-allocated reference type. Astra should support value types (structs) for small, frequently-used data.

### 9.3 How Astra's FFI Should Improve on CPython's C API

**Problems with CPython's C API:**
- Reference counting is error-prone (new vs borrowed vs stolen references)
- The C API is not stable across versions
- Macros like `Py_INCREF`/`Py_DECREF` are unsafe if called on wrong objects
- No type safety — `PyObject *` is used for everything

**Astra FFI improvements:**
1. **Safe reference handles:** Instead of raw pointers, use opaque handles with lifetime tracking
2. **Automatic reference management:** RAII-style or scope-based ref management where possible
3. **Stable ABI from day one:** Design the ABI to be forward-compatible
4. **Typed FFI:** Use generics or traits to provide type-safe C interop
5. **Memory arena API:** Let C extensions allocate from Astra's managed heap
6. **Capsule equivalent with types:** Not just `void *`, but typed capsules

### 9.4 How Astra Can Provide Python Compatibility Without Python's Limitations

1. **Python syntax compatibility layer:** Parse Python syntax, compile to Astra bytecode. This enables running existing Python code.

2. **CPython C API compatibility:** Implement the most-used C API functions (Py_INCREF, PyLong_FromLong, PyList_New, etc.) as a compatibility shim. This enables recompiling C extensions.

3. **Standard library reimplementation:** Reimplement Python's stdlib in Astra, calling into existing C libraries where beneficial.

4. **Gradual typing:** Python code runs dynamically; Astra-native code can add types for optimization.

5. **No GIL by default:** Astra should be free-threaded from the start. The C API compatibility layer can provide per-thread reference counting.

6. **Better memory model:** Use a compacting GC alongside reference counting. This eliminates fragmentation and enables moving objects for cache locality.

---

## Appendix A: Key Source Files

| File | Purpose |
|------|---------|
| `Python/ceval.c` | The evaluation loop (`_PyEval_EvalFrameDefault`) |
| `Python/ceval_macros.h` | Dispatch macros (`DISPATCH`, `NEXTOPARG`, `TARGET`) |
| `Python/bytecodes.c` | DSL definitions for all opcodes |
| `Python/compile.c` | Compiler driver |
| `Python/codegen.c` | AST → pseudo-instruction generation |
| `Python/flowgraph.c` | CFG construction and optimization |
| `Python/assemble.c` | Final bytecode assembly |
| `Python/symtable.c` | Symbol table analysis |
| `Parser/parser.c` | PEG parser (generated) |
| `Grammar/python.gram` | Python grammar definition |
| `Parser/Python.asdl` | AST node definitions |
| `Include/object.h` | `PyObject`, `PyVarObject`, core macros |
| `Include/cpython/object.h` | `PyTypeObject`, slot signatures |
| `Objects/typeobject.c` | Type creation, slot wiring, MRO |
| `Objects/obmalloc.c` | PyMalloc arena/pool/block allocator |
| `Objects/capsule.c` | Capsule implementation |
| `Python/import.c` | Import system (C level) |
| `Lib/importlib/_bootstrap.py` | Import system (Python level) |
| `Lib/importlib/_bootstrap_external.py` | Filesystem import logic |
| `Python/gc.c` | Cyclic garbage collector |
| `Python/jit.c` | Copy-and-patch JIT compiler |
| `Python/pystate.c` | Thread state management |
| `Include/internal/pycore_opcode_metadata.h` | Per-opcode metadata |

## Appendix B: Key Design Patterns

### Pattern 1: Object Header Inheritance
Every type starts with `PyObject` or `PyVarObject`, enabling polymorphic dispatch via `ob_type` pointer. This is C's manual implementation of inheritance.

### Pattern 2: Slot-based Dispatch
`PyTypeObject` has function pointers (`tp_*` slots) that the runtime calls instead of type-checking. This is like virtual method tables in C++.

### Pattern 3: Arena Allocation for Compilation
The `PyArena` bump allocator simplifies compilation memory management — no per-node frees, just one sweep at the end.

### Pattern 4: Inline Caches
Specialized bytecodes store type information and offsets directly after the instruction in the bytecode stream. This avoids hash table lookups on hot paths.

### Pattern 5: Copy-and-Patch JIT
Build-time stencil generation + runtime patching = fast JIT compilation with zero runtime dependencies. The same DSL drives the interpreter, specializer, and JIT.

---

*Report compiled from CPython 3.14/3.15 source code, PEPs, and internal documentation. Last updated: September 2026.*
