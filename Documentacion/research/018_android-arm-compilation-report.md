# Android & ARM Compilation for Astra: Comprehensive Research Report

**Version:** 1.0 | **Date:** September 2026

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Android NDK Deep Dive](#2-android-ndk-deep-dive)
3. [Android ABI Targets](#3-android-abi-targets)
4. [Android App Bundling](#4-android-app-bundling)
5. [JNI (Java Native Interface)](#5-jni-java-native-interface)
6. [ART Runtime](#6-art-runtime)
7. [ARM-Specific Optimizations](#7-arm-specific-optimizations)
8. [Cross-Compilation for Android](#8-cross-compilation-for-android)
9. [Android NDK API Levels](#9-android-ndk-api-levels)
10. [Static vs Dynamic Linking on Android](#10-static-vs-dynamic-linking-on-android)
11. [Astra Android Strategy](#11-astra-android-strategy)

---

## 1. Executive Summary

Android is the dominant mobile platform with 3.5B+ active devices, overwhelmingly ARM-based. For Astra to succeed as a "write once, run anywhere" language, Android support is not optional—it is existential. This report provides the technical foundation for Astra's Android strategy, covering the NDK toolchain, ABI targets, JNI interop, ART runtime internals, ARM SIMD optimizations, cross-compilation, API levels, linking strategies, and a concrete integration roadmap.

**Key Findings:**
- The Android NDK is LLVM-based (Clang + LLD), making Astra's LLVM backend directly applicable
- arm64-v8a is the only mandatory ABI for Google Play (since August 2023)
- Bionic libc (Android's C library) is NOT glibc—it has significant API differences
- ART uses Concurrent Copying GC with AOT+JIT hybrid compilation
- ARM NEON is mandatory on arm64-v8a; hand-tuned SIMD gives 3-4x throughput gains
- Static binaries are NOT supported on Android (Bionic requirement)
- The `astra build --target aarch64-linux-android21` pipeline is feasible using NDK's Clang as the linker

---

## 2. Android NDK Deep Dive

### 2.1 What the NDK Is

The Android NDK (Native Development Kit) is a set of tools that allows developers to implement parts of their app using native code (C/C++). It provides:

- **Clang/LLVM compiler** (the only supported compiler since NDK r17; GCC was removed)
- **LLD linker** (replaced `ld` as default since NDK r23)
- **Bionic sysroot** (headers and libraries for Android's C library)
- **CMake toolchain file** (`android.toolchain.cmake`)
- **ndk-build** (Android.mk-based build system, alternative to CMake)
- **LLVM tools** (llvm-ar, llvm-strip, llvm-ranlib, llvm-readelf, etc.)

### 2.2 Toolchain Layout

```
$NDK/toolchains/llvm/prebuilt/<host-tag>/
├── bin/
│   ├── clang, clang++              # The compiler
│   ├── aarch64-linux-android21-clang    # Target-prefixed wrappers
│   ├── armv7a-linux-androideabi21-clang
│   ├── i686-linux-android21-clang
│   ├── x86_64-linux-android21-clang
│   ├── ld.lld                        # Linker
│   ├── llvm-ar, llvm-ranlib, llvm-strip
│   └── llvm-readelf, llvm-objcopy
├── lib/
│   └── clang/<version>/lib/linux/    # compiler-rt builtins
├── sysroot/
│   ├── usr/include/                  # Bionic + NDK headers
│   └── usr/lib/<triple>/             # Target libraries
└── build/cmake/android.toolchain.cmake
```

### 2.3 Key Clang Flags for Android

```bash
# Target selection (recommended method)
--target=aarch64-linux-android21    # arm64, API 21
--target=armv7a-linux-androideabi21 # arm32, API 21
--target=i686-linux-android21       # x86, API 21
--target=x86_64-linux-android21     # x86_64, API 21

# Common flags
-ffunction-sections -fdata-sections  # Enable dead code elimination
-Wl,--gc-sections                    # Strip unused sections at link time
-Wl,--icf=safe                       # Identical code folding (safe)
-O2 -DNDEBUG                         # Optimization level

# ARM-specific
-mthumb                               # Generate Thumb-2 code (smaller, recommended)
-march=armv7-a -mfpu=neon            # ARMv7 with NEON (auto-enabled)
-march=armv8-a                        # ARMv8 (default for aarch64)

# Dynamic linking (required on Android)
-shared -Wl,--no-undefined
```

### 2.4 What Changed in Recent NDK Versions

| NDK Version | Key Changes |
|:------------|:------------|
| r21 | `make_standalone_toolchain.py` deprecated; use Clang directly |
| r22 | LLD becomes default linker; old `ld` removed |
| r23 | Full LLD transition; GCC completely removed |
| r24 | C++20 support in libc++;最低 API level bumped to 21 |
| r25 | Android 14 SDK support; RISC-V experimental |
| r26 | Stable RISC-V support; improved LTO; mold linker support |
| r27 | NDK r27 (2024): C++23 support, improved constexpr |
| r28 | NDK r28 (2025): clang 18, LLD improvements |

---

## 3. Android ABI Targets

### 3.1 Supported ABIs

| ABI | Arch | Triple | Min API | Status | Notes |
|:----|:-----|:-------|:--------|:-------|:------|
| `armeabi-v7a` | arm | `armv7a-linux-androideabi` | 21 | Supported | Thumb-2, VFPv3-D16. NEON optional but virtually universal |
| `arm64-v8a` | aarch64 | `aarch64-linux-android` | 21 | **Required** | NEON mandatory. Google Play requires 64-bit |
| `x86` | x86 | `i686-linux-android` | 21 | Legacy | Emulators only. SSE2/SSE3. No SSE4, no MOVBE |
| `x86_64` | x86_64 | `x86_64-linux-android` | 21 | Supported | Emulators. Full SSE4.1/4.2, POPCNT |
| `riscv64` | riscv64 | `riscv64-linux-android` | 35 | Experimental | Added in NDK r26. Future-proofing |

### 3.2 ABI Differences in Detail

#### armeabi-v7a (32-bit ARM)
- **Instruction set:** ARMv7-A with Thumb-2
- **FPU:** VFPv3-D16 (16 double-precision FP registers)
- **NEON:** Optional but ~100% of devices support it (all API 21+ devices)
- **Registers:** 16 core registers (r0-r15), 32 FP/SIMD registers (d0-d31 or s0-s31)
- **Calling convention:** AAPCS (r0-r3 for args, r0-r1 return, r13=SP, r14=LR, r15=PC)
- **Important:** Double values passed in core register pairs, not FP registers (ABI compatibility)
- **Code density:** Thumb-2 gives ~65% of ARM code size with ~90% of ARM performance

#### arm64-v8a (64-bit ARM)
- **Instruction set:** AArch64
- **FPU:** Mandatory FP16, FP32, FP64
- **NEON/SIMD:** Mandatory. 128-bit vector registers (v0-v31)
- **Registers:** 31 general-purpose 64-bit registers (x0-x30), 32 SIMD/FP registers (v0-v31)
- **Dot product:** `vdotq_s32` available on ARMv8.2+ (most devices since 2019)
- **SVE/SVE2:** Scalable Vector Extension (ARMv8.2+), optional
- **Key advantage:** 64-bit pointers, larger address space, better performance

#### x86 / x86_64 (Intel)
- Primarily for **emulators** and a small number of Intel-based tablets
- x86: MMX, SSE, SSE2, SSE3, SSSE3 (no SSE4, no MOVBE)
- x86_64: Full SSE4.1/4.2, POPCNT, CMPXCHG16B, LAHF-SAHF
- No AVX (must use runtime feature detection)
- Some ARM-to-x86 translation layers exist (NativeBridge)

### 3.3 ABI Selection Strategy

```
Google Play requires: arm64-v8a (mandatory since August 2023)
Recommended minimum:  arm64-v8a + armeabi-v7a
Full coverage:        arm64-v8a + armeabi-v7a + x86_64 + x86
```

**Rule:** If you include ANY 64-bit library, you must include ALL libraries for that 64-bit ABI. Android will NOT fall back from arm64-v8a to armeabi-v7a if any arm64-v8a library is present.

---

## 4. Android App Bundling

### 4.1 APK vs AAB

| Format | Description | When to Use |
|:-------|:------------|:------------|
| **APK** | Single file, contains all ABIs. Legacy format. | Internal testing, non-Play Store distribution |
| **AAB** (Android App Bundle) | Google Play dynamic delivery. Only delivers matching ABI. | **Production (recommended)** |

### 4.2 Native Library Placement in APK/AAB

```
app/
├── src/main/
│   ├── jniLibs/                    # Pre-built .so files
│   │   ├── arm64-v8a/
│   │   │   └── libastra_runtime.so
│   │   ├── armeabi-v7a/
│   │   │   └── libastra_runtime.so
│   │   ├── x86_64/
│   │   │   └── libastra_runtime.so
│   │   └── x86/
│   │       └── libastra_runtime.so
│   └── java/
│       └── com/astralang/
│           └── AstraRuntime.java    # JNI bridge class
```

### 4.3 Gradle Configuration for Native Libraries

```groovy
// build.gradle (app module)
android {
    compileSdkVersion 35
    
    defaultConfig {
        minSdkVersion 21
        targetSdkVersion 35
        
        ndk {
            abiFilters 'arm64-v8a', 'armeabi-v7a', 'x86_64'
        }
    }
    
    externalNativeBuild {
        cmake {
            path "src/main/cpp/CMakeLists.txt"
            version "3.22.1"
        }
    }
    
    // For pre-built .so files
    packaging {
        jniLibs {
            useLegacyPackaging = false  // Uncompressed, page-aligned (API 23+)
        }
    }
}
```

### 4.4 AAB Structure

```
base.apk
├── AndroidManifest.xml
├── classes.dex                     # Java/Kotlin bytecode
├── lib/
│   ├── arm64-v8a/
│   │   ├── libastra_runtime.so    # Astra runtime for this ABI
│   │   └── libastra_stdlib.so     # Astra standard library
│   └── armeabi-v7a/
│       ├── libastra_runtime.so
│       └── libastra_stdlib.so
├── assets/                         # App assets
└── res/                            # Resources

# After AAB → APK split:
# Device gets ONLY its matching ABI folder
```

### 4.5 .so File Naming Convention

```
lib{name}.so

Examples:
libastra_runtime.so     # Astra runtime library
libastra_stdlib.so      # Astra standard library
libastra_jni.so         # JNI bridge library
```

The `lib` prefix and `.so` suffix are **mandatory** on Android. `System.loadLibrary("astra_runtime")` strips both.

---

## 5. JNI (Java Native Interface)

### 5.1 How JNI Works

JNI is the mechanism by which Java/Kotlin code calls native (C/C++) code and vice versa. The flow:

```
Java/Kotlin Code
    ↓ System.loadLibrary("astra_runtime")
    ↓ native method declarations
JNI Bridge (C-ABI)
    ↓ JNIEnv* pointer
    ↓ JNI function table
Native Code (C/C++/Astra)
```

### 5.2 JNI Function Signatures

```c
// Standard JNI function signature
JNIEXPORT jdouble JNICALL
Java_com_astralang_AstraRuntime_evalExpression(
    JNIEnv* env,          // JNI environment pointer
    jobject thiz,         // 'this' reference (for instance methods)
    jstring expression)   // Java String parameter
{
    const char* nativeStr = (*env)->GetStringUTFChars(env, expression, NULL);
    double result = compute(nativeStr);
    (*env)->ReleaseStringUTFChars(env, expression, nativeStr);
    return result;
}
```

### 5.3 JNI Type Mapping

| Java Type | JNI Type | Native Type |
|:----------|:---------|:------------|
| `boolean` | `jboolean` | `unsigned char` |
| `byte` | `jbyte` | `signed char` |
| `char` | `jchar` | `unsigned short` |
| `short` | `jshort` | `short` |
| `int` | `jint` | `int` |
| `long` | `jlong` | `long long` |
| `float` | `jfloat` | `float` |
| `double` | `jdouble` | `double` |
| `String` | `jstring` | (opaque handle) |
| `Object` | `jobject` | (opaque handle) |
| `int[]` | `jintArray` | (opaque handle) |

### 5.4 JNI Performance Annotations

Android provides annotations to optimize JNI transitions:

| Annotation | JNI Cost | Use Case |
|:-----------|:---------|:---------|
| Regular JNI | ~115 ns | Default. Full state transition. |
| `@FastNative` | ~35 ns | Method uses managed objects but no blocking |
| `@CriticalNative` | ~25 ns | No managed objects in/out. Fastest possible. |

```kotlin
// Kotlin side
class AstraRuntime {
    companion object {
        init { System.loadLibrary("astra_runtime") }
    }
    
    @FastNative
    external fun evalExpression(expr: String): Double
    
    @CriticalNative
    external fun getVersion(): Int
    
    external fun processArray(input: IntArray): IntArray
}
```

### 5.5 JNI RegisterNatives (Recommended for Astra)

Dynamic JNI symbol lookup is slow. `RegisterNatives` provides direct function pointer binding:

```c
static JNINativeMethod methods[] = {
    {"evalExpression", "(Ljava/lang/String;)D", 
     (void*)astra_eval_expression},
    {"getVersion", "()I", 
     (void*)astra_get_version},
};

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    JNIEnv* env;
    vm->GetEnv((void**)&env, JNI_VERSION_1_6);
    
    jclass cls = env->FindClass("com/astralang/AstraRuntime");
    env->RegisterNatives(cls, methods, sizeof(methods)/sizeof(methods[0]));
    
    return JNI_VERSION_1_6;
}
```

### 5.6 Critical JNI Considerations for Astra

1. **Object pinning:** ART's Concurrent Copying GC can move objects. `GetPrimitiveArrayCritical` may pin but has restrictions.
2. **Local references:** Must be deleted or frames must be pushed for long-running native code.
3. **Exception handling:** Check for exceptions after every JNI call. Native code must not continue after Java exceptions.
4. **Thread attachment:** Native threads must call `AttachCurrentThread` before JNI calls. Detach on exit.
5. **ARC interaction:** Astra's ARC objects must NOT be passed directly as `jobject`. Marshal at the boundary.

---

## 6. ART Runtime

### 6.1 ART Architecture

```
┌─────────────────────────────────────────────────────┐
│                    ART Runtime                       │
│                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────┐ │
│  │   DEX2OAT    │  │   Runtime    │  │   JIT    │ │
│  │   (AOT       │  │   (libart.so)│  │  Compiler│ │
│  │   Compiler)  │  │              │  │          │ │
│  └──────────────┘  └──────────────┘  └──────────┘ │
│                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────┐ │
│  │   GC (CC)    │  │   Class      │  │  JNI     │ │
│  │   Concurrent │  │   Loading    │  │  Bridge  │ │
│  │   Copying    │  │              │  │          │ │
│  └──────────────┘  └──────────────┘  └──────────┘ │
│                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────┐ │
│  │   AOT        │  │   Profile    │  │  Native  │ │
│  │   Compiled   │  │   Guided     │  │  Loader  │ │
│  │   (.oat)     │  │   Optimization│  │  (namespaces)│
│  └──────────────┘  └──────────────┘  └──────────┘ │
└─────────────────────────────────────────────────────┘
```

### 6.2 ART Compilation Pipeline

```
Java/Kotlin Source
    ↓
DEX Bytecode (.dex files in APK)
    ↓
┌─────────────────────────────────────────┐
│  Install-time: dex2oat (AOT)            │
│  - Verifies DEX bytecode                │
│  - Compiles methods to native code      │
│  - Generates .oat files (ELF format)    │
│  - Compiler filter: speed-profile       │
└─────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────┐
│  Runtime: JIT Compiler                  │
│  - Compiles hot methods on-the-fly      │
│  - Profile-guided optimization          │
│  - Code cache (default max 64MB)        │
│  - De-optimization support              │
└─────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────┐
│  Background: ART Service (Android 14+)  │
│  - Periodic recompilation               │
│  - Profile updates                      │
│  - Cloud profile integration            │
└─────────────────────────────────────────┘
```

### 6.3 ART Garbage Collection

ART uses **Concurrent Copying (CC)** collector (since Android 8):

- **Mostly concurrent:** GC runs mostly without pausing application threads
- **Single short pause:** Brief pause for root marking (~1-2ms)
- **Object compaction:** Objects are moved in memory to reduce fragmentation
- **Read barriers:** Baker read barriers for concurrent copying (minimal overhead)
- **Region-based:** Heap divided into regions for targeted collection

**Implications for Astra's ARC/ORC on Android:**
- ART's CC collector moves objects. Any JNI pointers obtained via `GetObjectField` become invalid after GC.
- Astra's ARC is independent of ART's GC. They can coexist, but JNI boundary crossings must handle both.
- `GetPrimitiveArrayCritical` may return a direct pointer, but it pins the array during use.

### 6.4 ART Compiler Filters

| Filter | Description | Install Time | Runtime Perf |
|:-------|:------------|:-------------|:-------------|
| `verify` | Only verify DEX bytecode | Fastest | Interpreter only |
| `quicken` | Verify + optimize DEX instructions | Fast | Better interpreter |
| `speed` | AOT-compile ALL methods | Slowest | Best (but large .oat) |
| `speed-profile` | AOT-compile hot methods from profile | Moderate | Good (default) |

### 6.5 ART and Native Libraries

ART loads native libraries through `libnativeloader`:

1. **Linker namespaces:** Each APK gets its own namespace. Libraries in the APK are accessible; other APKs' libraries are NOT.
2. **Public libraries:** Only libraries in `/system/etc/public.libraries.txt` are accessible from platform.
3. **NativeBridge:** For running ARM libraries on x86 via translation.
4. **Library loading order:** `System.loadLibrary()` → `libnativeloader` → `dlopen()` within the app's namespace.

---

## 7. ARM-Specific Optimizations

### 7.1 NEON SIMD

ARM NEON provides 128-bit SIMD operations. On arm64-v8a, NEON is **mandatory**.

#### Key NEON Intrinsics

```c
#include <arm_neon.h>

// 128-bit vector operations (process 4x float32 simultaneously)
float32x4_t va = vld1q_f32(data);        // Load 4 floats
float32x4_t vb = vdupq_n_f32(scalar);    // Broadcast scalar
float32x4_t vc = vmlaq_f32(va, vb, vd);  // Fused multiply-add: va + vb*vd

// Integer operations (process 16x int8 simultaneously)
int8x16_t ia = vld1q_s8(data);
int8x16_t ib = vld1q_s8(data2);
int32x4_t acc = vdupq_n_s32(0);
acc = vdotq_s32(acc, ia, ib);  // Dot product (ARMv8.2+)

// Reduction operations
float32x2_t sum = vadd_f32(vget_low_f32(vc), vget_high_f32(vc));
float result = vget_lane_f32(vpadd_f32(sum, sum), 0);
```

#### NEON Performance Gains

| Operation | Scalar | NEON | Speedup |
|:----------|:-------|:-----|:--------|
| Float multiply (4 elements) | 4 cycles | 1 cycle | 4x |
| FFT butterfly | 1 complex MADD | 4 complex MADD | 4x |
| Matrix multiply (int8) | 1 element/cycle | 4 elements/cycle | 4x |
| Text embedding (int8 GEMM) | ~15ms | ~4.7ms | 3.2x |

#### Auto-Vectorization vs Intrinsics

```c
// BEST: Write portable Clang vector types
// Compiler auto-selects NEON on ARM, SSE on x86
typedef float v4f __attribute__((ext_vector_type(4)));
v4f result = a + b * c;  // Auto-vectorized to NEON/SSE

// OK: Use NEON intrinsics (ARM-specific, but same codegen)
float32x4_t result = vmlaq_f32(a, b, c);

// AVOID: Raw assembly (no benefit over intrinsics, less portable)
```

### 7.2 Function Multi-Versioning (FMV)

ARM supports runtime CPU feature detection via `ifunc`:

```c
// Two implementations of the same function
__attribute__((target("default")))
void process_data(float* data, int n) {
    // Generic implementation (works on all ARM)
    for (int i = 0; i < n; i++) data[i] *= 2.0f;
}

__attribute__((target("arch=armv8.2-a")))
void process_data(float* data, int n) {
    // Optimized for ARMv8.2+ (uses dot product, etc.)
    for (int i = 0; i < n; i += 4) {
        float32x4_t v = vld1q_f32(data + i);
        v = vmulq_n_f32(v, 2.0f);
        vst1q_f32(data + i, v);
    }
}

// Compiler generates ifunc dispatch table
// Best implementation selected at LOAD TIME (not per call)
```

### 7.3 Cache Line Considerations

```c
// ARM Cortex-A cache line: 64 bytes
// Prevent false sharing in concurrent data structures
struct alignas(64) RingBuffer {
    std::atomic<size_t> read_pos;   // Cache line 0
    // ... padding to 64 bytes ...
    std::atomic<size_t> write_pos;  // Cache line 1
    char data[BUFFER_SIZE];
};

// Align critical data to cache lines
alignas(64) static float hotspot_buffer[16];
```

### 7.4 ARM-Specific Compiler Flags

```bash
# arm64-v8a (default, all flags implicit)
-march=armv8-a          # Base ARMv8
-mtune=cortex-a78       # Tune for specific core (optional)

# armeabi-v7a
-mthumb                  # Thumb-2 code (smaller, recommended)
-march=armv7-a -mfpu=neon -mfloat-abi=softfp

# Profile-guided optimization for Android
-fprofile-sample-use=profile.prof  # Use collected profiles
-fprofile-instr-generate           # Generate profile data
```

---

## 8. Cross-Compilation for Android

### 8.1 Method 1: Using NDK Clang Directly (Recommended)

```bash
# Set environment
export NDK=/path/to/ndk
export HOST_TAG=linux-x86_64  # or darwin-x86_64, windows-x86_64
export TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/$HOST_TAG

# For Astra: compile AIR → C99 → compile with NDK Clang
# Step 1: Astra generates C99 code targeting Android
astra build --target aarch64-linux-android21 --output gen/

# Step 2: Compile generated C with NDK Clang
$TOOLCHAIN/bin/clang \
    --target=aarch64-linux-android21 \
    --sysroot=$TOOLCHAIN/sysroot \
    -O2 -ffunction-sections -fdata-sections \
    -c gen/astra_runtime.c -o astra_runtime.o

# Step 3: Link into shared library
$TOOLCHAIN/bin/clang \
    --target=aarch64-linux-android21 \
    -shared -Wl,--no-undefined -Wl,--gc-sections \
    astra_runtime.o -lm -ldl \
    -o libastra_runtime.so
```

### 8.2 Method 2: CMake Toolchain File

```cmake
# CMakeLists.txt
cmake_minimum_required(VERSION 3.22)
project(astra_runtime C)

# Use NDK's toolchain file
# cmake -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
#        -DANDROID_ABI=arm64-v8a \
#        -DANDROID_PLATFORM=android-21 \
#        ..

add_library(astra_runtime SHARED
    src/runtime.c
    src/gc.c
    src/fibers.c
)

target_compile_options(astra_runtime PRIVATE
    -O2 -ffunction-sections -fdata-sections
)

target_link_options(astra_runtime PRIVATE
    -Wl,--gc-sections
    -Wl,--icf=safe
)
```

### 8.3 Method 3: LLVM-Based Cross-Compilation

Since Astra uses LLVM as its production backend, cross-compilation for Android is natural:

```bash
# Generate LLVM IR for Android target
llc -mtriple=aarch64-linux-android21 \
    -O2 \
    -relocation-model=pic \
    astra.ll -o astra.s

# Assemble
$TOOLCHAIN/bin/clang --target=aarch64-linux-android21 \
    -c astra.s -o astra.o

# Link
$TOOLCHAIN/bin/clang --target=aarch64-linux-android21 \
    -shared astra.o -o libastra.so
```

### 8.4 Method 4: For Rust Seed Compiler Cross-Compilation

If Astra's seed compiler is written in Rust:

```toml
# .cargo/config.toml
[target.aarch64-linux-android]
linker = "/path/to/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang"
```

```bash
rustup target add aarch64-linux-android
cargo build --target aarch64-linux-android --release
```

**Important:** Rust's `+crt-static` does NOT work on Android. Always dynamic linking.

### 8.5 Cross-Compilation Matrix

| Host | Target | Tool | Notes |
|:-----|:-------|:-----|:------|
| Linux x86_64 | Android ARM64 | NDK Clang | Primary development path |
| Linux x86_64 | Android ARM32 | NDK Clang | Legacy device support |
| macOS x86_64 | Android ARM64 | NDK Clang | Works, slower than Linux |
| macOS ARM64 | Android ARM64 | NDK Clang | Native Apple Silicon |
| Windows x86_64 | Android ARM64 | NDK Clang | Use WSL2 or native |
| Any host | Android x86_64 | NDK Clang | For emulator testing |

---

## 9. Android NDK API Levels

### 9.1 API Level Mapping

| API Level | Android Version | Release Date | Key NDK Features |
|:----------|:----------------|:-------------|:-----------------|
| 21 | 5.0 Lollipop | 2014 | Minimum for NDK r23+. 64-bit support. Full pthread. |
| 23 | 6.0 Marshmallow | 2015 | Runtime permissions. Page-aligned .so loading. |
| 24 | 7.0 Nougat | 2016 | `getifaddrs`, `pthread_barrier`, full FORTIFY. |
| 26 | 8.0 Oreo | 2017 | `getentropy`, `glob`, `pthread_getname_np`. |
| 28 | 9.0 Pie | 2018 | `aligned_alloc`, `strlcpy/strlcat`, `getrandom`. |
| 29 | 10 | 2019 | `android_get_device_api_level()`, full C11 support. |
| 31 | 12 | 2021 | `timespec_get`, C++20 in libc++. |
| 33 | 13 | 2022 | `backtrace_symbols`. |
| 34 | 14 | 2023 | `timespec_getres`, ART Service. |
| 35 | 15 | 2024 | `mseal`, `qsort_r`. |

### 9.2 Bionic vs glibc: Key Differences

| Feature | Bionic (Android) | glibc (Linux) |
|:--------|:-----------------|:--------------|
| System V IPC | NOT supported | Supported |
| Locale support | Minimal | Full |
| `dlmopen` | Not supported | Supported |
| `libpthread` | Included in libc | Separate library |
| `librt` | Included in libc | Separate library |
| `locale_t` | Very limited | Full support |
| Thread naming | `pthread_setname_np` (GNU) | `pthread_setname_np` (GNU) |
| Signal handling | Some differences | Standard POSIX |
| Allocator | jemalloc-based | ptmalloc/glibc |
| Stack size | Default ~1MB (unified) | Default ~8MB |
| `__ANDROID_API__` | Defined by `--target` suffix | Not applicable |

### 9.3 Recommended API Level Strategy

```
minSdkVersion: 21  (Android 5.0, covers 99%+ devices)
targetSdkVersion: 35 (Android 15, latest)

Rationale:
- API 21: Minimum for arm64-v8a. Full pthread. 64-bit pointers.
- API 21+: ~99.8% device coverage.
- API 23+: Page-aligned .so loading (better performance).
- API 26+: Many useful Bionic functions.
```

### 9.4 Using Newer APIs Than minSdkVersion

```c
// Runtime feature detection for newer APIs
#include <android/api-level.h>

void* get_newer_function() {
    int api = android_get_device_api_level();  // Available since API 29
    if (api >= 26) {
        return dlsym(RTLD_DEFAULT, "new_function");
    }
    return NULL;
}
```

---

## 10. Static vs Dynamic Linking on Android

### 10.1 The Rule: Dynamic Linking Only

**Android does NOT support static binaries.** Bionic's dynamic linker (`/system/bin/linker` or `/system/bin/linker64`) is required for all executables. This is a fundamental platform constraint.

### 10.2 Linking Strategies

| Strategy | Description | When to Use |
|:---------|:------------|:------------|
| **Shared library (.so)** | Default for Android. Loaded by `System.loadLibrary()`. | **Always for JNI libraries** |
| **Static library (.a)** | Used during build, linked into .so. | Internal build artifacts only |
| **Whole-archive static** | All symbols from .a included. | When you need to force-link symbols |
| **LTO (Link-Time Optimization)** | Cross-module optimization at link time. | Performance-critical code |

### 10.3 Static Linking Into Shared Library

```bash
# Build Astra runtime as static library
$TOOLCHAIN/bin/clang --target=aarch64-linux-android21 -O2 -c runtime.c -o runtime.o
$TOOLCHAIN/bin/llvm-ar rcs libastra_runtime.a runtime.o

# Link into final .so with everything statically included
$TOOLCHAIN/bin/clang --target=aarch64-linux-android21 \
    -shared \
    -Wl,--whole-archive libastra_runtime.a -Wl,--no-whole-archive \
    -Wl,--no-undefined \
    -lm -ldl \
    -o libastra_runtime.so
```

### 10.4 What to Link Statically vs Dynamically

| Library | Link Statically | Link Dynamically | Notes |
|:--------|:----------------|:-----------------|:------|
| Astra runtime | ✅ (into .so) | N/A | Self-contained |
| Astra stdlib | ✅ (into .so) | N/A | Minimize dependencies |
| libc (Bionic) | N/A | ✅ | Always dynamic. Part of Android. |
| libm | N/A | ✅ | Always dynamic. Part of Android. |
| libdl | N/A | ✅ | For dlopen/dlsym |
| liblog | N/A | ✅ | For __android_log_print |
| libz | N/A | ✅ | If compression needed |
| libGLESv2 | N/A | ✅ | If OpenGL needed |

### 10.5 Symbol Visibility

```bash
# Hide internal symbols in .so (reduce binary size, improve load time)
-Wl,--version-script=exports.map

# exports.map:
{
    global:
        Java_com_astralang_*;    # JNI functions (must be visible)
        astra_*;                  # Public C API
    local:
        *;                        # Hide everything else
};
```

---

## 11. Astra Android Strategy

### 11.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Android Application                     │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Java/Kotlin Layer                                  │   │
│  │  - MainActivity, UI, Android lifecycle              │   │
│  │  - System.loadLibrary("astra_runtime")              │   │
│  │  - native method declarations                       │   │
│  └──────────────────────┬──────────────────────────────┘   │
│                         │ JNI                               │
│  ┌──────────────────────▼──────────────────────────────┐   │
│  │  libastra_runtime.so                                │   │
│  │                                                     │   │
│  │  ┌─────────────────────────────────────────────┐   │   │
│  │  │  JNI Bridge Layer                           │   │   │
│  │  │  - RegisterNatives for fast dispatch        │   │   │
│  │  │  - Type marshaling (Astra ↔ Java)           │   │   │
│  │  │  - Error propagation                        │   │   │
│  │  └─────────────────────────────────────────────┘   │   │
│  │                                                     │   │
│  │  ┌─────────────────────────────────────────────┐   │   │
│  │  │  Astra Runtime                              │   │   │
│  │  │  - ARC/ORC memory management                │   │   │
│  │  │  - Fiber scheduler (M:N)                    │   │   │
│  │  │  - I/O system                               │   │   │
│  │  │  - Custom allocators                        │   │   │
│  │  └─────────────────────────────────────────────┘   │   │
│  │                                                     │   │
│  │  ┌─────────────────────────────────────────────┐   │   │
│  │  │  Astra Standard Library                     │   │   │
│  │  │  - android/ platform module                  │   │   │
│  │  │  - std/io, std/net, std/math                 │   │   │
│  │  └─────────────────────────────────────────────┘   │   │
│  │                                                     │   │
│  │  Platform: aarch64-linux-android21                  │   │
│  │  ABI: arm64-v8a (+ armeabi-v7a fallback)           │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Android Platform                                   │   │
│  │  - Bionic libc (libdl, libm, liblog)               │   │
│  │  - ART Runtime (GC, class loading, JNI)            │   │
│  │  - Android Framework (Activity, Intent, etc.)      │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 11.2 Astra Android Toolchain

```bash
# Cross-compilation command
astra build --target aarch64-linux-android21 \
            --output build/android/ \
            --shared \
            --release

# What this does internally:
# 1. Parse Astra source → AST → Type Check → AIR
# 2. AIR → LLVM IR (targeting aarch64-linux-android21)
# 3. LLVM IR → Object files (using NDK Clang as linker)
# 4. Object files → libastra_runtime.so (shared library)
```

### 11.3 Target Triples for Astra

```rust
// Astra target triples (matching NDK conventions)
"aarch64-linux-android21"    // arm64-v8a, minimum API 21
"armv7a-linux-androideabi21" // armeabi-v7a, minimum API 21
"i686-linux-android21"       // x86, minimum API 21
"x86_64-linux-android21"     // x86_64, minimum API 21
```

### 11.4 Astra Runtime on Android

#### Memory Management
- **ARC/ORC:** Works natively on Android. No interaction with ART's GC needed (separate heaps).
- **Atomic operations:** Use `__atomic_*` builtins which map to ARM's `LDXR/STXR` instructions.
- **Custom allocators:** Use `mmap` (available since API 21) for arena/bump allocators.

#### Fiber Scheduler
- **M:N scheduling:** Astra fibers run on pthreads. Android pthreads support `sched_setaffinity` (API 26+).
- **Stack size:** Default 2KB per fiber (configurable). Android's unified stack model works well.
- **Yield points:** Implemented as function calls with inline assembly for ARM.

#### I/O System
- **Non-blocking I/O:** Use `epoll` (available since API 21 on Bionic).
- **File operations:** Standard POSIX `open/read/write/close`.
- **Networking:** Standard BSD sockets (same as Linux).

### 11.5 Android-Specific Astra Module

```astra
// android/astra_runtime.astra
import android.os
import android.content

# Platform detection
val api_level = android.get_device_api_level()
val is_arm64 = android.arch() == "aarch64"

# JNI interop helpers
@jni_bridge
fn call_java(class_name: String, method: String, args: Array<Any>) -> Any {
    # Generated JNI bridge code
}

# Android lifecycle integration
trait AndroidLifecycle {
    fn on_create(ctx: ActivityContext)
    fn on_resume()
    fn on_pause()
    fn on_destroy()
}
```

### 11.6 Packaging Strategy

```
# Build produces:
build/android/
├── arm64-v8a/
│   └── libastra_runtime.so       # ~2-5 MB (with stdlib)
├── armeabi-v7a/
│   └── libastra_runtime.so       # ~2-4 MB
└── astra-stdlib.aar              # Android Archive with everything

# For distribution via Maven/Gradle:
# Publish AAR with embedded .so files
# Or publish .so files separately for manual inclusion
```

### 11.7 Performance Considerations

| Aspect | Strategy | Rationale |
|:-------|:---------|:----------|
| **NEON** | Always enabled on arm64-v8a | Mandatory. Use `float32x4_t` for vector ops. |
| **LTO** | Enable for release builds | Cross-module inlining reduces call overhead. |
| **ARC overhead** | Use `@ffi::direct` for hot FFI | Minimize JNI transitions for frequent calls. |
| **Fiber yield** | Use `entersyscall/exitsyscall` | Properly detach from OS thread during blocking I/O. |
| **Binary size** | `-ffunction-sections -fdata-sections -Wl,--gc-sections` | Strip unused code. Target 2-5 MB per ABI. |
| **Startup time** | AOT compile .so on build, not on device | No JIT warmup. Instant execution. |

### 11.8 Testing Strategy

```bash
# Cross-compilation tests
astra test --target aarch64-linux-android21
astra test --target armv7a-linux-androideabi21

# Emulator testing (x86_64)
astra test --target x86_64-linux-android21 --emulator

# Physical device testing
adb push libastra_runtime.so /data/local/tmp/
adb shell /data/local/tmp/astra_test

# JNI integration tests
./gradlew connectedAndroidTest
```

### 11.9 Phased Implementation Roadmap

```
Phase 1: Foundation (3-4 months)
├── Target triple support for Android in Astra compiler
├── LLVM IR generation for aarch64-linux-android21
├── NDK Clang integration as linker
├── Basic .so generation (no stdlib)
└── JNI bridge generation (basic)

Phase 2: Runtime (3-4 months)
├── Astra runtime on Bionic (libc, libm, libdl)
├── ARC/ORC on Android (atomic operations)
├── Fiber scheduler using pthreads
├── I/O system using epoll
└── Custom allocator support (mmap-based)

Phase 3: Integration (2-4 months)
├── Android-specific Astra module
├── Java/Kotlin ↔ Astra type marshaling
├── Lifecycle integration (Activity, Service)
├── AAR packaging for distribution
└── Android Studio plugin (optional)

Phase 4: Optimization (ongoing)
├── NEON-optimized stdlib functions
├── Profile-guided optimization support
├── ARM-specific intrinsics for hot paths
├── Binary size optimization
└── Performance benchmarking suite
```

---

## Appendix A: Key Files and References

### NDK Documentation
- [NDK Guide](https://developer.android.com/ndk/guides)
- [Build System Maintainers Guide](https://android.googlesource.com/platform/ndk/+/refs/heads/main/docs/BuildSystemMaintainers.md)
- [Native APIs](https://developer.android.com/ndk/guides/stable_apis)
- [Android ABIs](https://developer.android.com/ndk/guides/abis)
- [NEON Support](https://developer.android.com/ndk/guides/cpu-arm-neon)

### ART Runtime
- [ART Source](https://android.googlesource.com/platform/art/)
- [libnativeloader](https://android.googlesource.com/platform/art/+/refs/heads/main/libnativeloader/)
- [dex2oat](https://android.googlesource.com/platform/art/+/refs/heads/main/dex2oat/)
- [Concurrent Copying GC](https://android.googlesource.com/platform/art/+/refs/heads/main/runtime/gc/collector/concurrent_copying.cc)

### Bionic
- [Bionic Source](https://android.googlesource.com/platform/bionic/)
- [Bionic API Status](https://android.googlesource.com/platform/bionic/+/refs/heads/main/docs/status.md)
- [API Level Header](https://android.googlesource.com/platform/bionic/+/main/libc/include/android/api-level.h)

### ARM Architecture
- [ARM NEON Programmer's Guide](https://developer.arm.com/documentation/den0018/latest/)
- [ARM C Language Extensions (ACLE)](https://developer.arm.com/documentation/ihi0053/latest)
- [ARM Architecture Reference Manual](https://developer.arm.com/documentation/ddi0487/latest)

---

## Appendix B: Astra Android Quick Reference

```bash
# Install NDK
sdkmanager "ndk;27.0.12077973"

# Set environment
export NDK=$ANDROID_HOME/ndk/27.0.12077973
export TARGET=aarch64-linux-android
export API=21
export TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64

# Compile Astra to shared library for Android
astra build --target ${TARGET}${API} --shared --release \
    -o libastra_runtime.so

# Verify the binary
$TOOLCHAIN/bin/llvm-readelf -h libastra_runtime.so
# Expected: Machine: AArch64

$TOOLCHAIN/bin/llvm-readelf -d libastra_runtime.so
# Expected: NEEDED: [libc.so], NEEDED: [libm.so], NEEDED: [libdl.so]

# Test on device
adb push libastra_runtime.so /data/local/tmp/
adb shell "LD_LIBRARY_PATH=/data/local/tmp /data/local/tmp/astra_test"
```

---

*This report provides the technical foundation for Astra's Android integration. The strategy centers on leveraging Astra's existing LLVM backend and C code generation to cross-compile for Android via NDK Clang, with JNI as the primary interop mechanism and Bionic as the C runtime.*
