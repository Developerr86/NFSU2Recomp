/* iOS replacement for bundle.m (ios branch).
 *
 * The game data is NOT in the app: it lives in a folder the user fills over SSH,
 * /var/mobile/Media/NFSU2 (SPEED2.EXE + the game folders).  The app is installed in
 * /Applications with the no-container entitlement, so it can read and write there.
 *
 *   /var/mobile/Media/NFSU2/            game root (SPEED2.EXE, TRACKS, CARS, ...)
 *   /var/mobile/Media/NFSU2/env.txt     optional KEY=VALUE lines, applied before start
 *   /var/mobile/Media/NFSU2/nfsu2.log   stderr of the last run (previous: nfsu2-previous.log)
 *   /var/mobile/Media/NFSU2/saves/      career saves (NFSU2_SAVEDIR)
 *   /var/mobile/Media/NFSU2/home/       HOME (registry file .nfsu2_registry)
 */
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef NFS_ENHANCED
#define NFS_ENHANCED 0
#endif

const char *app_ios_root(void){
    const char *e = getenv("NFSU2_ROOT");
    return (e && *e) ? e : "/var/mobile/Media/NFSU2";
}

int app_is_bundled(void){ return 1; }

static void setdef(const char *k, const char *v){ if (!getenv(k)) setenv(k, v, 1); }

/* env.txt: one KEY=VALUE per line, '#' comments.  Applied with overwrite so the
 * file wins over the built-in defaults below (they use setdef). */
static void load_env_file(void){
    char p[1200]; snprintf(p, sizeof p, "%s/env.txt", app_ios_root());
    FILE *f = fopen(p, "r"); if (!f) return;
    char ln[1024];
    while (fgets(ln, sizeof ln, f)){
        char *s = ln; while (*s == ' ' || *s == '\t') s++;
        if (*s == '#' || *s == '\n' || !*s) continue;
        char *eq = strchr(s, '='); if (!eq) continue;
        *eq = 0; char *v = eq + 1;
        size_t n = strlen(v); while (n && (v[n-1] == '\n' || v[n-1] == '\r' || v[n-1] == ' ')) v[--n] = 0;
        char *k = s; size_t kn = strlen(k); while (kn && (k[kn-1] == ' ' || k[kn-1] == '\t')) k[--kn] = 0;
        if (*k){ setenv(k, v, 1); fprintf(stderr, "env.txt: %s=%s\n", k, v); }
    }
    fclose(f);
}

void app_set_defaults(void){
    load_env_file();
    setdef("WINDOW", "1");
    setdef("ALARM", "0");
    setdef("FIXMAT", "1");
    setdef("FIXMAT_MODE", "3");
    setdef("NOMOVIES", "1");
    setdef("SNDSYNC", "1");
    setdef("GPUVS", "1");
    /* iPad mini 2: 2048x1536 (4:3) screen, A7 GPU.  The game renders at its own
     * 4:3 mode and the layer scales it up; no Retina upscaling of the surface. */
    setdef("NFSNATIVE", "0");
    setdef("NFSRES", "1024x768");
    /* memory (1 GB device): smaller use-after-free quarantines than the Mac defaults
     * (heap 32 MB, buffer heap 1500 presents) */
    setdef("NFSU2_HEAP_QUAR_MB", "8");
    setdef("NFSU2_GBUF_QUAR", "600");
    char d[1200];
    snprintf(d, sizeof d, "%s/saves", app_ios_root()); mkdir(d, 0755); setdef("NFSU2_SAVEDIR", d);
}

void app_open_log(void){
    char pth[1200], prev[1300];
    snprintf(pth, sizeof pth, "%s/nfsu2.log", app_ios_root());
    snprintf(prev, sizeof prev, "%s/nfsu2-previous.log", app_ios_root());
    rename(pth, prev);
    if (freopen(pth, "w", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
    freopen(pth, "a", stdout);
}

const char *app_save_dir(void){
    static char dir[1200];
    const char *env = getenv("NFSU2_SAVEDIR");
    if (env && *env){ snprintf(dir, sizeof dir, "%s", env); return dir; }
    snprintf(dir, sizeof dir, "%s/saves", app_ios_root());
    mkdir(dir, 0755);
    return dir;
}

const char *app_find_game(void){
    static char p[1200]; struct stat st;
    static const char *names[] = { "SPEED2.EXE", "speed2.exe", "Speed2.exe" };
    for (unsigned i = 0; i < 3; i++){
        snprintf(p, sizeof p, "%s/%s", app_ios_root(), names[i]);
        if (stat(p, &st) == 0 && S_ISREG(st.st_mode)) return p;
    }
    return NULL;
}

void app_no_game(void){
    fprintf(stderr, "no SPEED2.EXE in %s: copy the game folder there\n", app_ios_root());
}

/* Same rule as bundle.m: the engine is built for one executable. */
#if defined(NFS_EXE_NA) && NFS_EXE_NA
static const char *kSha = "f9dd86c054878ce6276beb07c1fd61874f7a1e4bf1f241b084c65b73e24168a7";
static const char *kName = "North American v1.2";
#else
static const char *kSha = "8f6a9ae2c4cfa01181d2fd755d99c6f4b7103f60273908ea1de1e719dfe2a297";
static const char *kName = "European v1.2";
#endif
int app_check_exe(const char *exe){
    const char *any = getenv("NFSU2_ANY_EXE");
    if (any && *any == '1') return 1;
    FILE *f = fopen(exe, "rb");
    if (!f) return 1;
    CC_SHA256_CTX c; CC_SHA256_Init(&c);
    static unsigned char buf[65536]; size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) CC_SHA256_Update(&c, buf, (CC_LONG)n);
    fclose(f);
    unsigned char md[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(md, &c);
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + 2 * i, 3, "%02x", md[i]);
    if (!strcmp(hex, kSha)){ fprintf(stderr, "SPEED2.EXE: %s\n", kName); return 1; }
    fprintf(stderr, "unsupported SPEED2.EXE %s (sha256 %s); this engine runs the %s one\n", exe, hex, kName);
    return 0;
}
