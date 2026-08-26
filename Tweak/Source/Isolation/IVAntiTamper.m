#import "IVAntiTamper.h"
#import "../vendor/fishhook/fishhook.h"

#import <mach-o/dyld.h>
#import <sys/syscall.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/proc.h>
#import <unistd.h>
#import <fcntl.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <errno.h>
#import <stdint.h>
#import <stdarg.h>
#import <limits.h>
#import <os/lock.h>

#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif
#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif

// A tiny stderr logger — safe from the earliest constructor (no Foundation, no
// CoreFoundation, just a write(2) to fd 2 which we never hook). Never called
// from inside a read/open hot path.
#define IVAT_LOG(...) do { fprintf(stderr, "[IVAntiTamper] " __VA_ARGS__); fprintf(stderr, "\n"); } while (0)

#pragma mark - Baseline (pristine header bytes staged in the bundle at CI time)

// ivbaseline.bin layout (little-endian): "IVB1", u32 regionCount,
// then per region: u64 fileOffset, u64 length, <length> bytes.
#define IVAT_MAX_REGIONS 8
typedef struct { off_t off; size_t len; uint8_t *bytes; } IVATRegion;
static IVATRegion gRegions[IVAT_MAX_REGIONS];
static int        gRegionCount = 0;

#pragma mark - State

static BOOL gInstalled = NO;
static BOOL gArmed     = NO;           // set true only after all origs are saved
static char gMainReal[PATH_MAX] = {0}; // realpath of the main executable
static const char *gMainBase = NULL;   // basename within gMainReal (fast pre-filter)

// Saved originals. NOCANCEL variants share the same replacement; each keeps its
// own slot (fishhook writes one per rebinding) and we call whichever is non-NULL.
static ssize_t (*orig_read)(int, void *, size_t)            = NULL;
static ssize_t (*orig_read_nc)(int, void *, size_t)         = NULL;
static ssize_t (*orig_pread)(int, void *, size_t, off_t)    = NULL;
static ssize_t (*orig_pread_nc)(int, void *, size_t, off_t) = NULL;
static off_t   (*orig_lseek)(int, off_t, int)               = NULL;
static int     (*orig_open)(const char *, int, ...)         = NULL;
static int     (*orig_open_nc)(const char *, int, ...)      = NULL;
static int     (*orig_openat)(int, const char *, int, ...)  = NULL;
static int     (*orig_openat_nc)(int, const char *, int, ...) = NULL;
static int     (*orig_close)(int)                           = NULL;
static int     (*orig_close_nc)(int)                        = NULL;
static int     (*orig_ptrace)(int, pid_t, caddr_t, int)     = NULL;
static long    (*orig_syscall)(int, ...)                    = NULL;
static int     (*orig_sysctl_at)(int *, u_int, void *, size_t *, void *, size_t) = NULL;

#pragma mark - fd tracking (only fds opened on the main-executable path)

#define IVAT_MAX_FDS 64
static struct { int fd; off_t off; } gFds[IVAT_MAX_FDS];
static int gFdCount = 0;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

static void iv_track_add(int fd) {
    os_unfair_lock_lock(&gLock);
    if (gFdCount < IVAT_MAX_FDS) { gFds[gFdCount].fd = fd; gFds[gFdCount].off = 0; gFdCount++; }
    os_unfair_lock_unlock(&gLock);
}
// Returns the tracked offset for fd, or -1 if fd is not tracked.
static off_t iv_track_off(int fd) {
    off_t r = -1;
    os_unfair_lock_lock(&gLock);
    for (int i = 0; i < gFdCount; i++) if (gFds[i].fd == fd) { r = gFds[i].off; break; }
    os_unfair_lock_unlock(&gLock);
    return r;
}
static void iv_track_setoff(int fd, off_t off) {
    os_unfair_lock_lock(&gLock);
    for (int i = 0; i < gFdCount; i++) if (gFds[i].fd == fd) { gFds[i].off = off; break; }
    os_unfair_lock_unlock(&gLock);
}
static void iv_track_remove(int fd) {
    os_unfair_lock_lock(&gLock);
    for (int i = 0; i < gFdCount; i++) if (gFds[i].fd == fd) { gFds[i] = gFds[--gFdCount]; break; }
    os_unfair_lock_unlock(&gLock);
}

#pragma mark - Main-executable path + baseline loading (both before rebinding)

static const char *iv_basename(const char *p) {
    const char *b = strrchr(p, '/');
    return b ? b + 1 : p;
}

static void iv_resolve_main_path(void) {
    const char *n = _dyld_get_image_name(0);      // index 0 == main executable
    if (!n) { gMainReal[0] = '\0'; return; }
    if (!realpath(n, gMainReal)) strlcpy(gMainReal, n, sizeof(gMainReal));
    gMainBase = iv_basename(gMainReal);
}

