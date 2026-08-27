#import "IVAntiTamper.h"
#import "../vendor/fishhook/fishhook.h"

#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <sys/types.h>
#import <sys/syscall.h>
#import <sys/sysctl.h>
#import <sys/proc.h>
#import <unistd.h>
#import <string.h>
#import <stdint.h>
#import <stdarg.h>
#import <stdio.h>
#import <os/lock.h>

#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif
#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif

// Tiny stderr logger — safe from the earliest constructor (no Foundation).
#define IVAT_LOG(...) do { fprintf(stderr, "[IVAntiTamper] " __VA_ARGS__); fprintf(stderr, "\n"); } while (0)

#pragma mark - State

static BOOL gInstalled = NO;
static const struct mach_header *gSelfHeader = NULL;  // this dylib's own image

// Saved originals (filled by fishhook at rebind time).
static uint32_t                  (*orig_image_count)(void)                          = NULL;
static const char *              (*orig_image_name)(uint32_t)                        = NULL;
static const struct mach_header *(*orig_image_header)(uint32_t)                      = NULL;
static intptr_t                  (*orig_image_slide)(uint32_t)                       = NULL;
static void                      (*orig_register_add)(void (*)(const struct mach_header *, intptr_t)) = NULL;
static int                       (*orig_dladdr)(const void *, Dl_info *)             = NULL;
static int                       (*orig_ptrace)(int, pid_t, caddr_t, int)           = NULL;
static long                      (*orig_syscall)(int, ...)                           = NULL;
static int                       (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;

#pragma mark - Image hiding (make THIS dylib invisible to dyld enumeration)

// Tinder scans the loaded-image list at launch and aborts when it finds a dylib
// that is not part of the original bundle (the classic _dyld_image_count +
// _dyld_get_image_name anti-injection sweep — same shape as GeoShift's
// detectDynamicLibraryInjection). We give every enumerator a view of the list
// with OUR row removed and the surrounding rows renumbered around it. Every
// value returned is the REAL name/header/slide of a surviving image — only our
// own entry is omitted, so the sweep never sees the injected library.

static uint32_t iv_self_real_index(void) {
    if (!gSelfHeader || !orig_image_count || !orig_image_header) return UINT32_MAX;
    uint32_t c = orig_image_count();
    for (uint32_t i = 0; i < c; i++)
        if (orig_image_header(i) == gSelfHeader) return i;
    return UINT32_MAX;
}

static uint32_t iv_real_index_for_public(uint32_t pub) {
    uint32_t self = iv_self_real_index();
    if (self == UINT32_MAX) return pub;      // not loaded (yet) → identity
    return pub < self ? pub : pub + 1;       // skip our slot
}

static uint32_t iv_image_count(void) {
    uint32_t c = orig_image_count ? orig_image_count() : 0;
    return (c > 0 && iv_self_real_index() != UINT32_MAX) ? c - 1 : c;
}
static const char *iv_image_name(uint32_t i) {
    return orig_image_name ? orig_image_name(iv_real_index_for_public(i)) : NULL;
}
static const struct mach_header *iv_image_header(uint32_t i) {
    return orig_image_header ? orig_image_header(iv_real_index_for_public(i)) : NULL;
}
static intptr_t iv_image_slide(uint32_t i) {
    return orig_image_slide ? orig_image_slide(iv_real_index_for_public(i)) : 0;
}

#pragma mark - add-image callback filtering

// _dyld_register_func_for_add_image replays every already-loaded image to the
// caller synchronously, then delivers future ones. A caller registered AFTER us
// (Tinder / Sentry) must not receive our image. We slot each callback behind a
// dedicated trampoline that drops our header and forwards the rest. dyld drives
// these under its own lock, so the hot path stays lock-free.
#define IV_MAX_ADDCB 8
static void (*gAddFuncs[IV_MAX_ADDCB])(const struct mach_header *, intptr_t);
static int gAddCount = 0;
static os_unfair_lock gAddLock = OS_UNFAIR_LOCK_INIT;

static void iv_add_dispatch(int slot, const struct mach_header *mh, intptr_t slide) {
    if (mh == gSelfHeader) return;                       // hide the injected image
    void (*f)(const struct mach_header *, intptr_t) = gAddFuncs[slot];
    if (f) f(mh, slide);
}
#define IV_TRAMP(n) static void iv_add_tramp_##n(const struct mach_header *mh, intptr_t s) { iv_add_dispatch(n, mh, s); }
IV_TRAMP(0) IV_TRAMP(1) IV_TRAMP(2) IV_TRAMP(3)
IV_TRAMP(4) IV_TRAMP(5) IV_TRAMP(6) IV_TRAMP(7)
static void (*const gAddTramps[IV_MAX_ADDCB])(const struct mach_header *, intptr_t) = {
    iv_add_tramp_0, iv_add_tramp_1, iv_add_tramp_2, iv_add_tramp_3,
    iv_add_tramp_4, iv_add_tramp_5, iv_add_tramp_6, iv_add_tramp_7,
};

static void iv_register_add(void (*func)(const struct mach_header *, intptr_t)) {
    os_unfair_lock_lock(&gAddLock);
    int slot = (gAddCount < IV_MAX_ADDCB) ? gAddCount++ : -1;
    if (slot >= 0) gAddFuncs[slot] = func;
    os_unfair_lock_unlock(&gAddLock);
    if (!orig_register_add) return;
    if (slot < 0) { orig_register_add(func); return; }   // overflow → unfiltered
    orig_register_add(gAddTramps[slot]);                 // dyld replays existing images now
}

static int iv_dladdr(const void *addr, Dl_info *info) {
    int r = orig_dladdr ? orig_dladdr(addr, info) : 0;
    if (r && info && gSelfHeader && info->dli_fbase == (const void *)gSelfHeader)
        return 0;                                        // address resolves to "no image"
    return r;
}

#pragma mark - Anti-debug (defeat RASP self-checks that abort when "traced")

static int iv_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    if (request == PT_DENY_ATTACH) return 0;             // swallow the self-deny
    if (orig_ptrace) return orig_ptrace(request, pid, addr, data);
    return (int)syscall(SYS_ptrace, request, pid, addr, data);
}

