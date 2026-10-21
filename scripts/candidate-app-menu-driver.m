// Test-only menu driver for the packaged ClashFX app on a disposable GitHub
// hosted macOS runner. Load with DYLD_INSERT_LIBRARIES and set:
//
//   CLASHFX_ACCEPTANCE_COMMAND=/.../command.json
//   CLASHFX_ACCEPTANCE_RESPONSE=/.../response.json
//
// Atomically replace the command file with one request at a time:
//   {"id":"unique-id","action":"list"}
//   {"id":"unique-id","action":"invoke","title":"LocalFixture"}
//   {"id":"unique-id","action":"invoke","selector":"actionRestart:"}
//   {"id":"unique-id","action":"dismiss"}
//   {"id":"unique-id","action":"expect_reload_alert"}
//
// Responses have an `items` array containing the current menu graph. A visible
// modal alert is reported in `alert`. The explicit expectation acknowledges
// only a `Reload Config Fail` modal and writes its captured details to
// `<CLASHFX_ACCEPTANCE_RESPONSE>.reload-alert.json` after clicking its `OK`
// button. Other modal alerts stay open until a dismiss request. No app
// configuration, preferences, or helper state are written here.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <stdlib.h>
#import <unistd.h>

static NSString *const kCandidateBundleIdentifier = @"com.clashfx.app";

static NSTimer *gPollTimer;
static id gWindowBecameKeyObserver;
static id gWindowDidUpdateObserver;
static NSData *gLastRequestData;
static NSString *gLastRequestID;
static NSString *gExpectedReloadAlertRequestID;
static BOOL gRequestInProgress;

static NSString *EnvironmentValue(const char *name) {
    const char *value = getenv(name);
    if (value == NULL || value[0] == '\0') { return nil; }
    return [NSString stringWithUTF8String:value];
}

static BOOL PathIsInsideRunnerTemp(NSString *path) {
    NSString *runnerTemp = EnvironmentValue("RUNNER_TEMP");
    if (path.length == 0 || runnerTemp.length == 0) { return NO; }

    NSString *standardTemp = runnerTemp.stringByStandardizingPath;
    NSString *standardPath = path.stringByStandardizingPath;
    NSString *prefix = [standardTemp stringByAppendingString:@"/"];
    if (![standardPath hasPrefix:prefix]) { return NO; }

    // Resolve the parent too, so a symlink under RUNNER_TEMP cannot redirect
    // command or response files outside the hosted job's private directory.
    NSString *parent = standardPath.stringByDeletingLastPathComponent;
    NSURL *resolvedTempURL = [[NSURL fileURLWithPath:standardTemp] URLByResolvingSymlinksInPath];
    NSURL *resolvedParentURL = [[NSURL fileURLWithPath:parent] URLByResolvingSymlinksInPath];
    NSString *resolvedTemp = resolvedTempURL.path.stringByStandardizingPath;
    NSString *resolvedParent = resolvedParentURL.path.stringByStandardizingPath;
    NSString *resolvedPrefix = [resolvedTemp stringByAppendingString:@"/"];
    return [resolvedParent isEqualToString:resolvedTemp] || [resolvedParent hasPrefix:resolvedPrefix];
}

static BOOL IsHostedCandidateApp(void) {
    NSString *githubActions = EnvironmentValue("GITHUB_ACTIONS");
    NSString *runnerEnvironment = EnvironmentValue("RUNNER_ENVIRONMENT");
    NSString *runnerOS = EnvironmentValue("RUNNER_OS");
    NSString *workspace = EnvironmentValue("GITHUB_WORKSPACE");
    NSString *runnerTemp = EnvironmentValue("RUNNER_TEMP");
    NSString *ci = EnvironmentValue("CI");
    NSString *commandPath = EnvironmentValue("CLASHFX_ACCEPTANCE_COMMAND");
    NSString *responsePath = EnvironmentValue("CLASHFX_ACCEPTANCE_RESPONSE");
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;

    return [githubActions isEqualToString:@"true"] &&
        [runnerEnvironment isEqualToString:@"github-hosted"] &&
        [runnerOS isEqualToString:@"macOS"] &&
        [ci isEqualToString:@"true"] &&
        [workspace hasPrefix:@"/Users/runner/work/"] &&
        [runnerTemp hasPrefix:@"/Users/runner/work/"] &&
        [bundleIdentifier isEqualToString:kCandidateBundleIdentifier] &&
        PathIsInsideRunnerTemp(commandPath) &&
        PathIsInsideRunnerTemp(responsePath);
}

