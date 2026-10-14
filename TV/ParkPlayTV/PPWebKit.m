// ParkPlay TV — WKWebView pe tvOS, încărcat dinamic. Autor: arturm
#import "PPWebKit.h"
#import <dlfcn.h>
#import <objc/runtime.h>

// Declarații minime pentru metodele WebKit pe care le folosim (fără antetele WebKit).
@interface NSObject (PPWebKitPrivate)
- (instancetype)initWithFrame:(CGRect)frame configuration:(id)configuration;
- (instancetype)initWithSource:(NSString *)source injectionTime:(NSInteger)injectionTime forMainFrameOnly:(BOOL)forMainFrameOnly;
- (id)loadRequest:(NSURLRequest *)request;
- (id)reload;
- (void)evaluateJavaScript:(NSString *)javaScriptString completionHandler:(void (^)(id, NSError *))completionHandler;
- (void)setCustomUserAgent:(NSString *)customUserAgent;
- (void)setNavigationDelegate:(id)navigationDelegate;
- (void)addUserScript:(id)userScript;
- (void)addScriptMessageHandler:(id)scriptMessageHandler name:(NSString *)name;
- (void)addContentRuleList:(id)contentRuleList;
- (void)setCookie:(NSHTTPCookie *)cookie completionHandler:(void (^)(void))completionHandler;
- (void)compileContentRuleListForIdentifier:(NSString *)identifier encodedContentRuleList:(NSString *)encodedContentRuleList completionHandler:(void (^)(id, NSError *))completionHandler;
+ (instancetype)defaultStore;
+ (instancetype)storeWithURL:(NSURL *)url;
@end

static NSString *gInfo = @"";

static BOOL PPLoadWebKit(void) {
    static BOOL loaded = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *paths[] = {
            "/System/Library/Frameworks/WebKit.framework/WebKit",
            "/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
        };
        for (int i = 0; i < 2 && !loaded; i++) {
            if (dlopen(paths[i], RTLD_NOW)) {
                gInfo = [NSString stringWithFormat:@"WebKit încărcat din %s", paths[i]];
                loaded = NSClassFromString(@"WKWebView") != nil;
            }
        }
        if (!loaded) {
            const char *err = dlerror();
            gInfo = [NSString stringWithFormat:@"WebKit nu e disponibil: %s", err ? err : "WKWebView lipsește"];
        }
    });
    return loaded;
}

// ---- Primește mesajele din pagină și evenimentele de navigare ----

@interface PPWebKitHandler : NSObject
@property (nonatomic, weak) id<PPWebViewDelegate> delegate;
@end

@implementation PPWebKitHandler
- (void)userContentController:(id)userContentController didReceiveScriptMessage:(id)message {
    id body = nil;
    @try { body = [message valueForKey:@"body"]; } @catch (__unused NSException *e) {}
    if (body) [self.delegate ppWebViewMessage:body];
}
- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    [self.delegate ppWebViewDidFinish];
}
- (void)webViewWebContentProcessDidTerminate:(id)webView {
    [self.delegate ppWebViewProcessTerminated];
}
@end

static void PPSet(id obj, id value, NSString *key) {
    @try { [obj setValue:value forKey:key]; }
    @catch (NSException *e) { NSLog(@"ParkPlayTV: nu pot seta %@: %@", key, e.reason); }
}

@implementation PPWebView {
    UIView *_view;
    id _userContent;
    PPWebKitHandler *_handler;
}

+ (BOOL)isAvailable { return PPLoadWebKit(); }
+ (NSString *)availabilityInfo { PPLoadWebKit(); return gInfo; }

