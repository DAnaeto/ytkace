#import "../Downloads/DownloadLog.h"
#import "../../YTKACE.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSUInteger const YTKACEDiagnosticMaxDepth = 6;
static NSUInteger const YTKACEDiagnosticNodeBudget = 80;
static NSUInteger const YTKACEDiagnosticArrayLimit = 8;
static NSUInteger const YTKACEDiagnosticSeenLimit = 1000;
static NSUInteger const YTKACEDiagnosticViewBudget = 600;
static NSUInteger const YTKACEDiagnosticIdentifierLimit = 96;

static BOOL YTKACEDiagnosticFirstSighting(NSString *signature) {
    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        seen = [NSMutableSet set];
    });
    @synchronized(seen) {
        if (seen.count >= YTKACEDiagnosticSeenLimit || [seen containsObject:signature]) return NO;
        [seen addObject:signature];
        return YES;
    }
}

static id YTKACEDiagnosticValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL YTKACEDiagnosticHas(id object, NSString *name) {
    if (name.length == 0) return NO;
    NSString *capitalized = [[name substringToIndex:1].uppercaseString
        stringByAppendingString:[name substringFromIndex:1]];
    SEL selector = NSSelectorFromString([@"has" stringByAppendingString:capitalized]);
    if (![object respondsToSelector:selector]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static NSArray<NSString *> *YTKACEDiagnosticFieldNames(id message) {
    id fields = YTKACEDiagnosticValue(YTKACEDiagnosticValue([message class], @"descriptor"), @"fields");
    if (![fields isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id field in (NSArray *)fields) {
        id name = YTKACEDiagnosticValue(field, @"name");
        if ([name isKindOfClass:NSString.class] && [name length] != 0) [names addObject:name];
    }
    return names;
}

static BOOL YTKACEDiagnosticFollows(NSString *name) {
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"renderer"] || [lower hasPrefix:@"contents"] ||
        [lower hasPrefix:@"items"] || [lower isEqualToString:@"content"];
}

static NSString *YTKACEDiagnosticIdentifier(id node) {
    for (NSString *name in @[@"elementIdentifier", @"sharedElementIdentifier"]) {
        id value = YTKACEDiagnosticValue(node, name);
        if (![value isKindOfClass:NSString.class] || [value length] == 0) continue;
        return [value length] > YTKACEDiagnosticIdentifierLimit
            ? [value substringToIndex:YTKACEDiagnosticIdentifierLimit] : value;
    }
    return nil;
}

static NSString *YTKACEDiagnosticTree(id node, NSUInteger depth, NSUInteger *budget, NSHashTable *path) {
    NSMutableString *text = [NSStringFromClass([node class]) mutableCopy];
    NSString *identifier = YTKACEDiagnosticIdentifier(node);
    if (identifier != nil) [text appendFormat:@"#%@", identifier];
    Class messageClass = NSClassFromString(@"GPBMessage");
    if (messageClass == Nil || depth >= YTKACEDiagnosticMaxDepth || *budget == 0 || [path containsObject:node]) {
        return text;
    }
    [path addObject:node];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *name in YTKACEDiagnosticFieldNames(node)) {
        if (*budget == 0) break;
        if (!YTKACEDiagnosticFollows(name)) continue;
        if ([name hasSuffix:@"Array"]) {
            id values = YTKACEDiagnosticValue(node, name);
            if (![values isKindOfClass:NSArray.class]) continue;
            NSMutableOrderedSet<NSString *> *children = [NSMutableOrderedSet orderedSet];
            for (id child in (NSArray *)values) {
                if (*budget == 0 || children.count >= YTKACEDiagnosticArrayLimit) break;
                if (![child isKindOfClass:messageClass]) continue;
                (*budget)--;
                [children addObject:YTKACEDiagnosticTree(child, depth + 1, budget, path)];
            }
            if (children.count != 0) {
                [parts addObject:[NSString stringWithFormat:@"%@:[%@]", name,
                    [children.array componentsJoinedByString:@", "]]];
            }
        } else if (YTKACEDiagnosticHas(node, name)) {
            id child = YTKACEDiagnosticValue(node, name);
            if (![child isKindOfClass:messageClass]) continue;
            (*budget)--;
            [parts addObject:[NSString stringWithFormat:@"%@:%@", name,
                YTKACEDiagnosticTree(child, depth + 1, budget, path)]];
        }
    }
    [path removeObject:node];
    if (parts.count != 0) [text appendFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
    return text;
}

static BOOL YTKACEDiagnosticMentionsMembers(id section) {
    Class messageClass = NSClassFromString(@"GPBMessage");
    if (messageClass == Nil || ![section isKindOfClass:messageClass]) return NO;
    id data = YTKACEDiagnosticValue(section, @"data");
    if (![data isKindOfClass:NSData.class] || [data length] == 0) return NO;
    NSData *needle = [@"Members only" dataUsingEncoding:NSUTF8StringEncoding];
    return [data rangeOfData:needle options:0 range:NSMakeRange(0, [data length])].location != NSNotFound;
}

static NSString *YTKACEDiagnosticBrowse(id receiver) {
    id parent = YTKACEDiagnosticValue(receiver, @"parentViewController");
    for (id object in @[receiver ?: NSNull.null, parent ?: NSNull.null]) {
        for (NSString *name in @[@"browseID", @"browseIdentifier"]) {
            id value = YTKACEDiagnosticValue(object, name);
            if (![value isKindOfClass:NSString.class] || [value length] == 0) continue;
            return [value hasPrefix:@"FE"] || [value hasPrefix:@"SP"] ? value : @"other";
        }
    }
    return @"-";
}

void YTKACEDiagnoseFeedSections(id receiver, NSArray *sections) {
    if (!YTKACEDebugLogsEnabled() || ![sections isKindOfClass:NSArray.class]) return;
    Class parentClass = [YTKACEDiagnosticValue(receiver, @"parentViewController") class];
    NSString *parent = parentClass != Nil ? NSStringFromClass(parentClass) : @"-";
    NSString *browse = YTKACEDiagnosticBrowse(receiver);
    for (id section in sections) {
        NSUInteger budget = YTKACEDiagnosticNodeBudget;
        NSHashTable *path = [[NSHashTable alloc]
            initWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                   capacity:8];
        NSString *line = [NSString stringWithFormat:@"feed parent=%@ browse=%@ members=%d %@", parent, browse,
            YTKACEDiagnosticMentionsMembers(section), YTKACEDiagnosticTree(section, 0, &budget, path)];
        if (YTKACEDiagnosticFirstSighting(line)) YTKACEDebugLog(@"diag", @"%@", line);
    }
}

static NSString *YTKACEDiagnosticViewIvars(Class cls) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (Class current = cls; current != Nil && current != UIView.class; current = class_getSuperclass(current)) {
        if (![NSStringFromClass(current) hasPrefix:@"YT"]) break;
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            const char *name = ivar_getName(ivars[index]);
            if (type == NULL || name == NULL || strncmp(type, "@\"", 2) != 0 || strlen(type) < 4) continue;
            NSString *typeName = [[NSString alloc] initWithBytes:type + 2 length:strlen(type) - 3
                                                        encoding:NSUTF8StringEncoding];
            typeName = [typeName componentsSeparatedByString:@"<"].firstObject;
            Class ivarClass = typeName.length != 0 ? NSClassFromString(typeName) : Nil;
            if (ivarClass == Nil || ![ivarClass isSubclassOfClass:UIView.class]) continue;
            [parts addObject:[NSString stringWithFormat:@"%s:%@", name, typeName]];
        }
        free(ivars);
    }
    return [parts componentsJoinedByString:@", "];
}