static NSMenu *StatusMenu(NSString **errorMessage) {
    id delegate = NSApp.delegate;
    if (delegate == nil) {
        if (errorMessage != NULL) { *errorMessage = @"application_delegate_unavailable"; }
        return nil;
    }

    id menu = nil;
    @try {
        // AppDelegate.statusMenu is an IBOutlet. KVC avoids linking this
        // standalone dylib against the app's generated Swift header.
        menu = [delegate valueForKey:@"statusMenu"];
    } @catch (NSException *exception) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"status_menu_lookup_failed:%@", exception.name];
        }
        return nil;
    }

    if (![menu isKindOfClass:NSMenu.class]) {
        if (errorMessage != NULL) { *errorMessage = @"status_menu_unavailable"; }
        return nil;
    }
    return (NSMenu *)menu;
}

static void RefreshStatusMenu(NSMenu *menu) {
    id<NSMenuDelegate> delegate = menu.delegate;
    if ([delegate respondsToSelector:@selector(menuNeedsUpdate:)]) {
        // This is the same delegate callback AppKit uses before displaying the
        // menu. It populates the current local YAML profile switcher.
        [delegate menuNeedsUpdate:menu];
    }
    [menu update];
}

static void AppendVisibleText(NSView *view, NSMutableArray<NSString *> *output) {
    if ([view isKindOfClass:NSTextField.class]) {
        NSString *value = ((NSTextField *)view).stringValue;
        NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0) { [output addObject:trimmed]; }
    }
    for (NSView *child in view.subviews) {
        AppendVisibleText(child, output);
    }
}

static void AppendButtons(NSView *view, NSMutableArray<NSButton *> *output) {
    if ([view isKindOfClass:NSButton.class]) { [output addObject:(NSButton *)view]; }
    for (NSView *child in view.subviews) { AppendButtons(child, output); }
}

static NSDictionary *AlertDetailsForWindow(NSWindow *window) {
    if (window == nil) { return nil; }

    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    if (window.contentView != nil) { AppendVisibleText(window.contentView, texts); }
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    if (window.contentView != nil) { AppendButtons(window.contentView, buttons); }

    NSMutableArray<NSString *> *buttonTitles = [NSMutableArray array];
    for (NSButton *button in buttons) {
        if (button.title.length > 0) { [buttonTitles addObject:button.title]; }
    }

    NSString *title = texts.firstObject ?: window.title ?: @"";
    NSArray<NSString *> *remaining = texts.count > 1 ? [texts subarrayWithRange:NSMakeRange(1, texts.count - 1)] : @[];
    return @{
        @"title": title,
        @"info": [remaining componentsJoinedByString:@"\n"],
        @"windowTitle": window.title ?: @"",
        @"buttons": buttonTitles
    };
}

static NSDictionary *CurrentAlert(void) {
    return AlertDetailsForWindow(NSApp.modalWindow);
}

