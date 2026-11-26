//
//  DSHVoice.m
//
#import "DSHVoice.h"

#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

// iOS 17 把 requestRecordPermission / recordPermission 标成 deprecated，
// 但新 API（AVAudioApplication）要 iOS 17+，为了兼容 iOS 14 还得用旧的。
// 这里局部关掉弃用警告，别让 -Wall 输出被淹掉。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface DSHVoice ()
@property (nonatomic, strong, nullable) AVAudioEngine *engine;
@property (nonatomic, strong, nullable) SFSpeechRecognizer *recognizer;
@property (nonatomic, strong, nullable) SFSpeechAudioBufferRecognitionRequest *request;
@property (nonatomic, strong, nullable) SFSpeechRecognitionTask *task;
@property (nonatomic, copy, nullable) NSString *lastPartial;
@property (nonatomic, assign) BOOL recording;
@property (nonatomic, assign) BOOL tapInstalled;
/// 防止「final 结果」和「停止后的兜底交付」重复插入同一段文字
@property (nonatomic, assign) BOOL delivered;
@end

@implementation DSHVoice

+ (instancetype)shared {
    static DSHVoice *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[DSHVoice alloc] init]; });
    return instance;
}

#pragma mark - 语言选择

/// 优先中文。系统没装中文识别模型时退回英文，总比不可用强。
- (NSString *)localeIdentifier {
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    for (NSLocale *l in [SFSpeechRecognizer supportedLocales]) {
        if (l.localeIdentifier.length > 0) [ids addObject:l.localeIdentifier];
    }
    if (ids.count == 0) return @"en-US";

    // 常见写法在不同 iOS 版本里不一样，按优先级试
    for (NSString *want in @[@"zh-CN", @"zh-Hans-CN", @"zh-Hans", @"zh_CN", @"en-US"]) {
        if ([ids containsObject:want]) return want;
    }
    // 系统语言匹配
    NSLocale *cur = [NSLocale currentLocale];
    if (cur.localeIdentifier && [ids containsObject:cur.localeIdentifier]) {
        return cur.localeIdentifier;
    }
    NSString *lang = cur.languageCode;
    if (lang.length > 0) {
        for (NSString *i in ids) {
            if ([i hasPrefix:lang]) return i;
        }
    }
    return @"en-US";
}

- (BOOL)isAvailable {
    SFSpeechRecognizer *r = [[SFSpeechRecognizer alloc]
                             initWithLocale:[NSLocale localeWithLocaleIdentifier:[self localeIdentifier]]];
    return r != nil && r.isAvailable;
}

#pragma mark - 对外接口

- (void)toggle {
    if (self.recording) {
        [self stop];
    } else {
        [self start];
    }
}

- (void)start {
    if (self.recording) return;

    __weak typeof(self) weakSelf = self;

    // 1) 语音识别权限
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            [self fail:[self messageForSpeechStatus:status]];
            return;
        }

        // 2) 麦克风权限
        [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (!granted) {
                [self fail:@"麦克风权限被拒绝。\n设置 → 隐私 → 麦克风 → 打开 DeepSeek Harness。"];
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self beginSession];
            });
        }];
    }];
}

- (void)stop {
    if (!self.recording) return;
    self.recording = NO;

    [self teardownAudio];
    [self.request endAudio];   // 让识别器把剩下的音频处理完

    if (self.onState) self.onState(@"识别中…");

    // 正常情况下 final 结果几百毫秒内就到；
    // 没网 / 识别器卡住时用最后的 partial 兜底，别让用户白说一遍。
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.delivered) return;
        [self deliverFinal];
    });
}

#pragma mark - 会话

