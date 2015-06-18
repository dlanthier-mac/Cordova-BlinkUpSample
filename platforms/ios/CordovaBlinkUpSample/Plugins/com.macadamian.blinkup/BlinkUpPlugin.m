/*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Created by Stuart Douglas (sdouglas@macadamian.com) on June 11, 2015.
 * Copyright (c) 2015 Macadamian. All rights reserved.
 */

#import "BlinkUpPlugin.h"
#import <BlinkUp/BlinkUp.h>

typedef NS_ENUM(NSInteger, BlinkupArguments) {
    BlinkUpArgumentApiKey = 0,
    BlinkUpArgumentDeveloperPlanId,
    BlinkUpArgumentTimeOut,
    BlinkUpUsedCachedPlanId
};

// status codes
typedef NS_ENUM(NSInteger, BlinkUpStatusCodes) {
    DEVICE_CONNECTED    = 0,
    ERROR               = 1,
    
    INVALID_ARGUMENTS   = 100,
    PROCESS_TIMED_OUT   = 101,
    CANCELLED_BY_USER   = 102,
    INVALID_API_KEY     = 103, // android only
    VERIFY_API_KEY_FAIL = 104, // android only
    
    GATHERING_INFO      = 200,
    CLEAR_COMPLETE      = 201
};

@implementation BlinkUpPlugin

NSString * const STATUS_KEY = @"status";
NSString * const ERROR_MSG_KEY = @"errorMsg";
NSString * const PLAN_ID_KEY = @"planId";
NSString * const DEVICE_ID_KEY = @"deviceId";
NSString * const AGENT_URL_KEY = @"agentURL";
NSString * const GATHERING_DEVICE_INFO_KEY = @"gatheringDeviceInfo";

/*********************************************************
 * Called by Javascript in Cordova application.
 * `command.arguments` is array, first item is apiKey
 ********************************************************/
- (void)invokeBlinkUp:(CDVInvokedUrlCommand*)command {
    self.callbackId = command.callbackId;
    
    if (command.arguments.count <= BlinkUpUsedCachedPlanId) {
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: [@(INVALID_ARGUMENTS) stringValue]];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    self.apiKey = [command.arguments objectAtIndex:BlinkUpArgumentApiKey];
    self.developerPlanId = [command.arguments objectAtIndex:BlinkUpArgumentDeveloperPlanId];
    self.timeoutInMs = [command.arguments objectAtIndex:BlinkUpArgumentTimeOut];
    self.useCachedPlanId = [command.arguments objectAtIndex:BlinkUpUsedCachedPlanId];
    
    [self navigateToBlinkUpView];
}


/*********************************************************
 * shows default UI for BlinkUp process. Modify this method
 * if you wish to use a custom UI (refer to API docs)
 ********************************************************/
- (void) navigateToBlinkUpView {
    
    // load cached planID (if not cached yet, BlinkUp automatically generates a new one)
    NSString *planId = [[NSUserDefaults standardUserDefaults] objectForKey:PLAN_ID_KEY];
    
    // see electricimp.com/docs/manufacturing/planids/ for info about planIDs
    #ifdef DEBUG
        planId = (self.developerPlanId != "") ? self.developerPlanId : nil;
    #endif
    
    if (self.useCachedPlanId.boolValue) {
        self.blinkUpController = [[BUBasicController alloc] initWithApiKey:self.apiKey planId:planId];
    }
    else {
        self.blinkUpController = [[BUBasicController alloc] initWithApiKey:self.apiKey];
    }

    [self.blinkUpController presentInterfaceAnimated:YES
        resignActive: ^(BOOL willRespond, BOOL userDidCancel, NSError *error) {
            [self blinkUpDidComplete:willRespond userDidCancel:userDidCancel error:error];
        }
        devicePollingDidComplete: ^(BUDeviceInfo *deviceInfo, BOOL timedOut, NSError *error) {
            [self deviceRequestDidCompleteWithDeviceInfo:deviceInfo timedOut:timedOut error:error];
        }
    ];
}


/*********************************************************
 * Called when BlinkUp controller is closed, by user
 * cancelling, flashing process complete, or on error.
 * Sends status back to Cordova app.
 ********************************************************/