// True when `path` refers to the main executable. Cheap basename check first,
// then a realpath comparison only on a basename match.
static BOOL iv_is_main_path(const char *path) {
    if (!path || !gMainBase || gMainReal[0] == '\0') return NO;
    if (strcmp(iv_basename(path), gMainBase) != 0) return NO;   // fast reject
    char rp[PATH_MAX];
    if (realpath(path, rp)) return strcmp(rp, gMainReal) == 0;
    return strcmp(path, gMainReal) == 0;
}

// Loads ivbaseline.bin from the app bundle (dir of the main executable). Uses
// the REAL open/read directly — called BEFORE rebinding, so no hook fires and
// no recursion is possible. Silent no-op on any error (redirect stays disabled).
static void iv_load_baseline(void) {
    if (gMainReal[0] == '\0') return;
    char path[PATH_MAX];
    strlcpy(path, gMainReal, sizeof(path));
    char *slash = strrchr(path, '/');
    if (!slash) return;
    *slash = '\0';                                  // -> .../Tinder.app
    strlcat(path, "/ivbaseline.bin", sizeof(path));

    int fd = open(path, O_RDONLY);
    if (fd < 0) { IVAT_LOG("no baseline (%s) — redirect disabled, anti-debug only", strerror(errno)); return; }

    uint8_t hdr[8];
    if (read(fd, hdr, 8) != 8 || memcmp(hdr, "IVB1", 4) != 0) { close(fd); IVAT_LOG("baseline bad magic"); return; }
    uint32_t count; memcpy(&count, hdr + 4, 4);
    if (count == 0 || count > IVAT_MAX_REGIONS) { close(fd); IVAT_LOG("baseline bad count=%u", count); return; }

    for (uint32_t i = 0; i < count; i++) {
        uint8_t meta[16];
        if (read(fd, meta, 16) != 16) { IVAT_LOG("baseline truncated meta"); break; }
        uint64_t off, len; memcpy(&off, meta, 8); memcpy(&len, meta + 8, 8);
        if (len == 0 || len > (64u * 1024u * 1024u)) { IVAT_LOG("baseline bad len=%llu", len); break; }
        uint8_t *b = malloc((size_t)len);
        if (!b) break;
        if (read(fd, b, (size_t)len) != (ssize_t)len) { free(b); IVAT_LOG("baseline truncated data"); break; }
        gRegions[gRegionCount].off = (off_t)off;
        gRegions[gRegionCount].len = (size_t)len;
        gRegions[gRegionCount].bytes = b;
        gRegionCount++;
    }
    close(fd);
    IVAT_LOG("baseline loaded: %d region(s)", gRegionCount);
}

// Overlays pristine bytes onto a buffer that holds file bytes [fileOff, fileOff+n).
static void iv_overlay(off_t fileOff, void *buf, size_t n) {
    for (int i = 0; i < gRegionCount; i++) {
        off_t a = fileOff > gRegions[i].off ? fileOff : gRegions[i].off;
        off_t bEnd = (off_t)(fileOff + (off_t)n);
        off_t rEnd = (off_t)(gRegions[i].off + (off_t)gRegions[i].len);
        off_t b = bEnd < rEnd ? bEnd : rEnd;
        if (a < b) {
            memcpy((uint8_t *)buf + (a - fileOff),
                   gRegions[i].bytes + (a - gRegions[i].off),
                   (size_t)(b - a));
        }
    }
}

#pragma mark - File-read hooks (redirect self-reads to the pristine baseline)

static int iv_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    int (*o)(const char *, int, ...) = orig_open ? orig_open : orig_open_nc;
    int fd = o ? o(path, flags, mode) : -1;
    if (fd >= 0 && gRegionCount > 0 && iv_is_main_path(path)) iv_track_add(fd);
    return fd;
}

static int iv_openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    int (*o)(int, const char *, int, ...) = orig_openat ? orig_openat : orig_openat_nc;
    int fd = o ? o(dirfd, path, flags, mode) : -1;
    // Only absolute paths can be matched against the resolved main-exec path.
    if (fd >= 0 && gRegionCount > 0 && path && path[0] == '/' && iv_is_main_path(path)) iv_track_add(fd);
    return fd;
}

static ssize_t iv_read(int fd, void *buf, size_t n) {
    ssize_t (*o)(int, void *, size_t) = orig_read ? orig_read : orig_read_nc;
    ssize_t k = o ? o(fd, buf, n) : -1;
    // Lock-free fast reject: no main-exec fd is open, so nothing to overlay.
    if (k > 0 && gRegionCount > 0 && gFdCount > 0) {
        off_t off = iv_track_off(fd);
        if (off >= 0) {                             // fd is the main executable
            iv_overlay(off, buf, (size_t)k);
            iv_track_setoff(fd, off + k);           // read(2) advances the offset
        }
    }
    return k;
}

static ssize_t iv_pread(int fd, void *buf, size_t n, off_t offset) {
    ssize_t (*o)(int, void *, size_t, off_t) = orig_pread ? orig_pread : orig_pread_nc;
    ssize_t k = o ? o(fd, buf, n, offset) : -1;
    if (k > 0 && gRegionCount > 0 && gFdCount > 0 && iv_track_off(fd) >= 0) iv_overlay(offset, buf, (size_t)k);
    return k;                                       // pread does NOT move the fd offset
}