- (instancetype)initWithFrame:(CGRect)frame userAgent:(NSString *)userAgent delegate:(id<PPWebViewDelegate>)delegate {
    if (!PPLoadWebKit()) return nil;
    self = [super init];
    if (!self) return nil;

    _handler = [PPWebKitHandler new];
    _handler.delegate = delegate;
    // WebKit cere ca handler-ele să declare protocoalele; le adăugăm la rulare.
    Protocol *p1 = objc_getProtocol("WKScriptMessageHandler");
    Protocol *p2 = objc_getProtocol("WKNavigationDelegate");
    if (p1) class_addProtocol([PPWebKitHandler class], p1);
    if (p2) class_addProtocol([PPWebKitHandler class], p2);

    id config = [NSClassFromString(@"WKWebViewConfiguration") new];
    _userContent = [NSClassFromString(@"WKUserContentController") new];
    PPSet(config, _userContent, @"userContentController");
    PPSet(config, @YES, @"allowsInlineMediaPlayback");
    PPSet(config, @0, @"mediaTypesRequiringUserActionForPlayback"); // fără atingere pentru redare
    PPSet(config, @YES, @"allowsAirPlayForMediaPlayback");
    [_userContent addScriptMessageHandler:_handler name:@"pp"];

    UIView *wv = (UIView *)[[NSClassFromString(@"WKWebView") alloc] initWithFrame:frame configuration:config];
    if (!wv) return nil;
    [wv setCustomUserAgent:userAgent];
    [wv setNavigationDelegate:_handler];
    wv.backgroundColor = UIColor.blackColor;
    wv.opaque = NO;
    wv.userInteractionEnabled = NO; // telecomanda comandă interfața aplicației, nu pagina
    wv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    @try {
        UIScrollView *sv = [wv valueForKey:@"scrollView"];
        sv.backgroundColor = UIColor.blackColor;
        sv.scrollEnabled = NO;
    } @catch (__unused NSException *e) {}
    _view = wv;
    return self;
}

- (UIView *)view { return _view; }

- (void)setUserAgent:(NSString *)userAgent { [_view setCustomUserAgent:userAgent]; }

- (void)addDocumentStartScript:(NSString *)source mainFrameOnly:(BOOL)mainFrameOnly {
    // WKUserScriptInjectionTimeAtDocumentStart = 0
    id script = [[NSClassFromString(@"WKUserScript") alloc] initWithSource:source injectionTime:0 forMainFrameOnly:mainFrameOnly];
    if (script) [_userContent addUserScript:script];
}

- (void)addContentRules:(NSString *)json identifier:(NSString *)identifier completion:(void (^)(BOOL, NSString *))completion {
    Class storeClass = NSClassFromString(@"WKContentRuleListStore");
    // Magazinul implicit nu se poate scrie pe tvOS („Opening temporary file failed”):
    // folosim un dosar al nostru în Caches și ne asigurăm că există și tmp/.
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:NSTemporaryDirectory() withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *caches = [fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [caches URLByAppendingPathComponent:@"ParkPlayContentRules" isDirectory:YES];
    if (dir) [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    id store = nil;
    if (storeClass && dir && [storeClass respondsToSelector:@selector(storeWithURL:)]) store = [storeClass storeWithURL:dir];
    if (!store && storeClass) store = [storeClass defaultStore];
    if (!store) { completion(NO, @"WKContentRuleListStore lipsește"); return; }
    id uc = _userContent;
    [store compileContentRuleListForIdentifier:identifier encodedContentRuleList:json completionHandler:^(id list, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (list) [uc addContentRuleList:list];
            completion(list != nil, error.localizedDescription);
        });
    }];
}

- (void)setCookies:(NSArray<NSHTTPCookie *> *)cookies completion:(void (^)(void))completion {
    id store = nil;
    @try {
        id config = [_view valueForKey:@"configuration"];
        id dataStore = [config valueForKey:@"websiteDataStore"];
        store = [dataStore valueForKey:@"httpCookieStore"];
    } @catch (__unused NSException *e) {}
    if (!store || cookies.count == 0) { completion(); return; }
    dispatch_group_t g = dispatch_group_create();
    for (NSHTTPCookie *c in cookies) {
        dispatch_group_enter(g);
        [store setCookie:c completionHandler:^{ dispatch_group_leave(g); }];
    }
    dispatch_group_notify(g, dispatch_get_main_queue(), completion);
}

- (void)loadURL:(NSURL *)url { [_view loadRequest:[NSURLRequest requestWithURL:url]]; }

- (void)reload { [_view reload]; }

- (void)evaluate:(NSString *)js completion:(void (^)(id, NSError *))completion {
    [_view evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
        if (completion) completion(result, error);
    }];
}

@end
