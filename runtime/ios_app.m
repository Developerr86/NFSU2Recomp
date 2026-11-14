/* iOS app shell (ios branch): UIKit owns the main thread, the original boot code
 * (tests/boot.c, compiled with -Dmain=nfs_boot_main) runs on its own thread.
 *
 *   main thread : UIApplicationMain, touch input, on-screen controls, lifecycle
 *   boot thread : nfs_boot_main -> loads SPEED2.EXE, starts the guest thread
 *                 (1 GB stack), then runs metal_run_main_loop (frame encoding +
 *                 present) on THIS thread instead of the macOS main thread
 *   guest thread: the recompiled game
 *
 * Input: a touch outside the controls is the mouse (the front end is mouse
 * driven); the controls send DirectInput scan codes.  Control keys can be
 * changed in env.txt: NFSU2_KEY_NOS=0x38 etc. (hex DIK codes). */
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/CAMetalLayer.h>
#include <pthread.h>
#include <sys/stat.h>
#include <math.h>
#include <unistd.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int  nfs_boot_main(int argc, char **argv);
const char *app_ios_root(void);
const char *app_find_game(void);
void metal_ios_attach_layer(CAMetalLayer *l);
void metal_ios_set_screen(int wpt, int hpt, double scale);
void metal_ios_set_paused(int p);
void metal_ios_touch(double px, double py, int phase);
void metal_ios_key(unsigned char dik, int down);

static unsigned char env_key(const char *name, unsigned char def){
    const char *e = getenv(name);
    return (e && *e) ? (unsigned char)strtoul(e, 0, 0) : def;
}

/* ---- game view: CAMetalLayer, touches = mouse ------------------------------ */
@interface NfsView : UIView @end
@implementation NfsView {
    double tdown; int pressed; UITouch *mouseTouch;
}
+ (Class)layerClass { return [CAMetalLayer class]; }
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    /* During a movie a tap is Enter: the game's own skip (the opening FMV and the story
     * movies take Enter; the EA/THX logos and the PSA ignore all input, as on the PC). */
    { int fileio_movie_playing(void);
      if (fileio_movie_playing()){
          metal_ios_key(0x1C, 1);
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
              metal_ios_key(0x1C, 0); });
          return; } }
    if (mouseTouch) return;
    mouseTouch = [touches anyObject];
    CGPoint p = [mouseTouch locationInView:self];
    metal_ios_touch(p.x, p.y, 1);                 /* move the cursor there first */
    tdown = CACurrentMediaTime(); pressed = 0;
    /* press a little later: the game hit-tests at the cursor of the frame it polls */
    double x = p.x, y = p.y;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (self->mouseTouch){ metal_ios_touch(x, y, 0); self->pressed = 1; } });
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (!mouseTouch || ![touches containsObject:mouseTouch]) return;
    CGPoint p = [mouseTouch locationInView:self];
    metal_ios_touch(p.x, p.y, 1);
}
- (void)endMouse:(NSSet<UITouch *> *)touches {
    if (!mouseTouch || ![touches containsObject:mouseTouch]) return;
    CGPoint p = [mouseTouch locationInView:self];
    mouseTouch = nil;
    double held = CACurrentMediaTime() - tdown, x = p.x, y = p.y;
    /* hold the button for at least ~6 frames so a quick tap is seen as a click */
    double wait = 0.12 - held; if (!pressed) wait += 0.04;
    if (wait < 0) wait = 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->pressed) metal_ios_touch(x, y, 0);
        metal_ios_touch(x, y, 2); self->pressed = 0; });
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)event; [self endMouse:touches]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)event; [self endMouse:touches]; }
@end

/* ---- system keyboard for the game's text boxes (profile name) -----------------
 * Shown while the game has a text box taking characters (win32_ext.c
 * nfs_textbox_active, polled every 100 ms); typed text goes to the WM_CHAR queue the
 * window procedure reads (Return = 0x0D accept, Backspace = 0x08). */
