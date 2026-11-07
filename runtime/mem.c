/* Guest memory: 4 GB reserved (PROT_NONE), the regions in use are committed. */
#include <errno.h>
#include <pthread.h>
#include "cpu.h"
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdlib.h>
void (*g_backtrace_fn)(struct CPU*,int) = 0;   /* set by dispatch.c */
CPU *g_cur_cpu = 0;

uint8_t *g_mem = 0;
uint32_t g_eflags_hi = 0;   /* EFLAGS AC/ID bits, see eflags_get in cpu.h */
uint32_t g_image_base = 0x400000u, g_res_dir_va = 0, g_res_dir_size = 0;

/* watch state: must be defined in every build (debug.c is optional) */
uint32_t g_itrace[ITRACE_SIZE];
uint64_t g_itrace_n = 0;
uint32_t g_watch_addr = 0, g_watch_val = 0, g_watch_prev_ip = 0;
void (*g_itrace_dump_fn)(int) = 0;      /* set by debug.c */
void (*g_report_fn)(void) = 0;          /* set by boot.c */
__attribute__((weak)) void watch_report_change(uint32_t ip, uint32_t o, uint32_t n){
    (void)ip;(void)o;(void)n;
}
static uint64_t g_committed = 0;
/* bitmap of committed 16 KB pages (4 GB / 16 KB = 262144 bits = 32 KB) */
uint8_t g_cbits[1u<<15] = {0};
/* The body is now inline in cpu.h (three instructions).  As a separate call
 * it was 1.45% of the guest thread in the profile -- not work, call overhead. */


void mprot_arm(uint32_t);
/* Reserved size.  4 GB on macOS.  iOS (iPad mini 2, 16 KB __PAGEZERO): the full
 * 4 GB is granted only sometimes (9/20 launches measured), >= ~3 GB always; the
 * guest's map stays below 2 GB (main stack ends at 0x7FF00000), so the largest
 * available block is taken.  Translation is unchanged (base + 32-bit offset):
 * an access beyond g_memsz is no longer guaranteed to fault (debug aid only). */
uint64_t g_memsz = GSZ;
#if defined(NFS_GUEST_IN_IMAGE) && NFS_GUEST_IN_IMAGE
/* iOS (jailbroken iPad mini 2): the guest space is a 4 GB zero-fill array INSIDE the
 * executable.  With the 16 KB __PAGEZERO the kernel maps the main image at the bottom
 * of the address space, so the image (and this array) covers 0..4 GB and every dylib
 * is loaded ABOVE 4 GB.  Needed because the jailbreak's injected
 * pspawn_payload-stg2.dylib, when loaded below 4 GB (plain 16 KB pagezero), makes
 * libxpc jump to 0x2_0000_0000 | low32(its hook) during GameController's initializer
 * (crash 2026-11-07).  Untouched zero-fill pages cost no memory; mem_init re-protects
 * the array PROT_NONE so uncommitted accesses still fault as on macOS. */
/* own segment, laid out after __DATA: inside __bss it pushed other globals beyond ADRP range */
static uint8_t g_guest_image[GSZ] __attribute__((section("__GUEST,__mem,zerofill"), aligned(16384)));
void mem_init(void){
    if (g_mem) return;
    g_mem = g_guest_image;
    if (mprotect(g_mem, GSZ, PROT_NONE) != 0) perror("mprotect guest image");
    fprintf(stderr, "mem: guest space 4096 MB in the image at %p\n", (void *)g_mem);
}
#else
void mem_init(void){
    if (g_mem) return;
    g_mem = mmap(0, GSZ, PROT_NONE, MAP_PRIVATE|MAP_ANON|MAP_NORESERVE, -1, 0);
    if (g_mem == MAP_FAILED){
        uint64_t lo = 0, hi = GSZ;                       /* 16 MB resolution */
        while (hi - lo > (16ull << 20)){
            uint64_t mid = ((lo + hi) / 2) & ~((16ull << 20) - 1);
            void *p = mmap(0, mid, PROT_NONE, MAP_PRIVATE|MAP_ANON|MAP_NORESERVE, -1, 0);
            if (p != MAP_FAILED){ munmap(p, mid); lo = mid; } else hi = mid;
        }
        if (lo < 0x80000000ull){ fprintf(stderr, "mem: only %llu MB of address space, need 2048\n",
                                         (unsigned long long)(lo >> 20)); exit(1); }
        g_mem = mmap(0, lo, PROT_NONE, MAP_PRIVATE|MAP_ANON|MAP_NORESERVE, -1, 0);
        if (g_mem == MAP_FAILED){ perror("mmap guest"); exit(1); }
        g_memsz = lo;
    }
    fprintf(stderr, "mem: guest space %llu MB reserved at %p\n", (unsigned long long)(g_memsz >> 20), (void *)g_mem);
}
#endif