static void YTKACEDiagnosticWalkViews(UIView *view, NSUInteger depth, NSUInteger *budget, NSHashTable *visited) {
    if (view == nil || *budget == 0 || depth > 12) return;
    (*budget)--;
    if (![visited containsObject:view]) {
        [visited addObject:view];
        NSString *name = NSStringFromClass(view.class);
        NSString *identifier = view.accessibilityIdentifier;
        if (identifier.length > YTKACEDiagnosticIdentifierLimit) {
            identifier = [identifier substringToIndex:YTKACEDiagnosticIdentifierLimit];
        }
        NSString *line = [NSString stringWithFormat:@"overlay view=%@ id=%@ parent=%@", name,
            identifier.length != 0 ? identifier : @"-",
            view.superview != nil ? NSStringFromClass(view.superview.class) : @"-"];
        if (YTKACEDiagnosticFirstSighting(line)) YTKACEDebugLog(@"diag", @"%@", line);
        if ([name hasPrefix:@"YT"] && YTKACEDiagnosticFirstSighting([@"ivars " stringByAppendingString:name])) {
            NSString *ivars = YTKACEDiagnosticViewIvars(view.class);
            if (ivars.length != 0) YTKACEDebugLog(@"diag", @"overlay ivars %@: %@", name, ivars);
        }
    }
    for (UIView *subview in view.subviews) {
        YTKACEDiagnosticWalkViews(subview, depth + 1, budget, visited);
    }
}

void YTKACEDiagnoseOverlay(UIView *overlay) {
    if (overlay == nil || !YTKACEDebugLogsEnabled()) return;
    static NSHashTable<UIView *> *visited;
    if (visited == nil) visited = [NSHashTable weakObjectsHashTable];
    NSUInteger budget = YTKACEDiagnosticViewBudget;
    YTKACEDiagnosticWalkViews(overlay, 0, &budget, visited);
}
