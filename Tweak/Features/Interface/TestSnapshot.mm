#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "../Downloads/DownloadLog.h"

static id YTKACESnapshotValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return object != nil && [object respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(object, selector)
        : nil;
}

static BOOL YTKACESnapshotFlag(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return object != nil && [object respondsToSelector:selector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSUInteger YTKACESnapshotLength(id value) {
    return [value isKindOfClass:NSString.class] ? [value length] : 0;
}

static BOOL YTKACESnapshotShown(UIView *view) {
    if (view.window == nil) return NO;
    for (UIView *current = view; current != nil; current = current.superview) {
        if (current.hidden || current.alpha < 0.01) return NO;
    }
    return YES;
}

static NSString *YTKACESnapshotParents(UIView *view) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    UIView *current = view.superview;
    for (NSUInteger index = 0; current != nil && index < 4; index++, current = current.superview) {
        [names addObject:NSStringFromClass(current.class)];
    }
    return [names componentsJoinedByString:@"<"];
}

static BOOL YTKACESnapshotIsFeaturedWatermark(UIView *view) {
    Class overlayClass = NSClassFromString(@"YTMainAppVideoPlayerOverlayView");
    for (UIView *current = view.superview; current != nil; current = current.superview) {
        if (overlayClass != Nil && [current isKindOfClass:overlayClass]) {
            return YTKACESnapshotValue(current, @"featuredChannelWatermarkImageView") == view;
        }
    }
    return NO;
}

static void YTKACESnapshotWalk(UIView *view, NSMutableArray<NSString *> *lines, NSUInteger depth) {
    if (view == nil || depth > 120) return;
    NSString *name = NSStringFromClass(view.class);
    NSString *token = [[NSString stringWithFormat:@"%@ %@", name, view.accessibilityIdentifier ?: @""]
        lowercaseString];
    if ([name hasSuffix:@"PivotBarItemView"]) {
        id renderer = YTKACESnapshotValue(view, @"renderer");
        id iconOnly = YTKACESnapshotValue(view, @"iconOnlyItemRenderer");
        id source = renderer ?: iconOnly;
        id title = YTKACESnapshotValue(YTKACESnapshotValue(renderer, @"title"), @"stringWithFormattingRemoved");
        id accessibility = YTKACESnapshotValue(YTKACESnapshotValue(source, @"accessibility"), @"accessibilityData");
        id button = YTKACESnapshotValue(view, @"navigationButton");
        UILabel *label = [button isKindOfClass:UIButton.class] ? ((UIButton *)button).titleLabel : nil;
        [lines addObject:[NSString stringWithFormat:
            @"tab %@ id=%@ kind=%@ title=%lu a11y=%lu hideLabel=%d labelText=%lu labelShown=%d",
            name, YTKACESnapshotValue(source, @"pivotIdentifier") ?: @"-",
            renderer != nil ? @"item" : (iconOnly != nil ? @"iconOnly" : @"none"),
            (unsigned long)YTKACESnapshotLength(title),
            (unsigned long)YTKACESnapshotLength(YTKACESnapshotValue(accessibility, @"label")),
            YTKACESnapshotFlag(view, @"hideLabel"), (unsigned long)label.text.length,
            label != nil && YTKACESnapshotShown(label)]];
    }
    if ([token containsString:@"watermark"] || [token containsString:@"branding"]) {
        [lines addObject:[NSString stringWithFormat:
            @"watermark %@ id=%@ hidden=%d alpha=%.2f shown=%d featured=%d frame=%@ parents=%@",
            name, view.accessibilityIdentifier ?: @"-", view.hidden, view.alpha,
            YTKACESnapshotShown(view), YTKACESnapshotIsFeaturedWatermark(view),
            NSStringFromCGRect(view.frame), YTKACESnapshotParents(view)]];
    }
    for (UIView *subview in view.subviews) {
        YTKACESnapshotWalk(subview, lines, depth + 1);
    }
}

static NSString *YTKACESnapshotChain(UIView *view, NSUInteger count) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    UIView *current = view.superview;
    for (NSUInteger index = 0; current != nil && index < count; index++, current = current.superview) {
        NSString *identifier = current.accessibilityIdentifier;
        [names addObject:identifier.length != 0
            ? [NSString stringWithFormat:@"%@#%@", NSStringFromClass(current.class), identifier]
            : NSStringFromClass(current.class)];
    }
    return [names componentsJoinedByString:@"<"];
}