void mem_commit(uint32_t addr, uint32_t size){
    uint64_t lo = addr & ~0x3FFFull;                    /* 16 KB page */
    uint64_t hi = ((uint64_t)addr + size + 0x3FFF) & ~0x3FFFull;
    if (hi > 0x100000000ull) hi = 0x100000000ull;
    if (hi > g_memsz){
        fprintf(stderr,"mem_commit 0x%08x+%u beyond the reserved %llu MB\n", addr, size,
                (unsigned long long)(g_memsz >> 20)); exit(1); }
    if (mprotect(g_mem + lo, hi - lo, PROT_READ|PROT_WRITE) != 0){
        fprintf(stderr,"mem_commit 0x%08x+%u failed\n", addr, size); exit(1);
    }
    for (uint64_t a2 = lo; a2 < hi; a2 += 0x4000ull){
        uint32_t pg = (uint32_t)(a2 >> 14);
        g_cbits[pg>>3] |= (uint8_t)(1u << (pg&7));
    }
    g_committed += hi - lo;
    /* WATCHADDR=<address>: set a watchpoint as soon as that address is committed.
     * This way even the first writer is caught. */
    { static int wa_done = 0;
      const char *wa = getenv("WATCHADDR");
      if (wa && !wa_done){
          uint32_t t = (uint32_t)strtoul(wa, 0, 0);
          if ((uint64_t)t >= lo && (uint64_t)t < hi){ wa_done = 1; mprot_arm(t); }
      } }
}
uint64_t mem_committed(void){ return g_committed; }

/* Diagnose a guest access to an uncommitted region */
static volatile int g_in_handler = 0;
/* --- write trapping: make a guest page read-only and find the writer ---
 * Answers "who writes to this memory?" without watchpoint instrumentation:
 * the write produces a SIGSEGV, and the generated function (and so the guest
 * function) is resolved from the faulting host PC.                       */
uint8_t *g_mprot_page = 0;
static size_t g_mprot_sz = 0;
static int g_mprot_hits = 0;
static uint32_t g_mprot_target = 0;      /* the exact address we care about */
static volatile int g_mprot_found = 0;   /* found the writer to the target */
static int      g_mprot_persist = 0;     /* re-arm every frame */
/* provided by dispatch.c; a weak default for test runs linked on their own */
__attribute__((weak)) uint32_t guest_fn_from_host(const void *pc){ (void)pc; return 0; }

/* The protected page is 16 KB and very busy: the first foreign write drops
 * the protection.  A separate thread keeps re-arming it, so the writer to the
 * target gets caught. */
static void *mprot_rearm_thread(void *a0){
    (void)a0;
    for (;;){
        /* re-protect even if g_mprot_page is set: an intervening mem_commit may have
         * silently removed the protection. */
        if (g_mprot_target && !g_mprot_found){
            size_t ps = (size_t)getpagesize();
            uint8_t *pg = (uint8_t*)((uintptr_t)(g_mem + g_mprot_target) & ~(uintptr_t)(ps-1));
            if (mprotect(pg, ps, PROT_READ) == 0){ g_mprot_page = pg; g_mprot_sz = ps; }
        }
        struct timespec ts = {0, 50 * 1000};    /* 50 us */
        nanosleep(&ts, 0);
    }
    return 0;
}