int  nfs_textbox_active(void);
void metal_ios_char(unsigned char ch);
@interface NfsKeyInput : UIView <UIKeyInput, UITextInputTraits> @end
@implementation NfsKeyInput
@synthesize autocapitalizationType, autocorrectionType, spellCheckingType, keyboardType,
            keyboardAppearance, returnKeyType, enablesReturnKeyAutomatically, secureTextEntry,
            smartQuotesType, smartDashesType, smartInsertDeleteType;
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])){
        self.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.autocorrectionType = UITextAutocorrectionTypeNo;
        self.spellCheckingType = UITextSpellCheckingTypeNo;
        self.keyboardType = UIKeyboardTypeASCIICapable;
        self.keyboardAppearance = UIKeyboardAppearanceDark;
        self.returnKeyType = UIReturnKeyDone;
        if (@available(iOS 11.0, *)){
            self.smartQuotesType = UITextSmartQuotesTypeNo;
            self.smartDashesType = UITextSmartDashesTypeNo;
            self.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
        }
        self.userInteractionEnabled = NO;
    }
    return self;
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (void)insertText:(NSString *)text {
    for (NSUInteger i = 0; i < text.length; i++){
        unichar u = [text characterAtIndex:i];
        if (u == '\n' || u == '\r') metal_ios_char(0x0D);
        else if ((u >= 0x20 && u < 0x7F) || (u >= 0xA0 && u <= 0xFF)) metal_ios_char((unsigned char)u);
    }
}
- (void)deleteBackward { metal_ios_char(0x08); }
@end

/* ---- on-screen controls ------------------------------------------------------ */
@interface NfsKey : UIView
@property (nonatomic) unsigned char dik;
@property (nonatomic, strong) UILabel *label;
@end
@implementation NfsKey { int downCount; }
- (instancetype)initWithFrame:(CGRect)f title:(NSString *)t dik:(unsigned char)k {
    if ((self = [super initWithFrame:f])){
        _dik = k;
        self.multipleTouchEnabled = YES;
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        self.layer.cornerRadius = 14; self.layer.borderWidth = 2;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
        _label = [[UILabel alloc] initWithFrame:self.bounds];
        _label.text = t; _label.textAlignment = NSTextAlignmentCenter;
        _label.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
        _label.font = [UIFont boldSystemFontOfSize:20];
        _label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_label];
    }
    return self;
}
- (void)set:(int)down {
    metal_ios_key(_dik, down);
    self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:down ? 0.40 : 0.14];
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { (void)e; if (!downCount) [self set:1]; downCount += (int)t.count; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { (void)e; downCount -= (int)t.count; if (downCount <= 0){ downCount = 0; [self set:0]; } }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self touchesEnded:t withEvent:e]; }
/* show / hide (releasing a held key first); k != 0 re-targets the key */
- (void)show:(BOOL)on dik:(unsigned char)k {
    if (!on && !self.hidden && downCount){ downCount = 0; [self set:0]; }
    if (k && k != _dik && !downCount) _dik = k;
    self.hidden = !on;
}
@end

/* The pad covers the whole screen; touches that miss a key fall through to the
 * game view (otherwise the menus can't be clicked). */
@interface NfsPad : UIView @end
@implementation NfsPad
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *h = [super hitTest:p withEvent:e];
    return h == self ? nil : h;
}
@end

void nfs_dump_threads(const char *why);
@interface NfsVC : UIViewController @end
@implementation NfsVC { UIView *pad; NfsKeyInput *keys; UILabel *note; NfsKey *gearUp, *gearDn, *mapKey, *smsKey; }
/* three-finger tap: write a hang report (all guest threads' call chains + last files) */
- (void)dumpTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ nfs_dump_threads("three-finger tap"); });
    if (!note){
        note = [[UILabel alloc] initWithFrame:CGRectMake(0, 70, self.view.bounds.size.width, 40)];
        note.textAlignment = NSTextAlignmentCenter; note.textColor = [UIColor whiteColor];
        note.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6]; note.font = [UIFont boldSystemFontOfSize:18];
        note.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self.view addSubview:note];
    }
    note.text = @"Diagnostics saved to nfsu2.log"; note.hidden = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ self->note.hidden = YES; });
}
- (void)pollTextBox {
    int on = nfs_textbox_active();
    if (on && !keys.isFirstResponder) [keys becomeFirstResponder];
    else if (!on && keys.isFirstResponder) [keys resignFirstResponder];
    [self pollDriveKeys];
}
/* DRIVING KEYS: GEAR ▲ / GEAR ▼ only while driving in a drag race or with manual
 * transmission; MAP and SMS while driving (race / free roam).  The keys send whatever
 * the game's active map binds (com.c nfs_drive_keys).  NFSU2_GEARKEYS=1: gear keys
 * whenever driving, 0: never. */