static long iv_syscall(int number, ...) {
    va_list ap; va_start(ap, number);
    long a0 = va_arg(ap, long), a1 = va_arg(ap, long), a2 = va_arg(ap, long),
         a3 = va_arg(ap, long), a4 = va_arg(ap, long), a5 = va_arg(ap, long);
    va_end(ap);
    if (number == SYS_ptrace && a0 == PT_DENY_ATTACH) return 0;
    if (orig_syscall) return orig_syscall(number, a0, a1, a2, a3, a4, a5);
    return 0;
}

static int iv_sysctl(int *name, u_int nl, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int r = orig_sysctl ? orig_sysctl(name, nl, oldp, oldlenp, newp, newlen) : -1;
    // Clear P_TRACED so a KERN_PROC self-query never reports a debugger.
    if (r == 0 && oldp && oldlenp && name && nl >= 4 &&
        name[0] == CTL_KERN && name[1] == KERN_PROC && name[2] == KERN_PROC_PID &&
        *oldlenp >= sizeof(struct kinfo_proc)) {
        struct kinfo_proc *kp = (struct kinfo_proc *)oldp;
        kp->kp_proc.p_flag &= ~P_TRACED;
    }
    return r;
}

#pragma mark - Install

@implementation IVAntiTamper

+ (void)install {
    if (gInstalled) return;
    gInstalled = YES;

    // Identify our own image BEFORE rebinding, via the real dladdr (our hook is
    // not armed yet). The address of a static in this file resolves to this
    // dylib's mach_header through Dl_info.dli_fbase.
    Dl_info info;
    if (dladdr((const void *)&gInstalled, &info)) gSelfHeader = (const struct mach_header *)info.dli_fbase;

    struct rebinding rb[16];
    int n = 0;
    rb[n++] = (struct rebinding){"_dyld_image_count",                (void *)iv_image_count,   (void **)&orig_image_count};
    rb[n++] = (struct rebinding){"_dyld_get_image_name",             (void *)iv_image_name,    (void **)&orig_image_name};
    rb[n++] = (struct rebinding){"_dyld_get_image_header",           (void *)iv_image_header,  (void **)&orig_image_header};
    rb[n++] = (struct rebinding){"_dyld_get_image_vmaddr_slide",     (void *)iv_image_slide,   (void **)&orig_image_slide};
    rb[n++] = (struct rebinding){"_dyld_register_func_for_add_image",(void *)iv_register_add,  (void **)&orig_register_add};
    rb[n++] = (struct rebinding){"dladdr",                           (void *)iv_dladdr,        (void **)&orig_dladdr};
    rb[n++] = (struct rebinding){"ptrace",                           (void *)iv_ptrace,        (void **)&orig_ptrace};
    rb[n++] = (struct rebinding){"syscall",                          (void *)iv_syscall,       (void **)&orig_syscall};
    rb[n++] = (struct rebinding){"sysctl",                           (void *)iv_sysctl,        (void **)&orig_sysctl};
    int rc = rebind_symbols(rb, n);
    IVAT_LOG("armed rc=%d self=%p hidden_real_index=%u", rc, (void *)gSelfHeader, iv_self_real_index());
}

@end

// Priority 101 → runs before Bootstrap's default-priority constructor, so the
// shield is up before any of our own (or the app's later) code touches dyld.
__attribute__((constructor(101)))
static void IVAntiTamperCtor(void) {
#ifndef TINDERVAULT_INERT
    [IVAntiTamper install];
#endif
}