static BOOL IsReloadConfigFailureAlert(NSDictionary *alert) {
    NSString *title = [alert[@"title"] isKindOfClass:NSString.class] ? alert[@"title"] : @"";
    NSString *windowTitle = [alert[@"windowTitle"] isKindOfClass:NSString.class] ? alert[@"windowTitle"] : @"";
    NSString *expectedTitle = @"Reload Config Fail";
    NSString *trimmedTitle = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *trimmedWindowTitle = [windowTitle stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [trimmedTitle caseInsensitiveCompare:expectedTitle] == NSOrderedSame ||
        [trimmedWindowTitle caseInsensitiveCompare:expectedTitle] == NSOrderedSame;
}

static NSButton *ReloadAlertOKButton(NSWindow *window) {
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    if (window.contentView != nil) { AppendButtons(window.contentView, buttons); }

    NSButton *match = nil;
    for (NSButton *button in buttons) {
        if (!button.enabled || button.isHidden || ![button.title isEqualToString:@"OK"]) { continue; }
        if (match != nil) { return nil; }
        match = button;
    }
    return match;
}

static NSButton *DismissButton(NSWindow *window) {
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    if (window.contentView != nil) { AppendButtons(window.contentView, buttons); }

    // Prefer a neutral dismissal. In particular, Reload Config Fail puts
    // "Edit in Text Mode" first and "OK" second; clicking its Return-key
    // default would launch an editor during acceptance.
    NSSet<NSString *> *safeTitles = [NSSet setWithArray:@[
        @"OK", @"Done", @"Close", @"Dismiss", @"Cancel",
        @"确定", @"好的", @"關閉", @"確定", @"閉じる", @"閉じる"
    ]];
    for (NSButton *button in buttons) {
        if (button.enabled && [safeTitles containsObject:button.title]) { return button; }
    }

    // Fall back to the alert's default button, then its last enabled button.
    for (NSButton *button in buttons) {
        NSString *key = button.keyEquivalent;
        if (button.enabled && ([key isEqualToString:@"\r"] || [key isEqualToString:@"\n"])) {
            return button;
        }
    }
    for (NSButton *button in buttons.reverseObjectEnumerator) {
        if (button.enabled) { return button; }
    }
    return nil;
}

static NSString *SelectorName(NSMenuItem *item) {
    return item.action == NULL ? @"" : NSStringFromSelector(item.action);
}

static NSString *TargetClassName(id target) {
    if (target == nil) { return @""; }
    return NSStringFromClass([target class]) ?: @"";
}

static NSDictionary *MenuItemMetadata(NSMenuItem *item,
                                      NSUInteger index,
                                      NSArray<NSString *> *menuPath,
                                      NSArray<NSString *> *itemPath,
                                      BOOL ancestorVisible,
                                      BOOL ancestorEnabled) {
    NSString *title = item.title ?: @"";
    NSMutableArray<NSString *> *nextItemPath = [itemPath mutableCopy];
    [nextItemPath addObject:title];

    return @{
        @"title": title,
        @"selector": SelectorName(item),
        @"enabled": @(ancestorEnabled && item.enabled),
        @"state": @((NSInteger)item.state),
        @"path": nextItemPath,
        @"menuPath": menuPath,
        @"index": @(index),
        @"hidden": @(!ancestorVisible || item.hidden),
        @"keyEquivalent": item.keyEquivalent ?: @"",
        @"targetClass": TargetClassName(item.target),
        @"separator": @(item.isSeparatorItem),
        @"hasSubmenu": @(item.submenu != nil)
    };
}

static void AppendMenuGraph(NSMenu *menu,
                            NSArray<NSString *> *menuPath,
                            NSArray<NSString *> *itemPath,
                            BOOL ancestorVisible,
                            BOOL ancestorEnabled,
                            NSMutableSet<NSValue *> *visitedMenus,
                            NSMutableArray<NSDictionary *> *output) {
    if (menu == nil || menuPath.count > 32) { return; }
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)menu];
    if ([visitedMenus containsObject:identity]) { return; }
    [visitedMenus addObject:identity];

    NSArray<NSMenuItem *> *items = [menu.itemArray copy];
    [items enumerateObjectsUsingBlock:^(NSMenuItem *item, NSUInteger index, BOOL *stop) {
        [output addObject:MenuItemMetadata(item, index, menuPath, itemPath,
                                           ancestorVisible, ancestorEnabled)];
        if (item.submenu == nil) { return; }

        NSString *component = item.title.length > 0 ? item.title : @"(untitled)";
        NSMutableArray<NSString *> *nextMenuPath = [menuPath mutableCopy];
        [nextMenuPath addObject:component];
        NSMutableArray<NSString *> *nextItemPath = [itemPath mutableCopy];
        [nextItemPath addObject:item.title ?: @""];
        AppendMenuGraph(item.submenu, nextMenuPath, nextItemPath,
                        ancestorVisible && !item.hidden,
                        ancestorEnabled && item.enabled,
                        visitedMenus, output);
    }];
}

static NSArray<NSDictionary *> *MenuItems(NSMenu *menu) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSValue *> *visitedMenus = [NSMutableSet set];
    AppendMenuGraph(menu, @[@"statusMenu"], @[], YES, YES, visitedMenus, items);
    return items;
}

