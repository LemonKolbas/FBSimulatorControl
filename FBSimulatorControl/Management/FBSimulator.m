/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBSimulator.h"
#import "FBSimulator+Private.h"

#import <CoreSimulator/SimDevice.h>
#import <CoreSimulator/SimDeviceSet.h>
#import <CoreSimulator/SimDeviceType.h>

#import <Foundation/Foundation.h>

#import <FBControlCore/FBControlCore.h>

#import "FBAccessibilityFetch.h"
#import "FBCompositeSimulatorEventSink.h"
#import "FBMutableSimulatorEventSink.h"
#import "FBSimulatorAgentCommands.h"
#import "FBSimulatorApplicationCommands.h"
#import "FBSimulatorBridgeCommands.h"
#import "FBSimulatorConfiguration+CoreSimulator.h"
#import "FBSimulatorConfiguration.h"
#import "FBSimulatorControlConfiguration.h"
#import "FBSimulatorControlOperator.h"
#import "FBSimulatorDiagnostics.h"
#import "FBSimulatorError.h"
#import "FBSimulatorMutableState.h"
#import "FBSimulatorEventSink.h"
#import "FBSimulatorHIDEvent.h"
#import "FBSimulatorLifecycleCommands.h"
#import "FBSimulatorLogCommands.h"
#import "FBSimulatorLoggingEventSink.h"
#import "FBSimulatorNotificationEventSink.h"
#import "FBSimulatorPool.h"
#import "FBSimulatorScreenshotCommands.h"
#import "FBSimulatorSet.h"
#import "FBSimulatorSettingsCommands.h"
#import "FBSimulatorVideoRecordingCommands.h"
#import "FBSimulatorXCTestCommands.h"
#import "FBSimulatorApplicationDataCommands.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wincomplete-implementation"

@implementation FBSimulator

@synthesize deviceOperator = _deviceOperator;
@synthesize auxillaryDirectory = _auxillaryDirectory;
@synthesize logger = _logger;

#pragma mark Lifecycle

+ (instancetype)fromSimDevice:(SimDevice *)device configuration:(nullable FBSimulatorConfiguration *)configuration launchdSimProcess:(nullable FBProcessInfo *)launchdSimProcess containerApplicationProcess:(nullable FBProcessInfo *)containerApplicationProcess set:(FBSimulatorSet *)set
{
  return [[[FBSimulator alloc]
    initWithDevice:device
    configuration:configuration ?: [FBSimulatorConfiguration inferSimulatorConfigurationFromDeviceSynthesizingMissing:device]
    set:set
    processFetcher:set.processFetcher
    auxillaryDirectory:[FBSimulator auxillaryDirectoryFromSimDevice:device configuration:configuration]
    logger:set.logger]
    attachEventSinkCompositionWithLaunchdSimProcess:launchdSimProcess containerApplicationProcess:containerApplicationProcess];
}

- (instancetype)initWithDevice:(SimDevice *)device configuration:(FBSimulatorConfiguration *)configuration set:(FBSimulatorSet *)set processFetcher:(FBSimulatorProcessFetcher *)processFetcher auxillaryDirectory:(NSString *)auxillaryDirectory logger:(nullable id<FBControlCoreLogger>)logger
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _device = device;
  _configuration = configuration;
  _set = set;
  _processFetcher = processFetcher;
  _auxillaryDirectory = auxillaryDirectory;
  _logger = logger;
  _forwarder = [FBiOSTargetCommandForwarder forwarderWithTarget:self commandClasses:FBSimulator.commandResponders memoize:NO];

  return self;
}

- (instancetype)attachEventSinkCompositionWithLaunchdSimProcess:(nullable FBProcessInfo *)launchdSimProcess containerApplicationProcess:(nullable FBProcessInfo *)containerApplicationProcess
{
  FBSimulatorNotificationNameEventSink *notificationSink = [FBSimulatorNotificationNameEventSink withSimulator:self];
  FBSimulatorLoggingEventSink *loggingSink = [FBSimulatorLoggingEventSink withSimulator:self logger:self.logger];
  FBMutableSimulatorEventSink *mutableSink = [FBMutableSimulatorEventSink new];
  FBSimulatorDiagnostics *diagnosticsSink = [FBSimulatorDiagnostics withSimulator:self];

  FBCompositeSimulatorEventSink *compositeSink = [FBCompositeSimulatorEventSink withSinks:@[notificationSink, loggingSink, diagnosticsSink, mutableSink]];
  FBSimulatorMutableState *mutableState = [[FBSimulatorMutableState alloc] initWithLaunchdProcess:launchdSimProcess containerApplication:containerApplicationProcess sink:compositeSink];

  _mutableState = mutableState;
  _mutableSink = mutableSink;
  _simulatorDiagnostics = diagnosticsSink;

  return self;
}

#pragma mark FBiOSTarget

- (NSArray<Class> *)actionClasses
{
  return @[
    FBAccessibilityFetch.class,
    FBAgentLaunchConfiguration.class,
    FBLogTailConfiguration.class,
    FBSimulatorHIDEvent.class,
    FBTestLaunchConfiguration.class,
  ];
}