void mprot_arm(uint32_t guest_addr){
    /* On Apple Silicon a page is 16 KB; the alignment must come from the system value. */
    size_t ps = (size_t)getpagesize();
    uint8_t *pg = (uint8_t*)((uintptr_t)(g_mem + guest_addr) & ~(uintptr_t)(ps - 1));
    if (mprotect(pg, ps, PROT_READ) != 0){
        fprintf(stderr,"mprot: could not set up (%s)\n", strerror(errno)); return;
    }
    g_mprot_page = pg; g_mprot_sz = ps; g_mprot_target = guest_addr;
    g_mprot_persist = getenv("MPROT_PERSIST") ? 1 : 0;
    if (getenv("MPROT_HARD")){
        static pthread_t th; static int started = 0;
        if (!started){ started = 1; pthread_create(&th, 0, mprot_rearm_thread, 0); }
    }
    fprintf(stderr,"mprot: guest page 0x%08x read-only (to catch the writer)\n",
            guest_addr);
}

/* Re-arm the protection at the start of a frame (if a one-shot catch isn't enough). */
void mprot_rearm(void){
    if (!g_mprot_persist || g_mprot_page || !g_mprot_target) return;
    size_t ps = (size_t)getpagesize();
    uint8_t *pg = (uint8_t*)((uintptr_t)(g_mem + g_mprot_target) & ~(uintptr_t)(ps - 1));
    if (mprotect(pg, ps, PROT_READ) == 0){ g_mprot_page = pg; g_mprot_sz = ps; }
}

static void segv(int sig, siginfo_t *si, void *uc){
    (void)sig;
    /* a write to the protected page? */
    if (g_mprot_page){
        uint8_t *fa = (uint8_t*)si->si_addr;
        if (fa >= g_mprot_page && fa < g_mprot_page + g_mprot_sz){
            void *pc = 0;
#if defined(__aarch64__)
            ucontext_t *u = (ucontext_t*)uc;
            if (u && u->uc_mcontext) pc = (void*)(uintptr_t)u->uc_mcontext->__ss.__pc;
#endif
            uint32_t gfn = pc ? guest_fn_from_host(pc) : 0;
            uint32_t ga = (uint32_t)(fa - g_mem);
            int interesting = !g_mprot_target ||
                (ga >= g_mprot_target && ga < g_mprot_target + 64u);
            if (getenv("MPROT_ANY")) interesting = 1;   /* mechanism test */
            if (interesting && g_mprot_hits < 12){
                g_mprot_hits++;
                fprintf(stderr,"mprot: WRITE TO TARGET guest 0x%08x  guest function=sub_%08x\n",
                        ga, gfn);
                if (g_mprot_hits >= 6) g_mprot_found = 1;
            }
            mprotect(g_mprot_page, g_mprot_sz, PROT_READ|PROT_WRITE);
            g_mprot_page = 0;           /* one-shot */
            return;                      /* let the instruction run again */
        }
    }
    if (g_in_handler){ fprintf(stderr,"\n*** second fault inside the handler - exiting\n"); _exit(4); }
    g_in_handler = 1;
    /* The GUEST FUNCTION that caused the fault: resolved from the host PC.  The
     * stack trace only gives the callers; this tells exactly where it happened. */
    { void *fpc = 0;
#if defined(__aarch64__)
      ucontext_t *u2 = (ucontext_t*)uc;
      if (u2 && u2->uc_mcontext) fpc = (void*)(uintptr_t)u2->uc_mcontext->__ss.__pc;
#endif
      uint32_t ffn = fpc ? guest_fn_from_host(fpc) : 0;
      if (ffn) fprintf(stderr,"\n*** FAULTING GUEST FUNCTION: sub_%08x\n", ffn);
    }
    uint8_t *p = (uint8_t*)si->si_addr;
    if (p >= g_mem && p < g_mem + g_memsz)
        fprintf(stderr,"\n*** GUEST MEMORY FAULT: guest address 0x%08llx (unmapped)\n",
                (unsigned long long)(p - g_mem));
    else
        fprintf(stderr,"\n*** HOST SEGV: %p (outside guest space - probably a HOST STACK OVERFLOW:"
                       " infinite recursion in guest code)\n", p);
    { extern uint32_t g_watch_prev_ip; extern uint64_t g_itrace_n;
      if (g_itrace_n) fprintf(stderr,"    FAULTING GUEST INSTRUCTION: 0x%08x\n", g_watch_prev_ip); }
    if (g_cur_cpu){
        CPU *c = (CPU*)g_cur_cpu;
        fprintf(stderr,"    eax=%08x ecx=%08x edx=%08x ebx=%08x\n", c->eax,c->ecx,c->edx,c->ebx);
        fprintf(stderr,"    esp=%08x ebp=%08x esi=%08x edi=%08x  df=%u\n", c->esp,c->ebp,c->esi,c->edi,c->df);
        fprintf(stderr,"    fs_base=%08x tid=%u   [ebp+8]=%08x [ebp+4]=%08x\n",
                c->fs_base,
                (c->fs_base && mem_is_committed(c->fs_base+0x24u)) ? MR32(c->fs_base+0x24u) : 0u,
                mem_is_committed(c->ebp+8u) ? MR32(c->ebp+8u) : 0xDEADu,
                mem_is_committed(c->ebp+4u) ? MR32(c->ebp+4u) : 0xDEADu);
    }
    if (g_cur_cpu && g_backtrace_fn) g_backtrace_fn(g_cur_cpu, 12);
    if (g_itrace_dump_fn && getenv("ITRACE")) g_itrace_dump_fn(atoi(getenv("ITRACE")));
    if (g_report_fn) g_report_fn();
    _exit(3);
}
/* sigaltstack is set up PER THREAD: every guest thread must set up its own
 * signal stack, otherwise on a stack overflow the handler crashes too.   */
