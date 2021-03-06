// Copyright 2020 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "GADMAdapterFyberInterstitialAd.h"

#import <IASDKCore/IASDKCore.h>
#import <IASDKMRAID/IASDKMRAID.h>
#import <IASDKVideo/IASDKVideo.h>

#import <stdatomic.h>

#import "GADMAdapterFyberConstants.h"
#import "GADMAdapterFyberUtils.h"

@interface GADMAdapterFyberInterstitialAd () <GADMediationInterstitialAd, IAUnitDelegate>
@end

@implementation GADMAdapterFyberInterstitialAd {
  /// Ad configuration for the ad to be loaded.
  GADMediationInterstitialAdConfiguration *_adConfiguration;

  /// The completion handler to call when an ad loads successfully or fails.
  GADMediationInterstitialLoadCompletionHandler _loadCompletionHandler;

  /// The ad event delegate to forward ad rendering events to the Google Mobile Ads SDK.
  /// Intentionally keeping a reference to the delegate because this delegate is returned from the
  /// GMA SDK, not set on the GMA SDK.
  id<GADMediationInterstitialAdEventDelegate> _delegate;

  /// Fyber fullscreen controller to catch interstitial related ad events.
  IAFullscreenUnitController *_fullscreenUnitController;
}

- (instancetype)initWithAdConfiguration:(GADMediationInterstitialAdConfiguration *)adConfiguration {
  self = [super init];
  if (self) {
    _adConfiguration = adConfiguration;
  }
  return self;
}

- (void)loadInterstitialAdWithCompletionHandler:
    (GADMediationInterstitialLoadCompletionHandler)completionHandler {
  __block atomic_flag adLoadHandlerCalled = ATOMIC_FLAG_INIT;
  __block GADMediationInterstitialLoadCompletionHandler originalAdLoadHandler =
      [completionHandler copy];

  // Ensure the original completion handler is only called once, and is deallocated once called.
  _loadCompletionHandler = ^id<GADMediationInterstitialAdEventDelegate>(
      id<GADMediationInterstitialAd> interstitialAd, NSError *error) {
    if (atomic_flag_test_and_set(&adLoadHandlerCalled)) {
      return nil;
    }

    id<GADMediationInterstitialAdEventDelegate> delegate = nil;
    if (originalAdLoadHandler) {
      delegate = originalAdLoadHandler(interstitialAd, error);
    }

    originalAdLoadHandler = nil;
    return delegate;
  };

  NSError *initError = nil;
  BOOL didInitialize = GADMAdapterFyberInitializeWithAppID(
      _adConfiguration.credentials.settings[kGADMAdapterFyberApplicationID], &initError);
  if (!didInitialize) {
    GADMAdapterFyberLog(@"Failed to load interstitial ad: %@", initError.localizedDescription);
    _loadCompletionHandler(nil, initError);
    return;
  }

  NSString *spotID = _adConfiguration.credentials.settings[kGADMAdapterFyberSpotID];
  if (!spotID.length) {
    NSString *errorMessage = @"Missing or Invalid Spot ID.";
    GADMAdapterFyberLog(@"Failed to load interstitial ad: %@", errorMessage);
    NSError *error =
        GADMAdapterFyberErrorWithCodeAndDescription(kGADErrorMediationDataError, errorMessage);
    _loadCompletionHandler(nil, error);
    return;
  }

  IAAdRequest *request =
      GADMAdapterFyberBuildRequestWithSpotIDAndAdConfiguration(spotID, _adConfiguration);

  IAMRAIDContentController *MRAIDContentController =
      [IAMRAIDContentController build:^(id<IAMRAIDContentControllerBuilder> _Nonnull builder){
      }];
  IAVideoContentController *videoContentController =
      [IAVideoContentController build:^(id<IAVideoContentControllerBuilder> _Nonnull builder){
      }];

  GADMAdapterFyberInterstitialAd *__weak weakSelf = self;
  _fullscreenUnitController =
      [IAFullscreenUnitController build:^(id<IAFullscreenUnitControllerBuilder> _Nonnull builder) {
        GADMAdapterFyberInterstitialAd *strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }

        builder.unitDelegate = strongSelf;
        [builder addSupportedContentController:MRAIDContentController];
        [builder addSupportedContentController:videoContentController];
      }];

  IAAdSpot *adSpot = [IAAdSpot build:^(id<IAAdSpotBuilder> _Nonnull builder) {
    builder.adRequest = request;
    builder.mediationType = [[IAMediationAdMob alloc] init];

    GADMAdapterFyberInterstitialAd *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }

    [builder addSupportedUnitController:strongSelf->_fullscreenUnitController];
  }];

  [adSpot fetchAdWithCompletion:^(IAAdSpot *_Nullable adSpot, IAAdModel *_Nullable adModel,
                                  NSError *_Nullable error) {
    GADMAdapterFyberInterstitialAd *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }

    if (error) {
      GADMAdapterFyberLog(@"Failed to load interstitial ad: %@", error.localizedDescription);
      strongSelf->_loadCompletionHandler(nil, error);
      return;
    }

    strongSelf->_delegate = strongSelf->_loadCompletionHandler(strongSelf, nil);
  }];
}

#pragma mark - GADMediationInterstitialAd

- (void)presentFromViewController:(nonnull UIViewController *)viewController {
  if (_fullscreenUnitController.isPresented) {
    NSError *error = GADMAdapterFyberErrorWithCodeAndDescription(
        kGADErrorAdAlreadyUsed, @"Fyber Interstitial ad has already been presented");
    GADMAdapterFyberLog(@"Failed to present interstitial ad: %@", error.localizedDescription);
    [_delegate didFailToPresentWithError:error];
    return;
  }

  if (!_fullscreenUnitController.isReady) {
    NSError *error = GADMAdapterFyberErrorWithCodeAndDescription(
        kGADErrorInternalError, @"Fyber Interstitial ad is not ready to show.");
    GADMAdapterFyberLog(@"Failed to present interstitial ad: %@", error.localizedDescription);
    [_delegate didFailToPresentWithError:error];
    return;
  }

  [_fullscreenUnitController showAdAnimated:YES completion:nil];
}

#pragma mark - IAUnitDelegate

- (nonnull UIViewController *)IAParentViewControllerForUnitController:
    (nullable IAUnitController *)unitController {
  return _adConfiguration.topViewController;
}

- (void)IAAdDidReceiveClick:(nullable IAUnitController *)unitController {
  [_delegate reportClick];
}

- (void)IAAdWillLogImpression:(nullable IAUnitController *)unitController {
  [_delegate reportImpression];
}

- (void)IAUnitControllerWillPresentFullscreen:(nullable IAUnitController *)unitController {
  [_delegate willPresentFullScreenView];
}

- (void)IAUnitControllerWillDismissFullscreen:(nullable IAUnitController *)unitController {
  [_delegate willDismissFullScreenView];
}

- (void)IAUnitControllerDidDismissFullscreen:(nullable IAUnitController *)unitController {
  [_delegate didDismissFullScreenView];
}

- (void)IAUnitControllerWillOpenExternalApp:(nullable IAUnitController *)unitController {
  [_delegate willBackgroundApplication];
}

@end