- (void)beginSession {
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];

    // PlayAndRecord 而不是 Record：识别期间用户可能还想听到界面里的声音
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                         mode:AVAudioSessionModeMeasurement
                      options:AVAudioSessionCategoryOptionDefaultToSpeaker
                        error:&err]) {
        [self fail:[NSString stringWithFormat:@"音频会话设置失败：%@", err.localizedDescription]];
        return;
    }
    if (![session setActive:YES error:&err]) {
        [self fail:[NSString stringWithFormat:@"音频会话激活失败：%@", err.localizedDescription]];
        return;
    }

    NSString *lid = [self localeIdentifier];
    self.recognizer = [[SFSpeechRecognizer alloc]
                       initWithLocale:[NSLocale localeWithLocaleIdentifier:lid]];
    if (!self.recognizer || !self.recognizer.isAvailable) {
        [self teardownAudio];
        [self fail:[NSString stringWithFormat:
                    @"语音识别当前不可用（语言 %@）。\n可能原因：没联网，或系统未安装该语言模型。", lid]];
        return;
    }

    self.request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.request.shouldReportPartialResults = YES;
    self.delivered = NO;
    self.lastPartial = nil;

    __weak typeof(self) weakSelf = self;
    self.task = [self.recognizer recognitionTaskWithRequest:self.request
                                            resultHandler:^(SFSpeechRecognitionResult *result,
                                                            NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (result) {
            NSString *text = result.bestTranscription.formattedString;
            if (text.length > 0) {
                self.lastPartial = text;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.onPartial) self.onPartial(text);
                });
            }
            if (result.isFinal) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self deliverFinal];
                });
            }
        }

        if (error) {
            // 1110 = 没听到有效语音，属于正常情况（用户点开就关了）
            if (error.code == 1110) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self deliverFinal];
                });
            } else if (self.recording) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self fail:[NSString stringWithFormat:@"识别出错：%@", error.localizedDescription]];
                });
            }
        }
    }];

    self.engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = self.engine.inputNode;
    AVAudioFormat *format = [input outputFormatForBus:0];
    if (format.sampleRate <= 0 || format.channelCount == 0) {
        [self teardownAudio];
        [self fail:@"拿不到麦克风输入格式（设备没有可用输入？）"];
        return;
    }

    [input installTapOnBus:0
                bufferSize:1024
                    format:format
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self.request appendAudioPCMBuffer:buffer];
    }];
    self.tapInstalled = YES;

    [self.engine prepare];
    if (![self.engine startAndReturnError:&err]) {
        [self teardownAudio];
        [self fail:[NSString stringWithFormat:@"麦克风启动失败：%@", err.localizedDescription]];
        return;
    }

    self.recording = YES;
    if (self.onState) {
        self.onState([NSString stringWithFormat:@"正在聆听（%@）…再点一次结束", lid]);
    }
}

/// 停掉音频，但**不**结束识别任务 —— 还要等 final 结果
- (void)teardownAudio {
    if (self.tapInstalled && self.engine) {
        @try {
            [self.engine.inputNode removeTapOnBus:0];
        } @catch (NSException *e) {
            // 没装过 tap 时 removeTap 会抛，忽略
        }
        self.tapInstalled = NO;
    }
    if (self.engine && self.engine.isRunning) {
        [self.engine stop];
    }
    self.engine = nil;

    NSError *err = nil;
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:&err];
}

#pragma mark - 结果交付

- (void)deliverFinal {
    if (self.delivered) return;
    self.delivered = YES;

    NSString *text = [self.lastPartial
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.lastPartial = nil;
    self.recording = NO;

    if (text.length > 0) {
        if (self.onFinal) self.onFinal(text);
    } else if (self.onState) {
        self.onState(@"没听到内容");
    }
}

- (void)fail:(NSString *)message {
    self.recording = NO;
    [self teardownAudio];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onError) self.onError(message);
    });
}

- (NSString *)messageForSpeechStatus:(SFSpeechRecognizerAuthorizationStatus)status {
    switch (status) {
        case SFSpeechRecognizerAuthorizationStatusDenied:
            return @"语音识别权限被拒绝。\n设置 → 隐私 → 语音识别 → 打开 DeepSeek Harness。";
        case SFSpeechRecognizerAuthorizationStatusRestricted:
            return @"系统限制了语音识别（家长控制 / MDM）。";
        case SFSpeechRecognizerAuthorizationStatusNotDetermined:
            return @"语音识别权限未授予。";
        default:
            return @"语音识别不可用。";
    }
}

@end

#pragma clang diagnostic pop