- (void) blinkUpDidComplete:(BOOL)willRespond userDidCancel:(BOOL)userDidCancel error:(NSError*)error {
    
    CDVCommandStatus status;
    NSString *resultStatus;;
    
    if (willRespond) {
        // can't set timeout manually, so just tell devicePoller to stop polling (if timeout not default)
        long timeoutInMs = self.timeoutInMs.longValue;
        if (timeoutInMs != 60000) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, timeoutInMs * NSEC_PER_MSEC),
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                    [self.blinkUpController.devicePoller stopPolling];
                    [self deviceRequestDidCompleteWithDeviceInfo:nil timedOut:true error:nil];
            });
        }

        NSDictionary *resultsDict = @{
            STATUS_KEY : [@(GATHERING_INFO) stringValue],
            GATHERING_DEVICE_INFO_KEY : @"true"
        };
        resultStatus = [self toJsonString:resultsDict];
        status = CDVCommandStatus_OK;
    }
    
    else if (userDidCancel) {
        resultStatus = [@(CANCELLED_BY_USER) stringValue];
        status = CDVCommandStatus_ERROR;
    }
    
    else if (error != nil) {
        NSDictionary *resultsDict = @{
            STATUS_KEY : [@(ERROR) stringValue],
            ERROR_MSG_KEY : [NSString stringWithFormat:@"BlinkUp Error #%ld: %@", (long) error.code, error.localizedDescription]
        };
        resultStatus = [self toJsonString:resultsDict];
        status = CDVCommandStatus_ERROR;
    }
    
    else {
        resultStatus = [@(CLEAR_COMPLETE) stringValue];
        status = CDVCommandStatus_OK;
    }
    
    // send result, and keep callback if gathering device info
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:status messageAsString:resultStatus];

    if (willRespond) {
        [result setKeepCallbackAsBool:YES];
    }

    [self.commandDelegate sendPluginResult:result callbackId:self.callbackId];
}


/*********************************************************
 * Called when device info has been loaded from Electric
 * Imp server, or when that request timed out.
 * Sends device info and status back to Cordova app.
 ********************************************************/
- (void) deviceRequestDidCompleteWithDeviceInfo:(BUDeviceInfo*)deviceInfo timedOut:(BOOL)timedOut error:(NSError*)error {
    
    CDVCommandStatus status;
    NSString *resultStatus;

    if (timedOut) {
        resultStatus = [@(PROCESS_TIMED_OUT) stringValue];
        status = CDVCommandStatus_ERROR;
    }
    else if (error != nil) {
        NSDictionary *resultsDict = @{
            STATUS_KEY : [@(ERROR) stringValue],
            ERROR_MSG_KEY : [NSString stringWithFormat:@"BlinkUp Error #%ld: %@", (long) error.code, error.localizedDescription]
        };
        resultStatus = [self toJsonString:resultsDict];
        status = CDVCommandStatus_ERROR;
    }
    else {
        // cache plan ID (see electricimp.com/docs/manufacturing/planids/)
        [[NSUserDefaults standardUserDefaults] setObject:deviceInfo.planId forKey:PLAN_ID_KEY];

        NSDictionary *resultsDict = @{
           STATUS_KEY : [@(DEVICE_CONNECTED) stringValue],
           PLAN_ID_KEY : deviceInfo.planId,
           DEVICE_ID_KEY : deviceInfo.deviceId,
           AGENT_URL_KEY: deviceInfo.agentURL
        };
        resultStatus = [self toJsonString:resultsDict];
        status = CDVCommandStatus_OK;
    }
    
    // send result, discard callback
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:status messageAsString:resultStatus];
    [result setKeepCallbackAsBool:NO];
    [self.commandDelegate sendPluginResult:result callbackId:self.callbackId];
}


/********************************************
 * Takes dictionary and outputs a JSON string
 ********************************************/
- (NSString *) toJsonString:(NSDictionary *)resultsDict {
    
    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:resultsDict options:NSJSONWritingPrettyPrinted error:&jsonError];
    
    if (jsonError != nil) {
        NSLog(@"Error converting to JSON. %@", jsonError.localizedDescription);
        return @"";
    }
    
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

@end