- (void)pollDriveKeys {
    int nfs_drive_keys(unsigned char dik[4]);
    unsigned char k[4];
    int st = nfs_drive_keys(k);
    const char *e = getenv("NFSU2_GEARKEYS");
    int gears = (st & 1) && ((st & 2) || (e && *e == '1')) && !(e && *e == '0');
    static int last = -1;
    if (st != last){ last = st; fprintf(stderr, "[ios] driving keys: driving=%d gears=%d (keys 0x%02x 0x%02x 0x%02x 0x%02x)\n",
                                       st & 1, gears, k[0], k[1], k[2], k[3]); }
    [gearUp show:gears && k[0] dik:env_key("NFSU2_KEY_SHIFTUP", k[0])];
    [gearDn show:gears && k[1] dik:env_key("NFSU2_KEY_SHIFTDOWN", k[1])];
    [mapKey show:(st & 1) && k[2] dik:env_key("NFSU2_KEY_MAP", k[2])];
    [smsKey show:(st & 1) && k[3] dik:env_key("NFSU2_KEY_SMS", k[3])];
}
- (void)loadView {
    NfsView *v = [[NfsView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    v.multipleTouchEnabled = YES;
    v.backgroundColor = [UIColor blackColor];
    self.view = v;
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (NfsKey *)addKey:(NSString *)t dik:(unsigned char)k frame:(CGRect)f to:(UIView *)p mask:(UIViewAutoresizing)m {
    NfsKey *b = [[NfsKey alloc] initWithFrame:f title:t dik:k];
    b.autoresizingMask = m;
    [p addSubview:b];
    return b;
}
- (void)buildControls:(CGSize)S {
    pad = [[NfsPad alloc] initWithFrame:CGRectMake(0, 0, S.width, S.height)];
    pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    pad.userInteractionEnabled = YES; pad.multipleTouchEnabled = YES;
    /* the pad view itself must not swallow touches meant for the game view */
    pad.backgroundColor = [UIColor clearColor];
    CGFloat W = S.width, H = S.height, b = 96, g = 14;
    UIViewAutoresizing BL = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    UIViewAutoresizing BR = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    UIViewAutoresizing TL = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    UIViewAutoresizing TR = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self addKey:@"◀" dik:env_key("NFSU2_KEY_LEFT", 0xCB)  frame:CGRectMake(g, H - b - g, b, b) to:pad mask:BL];
    [self addKey:@"▶" dik:env_key("NFSU2_KEY_RIGHT", 0xCD) frame:CGRectMake(g * 2 + b, H - b - g, b, b) to:pad mask:BL];
    [self addKey:@"▲" dik:env_key("NFSU2_KEY_UP", 0xC8)    frame:CGRectMake(g + (b + g) / 2, H - 2 * b - 2 * g, b, b * 0.7) to:pad mask:BL];
    [self addKey:@"GAS"   dik:env_key("NFSU2_KEY_GAS", 0xC8)   frame:CGRectMake(W - b - g, H - b * 1.6 - g, b, b * 1.6) to:pad mask:BR];
    [self addKey:@"BRAKE" dik:env_key("NFSU2_KEY_BRAKE", 0xD0) frame:CGRectMake(W - 2 * b - 2 * g, H - b - g, b, b) to:pad mask:BR];
    [self addKey:@"E-BRK" dik:env_key("NFSU2_KEY_EBRAKE", 0x39) frame:CGRectMake(W - 3 * b - 3 * g, H - b - g, b, b) to:pad mask:BR];
    [self addKey:@"N2O"   dik:env_key("NFSU2_KEY_NOS", 0x38)   frame:CGRectMake(W - 2 * b - 2 * g, H - 2 * b - 2 * g, b, b) to:pad mask:BR];
    [self addKey:@"ESC"   dik:env_key("NFSU2_KEY_ESC", 0x01)   frame:CGRectMake(g, g, 80, 54) to:pad mask:TL];
    [self addKey:@"ENTER" dik:env_key("NFSU2_KEY_ENTER", 0x1C) frame:CGRectMake(W - 110 - g, g, 110, 54) to:pad mask:TR];
    [self addKey:@"▼" dik:env_key("NFSU2_KEY_DOWN", 0xD0)  frame:CGRectMake(g * 2 + 80, g, 70, 54) to:pad mask:TL];
    /* driving keys (shown by pollDriveKeys): gear down under ESC, gear up under ENTER,
     * SMS and MAP to the left of ENTER */
    gearDn = [self addKey:@"GEAR ▼" dik:0x1D frame:CGRectMake(g, g * 2 + 54, 110, 84) to:pad mask:TL];
    gearUp = [self addKey:@"GEAR ▲" dik:0x2A frame:CGRectMake(W - 110 - g, g * 2 + 54, 110, 84) to:pad mask:TR];
    smsKey = [self addKey:@"SMS" dik:0x0F frame:CGRectMake(W - 110 - g - (80 + g), g, 80, 54) to:pad mask:TR];
    mapKey = [self addKey:@"MAP" dik:0x32 frame:CGRectMake(W - 110 - g - 2 * (80 + g), g, 80, 54) to:pad mask:TR];
    gearDn.hidden = gearUp.hidden = smsKey.hidden = mapKey.hidden = YES;
    pad.hidden = getenv("NFSU2_NOPAD") && getenv("NFSU2_NOPAD")[0] == '1';
    [self.view addSubview:pad];
    { UITapGestureRecognizer *t3 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dumpTap:)];
      t3.numberOfTouchesRequired = 3; t3.cancelsTouchesInView = NO;
      [self.view addGestureRecognizer:t3]; }
    keys = [[NfsKeyInput alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    [self.view addSubview:keys];
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(pollTextBox) userInfo:nil repeats:YES];
}
@end


/* Battery guard (from OpenUG2's shim): a flat battery reboots the iPad and loses the
 * semi-untethered jailbreak, and the game out-drains the charger.  Sampled on the main
 * thread every 10 s; the mem thread exits the app at < 8% unplugged / < 5% charging. */
static volatile float g_battery = -1.0f; static volatile int g_charging;

/* jetsam enforces phys_footprint: log it (and the peak) every 5 s */
static void *mem_thread(void *arg){
    (void)arg; uint64_t peak = 0;
    for (;;){
        task_vm_info_data_t vi; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) == KERN_SUCCESS){
            uint64_t fp = vi.phys_footprint; if (fp > peak) peak = fp;
            long long metal_tex_bytes(void), metal_tex_kind_bytes(int);
            fprintf(stderr, "[mem] footprint %llu MB (peak %llu MB), resident %llu MB, textures %lld MB "
                    "(native %lld, DXT1 %lld, DXT3 %lld, DXT5 %lld), battery %.0f%%%s\n",
                    (unsigned long long)(fp >> 20), (unsigned long long)(peak >> 20),
                    (unsigned long long)(vi.resident_size >> 20), metal_tex_bytes() >> 20,
                    metal_tex_kind_bytes(0) >> 20, metal_tex_kind_bytes(1) >> 20,
                    metal_tex_kind_bytes(3) >> 20, metal_tex_kind_bytes(5) >> 20,
                    g_battery * 100.0f, g_charging ? " charging" : "");
        }
        /* no-frame watchdog: 20 s without a presented frame while in the foreground ->
         * one hang report (a stuck loading screen that still animates needs the
         * three-finger tap instead) */
        { long metal_frames_drawn(void); int metal_ios_is_paused(void);
          static long last_f = -1; static int idle = 0, dumped = 0;
          long f = metal_frames_drawn();
          if (f > 0 && f == last_f && !metal_ios_is_paused()){ idle += 5; if (idle >= 20 && !dumped){ dumped = 1; nfs_dump_threads("no frame for 20 s"); } }
          else { idle = 0; if (f != last_f) dumped = 0; }
          last_f = f; }
        if (g_battery >= 0.0f && (g_battery < 0.05f || (g_battery < 0.08f && !g_charging))){
            fprintf(stderr, "[ios] BATTERY GUARD EXIT: %.0f%%%s\n", g_battery * 100.0f,
                    g_charging ? " (charging, still too low)" : " and not charging");
            fflush(stderr); _exit(0);
        }
        sleep(5);
    }
    return NULL;
}

