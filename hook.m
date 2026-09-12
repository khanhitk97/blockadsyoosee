#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#pragma mark - Helper Functions & Constants

static inline BOOL isAdDomain(NSString *urlString) {
    if (!urlString || urlString.length == 0) return NO;
    NSString *lower = urlString.lowercaseString;
    
    static NSArray *adBlacklist = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        adBlacklist = @[
            @"doubleclick.net",
            @"googleads.g.doubleclick.net",
            @"pagead2.googlesyndication.com",
            @"pubads.g.doubleclick.net",
            @"admob.com",
            @"unityads.unity3d.com",
            @"applvn.com",
            @"applovin.com",
            @"vungle.com",
            @"ironsrc.mobi",
            @"supersonicads.com",
            @"mintegral.com",
            @"pglstatp-toutiao.com", // Pangle / TikTok Ads
            @"pangolin-sdk-toutiao.com",
            @"facebook.com/tr/",
            @"an.facebook.com",
            @"chartboost.com",
            @"adjoe.zone",
            @"adcolony.com",
            @"fyber.com"
        ];
    });

    for (NSString *domain in adBlacklist) {
        if ([lower containsString:domain]) {
            return YES;
        }
    }
    return NO;
}

static void SwizzleInstanceMethod(Class cls, SEL origSEL, SEL swizzledSEL) {
    if (!cls) return;
    Method origMethod = class_getInstanceMethod(cls, origSEL);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledSEL);
    if (origMethod && swizzledMethod) {
        method_exchangeImplementations(origMethod, swizzledMethod);
    }
}

#pragma mark - 1. Hook Network Layer (NSURLSession)

@interface NSURLSession (AdBlocker)
@end

@implementation NSURLSession (AdBlocker)

- (NSURLSessionDataTask *)hook_dataTaskWithRequest:(NSURLRequest *)request
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (request.URL && isAdDomain(request.URL.absoluteString)) {
        NSLog(@"[AdBlocker] Blocked Ad Request: %@", request.URL.absoluteString);
        if (completionHandler) {
            NSError *dummyError = [NSError errorWithDomain:NSURLErrorDomain
                                                      code:NSURLErrorCannotConnectToHost
                                                  userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil, dummyError);
            });
        }
        // Redirect sang dummy request để không gửi gói tin ra ngoài
        NSURLRequest *blankReq = [NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]];
        return [self hook_dataTaskWithRequest:blankReq completionHandler:nil];
    }
    return [self hook_dataTaskWithRequest:request completionHandler:completionHandler];
}

@end

#pragma mark - 2. Hook Web-based Ads (WKWebView)

@interface WKWebView (AdBlocker)
@end

@implementation WKWebView (AdBlocker)

- (instancetype)hook_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    // Tự động chèn CSS/JS ẩn thẻ quảng cáo nếu app render quảng cáo qua WKWebView
    NSString *hideAdJS = @"var style = document.createElement('style');"
                          "style.innerHTML = '[id*=\"google_ads\"], [class*=\"ad-banner\"], [class*=\"ad-unit\"], iframe[src*=\"ads\"] { display: none !important; }';"
                          "document.head.appendChild(style);";
    WKUserScript *script = [[WKUserScript alloc] initWithSource:hideAdJS
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                               forMainFrameOnly:NO];
    [configuration.userContentController addUserScript:script];
    return [self hook_initWithFrame:frame configuration:configuration];
}

@end

#pragma mark - 3. Neutralize Known Ad SDK Presentation (No-Op)

static void NeutralizeAdClass(const char *className, const char *selectorName) {
    Class cls = objc_getClass(className);
    if (!cls) return;
    
    SEL sel = sel_registerName(selectorName);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        // Thay thế implementation bằng hàm rỗng không làm gì cả
        IMP noop = imp_implementationWithBlock(^(id _self, id arg1, id arg2) {
            NSLog(@"[AdBlocker] Neutralized Ad Call: [%s %s]", className, selectorName);
            return;
        });
        method_setImplementation(m, noop);
    }
}

static void SuppressAdSDKs(void) {
    // Google AdMob
    NeutralizeAdClass("GADBannerView", "loadRequest:");
    NeutralizeAdClass("GADFullScreenContentDelegate", "adDidPresentFullScreenContent:");
    NeutralizeAdClass("GADInterstitialAd", "presentFromRootViewController:");
    NeutralizeAdClass("GADRewardedAd", "presentFromRootViewController:userDidEarnRewardHandler:");

    // AppLovin MAX
    NeutralizeAdClass("MAInterstitialAd", "showAd");
    NeutralizeAdClass("MARewardedAd", "showAd");
    NeutralizeAdClass("MAAdView", "loadAd");

    // Unity Ads
    NeutralizeAdClass("UnityAds", "show:showOptions:");
}

#pragma mark - Dylib Constructor (Entry Point)

__attribute__((constructor))
static void init_ad_shield(void) {
    NSLog(@"[AdBlocker] =========================================");
    NSLog(@"[AdBlocker] Ad-Shield Dylib Injected Successfully!");
    NSLog(@"[AdBlocker] =========================================");

    // 1. Hook NSURLSession
    SwizzleInstanceMethod([NSURLSession class],
                          @selector(dataTaskWithRequest:completionHandler:),
                          @selector(hook_dataTaskWithRequest:completionHandler:));

    // 2. Hook WKWebView
    SwizzleInstanceMethod([WKWebView class],
                          @selector(initWithFrame:configuration:),
                          @selector(hook_initWithFrame:configuration:));

    // 3. Chờ một khoảng ngắn cho các dynamic framework/SDK của app nạp xong rồi vô hiệu hóa các method show
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SuppressAdSDKs();
    });
}
