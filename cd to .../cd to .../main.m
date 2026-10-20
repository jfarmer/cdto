//
//  main.m
//  cd to ...
//
//  Created by James Tuley on 10/9/19.
//  Copyright © 2019 Jay Tuley. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <ScriptingBridge/ScriptingBridge.h>

#import "Finder.h"
#import "Terminal.h"

#pragma mark - Constants

// Terminal application bundle identifiers
static NSString * const CDTTerminalAppBundleIdentifier = @"com.apple.Terminal";
static NSString * const CDTKittyBundleIdentifier = @"net.kovidgoyal.kitty";

// Configuration keys
static NSString * const CDTPreferredTerminalKey = @"cdto-preferred-terminal";
static NSString * const CDTNewWindowSettingKey = @"cdto-new-window-setting";
static NSString * const CDTCloseDefaultWindowKey = @"cdto-close-default-window";
static NSString * const CDTKittySessionKey = @"cdto-kitty-session";

// Kitty remote control settings
static NSString * const CDTKittySocketPath = @"/tmp/cdto-kitty";
static NSTimeInterval const CDTKittySocketWaitTimeout = 5.0;
static NSTimeInterval const CDTKittySocketPollInterval = 0.05;
static NSTimeInterval const CDTTerminalBusyWaitInterval = 0.1;

// Terminal preference values
static NSString * const CDTTerminalPreferenceKitty = @"kitty";

#pragma mark - Helper Functions

/**
 * Counts the number of lines in a Terminal tab's history.
 * Used for detecting automatically opened launch windows.
 */
NSUInteger linesOfHistory(TerminalTab* tab) {
    NSString* hist = [[tab history] stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    return [[hist componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] count];
}

/**
 * Resolves the target directory from Finder selection or active window.
 * Handles aliases and ensures we get a directory path.
 */
NSURL * _Nullable resolveFinderTarget(FinderApplication *finder) {
    FinderItem *target = [(NSArray*)[[finder selection] get] firstObject];
    FinderFinderWindow* findWin = [[finder FinderWindows] objectAtLocation:@1];
    findWin = [[finder FinderWindows] objectWithID:[NSNumber numberWithInteger: findWin.id]];
    
    BOOL isSelected = (target != nil);
    if (target == nil) {
        target = [[findWin target] get];
    }
    
    // Handle aliases by getting the original item
    NSDictionary* itemProperties = [target properties];
    id originalItem = [itemProperties objectForKey:@"originalItem"];
    if (originalItem != nil && originalItem != [NSNull null]) {
        target = originalItem;
    }
    
    NSString* fileUrl = [target URL];
    if (!fileUrl) {
        return nil;
    }
    
    // For selected files, get the parent directory
    if (![fileUrl hasSuffix:@"/"] && isSelected) {
        fileUrl = [fileUrl stringByDeletingLastPathComponent];
    }
    
    return [NSURL URLWithString:fileUrl];
}

/**
 * Opens a directory in Terminal.app using the existing logic.
 */
BOOL openDirectoryInTerminal(NSURL *url) {
    TerminalApplication* terminal = [SBApplication applicationWithBundleIdentifier:CDTTerminalAppBundleIdentifier];
    if (!terminal) {
        NSLog(@"Error: Could not connect to Terminal.app");
        return NO;
    }
    
    // Track existing window for auto-close feature
    TerminalWindow* existingWin = nil;
    if ([[terminal windows] count] == 1) {
        //get front most and then reference by id
        existingWin = [[terminal windows] objectAtLocation:@1];
        existingWin = [[terminal windows] objectWithID: [NSNumber numberWithInteger:existingWin.id]];
    }
    
    [terminal open:@[url]];
    
    //get front most and then reference by id
    TerminalWindow* newWin = [[terminal windows] objectAtLocation:@1];
    newWin = [[terminal windows] objectWithID: [NSNumber numberWithInteger:newWin.id]];
    TerminalTab* newTab = [[newWin tabs] objectAtLocation:@1];
    
    if (!newTab) {
        NSLog(@"Warning: Could not access new Terminal tab");
        [terminal activate];
        return YES; // Directory was opened, just couldn't configure it
    }
    
    NSString* setName = [[NSUserDefaults standardUserDefaults] stringForKey:CDTNewWindowSettingKey];
    if (setName && ![setName isEqualToString:@""]) { //setting set
        TerminalSettingsSet* chosenSet = nil;
        for (TerminalSettingsSet *set in [terminal settingsSets]) {
            if([[set name] isEqualToString:setName]){
                chosenSet = set;
            }
        }
        if (chosenSet) {
            newTab.currentSettings = chosenSet;
        }
    }
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:CDTCloseDefaultWindowKey]) { //close first launch window
        if ([[existingWin tabs] count] == 1) {
            TerminalTab* existingTab = [[existingWin tabs] objectAtLocation:@1];
            if (![existingTab busy]) {
                //if history has same number of lines as new window
                // assume automatically opened new window, and close it
                NSUInteger oldTabLines = linesOfHistory(existingTab);
                while([newTab busy]){
                    [NSThread sleepForTimeInterval:CDTTerminalBusyWaitInterval];
                }
                NSUInteger newTabLines = linesOfHistory(newTab);
                if (oldTabLines == newTabLines) {
                    [existingWin closeSaving:TerminalSaveOptionsNo savingIn:nil];
                }
            }
        }
    }
    
    [terminal activate];
    return YES;
}

/**
 * Checks if Kitty is properly configured for remote control.
 */