static void *boot_thread(void *arg){
    (void)arg;
    const char *exe = app_find_game();
    char *argv[3] = { (char *)"NFSU2", (char *)(exe ? exe : ""), NULL };
    int rc = nfs_boot_main(exe ? 2 : 1, argv);
    fprintf(stderr, "ios: boot returned %d -> exit\n", rc);
    fflush(stderr);
    exit(rc);
    return NULL;
}

@interface NfsDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation NfsDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opt {
    (void)opt;
    app.idleTimerDisabled = YES;
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    [self sampleBattery];
    [NSTimer scheduledTimerWithTimeInterval:10.0 target:self selector:@selector(sampleBattery) userInfo:nil repeats:YES];
    { NSError *e = nil;
      [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&e];
      /* small device slice: the play cursor the game writes against advances per callback;
       * the default 1024 frames (23 ms) left no margin under the write lead (see audio.m).
       * NFSU2_IOBUF_MS overrides (default 5.8 ms = 256 frames at 44.1 kHz). */
      { const char *b = getenv("NFSU2_IOBUF_MS"); double ms = (b && *b) ? atof(b) : 5.8;
        [[AVAudioSession sharedInstance] setPreferredIOBufferDuration:ms / 1000.0 error:&e]; }
      [[AVAudioSession sharedInstance] setActive:YES error:&e]; }
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    NfsVC *vc = [NfsVC new];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    CGSize b = [UIScreen mainScreen].bounds.size;          /* landscape: long side is width */
    CGSize L = CGSizeMake(fmax(b.width, b.height), fmin(b.width, b.height));
    CGFloat sc = [UIScreen mainScreen].nativeScale;
    vc.view.frame = CGRectMake(0, 0, L.width, L.height);
    CAMetalLayer *ml = (CAMetalLayer *)vc.view.layer;
    ml.contentsScale = sc;
    metal_ios_set_screen((int)L.width, (int)L.height, sc);
    metal_ios_attach_layer(ml);
    [vc buildControls:L];