static void YTKACESnapshotCorner(UIView *view, UIWindow *window, NSMutableArray<NSString *> *lines, NSUInteger depth) {
    if (view == nil || depth > 120 || view.hidden || view.alpha < 0.01) return;
    CGRect frame = [view convertRect:view.bounds toView:window];
    CGFloat width = CGRectGetWidth(window.bounds);
    CGFloat height = CGRectGetHeight(window.bounds);
    if (CGRectGetMinX(frame) >= width * 0.8 && CGRectGetMinY(frame) >= height * 0.6 &&
        CGRectGetWidth(frame) >= 8.0 && CGRectGetHeight(frame) >= 8.0 &&
        CGRectGetWidth(frame) <= 160.0 && CGRectGetHeight(frame) <= 160.0) {
        UIImage *image = [view isKindOfClass:UIImageView.class] ? ((UIImageView *)view).image : nil;
        [lines addObject:[NSString stringWithFormat:
            @"corner %@ id=%@ label=%@ frame=%@ image=%@ contents=%d parents=%@",
            NSStringFromClass(view.class), view.accessibilityIdentifier ?: @"-",
            view.accessibilityLabel ?: @"-", NSStringFromCGRect(frame),
            image != nil ? NSStringFromCGSize(image.size) : @"-", view.layer.contents != nil,
            YTKACESnapshotChain(view, 10)]];
    }
    for (UIView *subview in view.subviews) {
        YTKACESnapshotCorner(subview, window, lines, depth + 1);
    }
}

static void YTKACESnapshotOverlays(UIView *view, NSMutableArray<NSString *> *lines, NSUInteger depth) {
    if (view == nil || depth > 120) return;
    if ([NSStringFromClass(view.class) isEqualToString:@"YTMainAppVideoPlayerOverlayView"]) {
        id watermark = YTKACESnapshotValue(view, @"featuredChannelWatermarkImageView");
        UIView *watermarkView = [watermark isKindOfClass:UIView.class] ? watermark : nil;
        [lines addObject:[NSString stringWithFormat:
            @"overlay enabled=%d watermark=%@ inWindow=%d hidden=%d super=%@",
            YTKACESnapshotFlag(view, @"isWatermarkEnabled"),
            watermark != nil ? NSStringFromClass([watermark class]) : @"nil",
            watermarkView.window != nil, watermarkView.hidden,
            watermarkView.superview != nil ? NSStringFromClass(watermarkView.superview.class) : @"-"]];
    }
    for (UIView *subview in view.subviews) {
        YTKACESnapshotOverlays(subview, lines, depth + 1);
    }
}

static void YTKACESnapshotTick(void) {
    if (!YTKACEDebugLogsEnabled()) return;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    BOOL landscape = NO;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            BOOL wide = CGRectGetWidth(window.bounds) > CGRectGetHeight(window.bounds);
            if (wide) landscape = YES;
            YTKACESnapshotWalk(window, lines, 0);
            YTKACESnapshotOverlays(window, lines, 0);
            if (wide) YTKACESnapshotCorner(window, window, lines, 0);
        }
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [lines insertObject:[NSString stringWithFormat:@"state landscape=%d watermarkPref=%d labelsHiddenPref=%d",
                         landscape,
                         [defaults boolForKey:@"YTKACE.Preference.Overlay.WatermarkHidden"],
                         [defaults boolForKey:@"YTKACE.Preference.Tabs.LabelsHidden"]]
                atIndex:0];
    static NSSet<NSString *> *previous;
    NSSet<NSString *> *current = [NSSet setWithArray:lines];
    if ([current isEqualToSet:previous]) return;
    for (NSString *line in lines) {
        if (![previous containsObject:line]) YTKACEDebugLog(@"snapshot", @"%@", line);
    }
    previous = current;
}

__attribute__((constructor)) static void YTKACEStartSnapshots(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) {
            YTKACESnapshotTick();
        }];
    });
}