static void FindMatches(NSMenu *menu,
                        NSString *title,
                        NSString *selector,
                        NSArray<NSString *> *menuPath,
                        NSArray<NSString *> *itemPath,
                        BOOL ancestorVisible,
                        BOOL ancestorEnabled,
                        NSMutableSet<NSValue *> *visitedMenus,
                        NSMutableArray<NSDictionary *> *metadata,
                        NSMutableArray<NSMenuItem *> *items) {
    if (menu == nil || menuPath.count > 32) { return; }
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)menu];
    if ([visitedMenus containsObject:identity]) { return; }
    [visitedMenus addObject:identity];

    NSArray<NSMenuItem *> *menuItems = [menu.itemArray copy];
    [menuItems enumerateObjectsUsingBlock:^(NSMenuItem *item, NSUInteger index, BOOL *stop) {
        BOOL titleMatches = title.length == 0 || [item.title isEqualToString:title];
        BOOL selectorMatches = selector.length == 0 || [SelectorName(item) isEqualToString:selector];
        if (titleMatches && selectorMatches) {
            [metadata addObject:MenuItemMetadata(item, index, menuPath, itemPath,
                                                 ancestorVisible, ancestorEnabled)];
            [items addObject:item];
        }

        if (item.submenu == nil) { return; }
        NSString *component = item.title.length > 0 ? item.title : @"(untitled)";
        NSMutableArray<NSString *> *nextMenuPath = [menuPath mutableCopy];
        [nextMenuPath addObject:component];
        NSMutableArray<NSString *> *nextItemPath = [itemPath mutableCopy];
        [nextItemPath addObject:item.title ?: @""];
        FindMatches(item.submenu, title, selector, nextMenuPath, nextItemPath,
                    ancestorVisible && !item.hidden,
                    ancestorEnabled && item.enabled,
                    visitedMenus, metadata, items);
    }];
}

static NSMutableDictionary *Response(NSString *requestID, BOOL ok) {
    return [@{
        @"id": requestID ?: @"",
        @"ok": @(ok),
        @"pid": @(getpid()),
        @"items": @[]
    } mutableCopy];
}

static void WriteResponse(NSDictionary *response) {
    NSString *path = EnvironmentValue("CLASHFX_ACCEPTANCE_RESPONSE");
    if (!PathIsInsideRunnerTemp(path)) { return; }

    NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    if (data != nil) {
        [data writeToURL:[NSURL fileURLWithPath:path] options:NSDataWritingAtomic error:nil];
    }
}

static NSString *ReloadAlertEventPath(void) {
    NSString *responsePath = EnvironmentValue("CLASHFX_ACCEPTANCE_RESPONSE");
    if (!PathIsInsideRunnerTemp(responsePath)) { return nil; }

    NSString *eventPath = [responsePath stringByAppendingString:@".reload-alert.json"];
    return PathIsInsideRunnerTemp(eventPath) ? eventPath : nil;
}

static void WriteReloadAlertEvent(NSDictionary *event) {
    NSString *path = ReloadAlertEventPath();
    if (path == nil) { return; }

    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (data != nil) {
        [data writeToURL:[NSURL fileURLWithPath:path] options:NSDataWritingAtomic error:nil];
    }
}

static void HandleExpectedReloadAlertNotification(NSNotification *notification) {
    if (![NSThread isMainThread] || !IsHostedCandidateApp() || gExpectedReloadAlertRequestID.length == 0) { return; }

    NSWindow *window = [notification.object isKindOfClass:NSWindow.class] ? notification.object : nil;
    if (window == nil || NSApp.modalWindow != window) { return; }

    NSDictionary *alert = AlertDetailsForWindow(window);
    if (!IsReloadConfigFailureAlert(alert)) { return; }

    NSString *eventPath = ReloadAlertEventPath();
    if (eventPath == nil) { return; }

    // Clear the one-shot arm before clicking: performClick may synchronously
    // post another window notification while NSAlert is unwinding its modal loop.
    NSString *requestID = [gExpectedReloadAlertRequestID copy];
    gExpectedReloadAlertRequestID = nil;

    NSMutableDictionary *event = [@{
        @"id": requestID,
        @"pid": @(getpid()),
        @"title": alert[@"title"] ?: @"",
        @"info": alert[@"info"] ?: @"",
        @"windowTitle": alert[@"windowTitle"] ?: @"",
        @"buttons": alert[@"buttons"] ?: @[],
        @"capturedAt": @([NSDate date].timeIntervalSince1970),
        @"acknowledged": @NO
    } mutableCopy];

    NSButton *button = ReloadAlertOKButton(window);
    if (button == nil) {
        event[@"error"] = @"reload_alert_has_no_unique_enabled_ok_button";
        WriteReloadAlertEvent(event);
        return;
    }

    event[@"acknowledgedButton"] = button.title ?: @"";
    WriteReloadAlertEvent(event);
    @try {
        [button performClick:nil];
        event[@"acknowledged"] = @YES;
        event[@"acknowledgedAt"] = @([NSDate date].timeIntervalSince1970);
    } @catch (NSException *exception) {
        event[@"error"] = [NSString stringWithFormat:@"reload_alert_acknowledgment_failed:%@", exception.name];
    }
    // The event is written only after the actual alert button action returns.
    WriteReloadAlertEvent(event);
}