void mem_altstack_install(void){
    size_t sz = (size_t)SIGSTKSZ * 8;
    void *p = malloc(sz);
    if (!p) return;
    stack_t ss; ss.ss_sp = p; ss.ss_size = sz; ss.ss_flags = 0;
    sigaltstack(&ss, 0);
}
void mem_fault_handler_install(void){
    mem_altstack_install();
    struct sigaction sa; memset(&sa,0,sizeof sa);
    sa.sa_sigaction = segv; sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV,&sa,0); sigaction(SIGBUS,&sa,0);
}

int mem_load_pe(const char *path){
    FILE *f = fopen(path, "rb");
    if(!f){ perror(path); return -1; }
    fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);
    uint8_t *buf = malloc(sz);
    if (fread(buf,1,sz,f)!=(size_t)sz){ fclose(f); free(buf); return -1; }
    fclose(f);
    uint32_t e_lfanew = *(uint32_t*)(buf+0x3c);
    uint8_t *nt = buf + e_lfanew;
    if (*(uint32_t*)nt != 0x00004550u){ fprintf(stderr,"no PE signature\n"); free(buf); return -1; }
    uint16_t nsec  = *(uint16_t*)(nt+6);
    uint16_t optsz = *(uint16_t*)(nt+20);
    uint32_t base  = *(uint32_t*)(nt+24+28);
    uint32_t imgsz = *(uint32_t*)(nt+24+56);
    /* DataDirectory[2] = RESOURCE */
    { /* PE32: DataDirectory is at byte 96 of the optional header; RESOURCE = index 2 */
      uint32_t dd = 24 + 96 + 2*8;
      uint32_t rva = *(uint32_t*)(nt + dd);
      uint32_t sz  = *(uint32_t*)(nt + dd + 4);
      g_image_base = base; g_res_dir_va = rva ? base + rva : 0; g_res_dir_size = sz; }
    uint8_t *sh    = nt + 24 + optsz;
    mem_init();
    mem_commit(base, imgsz);                 /* the whole image range */
    for (int i=0;i<nsec;i++){
        uint8_t *s = sh + i*40;
        char nm[9]={0}; memcpy(nm,s,8);
        uint32_t vsize=*(uint32_t*)(s+8), va=*(uint32_t*)(s+12);
        uint32_t rsize=*(uint32_t*)(s+16), roff=*(uint32_t*)(s+20);
        uint32_t n = rsize < vsize ? rsize : vsize;
        memcpy(g_mem + base + va, buf + roff, n);
        fprintf(stderr,"  loaded %-9s -> 0x%08x  %u bytes\n", nm[0]?nm:"<unnamed>", base+va, n);
    }
    free(buf);
    fprintf(stderr,"  image 0x%08x .. 0x%08x   resource directory 0x%08x (%u bytes)\n",
            base, base+imgsz, g_res_dir_va, g_res_dir_size);
    return 0;
}
