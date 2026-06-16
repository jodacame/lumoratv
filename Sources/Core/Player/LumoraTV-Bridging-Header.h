//
//  LumoraTV-Bridging-Header.h
//
//  Exposes the one Apple SPI we need for content frame-rate matching on tvOS.
//

#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>

// `AVDisplayCriteria` has NO public initializer. The only documented public way
// to obtain one is `AVAsset.preferredDisplayCriteria`, which is useless for a
// custom renderer (we decode with libmpv into a CAMetalLayer, not AVPlayer).
//
// To switch the Apple TV's HDMI output to the content's frame rate (and so kill
// 3:2 cadence judder on 24p material) we declare the SPI initializer that
// AVFoundation implements at runtime. This is the same approach used by every
// non-AVPlayer tvOS player (VLC, Infuse, KSPlayer). The method has been stable
// since tvOS 11.2. LumoraTV is sideloaded (not distributed via the App Store),
// so relying on this SPI is acceptable.
//
// videoDynamicRange values: 0 = SDR, 2 = HDR10 (PQ), 3 = HLG.
@interface AVDisplayCriteria (LumoraFrameRateMatching)
- (instancetype)initWithRefreshRate:(float)refreshRate
                   videoDynamicRange:(int)videoDynamicRange;
@end
