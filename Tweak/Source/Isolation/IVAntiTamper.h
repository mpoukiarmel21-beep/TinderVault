#import <Foundation/Foundation.h>

// IVAntiTamper — substrate-free defense against a hardened host (Tinder / Match
// Group) that aborts at launch when it detects a foreign dylib has been injected
// into its process.
//
// Two countermeasures, both installed from the earliest possible constructor
// (priority 101) so they are armed BEFORE the host's own anti-injection /
// anti-debug code runs — an injected dylib's initializers run before the main
// image's:
//
//   1. dyld image hiding. Tinder sweeps the loaded-image list at launch
//      (_dyld_image_count + _dyld_get_image_name, the same shape as GeoShift's
//      detectDynamicLibraryInjection) and aborts when it finds a library that
//      is not part of the original bundle. We fishhook the dyld enumeration
//      surface — _dyld_image_count / _dyld_get_image_name / _get_image_header /
//      _get_image_vmaddr_slide, the _dyld_register_func_for_add_image replay,
//      and dladdr — to present a view of the image list with THIS dylib's row
//      removed and the survivors renumbered around it. The scan never sees the
//      injected library; every other value returned is real.
//
//   2. Anti-debug neutralization. ptrace(PT_DENY_ATTACH) / syscall(SYS_ptrace)
//      swallowed, and the P_TRACED bit cleared from sysctl(KERN_PROC) results,
//      so a RASP self-check that aborts when "traced/tamperable" stays quiet.
//
// This CANNOT beat a kernel/AMFI code-signature failure (that happens before any
// of our code runs) — but a valid re-sign satisfies AMFI (Instagram/Threads
// prove the pipeline is sound through the byte-identical inject+sign flow), and
// those apps launch WITHOUT any image hiding, so a Tinder-specific in-process
// image sweep is the live differentiator. See AGENT-HANDOFF.md.
@interface IVAntiTamper : NSObject

// Idempotent. Safe to call from the earliest constructor. Compiled out of the
// INERT diagnostic build (the ctor is #ifndef TINDERVAULT_INERT).
+ (void)install;

@end
