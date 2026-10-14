// ParkPlay TV — WKWebView pe tvOS. SDK-ul tvOS nu are antetele WebKit, dar framework-ul
// există pe Apple TV: îl încărcăm dinamic și îl folosim prin runtime-ul Objective-C.
// API privat: merge doar instalat din Xcode (sideload), nu în App Store. Autor: arturm
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol PPWebViewDelegate <NSObject>
/// Mesaj din pagină: window.webkit.messageHandlers.pp.postMessage(obiect).
- (void)ppWebViewMessage:(id)body;
/// Pagina s-a încărcat.
- (void)ppWebViewDidFinish;
/// Procesul paginii a căzut (se poate reîncărca).
- (void)ppWebViewProcessTerminated;
@end

@interface PPWebView : NSObject

/// WebKit există și se poate folosi pe acest Apple TV.
+ (BOOL)isAvailable;
/// De ce nu (pentru ecranul Diagnostic).
+ (NSString *)availabilityInfo;

- (nullable instancetype)initWithFrame:(CGRect)frame userAgent:(NSString *)userAgent
                              delegate:(id<PPWebViewDelegate>)delegate;

/// View-ul WKWebView (de pus în interfață).
@property (nonatomic, readonly) UIView *view;

- (void)setUserAgent:(NSString *)userAgent;
- (void)addDocumentStartScript:(NSString *)source mainFrameOnly:(BOOL)mainFrameOnly;
/// Reguli de blocare (format WebKit content blocker). ok = NO dacă tvOS nu le acceptă.
- (void)addContentRules:(NSString *)json identifier:(NSString *)identifier completion:(void (^)(BOOL ok, NSString * _Nullable error))completion;
- (void)setCookies:(NSArray<NSHTTPCookie *> *)cookies completion:(void (^)(void))completion;
- (void)loadURL:(NSURL *)url;
- (void)reload;
- (void)evaluate:(NSString *)js completion:(nullable void (^)(id _Nullable result, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