- (id<FBDeviceOperator>)deviceOperator
{
  if (_deviceOperator == nil) {
    _deviceOperator = [FBSimulatorControlOperator operatorWithSimulator:self];
  }
  return _deviceOperator;
}

- (NSString *)udid
{
  return self.device.UDID.UUIDString;
}

- (NSString *)name
{
  return self.device.name;
}

- (FBSimulatorState)state
{
  return self.device.state;
}

- (FBiOSTargetType)targetType
{
  return FBiOSTargetTypeSimulator;
}

- (FBArchitecture)architecture
{
  return self.configuration.device.simulatorArchitecture;
}

- (FBDeviceType *)deviceType
{
  return self.configuration.device;
}

- (FBOSVersion *)osVersion
{
  return self.configuration.os;
}

- (FBiOSTargetScreenInfo *)screenInfo
{
  SimDeviceType *deviceType = self.device.deviceType;
  return [[FBiOSTargetScreenInfo alloc] initWithWidthPixels:(NSUInteger)deviceType.mainScreenSize.width heightPixels:(NSUInteger)deviceType.mainScreenSize.height scale:deviceType.mainScreenScale];
}

- (FBiOSTargetDiagnostics *)diagnostics
{
  return self.simulatorDiagnostics;
}

- (dispatch_queue_t)workQueue
{
  return dispatch_get_main_queue();
}

- (dispatch_queue_t)asyncQueue
{
  return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
}

- (NSComparisonResult)compare:(id<FBiOSTarget>)target
{
  return FBiOSTargetComparison(self, target);
}

#pragma mark Properties

- (FBControlCoreProductFamily)productFamily
{
  int familyID = self.device.deviceType.productFamilyID;
  switch (familyID) {
    case 1:
      return FBControlCoreProductFamilyiPhone;
    case 2:
      return FBControlCoreProductFamilyiPad;
    case 3:
      return FBControlCoreProductFamilyAppleTV;
    case 4:
      return FBControlCoreProductFamilyAppleWatch;
    default:
      return FBControlCoreProductFamilyUnknown;
  }
}

- (NSString *)stateString
{
  return FBSimulatorStateStringFromState(self.state);
}

- (NSString *)dataDirectory
{
  return self.device.dataPath;
}

- (BOOL)isAllocated
{
  if (!self.pool) {
    return NO;
  }
  return [self.pool.allocatedSimulators containsObject:self];
}

- (FBProcessInfo *)launchdProcess
{
  return self.mutableState.launchdProcess;
}

- (FBSimulatorConnection *)connection
{
  return self.mutableState.connection;
}

- (FBProcessInfo *)containerApplication
{
  return self.mutableState.containerApplication;
}

- (id<FBSimulatorEventSink>)eventSink
{
  return self.mutableState;
}

- (id<FBSimulatorEventSink>)userEventSink
{
  return self.mutableSink.eventSink;
}

- (void)setUserEventSink:(id<FBSimulatorEventSink>)userEventSink
{
  self.mutableSink.eventSink = userEventSink;
}

#pragma mark NSObject

- (NSUInteger)hash
{
  return self.device.hash;
}

- (BOOL)isEqual:(FBSimulator *)simulator
{
  if (![simulator isKindOfClass:self.class]) {
    return NO;
  }
  return [self.device isEqual:simulator.device];
}

#pragma mark FBDebugDescribeable

- (NSString *)description
{
  return [self debugDescription];
}

- (NSString *)debugDescription
{
  return [FBiOSTargetFormat.fullFormat format:self];
}

- (NSString *)shortDescription
{
  return [FBiOSTargetFormat.defaultFormat format:self];
}

#pragma mark FBJSONSerializable

- (NSDictionary *)jsonSerializableRepresentation
{
  return [FBiOSTargetFormat.fullFormat extractFrom:self];
}

#pragma mark Forwarding

- (id)forwardingTargetForSelector:(SEL)selector
{
  return [self.forwarder forwardingTargetForSelector:selector];
}

+ (NSArray<Class> *)commandResponders
{
  static dispatch_once_t onceToken;
  static NSArray<Class> *commandClasses;
  dispatch_once(&onceToken, ^{
    commandClasses = @[
      FBSimulatorScreenshotCommands.class,
      FBSimulatorAgentCommands.class,
      FBSimulatorApplicationCommands.class,
      FBSimulatorApplicationDataCommands.class,
      FBSimulatorBridgeCommands.class,
      FBSimulatorKeychainCommands.class,
      FBSimulatorLaunchCtlCommands.class,
      FBSimulatorLifecycleCommands.class,
      FBSimulatorLogCommands.class,
      FBSimulatorSettingsCommands.class,
      FBSimulatorVideoRecordingCommands.class,
      FBSimulatorXCTestCommands.class,
    ];
  });
  return commandClasses;
}

#pragma mark Private

+ (NSString *)auxillaryDirectoryFromSimDevice:(SimDevice *)device configuration:(FBSimulatorConfiguration *)configuration
{
  if (!configuration.auxillaryDirectory) {
    return [device.dataPath stringByAppendingPathComponent:@"fbsimulatorcontrol"];
  }
  return [configuration.auxillaryDirectory stringByAppendingPathComponent:device.UDID.UUIDString];
}

@end

#pragma clang diagnostic pop