static NSDictionary *HandleRequest(NSDictionary *request,
                                   NSString *requestID,
                                   BOOL *responseWrittenBeforeAction) {
    NSString *action = [request[@"action"] isKindOfClass:NSString.class] ? request[@"action"] : @"";
    NSMutableDictionary *response = Response(requestID, NO);
    response[@"action"] = action;

    NSMenu *menu = StatusMenu(nil);
    // A status query must stay read-only, especially while NSAlert owns a
    // modal loop. Updating NSMenu there can wait for that same alert to end.
    if (menu != nil && [action isEqualToString:@"invoke"] && NSApp.modalWindow == nil) { RefreshStatusMenu(menu); }
    response[@"items"] = menu == nil ? @[] : MenuItems(menu);

    NSDictionary *alert = CurrentAlert();
    if (alert != nil) { response[@"alert"] = alert; }

    if ([action isEqualToString:@"expect_reload_alert"]) {
        if (gExpectedReloadAlertRequestID.length > 0) {
            response[@"error"] = @"reload_alert_expectation_already_armed";
            return response;
        }
        if (NSApp.modalWindow != nil) {
            response[@"error"] = @"modal_alert_already_open";
            return response;
        }
        NSString *eventPath = ReloadAlertEventPath();
        if (eventPath == nil) {
            response[@"error"] = @"reload_alert_event_path_outside_runner_temp";
            return response;
        }
        gExpectedReloadAlertRequestID = [requestID copy];
        response[@"ok"] = @YES;
        response[@"armedFor"] = @"Reload Config Fail";
        response[@"eventPath"] = eventPath;
        return response;
    }

    if ([action isEqualToString:@"list"]) {
        if (menu == nil) {
            response[@"error"] = @"status_menu_unavailable";
            return response;
        }
        response[@"ok"] = @YES;
        return response;
    }

    if ([action isEqualToString:@"dismiss"]) {
        NSWindow *window = NSApp.modalWindow;
        if (window == nil) {
            response[@"error"] = @"no_modal_alert";
            return response;
        }
        NSButton *button = DismissButton(window);
        if (button == nil) {
            response[@"error"] = @"modal_alert_has_no_enabled_dismiss_button";
            return response;
        }
        response[@"dismissedButton"] = button.title ?: @"";
        [button performClick:nil];
        response[@"ok"] = @YES;
        return response;
    }

    if (![action isEqualToString:@"invoke"]) {
        response[@"error"] = @"unsupported_action";
        return response;
    }
    if (menu == nil) {
        response[@"error"] = @"status_menu_unavailable";
        return response;
    }
    if (alert != nil) {
        response[@"error"] = @"modal_alert_open_use_dismiss_first";
        return response;
    }

    NSString *title = [request[@"title"] isKindOfClass:NSString.class] ? request[@"title"] : @"";
    NSString *selector = [request[@"selector"] isKindOfClass:NSString.class] ? request[@"selector"] : @"";
    if (title.length == 0 && selector.length == 0) {
        response[@"error"] = @"title_or_selector_required";
        return response;
    }

    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    NSMutableArray<NSMenuItem *> *matchingItems = [NSMutableArray array];
    NSMutableSet<NSValue *> *visitedMenus = [NSMutableSet set];
    FindMatches(menu, title, selector, @[@"statusMenu"], @[], YES, YES,
                visitedMenus, matches, matchingItems);
    response[@"matches"] = matches;

    NSMutableArray<NSNumber *> *enabledIndexes = [NSMutableArray array];
    [matchingItems enumerateObjectsUsingBlock:^(NSMenuItem *item, NSUInteger index, BOOL *stop) {
        NSDictionary *metadata = matches[index];
        if ([metadata[@"enabled"] boolValue] && ![metadata[@"hidden"] boolValue] && item.action != NULL) {
            [enabledIndexes addObject:@(index)];
        }
    }];
    if (enabledIndexes.count == 0) {
        response[@"error"] = matches.count == 0 ? @"no_matching_item" : @"no_enabled_matching_item";
        return response;
    }
    if (enabledIndexes.count != 1) {
        response[@"error"] = @"ambiguous_menu_item";
        return response;
    }

    NSUInteger selectedIndex = enabledIndexes.firstObject.unsignedIntegerValue;
    NSMenuItem *item = matchingItems[selectedIndex];
    SEL selectorToSend = item.action;
    id target = item.target;
    if (target == nil) { target = [NSApp targetForAction:selectorToSend to:nil from:item]; }
    if (target == nil || ![target respondsToSelector:selectorToSend]) {
        response[@"error"] = @"menu_target_unavailable";
        return response;
    }

    response[@"ok"] = @YES;
    response[@"invoked"] = matches[selectedIndex];

    // A real restart or quit can terminate this process during sendAction.
    // Persist the acknowledgment first; the parent observes replacement
    // processes independently and does not assume DYLD injection survives.
    NSString *selectorName = NSStringFromSelector(selectorToSend);
    BOOL terminatesApp = [selectorName isEqualToString:@"actionRestart:"] ||
        [selectorName isEqualToString:@"actionQuit:"];
    if (terminatesApp) {
        WriteResponse(response);
        if (responseWrittenBeforeAction != NULL) { *responseWrittenBeforeAction = YES; }
    }

    if (![NSApp sendAction:selectorToSend to:target from:item]) {
        response[@"ok"] = @NO;
        response[@"error"] = @"menu_action_not_handled";
    }
    return response;
}