    pthread_attr_t at; pthread_attr_init(&at);
    pthread_attr_setstacksize(&at, 16u << 20);
    pthread_attr_set_qos_class_np(&at, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_t th;
    if (pthread_create(&th, &at, boot_thread, NULL) != 0){ fprintf(stderr, "ios: boot thread failed\n"); exit(1); }
    pthread_detach(th);
    pthread_t mt; if (pthread_create(&mt, NULL, mem_thread, NULL) == 0) pthread_detach(mt);
    return YES;
}
- (void)sampleBattery {
    UIDevice *d = [UIDevice currentDevice];
    g_battery = d.batteryLevel;
    g_charging = d.batteryState == UIDeviceBatteryStateCharging || d.batteryState == UIDeviceBatteryStateFull;
}
- (void)applicationWillResignActive:(UIApplication *)a { (void)a; metal_ios_set_paused(1); }
- (void)applicationDidEnterBackground:(UIApplication *)a { (void)a; metal_ios_set_paused(1); }
- (void)applicationDidBecomeActive:(UIApplication *)a { (void)a; metal_ios_set_paused(0); }
@end

int main(int argc, char **argv){
    /* HOME -> the data folder: the registry (~/.nfsu2_registry) and anything else the
     * runtime keeps under HOME stay next to the game data. */
    { char h[1200]; snprintf(h, sizeof h, "%s/home", app_ios_root());
      mkdir(h, 0755); setenv("HOME", h, 1); }
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([NfsDelegate class]));
    }
}
