# CSOM × Yk JIT Integration: Changes and Rationale

This document records every change made to integrate CSOM with the
[Yk meta-tracing JIT](https://github.com/ykjit/yk), explains why each change
was needed, and assesses whether it is safe to keep.

---

## 1. Yk runtime wiring

### 1.1 `YkMT` initialisation and shutdown — `src/vm/Universe.c`, `src/vm/Universe.h`

**What changed.**

`Universe.h` exposes the global Yk meta-tracer handle under `USE_YK`:

```c
#ifdef USE_YK
#include <yk.h>
extern YkMT *global_yk_mt;
#endif
```

`Universe.c` allocates it at startup and frees it at shutdown:

```c
#ifdef USE_YK
YkMT *global_yk_mt = NULL;
#endif

void Universe_start(...) {
#ifdef USE_YK
    char *yk_err = NULL;
    global_yk_mt = yk_mt_new(&yk_err);
    if (yk_err != NULL) {
        fprintf(stderr, "[YK] init failed: %s\n", yk_err);
        free(yk_err);
        global_yk_mt = NULL;
    }
#endif
    ...
}

void Universe_destruct(void) {
    ...
#ifdef USE_YK
    if (global_yk_mt != NULL) {
        yk_mt_shutdown(global_yk_mt);
        global_yk_mt = NULL;
    }
#endif
}
```

**Why.**
`YkMT` is Yk's meta-tracer object; every Yk-integrated program creates exactly
one at startup and destroys it on exit.  It must be globally accessible because
`Universe_start` creates it, but `Interpreter_start` (a separate translation
unit) passes it to every control-point call.

---

### 1.2 Per-bytecode `YkLocation` array — `src/vmobjects/VMMethod.c`, `src/vmobjects/VMMethod.h`

**What changed.**

`VMMethod.h` adds a `yklocs` field to the method struct:

```c
struct _VMMethod {
    VTABLE(VMMethod)* _vtable;
    METHOD_FORMAT;
#ifdef USE_YK
    void *yklocs;  /* YkLocation array, one per bytecode */
#endif
};
```

`VMMethod.c` allocates and initialises the array when a method is created, and
provides a cleanup function:

```c
void _VMMethod_init(void* _self, ...) {
    ...
#ifdef USE_YK
    if (self->bytecodes_length > 0) {
        self->yklocs = malloc(self->bytecodes_length * sizeof(YkLocation));
        if (self->yklocs != NULL) {
            for (size_t i = 0; i < self->bytecodes_length; i++)
                ((YkLocation*)self->yklocs)[i] = yk_location_new();
        }
    }
#endif
}

void VMMethod_cleanup_yklocs(pVMMethod method) {
    YkLocation* locs = (YkLocation*)method->yklocs;
    for (size_t i = 0; i < method->bytecodes_length; i++)
        if (!yk_location_is_null(locs[i]))
            yk_location_drop(locs[i]);
    free(method->yklocs);
    method->yklocs = NULL;
}
```

**Why.**
Yk's control point takes a `YkLocation*` that identifies the hot loop being
traced.  Separate location objects are required for each bytecode index in each
method so the tracer can distinguish different loops.  Allocating them at method
creation time (rather than lazily at the control point) keeps the hot dispatch
loop free of allocation.
---

### 1.3 Control point in the dispatch loop — `src/interpreter/Interpreter.c`

**What changed.**

```c
#ifdef USE_YK
#include <yk.h>
#endif

void Interpreter_start(void) {
    ...
    while (...) {
        SEND(_FRAME, set_bytecode_index, next_bytecode_index);

#ifdef USE_YK
        yk_mt_control_point(global_yk_mt,
            &((YkLocation*)method->yklocs)[bytecode_index]);
#endif
        switch(bytecode) { ... }
    }
}
```

**Why.**
`yk_mt_control_point` is the call that tells Yk "I am at this point in the
hot loop".  Yk counts how many times each `YkLocation` is reached; once the
threshold is exceeded it begins tracing.

---

## 2. Build system — `build/unix.make`

### 2.1 Yk compiler and linker flags

**What changed.**
Added a Yk-specific block at the top of `unix.make` (guarded by
`ifneq ($(strip $(YK_BUILD_TYPE)),)`):

```makefile
YK_CPPFLAGS := $(shell yk-config ${YK_BUILD_TYPE} --cppflags | sed 's/ *-DUSE_YK//')
YK_CFLAGS   := $(shell yk-config ${YK_BUILD_TYPE} --cflags)
YK_LDFLAGS  := $(shell yk-config ${YK_BUILD_TYPE} --ldflags)
YK_LIBS     := $(shell yk-config ${YK_BUILD_TYPE} --libs)
YK_CC       := $(shell yk-config ${YK_BUILD_TYPE} --cc)
YK_DEFINE   = -DUSE_YK
```

`YK_CFLAGS` expands to (at time of writing):

```
-flto -fyk-noinline-funcs-with-loops
-mllvm -yk-dont-opt-func-abi
-mllvm -yk-patch-control-point
-mllvm -yk-no-vectorize
```

---

### 2.2 Single-binary build — primitives linked into CSOM directly

**What changed.**

Before:

```makefile
PRIMITIVES_OBJ = $(PRIMITIVES_SRC:.c=.pic.o)   # -fPIC, shared lib objects

.c.pic.o:
    $(YK_CC) $(CFLAGS) -fPIC -c $< -o $*.pic.o

CORE: core-lib/.gitignore $(PRIMITIVES_OBJ)
    $(CC_LINK) $(LDFLAGS_LIB) ... -o SOMCore.so $(PRIMITIVES_OBJ) -lm
    mv SOMCore.so Smalltalk/

$(SRC_DIR)/CSOM: $(CSOM_OBJ) CORE
    $(CC_LINK) $(LDFLAGS) ... $(CSOM_OBJ) -ldl
```

After:

```makefile
PRIMITIVES_OBJ = $(PRIMITIVES_SRC:.c=.o)   # regular objects, no -fPIC

CSOM_OBJ = $(MEMORY_OBJ) ... $(VM_OBJ) $(PRIMITIVES_OBJ)

$(SRC_DIR)/CSOM: $(CSOM_OBJ)
    $(CC_LINK) $(LDFLAGS) ... $(CSOM_OBJ) -ldl -lm
```

The `CORE` / `SOMCore.so` build target, `LDFLAGS_LIB`, `YK_LDFLAGS_LIB`, and
the `.c.pic.o` suffix rule are removed entirely.  `-lm` moved from the
now-deleted `CORE_LIBS` into `CSOM_LIBS`.

**Why.**
Yk resolves global-variable addresses at runtime via `dlsym`.  With the
original two-binary layout (`CSOM` + `SOMCore.so`), each binary was processed
by the Yk LTO pass in a separate link invocation.  The `--export-dynamic` flag
that `yk-config --ldflags` supplies applies only to the binary being linked;
it cannot promote symbols in a separately-linked shared library.

Collapsing everything into one binary means:

1. The Yk LTO pass sees the complete program in a single invocation, exactly
   as in yklua and ykmicropython.
2. `--export-dynamic` covers every global in the one binary.
3. All symbols are findable by `dlsym` at JIT runtime.

**Safety.**
Linking without `-fPIC` is correct for a position-dependent executable; no code
dynamically loads the primitives at a different address.  The `load_lib` change
in §3 removes any remaining reliance on the `.so` path.  Non-Yk builds continue
to use the same object files; the only visible difference is that `SOMCore.so`
is no longer produced.

---

## 3. Primitive loading — `src/vmobjects/VMClass.c`

### 3.1 `load_lib` changed to open the main executable

**What changed.**

Before:

```c
void* load_lib(const pString restrict path) {
    static void* handle = NULL;
    if ((handle = dlopen(SEND(path, rawChars), DL_LOADMODE)))
        return handle;
    else { printf("dlopen failed: %s\n", dlerror()); return NULL; }
}
```

After:

```c
void* load_lib(const pString restrict path) {
    // Primitives are linked statically into the CSOM binary. Open the main
    // executable (NULL) so dlsym finds supports_class, init_csp, and all
    // _ClassName_method symbols without loading a separate shared library.
    // RTLD_DEFAULT is ((void*)0) on Linux and cannot be used as a handle.
    (void)path;
    return dlopen(NULL, RTLD_LAZY);
}
```

**Why.**
`_VMClass_load_primitives` calls `load_lib` to obtain a handle from which it
looks up `supports_class`, `init_csp`, and every `_ClassName_method` symbol
via `dlsym`.  In the single-binary build these symbols live in the CSOM
executable itself.  `dlopen(NULL, ...)` returns a handle for the running
process; `dlsym` against it searches the main binary and its dependencies.

`RTLD_DEFAULT` is defined as `((void*)0)` on Linux — numerically NULL — which
causes the `if (!dlhandle)` failure check in `_VMClass_load_primitives` to
falsely report a load failure.  `dlopen(NULL)` returns a proper non-NULL handle.

**Safety.**
`is_responsible`, `init_lib`, and `set_primitives` are unchanged.  All `dlsym`
calls work identically; they now search the executable rather than a `.so` file
but find the same symbols.  The `init_csp` double-init guard (`static bool
initialized = false` in `Core.c`) correctly prevents re-initialisation.