static void PollCommandFile(void) {
    if (gRequestInProgress || !IsHostedCandidateApp()) { return; }

    NSString *commandPath = EnvironmentValue("CLASHFX_ACCEPTANCE_COMMAND");
    NSData *data = [NSData dataWithContentsOfFile:commandPath options:0 error:nil];
    if (data == nil || [data isEqualToData:gLastRequestData]) { return; }
    gLastRequestData = [data copy];

    NSError *parseError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
    NSDictionary *request = [object isKindOfClass:NSDictionary.class] ? object : nil;
    NSString *requestID = [request[@"id"] isKindOfClass:NSString.class] ? request[@"id"] : nil;
    if (requestID.length == 0) {
        NSMutableDictionary *response = Response(@"", NO);
        response[@"error"] = parseError == nil ? @"request_id_required" : @"invalid_json";
        WriteResponse(response);
        return;
    }
    if ([requestID isEqualToString:gLastRequestID]) { return; }
    gLastRequestID = [requestID copy];

    gRequestInProgress = YES;
    BOOL responseWrittenBeforeAction = NO;
    NSDictionary *response = HandleRequest(request ?: @{}, requestID, &responseWrittenBeforeAction);
    if (!responseWrittenBeforeAction) { WriteResponse(response); }
    gRequestInProgress = NO;
}

__attribute__((constructor))
static void InstallCandidateAppMenuDriver(void) {
    @autoreleasepool {
        if (!IsHostedCandidateApp()) { return; }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (gPollTimer != nil) { return; }
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            gWindowBecameKeyObserver = [center addObserverForName:NSWindowDidBecomeKeyNotification
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:^(NSNotification *notification) {
                @autoreleasepool { HandleExpectedReloadAlertNotification(notification); }
            }];
            gWindowDidUpdateObserver = [center addObserverForName:NSWindowDidUpdateNotification
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:^(NSNotification *notification) {
                @autoreleasepool { HandleExpectedReloadAlertNotification(notification); }
            }];
            gPollTimer = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
                @autoreleasepool { PollCommandFile(); }
            }];
            // NSAlert.runModal spins a nested modal-panel run loop. Registering
            // in common modes keeps list/dismiss commands available there.
            [[NSRunLoop mainRunLoop] addTimer:gPollTimer forMode:NSRunLoopCommonModes];
            [[NSRunLoop mainRunLoop] addTimer:gPollTimer forMode:NSModalPanelRunLoopMode];
        });
    }
}