static off_t iv_lseek(int fd, off_t offset, int whence) {
    off_t r = orig_lseek ? orig_lseek(fd, offset, whence) : -1;
    if (r >= 0 && gFdCount > 0 && iv_track_off(fd) >= 0) iv_track_setoff(fd, r);
    return r;
}

static int iv_close(int fd) {
    if (gFdCount > 0) iv_track_remove(fd);
    int (*o)(int) = orig_close ? orig_close : orig_close_nc;
    return o ? o(fd) : -1;
}

#pragma mark - Anti-debug hooks (RASP self-checks that abort when "traced")

static int iv_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    if (request == PT_DENY_ATTACH) return 0;        // swallow — the classic abort trigger
    if (orig_ptrace) return orig_ptrace(request, pid, addr, data);
    return (int)syscall(SYS_ptrace, request, pid, addr, data);
}

// Some anti-debug code calls ptrace via the raw syscall stub instead of the libc
// wrapper. Sniff SYS_ptrace(PT_DENY_ATTACH) and swallow it.
static long iv_syscall(int number, ...) {
    va_list ap; va_start(ap, number);
    long a0 = va_arg(ap, long), a1 = va_arg(ap, long), a2 = va_arg(ap, long),
         a3 = va_arg(ap, long), a4 = va_arg(ap, long), a5 = va_arg(ap, long);
    va_end(ap);
    if (number == SYS_ptrace && a0 == PT_DENY_ATTACH) return 0;
    if (orig_syscall) return orig_syscall(number, a0, a1, a2, a3, a4, a5);
    return 0;
}

// Clear the P_TRACED bit from sysctl(KERN_PROC, KERN_PROC_PID) so a debugger-
// presence check reads clean. Chains correctly with IVDeviceSpoof's own sysctl
// hook (fishhook links the two; each calls its saved original).
static int iv_sysctl(int *name, u_int nl, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int r = orig_sysctl_at ? orig_sysctl_at(name, nl, oldp, oldlenp, newp, newlen) : -1;
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

    // 1. Resolve the main executable and load the pristine baseline BEFORE
    //    rebinding, so the loader's own reads use the real syscalls.
    iv_resolve_main_path();
    iv_load_baseline();

    // 2. Rebind. Read-redirect symbols are only wired when a baseline exists;
    //    anti-debug symbols are always wired (cheap, no state needed).
    struct rebinding rb[20];
    int n = 0;
    rb[n++] = (struct rebinding){"ptrace",  (void *)iv_ptrace,  (void **)&orig_ptrace};
    rb[n++] = (struct rebinding){"syscall", (void *)iv_syscall, (void **)&orig_syscall};
    rb[n++] = (struct rebinding){"sysctl",  (void *)iv_sysctl,  (void **)&orig_sysctl_at};
    if (gRegionCount > 0) {
        rb[n++] = (struct rebinding){"open",             (void *)iv_open,   (void **)&orig_open};
        rb[n++] = (struct rebinding){"open$NOCANCEL",     (void *)iv_open,   (void **)&orig_open_nc};
        rb[n++] = (struct rebinding){"openat",           (void *)iv_openat, (void **)&orig_openat};
        rb[n++] = (struct rebinding){"openat$NOCANCEL",   (void *)iv_openat, (void **)&orig_openat_nc};
        rb[n++] = (struct rebinding){"read",             (void *)iv_read,   (void **)&orig_read};
        rb[n++] = (struct rebinding){"read$NOCANCEL",     (void *)iv_read,   (void **)&orig_read_nc};
        rb[n++] = (struct rebinding){"pread",            (void *)iv_pread,  (void **)&orig_pread};
        rb[n++] = (struct rebinding){"pread$NOCANCEL",    (void *)iv_pread,  (void **)&orig_pread_nc};
        rb[n++] = (struct rebinding){"lseek",            (void *)iv_lseek,  (void **)&orig_lseek};
        rb[n++] = (struct rebinding){"close",            (void *)iv_close,  (void **)&orig_close};
        rb[n++] = (struct rebinding){"close$NOCANCEL",    (void *)iv_close,  (void **)&orig_close_nc};
    }
    int rc = rebind_symbols(rb, n);
    gArmed = YES;
    IVAT_LOG("armed: rc=%d symbols=%d redirect=%s main=%s",
             rc, n, gRegionCount > 0 ? "on" : "off", gMainReal[0] ? gMainReal : "?");
}

@end

__attribute__((constructor(101)))
static void IVAntiTamperCtor(void) {
#ifndef TINDERVAULT_INERT
    // Earliest priority so the hooks are armed before the host's integrity /
    // anti-debug initializers run. Pure C path — no Foundation touched here.
    // (Skipped in the INERT diagnostic build so it stays a true no-op baseline.)
    [IVAntiTamper install];
#endif
}
