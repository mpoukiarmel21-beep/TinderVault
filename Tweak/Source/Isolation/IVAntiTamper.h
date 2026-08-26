#import <Foundation/Foundation.h>

// IVAntiTamper — substrate-free defense against a hardened host (Tinder / Match
// Group) that aborts at launch when it detects its Mach-O has been modified and
// re-signed for sideloading.
//
// Two independent countermeasures, both installed from the earliest possible
// constructor so they are armed BEFORE the host's own integrity/anti-debug code
// runs (an injected dylib's initializers run before the main image's):
//
//   1. Self-read redirection. insert_dylib adds one LC_LOAD_DYLIB to the header;
//      the executable's code pages are otherwise byte-identical to the original.
//      A userspace integrity check that re-reads its own on-disk Mach-O and
//      hashes it therefore only sees a diff in the header/load-command region.
//      We fishhook the file-read syscalls and, ONLY for the main-executable fd,
//      overlay the pristine header bytes (staged in the bundle at CI time as
//      `ivbaseline.bin`) at their mirrored file offsets — so the check hashes
//      the untampered image and passes.
//
//   2. Anti-debug neutralization. ptrace(PT_DENY_ATTACH) / syscall(SYS_ptrace)
//      swallowed, and the P_TRACED bit cleared from sysctl(KERN_PROC) results,
//      so a RASP self-check that aborts when "traced/tamperable" stays quiet.
//
// This CANNOT beat a kernel/AMFI code-signature failure (that happens before any
// of our code runs) nor an in-MEMORY __TEXT hash — but a valid re-sign satisfies
// AMFI (Instagram proves the pipeline is sound), so the userspace self-check is
// the live differentiator. See docs/decisions and AGENT-HANDOFF.md.
@interface IVAntiTamper : NSObject

// Idempotent. Safe to call from the earliest constructor. Self-disables cleanly
// if the baseline resource is absent/malformed (redirect off, anti-debug still on).
+ (void)install;

@end