BOOL isKittyConfigured(void) {
    NSString *configPath = [@"~/.config/kitty/macos-launch-services-cmdline" stringByExpandingTildeInPath];
    NSString *content = [NSString stringWithContentsOfFile:configPath 
                                                   encoding:NSUTF8StringEncoding 
                                                      error:nil];
    
    BOOL allowsRemoteControl = ([content containsString:@"allow_remote_control=yes"] ||
                                [content containsString:@"allow_remote_control=socket-only"]);
    return (allowsRemoteControl && [content containsString:@"--listen-on"]);
}

/**
 * Shows setup instructions for Kitty configuration.
 */
void showKittySetupAlert(void) {
    [NSApplication sharedApplication];
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Kitty Setup Required"];
    [alert setInformativeText:[NSString stringWithFormat:
        @"To use cd to... with Kitty:\n\n"
        @"1. Create ~/.config/kitty/macos-launch-services-cmdline\n"
        @"2. Add this line: --single-instance -o allow_remote_control=socket-only --listen-on unix:%@\n"
        @"3. Restart Kitty\n\n"
        @"Falling back to Terminal.app for now.", CDTKittySocketPath]];
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

/**
 * Gets the path to the kitten executable from the Kitty app bundle.
 */
NSString * _Nullable getKittenExecutablePath(void) {
    NSURL *kittyURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:CDTKittyBundleIdentifier];
    if (!kittyURL) {
        NSLog(@"Error: Could not find Kitty application bundle");
        return nil;
    }
    
    NSString *kittenPath = [[kittyURL path] stringByAppendingPathComponent:@"Contents/MacOS/kitten"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:kittenPath]) {
        NSLog(@"Error: kitten executable not found at %@", kittenPath);
        return nil;
    }
    
    return kittenPath;
}

/**
 * Executes a Kitty command via kitten @ and returns success status.
 */
BOOL executeKittyCommand(NSString *kittenPath, NSArray<NSString *> *arguments) {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:kittenPath];
    [task setArguments:[@[@"@", @"--to", [@"unix:" stringByAppendingString:CDTKittySocketPath]] arrayByAddingObjectsFromArray:arguments]];
    
    // Capture error output for debugging
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardError:errorPipe];
    
    @try {
        [task launch];
        // Read stderr before waiting: kitten blocks if it fills the pipe buffer.
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
        
        if ([task terminationStatus] != 0) {
            NSString *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
            NSLog(@"Kitty command failed with status %d: %@", [task terminationStatus], errorString);
            return NO;
        }
        
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"Exception executing Kitty command: %@", exception.reason);
        return NO;
    }
}

/**
 * Opens a directory in Kitty using remote control commands.
 */
BOOL openDirectoryInKitty(NSURL *url) {
    if (!isKittyConfigured()) {
        NSLog(@"Kitty is not configured for remote control");
        showKittySetupAlert();
        return NO;
    }
    
    NSString *kittenPath = getKittenExecutablePath();
    if (!kittenPath) {
        return NO;
    }
    
    // launchApplication: also activates Kitty when it is already running,
    // so call it either way and only wait for the socket on a cold start.
    BOOL kittyWasRunning = [[NSRunningApplication runningApplicationsWithBundleIdentifier:CDTKittyBundleIdentifier] count] > 0;
    if (![[NSWorkspace sharedWorkspace] launchApplication:@"kitty"]) {
        NSLog(@"Failed to launch Kitty");
        return NO;
    }
    
    // A Kitty that was already running either has the socket or will not
    // create it until it is restarted, so only a new Kitty is waited for.
    if (!kittyWasRunning) {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:CDTKittySocketWaitTimeout];
        while (![[NSFileManager defaultManager] fileExistsAtPath:CDTKittySocketPath] && [deadline timeIntervalSinceNow] > 0) {
            [NSThread sleepForTimeInterval:CDTKittySocketPollInterval];
        }
    }
    
    NSString *cwdArgument = [@"--cwd=" stringByAppendingString:[url path]];
    if (!executeKittyCommand(kittenPath, @[@"launch", @"--type=tab", cwdArgument])) {
        return NO;
    }
    
    NSString *sessionName = [[NSUserDefaults standardUserDefaults] stringForKey:CDTKittySessionKey];
    if (sessionName.length > 0) {
        NSString *sessionPath = [NSString stringWithFormat:@"~/.config/kitty/sessions/%@.conf", sessionName];
        sessionPath = [sessionPath stringByExpandingTildeInPath];
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:sessionPath]) {
            executeKittyCommand(kittenPath, @[@"launch", @"--session", sessionPath]); // Non-fatal if this fails
        }
    }
    
    return YES;
}

#pragma mark - Main Function

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
        FinderApplication* finder = [SBApplication applicationWithBundleIdentifier:@"com.apple.Finder"];
        if (!finder) {
            NSLog(@"Error: Could not connect to Finder");
            return 1;
        }
        
        NSURL *targetURL = resolveFinderTarget(finder);
        if (!targetURL) {
            NSLog(@"Error: Could not determine target directory from Finder");
            return 1;
        }
        
        NSString *preferredTerminal = [[NSUserDefaults standardUserDefaults] stringForKey:CDTPreferredTerminalKey];
        
        BOOL success = NO;
        if ([preferredTerminal isEqualToString:CDTTerminalPreferenceKitty]) {
            success = openDirectoryInKitty(targetURL);
            if (!success) {
                NSLog(@"Falling back to Terminal.app");
            }
        }
        if (!success) {
            success = openDirectoryInTerminal(targetURL);
        }
        
        if (!success) {
            NSLog(@"Error: Failed to open directory in any terminal application");
            return 1;
        }
        
        return 0;
    }
}
