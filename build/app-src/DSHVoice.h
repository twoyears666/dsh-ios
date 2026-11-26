//
//  DSHVoice.h
//  dsh iOS 原生外壳 —— 语音输入（SFSpeechRecognizer）
//
//  macOS 桌面端的语音转文字走 sherpa-onnx，没有 iOS 产物；
//  这里改用系统自带的 Speech framework：
//    - 不需要额外依赖、不占体积
//    - 中文识别质量够用，且能边说边出字（partial results）
//    - 越狱机上只是普通 App 能力，不需要特殊 entitlement
//
//  权限：需要 Info.plist 里的
//    NSMicrophoneUsageDescription
//    NSSpeechRecognitionUsageDescription
//  缺失会直接 crash（iOS 强制要求），所以 build-app.sh 会校验。
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSHVoice : NSObject

+ (instancetype)shared;

/// 正在录音
@property (nonatomic, readonly) BOOL recording;

/// 边说边出的中间结果（主线程回调）
@property (nonatomic, copy, nullable) void (^onPartial)(NSString *text);

/// 最终结果（主线程回调）。调用方负责把文字塞进输入框。
@property (nonatomic, copy, nullable) void (^onFinal)(NSString *text);

/// 状态提示，例如「正在聆听…」（主线程回调）
@property (nonatomic, copy, nullable) void (^onState)(NSString *message);

/// 出错（主线程回调）。权限被拒、没有麦克风、识别器不可用都走这里。
@property (nonatomic, copy, nullable) void (^onError)(NSString *message);

/// 开始录音。已经在下就什么都不做。
- (void)start;

/// 停止录音，并把已识别的内容作为最终结果交出去。
- (void)stop;

/// 开始 / 停止切换
- (void)toggle;

/// 当前选用的识别语言（zh-CN / en-US / …）
- (NSString *)localeIdentifier;

/// 是否有可用的识别器（设备可能不支持当前语言）
- (BOOL)isAvailable;

@end

NS_ASSUME_NONNULL_END
