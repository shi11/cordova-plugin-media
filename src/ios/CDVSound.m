/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVSound.h"
#import "CDVFile.h"
#import <MediaPlayer/MPNowPlayingInfoCenter.h>
#import <MediaPlayer/MPMediaItem.h>
#import <MediaPlayer/MPRemoteCommandCenter.h>
#import <MediaPlayer/MPRemoteCommandEvent.h>
#import <MediaPlayer/MPRemoteCommand.h>
#import <AVFoundation/AVFoundation.h>

#define DOCUMENTS_SCHEME_PREFIX @"documents://"
#define HTTP_SCHEME_PREFIX @"http://"
#define HTTPS_SCHEME_PREFIX @"https://"
#define CDVFILE_PREFIX @"cdvfile://"
#define RECORDING_WAV @"wav"


@implementation CDVSound

@synthesize soundCache, avSession, currMediaId;

// Maps a url for a resource path for recording
- (NSURL*)urlForRecording:(NSString*)resourcePath
{
    NSURL* resourceURL = nil;
    NSString* filePath = nil;
    NSString* docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    
    // first check for correct extension
    if ([[resourcePath pathExtension] caseInsensitiveCompare:RECORDING_WAV] != NSOrderedSame) {
        resourceURL = nil;
        NSLog(@"Resource for recording must have %@ extension", RECORDING_WAV);
    } else if ([resourcePath hasPrefix:DOCUMENTS_SCHEME_PREFIX]) {
        // try to find Documents:// resources
        filePath = [resourcePath stringByReplacingOccurrencesOfString:DOCUMENTS_SCHEME_PREFIX withString:[NSString stringWithFormat:@"%@/", docsPath]];
        NSLog(@"Will use resource '%@' from the documents folder with path = %@", resourcePath, filePath);
    } else if ([resourcePath hasPrefix:CDVFILE_PREFIX]) {
        CDVFile *filePlugin = [self.commandDelegate getCommandInstance:@"File"];
        CDVFilesystemURL *url = [CDVFilesystemURL fileSystemURLWithString:resourcePath];
        filePath = [filePlugin filesystemPathForURL:url];
        if (filePath == nil) {
            resourceURL = [NSURL URLWithString:resourcePath];
        }
    } else {
        // if resourcePath is not from FileSystem put in tmp dir, else attempt to use provided resource path
        NSString* tmpPath = [NSTemporaryDirectory()stringByStandardizingPath];
        BOOL isTmp = [resourcePath rangeOfString:tmpPath].location != NSNotFound;
        BOOL isDoc = [resourcePath rangeOfString:docsPath].location != NSNotFound;
        if (!isTmp && !isDoc) {
            // put in temp dir
            filePath = [NSString stringWithFormat:@"%@/%@", tmpPath, resourcePath];
        } else {
            filePath = resourcePath;
        }
    }
    
    if (filePath != nil) {
        // create resourceURL
        resourceURL = [NSURL fileURLWithPath:filePath];
    }
    return resourceURL;
}

// Maps a url for a resource path for playing
// "Naked" resource paths are assumed to be from the www folder as its base
- (NSURL*)urlForPlaying:(NSString*)resourcePath
{
    NSURL* resourceURL = nil;
    NSString* filePath = nil;
    
    // first try to find HTTP:// or Documents:// resources
    
    if ([resourcePath hasPrefix:HTTP_SCHEME_PREFIX] || [resourcePath hasPrefix:HTTPS_SCHEME_PREFIX]) {
        // if it is a http url, use it
        NSLog(@"Will use resource '%@' from the Internet.", resourcePath);
        resourceURL = [NSURL URLWithString:resourcePath];
    } else if ([resourcePath hasPrefix:DOCUMENTS_SCHEME_PREFIX]) {
        NSString* docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
        filePath = [resourcePath stringByReplacingOccurrencesOfString:DOCUMENTS_SCHEME_PREFIX withString:[NSString stringWithFormat:@"%@/", docsPath]];
        NSLog(@"Will use resource '%@' from the documents folder with path = %@", resourcePath, filePath);
    } else if ([resourcePath hasPrefix:CDVFILE_PREFIX]) {
        CDVFile *filePlugin = [self.commandDelegate getCommandInstance:@"File"];
        CDVFilesystemURL *url = [CDVFilesystemURL fileSystemURLWithString:resourcePath];
        filePath = [filePlugin filesystemPathForURL:url];
        if (filePath == nil) {
            resourceURL = [NSURL URLWithString:resourcePath];
        }
    } else {
        // attempt to find file path in www directory or LocalFileSystem.TEMPORARY directory
        filePath = [self.commandDelegate pathForResource:resourcePath];
        if (filePath == nil) {
            // see if this exists in the documents/temp directory from a previous recording
            NSString* testPath = [NSString stringWithFormat:@"%@/%@", [NSTemporaryDirectory()stringByStandardizingPath], resourcePath];
            if ([[NSFileManager defaultManager] fileExistsAtPath:testPath]) {
                // inefficient as existence will be checked again below but only way to determine if file exists from previous recording
                filePath = testPath;
                NSLog(@"Will attempt to use file resource from LocalFileSystem.TEMPORARY directory");
            } else {
                // attempt to use path provided
                filePath = resourcePath;
                NSLog(@"Will attempt to use file resource '%@'", filePath);
            }
        } else {
            NSLog(@"Found resource '%@' in the web folder.", filePath);
        }
    }
    // if the resourcePath resolved to a file path, check that file exists
    if (filePath != nil) {
        // create resourceURL
        resourceURL = [NSURL fileURLWithPath:filePath];
        // try to access file
        NSFileManager* fMgr = [NSFileManager defaultManager];
        if (![fMgr fileExistsAtPath:filePath]) {
            resourceURL = nil;
            NSLog(@"Unknown resource '%@'", resourcePath);
        }
    }
    
    return resourceURL;
}

// Creates or gets the cached audio file resource object
- (CDVAudioFile*)audioFileForResource:(NSString*)resourcePath withId:(NSString*)mediaId doValidation:(BOOL)bValidate forRecording:(BOOL)bRecord
{
    BOOL bError = NO;
    CDVMediaError errcode = MEDIA_ERR_NONE_SUPPORTED;
    NSString* errMsg = @"";
    NSString* jsString = nil;
    CDVAudioFile* audioFile = nil;
    NSURL* resourceURL = nil;
    
    if ([self soundCache] == nil) {
        [self setSoundCache:[NSMutableDictionary dictionaryWithCapacity:1]];
    } else {
        audioFile = [[self soundCache] objectForKey:mediaId];
    }
    if (audioFile == nil) {
        // validate resourcePath and create
        if ((resourcePath == nil) || ![resourcePath isKindOfClass:[NSString class]] || [resourcePath isEqualToString:@""]) {
            bError = YES;
            errcode = MEDIA_ERR_ABORTED;
            errMsg = @"invalid media src argument";
        } else {
            audioFile = [[CDVAudioFile alloc] init];
            audioFile.resourcePath = resourcePath;
            audioFile.resourceURL = nil;  // validate resourceURL when actually play or record
            [[self soundCache] setObject:audioFile forKey:mediaId];
        }
    }
    if (bValidate && (audioFile.resourceURL == nil)) {
        if (bRecord) {
            resourceURL = [self urlForRecording:resourcePath];
        } else {
            resourceURL = [self urlForPlaying:resourcePath];
        }
        if (resourceURL == nil) {
            bError = YES;
            errcode = MEDIA_ERR_ABORTED;
            errMsg = [NSString stringWithFormat:@"Cannot use audio file from resource '%@'", resourcePath];
        } else {
            audioFile.resourceURL = resourceURL;
        }
    }
    
    if (bError) {
        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:errcode message:errMsg]];
        [self.commandDelegate evalJs:jsString];
    }
    
    return audioFile;
}

// returns whether or not audioSession is available - creates it if necessary
- (BOOL)hasAudioSession
{
    BOOL bSession = YES;
    
    if (!self.avSession) {
        NSError* error = nil;
        
        self.avSession = [AVAudioSession sharedInstance];
        if (error) {
            // is not fatal if can't get AVAudioSession , just log the error
            NSLog(@"error creating audio session: %@", [[error userInfo] description]);
            self.avSession = nil;
            bSession = NO;
        }
    }
    return bSession;
}

// helper function to create a error object string
- (NSString*)createMediaErrorWithCode:(CDVMediaError)code message:(NSString*)message
{
    NSMutableDictionary* errorDict = [NSMutableDictionary dictionaryWithCapacity:2];
    
    [errorDict setObject:[NSNumber numberWithUnsignedInteger:code] forKey:@"code"];
    [errorDict setObject:message ? message:@"" forKey:@"message"];
    
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:errorDict options:0 error:nil];
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (void)create:(CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        
        NSString* mediaId = [command argumentAtIndex:0];
        NSString* resourcePath = [command argumentAtIndex:1];
        NSString* jsString = nil;

        CDVAudioFile* audioFile = [self audioFileForResource:resourcePath withId:mediaId doValidation:NO forRecording:NO];
        
        if (audioFile == nil) {
            NSString* errorMessage = [NSString stringWithFormat:@"Failed to initialize Media file with path %@", resourcePath];
            NSString* jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_ABORTED message:errorMessage]];
            [self.commandDelegate evalJs:jsString];
        } else {
            NSURL* resourceUrl = [[NSURL alloc] initWithString:resourcePath];
            if (![resourceUrl isFileURL]) {
                // First create an AVPlayerItem
                AVPlayerItem* playerItem = [AVPlayerItem playerItemWithURL:resourceUrl];
                
                // Subscribe to the AVPlayerItem's DidPlayToEndTime notification.
                [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemDidFinishPlaying:) name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];

                //remove observer if exists
                if (avPlayer != nil)
                [avPlayer removeObserver:self forKeyPath:@"status"];


                // Pass the AVPlayerItem to a new player
                avPlayer = [[AVPlayer alloc] initWithPlayerItem:playerItem];
            
                //observe status
                [avPlayer addObserver:self forKeyPath:@"status" options:0 context:nil];
                
                //avPlayer = [[AVPlayer alloc] initWithURL:resourceUrl];

                jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_STARTING];
                if (jsString) {
                    [self.commandDelegate evalJs:jsString];
                }

            }
            
            self.currMediaId = mediaId;
            
            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }
    }];
}

/**
* loads the stream faster
**/
- (void) observeValueForKeyPath:(NSString *)keyPath
                       ofObject:(id)object
                         change:(NSDictionary  *)change
                        context:(void *)context {

    if ([keyPath isEqualToString:@"status"]) {
        if (avPlayer.status == AVPlayerStatusReadyToPlay) {
            //Audio session is set to allow streaming in background
            AVAudioSession *audioSession = [AVAudioSession sharedInstance];
            [audioSession setCategory:AVAudioSessionCategoryPlayback error:nil];
            [avPlayer play];
        }
        if (avPlayer.status == AVPlayerStatusFailed) {
            NSLog(@"Something went wrong: %@", avPlayer.error);
        }
    }
}

- (void)setVolume:(CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        NSString* callbackId = command.callbackId;
        
#pragma unused(callbackId)
        NSString* mediaId = [command argumentAtIndex:0];
        NSNumber* volume = [command argumentAtIndex:1 withDefault:[NSNumber numberWithFloat:1.0]];
        
        if ([self soundCache] != nil) {
            CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
            if (audioFile != nil) {
                audioFile.volume = volume;
                if (audioFile.player) {
                    audioFile.player.volume = [volume floatValue];
                }
                [[self soundCache] setObject:audioFile forKey:mediaId];
            }
        }
        
        // don't care for any callbacks
    }];
}

-(void) playEvent: (MPRemoteCommandEvent *) remoteEvent
{
    if (nowPlayingId != nil) {
        
        NSString* jsString = nil;
        CDVAudioFile* audioFile = [[self soundCache] objectForKey:nowPlayingId];
        
        if (audioFile != nil && audioFile.player != nil) {
            [avPlayer play];
            NSLog(@"Resumed playing audio sample from remote '%@'", audioFile.resourcePath);
            
            jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", nowPlayingId, MEDIA_STATE, 10];
        }
        
        [self.commandDelegate evalJs:jsString];
    }
}

- (void)togglePlayingAudio:(CDVInvokedUrlCommand*)command
//- (void)pausePlayingAudio:(CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        NSString* mediaId = [command argumentAtIndex:0];
        NSString* jsString = nil;
        CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];

        if ( (audioFile != nil && audioFile.player != nil) || (avPlayer != nil) ) {
            if (audioFile.player != nil) {
                [audioFile.player pause];
            }
            if (avPlayer != nil) {
                if (avPlayer.rate == 1.0) {
                    [avPlayer pause];
                    NSLog(@"Paused playing audio sample '%@'", audioFile.resourcePath);

                    jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_PAUSED];
                } else {
                    [avPlayer play];
                    jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_RUNNING];
                }
                //[avPlayer pause];
            }

        }
        // ignore if no media playing

        if (jsString) {
            [self.commandDelegate evalJs:jsString];
        }
    }];
}



-(void) nextTrackEvent: (MPRemoteCommandEvent *) remoteEvent
{   if (nowPlayingId != nil) {
        //NSLog(@"Next - Remote Event");
        NSString* jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", nowPlayingId, MEDIA_STATE, 12];
        [self.commandDelegate evalJs:jsString];
    }
}

- (void)startPlayingAudio:(CDVInvokedUrlCommand*)command
{
    
    [self.commandDelegate runInBackground:^{
        // this code necessary for queue playing in background mode
        if (!isBeginReceiveRemoteControlsSet) {
            [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
            isBeginReceiveRemoteControlsSet = TRUE;
            
            MPRemoteCommandCenter *rcc = [MPRemoteCommandCenter sharedCommandCenter];
            
            MPRemoteCommand *playCommand = [rcc playCommand];
            [playCommand setEnabled:YES];
            [playCommand addTarget:self action:@selector(playEvent:)];
            
            MPRemoteCommand *pauseCommand = [rcc pauseCommand];
            [pauseCommand setEnabled:YES];
            [pauseCommand addTarget:self action:@selector(pauseEvent:)];
            
            MPRemoteCommand *nextTrackCommand = [rcc nextTrackCommand];
            [nextTrackCommand setEnabled:YES];
            [nextTrackCommand addTarget:self action:@selector(nextTrackEvent:)];
        }
        
        NSString* callbackId = command.callbackId;
        
#pragma unused(callbackId)
        NSString* mediaId = [command argumentAtIndex:0];
        NSString* resourcePath = [command argumentAtIndex:1];
        NSDictionary* options = [command argumentAtIndex:2 withDefault:nil];
        
        BOOL bError = NO;
        NSString* jsString = nil;
        
        // check status of all AVPlayers
        NSLog(@"AVPlayer Status '%@'", avPlayerId);
 
        CDVAudioFile* audioFile = [self audioFileForResource:resourcePath withId:mediaId doValidation:YES forRecording:NO];
        if ((audioFile != nil) && (audioFile.resourceURL != nil)) {
            if (audioFile.player == nil) {
                bError = [self prepareToPlay:audioFile withId:mediaId];
            }
            if (!bError) {
                //self.currMediaId = audioFile.player.mediaId;
                self.currMediaId = mediaId;
                
                // audioFile.player != nil  or player was successfully created
                // get the audioSession and set the category to allow Playing when device is locked or ring/silent switch engaged
                
                if ([self hasAudioSession]) {
                    NSError* __autoreleasing err = nil;
                    NSNumber* playAudioWhenScreenIsLocked = [options objectForKey:@"playAudioWhenScreenIsLocked"];
                    BOOL bPlayAudioWhenScreenIsLocked = YES;
                    if (playAudioWhenScreenIsLocked != nil) {
                        bPlayAudioWhenScreenIsLocked = [playAudioWhenScreenIsLocked boolValue];
                    }
                    
                    NSString* sessionCategory = bPlayAudioWhenScreenIsLocked ? AVAudioSessionCategoryPlayback : AVAudioSessionCategorySoloAmbient;
                    [self.avSession setCategory:sessionCategory error:&err];
                    if (![self.avSession setActive:YES error:&err]) {
                        // other audio with higher priority that does not allow mixing could cause this to fail
                        NSLog(@"Unable to play audio: %@", [err localizedFailureReason]);
                        bError = YES;
                    }
                }
                if (!bError) {
                    NSLog(@"Playing audio sample '%@'", audioFile.resourcePath);
                    double position = 0;
                    NSNumber* preloadAudio = [options objectForKey:@"preloadAudio"];

                    // Main Player (NowPlaying)
                    if (preloadAudio == nil) {
                        
                        if (avPlayer) {
                            CMTime time = [avPlayer currentTime];
                            position = CMTimeGetSeconds(time);
                            
                            [avPlayer play];
                        }
                        
                        // Lockscreen Playback Info
                        position = round(position * 1000) / 1000;
                        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
                        NSMutableDictionary *playingInfo = [NSMutableDictionary dictionaryWithDictionary:center.nowPlayingInfo];
                        [playingInfo setObject:[NSNumber numberWithFloat:position] forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
                        center.nowPlayingInfo = playingInfo;
                    
                    }
                    
                    jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%.3f);\n%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_DURATION, position, @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_RUNNING];
                    [self.commandDelegate evalJs:jsString];
                }
            }
            if (bError) {
                /*  I don't see a problem playing previously recorded audio so removing this section - BG
                 NSError* error;
                 // try loading it one more time, in case the file was recorded previously
                 audioFile.player = [[ AVAudioPlayer alloc ] initWithContentsOfURL:audioFile.resourceURL error:&error];
                 if (error != nil) {
                 NSLog(@"Failed to initialize AVAudioPlayer: %@\n", error);
                 audioFile.player = nil;
                 } else {
                 NSLog(@"Playing audio sample '%@'", audioFile.resourcePath);
                 audioFile.player.numberOfLoops = numberOfLoops;
                 [audioFile.player play];
                 } */
                // error creating the session or player
                // jsString = [NSString stringWithFormat: @"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_ERROR,  MEDIA_ERR_NONE_SUPPORTED];
                jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_NONE_SUPPORTED message:nil]];
                [self.commandDelegate evalJs:jsString];
            }
        }
        // else audioFile was nil - error already returned from audioFile for resource
        return;
    }];
}

- (BOOL)prepareToPlay:(CDVAudioFile*)audioFile withId:(NSString*)mediaId
{
    BOOL bError = NO;
    NSError* __autoreleasing playerError = nil;
    
    // create the player
    NSURL* resourceURL = audioFile.resourceURL;
    
    if ([resourceURL isFileURL]) {
        audioFile.player = [[CDVAudioPlayer alloc] initWithContentsOfURL:resourceURL error:&playerError];
        avPlayer = nil;
    } else {
        NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:resourceURL];
        NSString* userAgent = [self.commandDelegate userAgent];
        if (userAgent) {
            [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
        }
        
        NSURLResponse* __autoreleasing response = nil;
        NSData* data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&playerError];
        if (playerError) {
            NSLog(@"Unable to download audio from: %@", [resourceURL absoluteString]);
        } else {
            // bug in AVAudioPlayer when playing downloaded data in NSData - we have to download the file and play from disk
            CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
            CFStringRef uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuidRef);
            NSString* filePath = [NSString stringWithFormat:@"%@/%@", [NSTemporaryDirectory()stringByStandardizingPath], uuidString];
            CFRelease(uuidString);
            CFRelease(uuidRef);
            
            [data writeToFile:filePath atomically:YES];
            NSURL* fileURL = [NSURL fileURLWithPath:filePath];
            audioFile.player = [[CDVAudioPlayer alloc] initWithContentsOfURL:fileURL error:&playerError];
        }
    }
    
    if (playerError != nil) {
        NSLog(@"Failed to initialize AVAudioPlayer: %@\n", [playerError localizedDescription]);
        audioFile.player = nil;
        if (self.avSession) {
            //[self.avSession setActive:NO error:nil];
        }
        bError = YES;
    } else {
        audioFile.player.mediaId = mediaId;
        audioFile.player.delegate = self;
        if (avPlayer == nil)
            bError = ![audioFile.player prepareToPlay];
    }
    return bError;
}

- (void)stopPlayingAudio:(CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        NSString* mediaId = [command argumentAtIndex:0];
        CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
        NSString* jsString = nil;
        
        if ((audioFile != nil) && (audioFile.player != nil)) {
            NSLog(@"Stopped playing audio sample '%@'", audioFile.resourcePath);
            [audioFile.player stop];
            audioFile.player.currentTime = 0;
            jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_STOPPED];
        }  // ignore if no media playing
        if (jsString) {
            [self.commandDelegate evalJs:jsString];
        }
    }];
}

- (void)pausePlayingAudio:(CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        NSString* mediaId = [command argumentAtIndex:0];
        NSString* jsString = nil;
        CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
        
        if (audioFile != nil && ((audioFile.player != nil) || (avPlayer != nil))) {
            if (audioFile.player != nil) {
                [audioFile.player pause];
            }
            if (avPlayer != nil) {
                [avPlayer pause];
            }
            NSLog(@"Paused playing audio sample '%@'", audioFile.resourcePath);
            
            jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_PAUSED];
        }
        // ignore if no media playing
        
        if (jsString) {
            [self.commandDelegate evalJs:jsString];
        }
    }];
}

- (void)seekToAudio:(CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        // args:
        // 0 = Media id
        // 1 = path to resource
        // 2 = seek to location in milliseconds
        
        NSString* mediaId = [command argumentAtIndex:0];
        
        CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
        double position = [[command argumentAtIndex:1] doubleValue];
        
        if (audioFile != nil) {
            NSString* jsString;
            double posInSeconds = position / 1000;
            
            if (audioFile.player != nil) {
                if (posInSeconds >= audioFile.player.duration) {
                    // The seek is past the end of file.  Stop media and reset to beginning instead of seeking past the end.
                    [audioFile.player stop];
                    audioFile.player.currentTime = 0;
                    jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%.3f);\n%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_POSITION, 0.0, @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_STOPPED];
                    // NSLog(@"seekToEndJsString=%@",jsString);
                } else {
                    audioFile.player.currentTime = posInSeconds;
                    jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%f);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_POSITION, posInSeconds];
                    // NSLog(@"seekJsString=%@",jsString);
                }
                
            } else if (avPlayer != nil) {
                int32_t timeScale = avPlayer.currentItem.asset.duration.timescale;
                CMTime timeToSeek = CMTimeMakeWithSeconds(posInSeconds, timeScale);
                // update info on the lock screen
                
                
                
                BOOL isPlaying = (avPlayer.rate > 0 && !avPlayer.error);
                
                [avPlayer seekToTime: timeToSeek
                     toleranceBefore: kCMTimeZero
                      toleranceAfter: kCMTimeZero
                   completionHandler: ^(BOOL finished) {
                       if (isPlaying) [avPlayer play];
                   }];
            }
            MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
            NSMutableDictionary *playingInfo = [NSMutableDictionary dictionaryWithDictionary:center.nowPlayingInfo];
            [playingInfo setObject:[NSNumber numberWithFloat:posInSeconds] forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
            center.nowPlayingInfo = playingInfo;
            
            [self.commandDelegate evalJs:jsString];
        }
    }];
}


- (void)release:(CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        NSString* mediaId = [command argumentAtIndex:0];
        NSString* jsString;
        
        if (mediaId != nil) {
            CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
            if (audioFile != nil) {
                
                // clear nowPlayingId reference when it finishes
                if (mediaId == nowPlayingId) {
                    nowPlayingId = nil;
                }
                
                if (audioFile.player && [audioFile.player isPlaying]) {
                    [audioFile.player stop];
                }
                if (audioFile.recorder && [audioFile.recorder isRecording]) {
                    [audioFile.recorder stop];
                }
                if (self.avSession) {
                   //[self.avSession setActive:NO error:nil];
                    //self.avSession = nil;
                }
                
                //clear player
                [avPlayer removeObserver:self forKeyPath:@"status"];
                avPlayer = nil;
                avPlayerId = nil;
                
                [[self soundCache] removeObjectForKey:mediaId];
                NSLog(@"Media with id %@ released", mediaId);
                
                jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_STOPPED];
                [self.commandDelegate evalJs:jsString];
            }
        }
    }];
}

- (void)getDurationAV:(CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        NSString* callbackId = command.callbackId;
        NSString* mediaId = [command argumentAtIndex:0];
        
#pragma unused(mediaId)
        Float64 duration = -1;
        
        if (avPlayer) {
            duration = CMTimeGetSeconds(avPlayer.currentItem.duration);
        }
        
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:duration];
        
        NSString* jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%.3f);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_POSITION, duration];
        [self.commandDelegate evalJs:jsString];
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
        
    }];
}


- (void)getCurrentPositionAudio:(CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        NSString* callbackId = command.callbackId;
        NSString* mediaId = [command argumentAtIndex:0];
        
#pragma unused(mediaId)
        CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
        double position = -1;
        
        if ((audioFile != nil) && (audioFile.player != nil) && [audioFile.player isPlaying]) {
            position = round(audioFile.player.currentTime * 1000) / 1000;
        }
        if (avPlayer) {
            CMTime time = [avPlayer currentTime];
            position = CMTimeGetSeconds(time);
        }
        
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDouble:position];
        
        NSString* jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%.3f);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_POSITION, position];
        [self.commandDelegate evalJs:jsString];
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
        
    }];
}

- (void)setLockScreenInfo:(CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        nowPlayingId = [command argumentAtIndex:0];
        NSString* title = [command.arguments objectAtIndex:1];
        // NSString* album = [command.arguments objectAtIndex:2];
        NSString* artist = [command.arguments objectAtIndex:3];
        NSString* pathToCover = [command.arguments objectAtIndex:4];
        NSNumber* duration = [command.arguments objectAtIndex:5];
        
        
        if ([MPNowPlayingInfoCenter class])  {
            /* we're on iOS 5, so set up the now playing center */
            NSMutableDictionary *songInfo = [[NSMutableDictionary alloc] init];
            [songInfo setObject:title forKey:MPMediaItemPropertyTitle];
            [songInfo setObject:artist forKey:MPMediaItemPropertyArtist];
            // we don't need to show the album: [songInfo setObject:album forKey:MPMediaItemPropertyAlbumTitle];
            [songInfo setObject:duration forKey:MPMediaItemPropertyPlaybackDuration];
            
            /* for local files: NSString *currentpath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject];
             currentpath = [NSString stringWithFormat:@"%@/files/%@", currentpath, pathToCover];
             UIImage *albumArtImage = [UIImage imageWithContentsOfFile:pathToCover]; */
            
            // for urls
            UIImage *albumArtImage = [UIImage imageWithData:[NSData dataWithContentsOfURL:[NSURL URLWithString:pathToCover]]];
            
            if (albumArtImage == nil) {
                // create from default image
                NSString *bundlePath = [[NSBundle mainBundle] resourcePath];
                NSString *defaultPathToCover = [NSString stringWithFormat:@"%@/www/img/lockscreen-soundwave.png", bundlePath];
                
                albumArtImage = [UIImage imageWithContentsOfFile:defaultPathToCover];
            }
            MPMediaItemArtwork* albumArt = [[MPMediaItemArtwork alloc] initWithImage:albumArtImage];
            [songInfo setObject:albumArt forKey:MPMediaItemPropertyArtwork];
            
            [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = songInfo;
        }
    }];
}

- (void)startRecordingAudio:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    
#pragma unused(callbackId)
    
    NSString* mediaId = [command argumentAtIndex:0];
    CDVAudioFile* audioFile = [self audioFileForResource:[command argumentAtIndex:1] withId:mediaId doValidation:YES forRecording:YES];
    __block NSString* jsString = nil;
    __block NSString* errorMsg = @"";
    
    if ((audioFile != nil) && (audioFile.resourceURL != nil)) {
        void (^startRecording)(void) = ^{
            NSError* __autoreleasing error = nil;
            
            if (audioFile.recorder != nil) {
                [audioFile.recorder stop];
                audioFile.recorder = nil;
            }
            // get the audioSession and set the category to allow recording when device is locked or ring/silent switch engaged
            if ([self hasAudioSession]) {
                if (![self.avSession.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
                    [self.avSession setCategory:AVAudioSessionCategoryRecord error:nil];
                }
                
                if (![self.avSession setActive:YES error:&error]) {
                    // other audio with higher priority that does not allow mixing could cause this to fail
                    errorMsg = [NSString stringWithFormat:@"Unable to record audio: %@", [error localizedFailureReason]];
                    // jsString = [NSString stringWithFormat: @"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_ERROR, MEDIA_ERR_ABORTED];
                    jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_ABORTED message:errorMsg]];
                    [self.commandDelegate evalJs:jsString];
                    return;
                }
            }
            
            // create a new recorder for each start record
            audioFile.recorder = [[CDVAudioRecorder alloc] initWithURL:audioFile.resourceURL settings:nil error:&error];
            
            bool recordingSuccess = NO;
            if (error == nil) {
                audioFile.recorder.delegate = self;
                audioFile.recorder.mediaId = mediaId;
                recordingSuccess = [audioFile.recorder record];
                if (recordingSuccess) {
                    NSLog(@"Started recording audio sample '%@'", audioFile.resourcePath);
                    jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_RUNNING];
                    [self.commandDelegate evalJs:jsString];
                }
            }
            
            if ((error != nil) || (recordingSuccess == NO)) {
                if (error != nil) {
                    errorMsg = [NSString stringWithFormat:@"Failed to initialize AVAudioRecorder: %@\n", [error localizedFailureReason]];
                } else {
                    errorMsg = @"Failed to start recording using AVAudioRecorder";
                }
                audioFile.recorder = nil;
                if (self.avSession) {
                    //[self.avSession setActive:NO error:nil];
                }
                jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_ABORTED message:errorMsg]];
                [self.commandDelegate evalJs:jsString];
            }
        };
        
        SEL rrpSel = NSSelectorFromString(@"requestRecordPermission:");
        if ([self hasAudioSession] && [self.avSession respondsToSelector:rrpSel])
        {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.avSession performSelector:rrpSel withObject:^(BOOL granted){
                if (granted) {
                    startRecording();
                } else {
                    NSString* msg = @"Error creating audio session, microphone permission denied.";
                    NSLog(@"%@", msg);
                    audioFile.recorder = nil;
                    if (self.avSession) {
                        //[self.avSession setActive:NO error:nil];
                    }
                    jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_ABORTED message:msg]];
                    [self.commandDelegate evalJs:jsString];
                }
            }];
#pragma clang diagnostic pop
        } else {
            startRecording();
        }
        
    } else {
        // file did not validate
        NSString* errorMsg = [NSString stringWithFormat:@"Could not record audio at '%@'", audioFile.resourcePath];
        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_ABORTED message:errorMsg]];
        [self.commandDelegate evalJs:jsString];
    }
}

- (void)stopRecordingAudio:(CDVInvokedUrlCommand*)command
{
    NSString* mediaId = [command argumentAtIndex:0];
    
    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
    NSString* jsString = nil;
    
    if ((audioFile != nil) && (audioFile.recorder != nil)) {
        NSLog(@"Stopped recording audio sample '%@'", audioFile.resourcePath);
        [audioFile.recorder stop];
        // no callback - that will happen in audioRecorderDidFinishRecording
    }
    // ignore if no media recording
    if (jsString) {
        [self.commandDelegate evalJs:jsString];
    }
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder*)recorder successfully:(BOOL)flag
{
    CDVAudioRecorder* aRecorder = (CDVAudioRecorder*)recorder;
    NSString* mediaId = aRecorder.mediaId;
    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
    NSString* jsString = nil;
    
    if (audioFile != nil) {
        NSLog(@"Finished recording audio sample '%@'", audioFile.resourcePath);
    }
    if (flag) {
        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_STOPPED];
    } else {
        // jsString = [NSString stringWithFormat: @"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_ERROR, MEDIA_ERR_DECODE];
        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_DECODE message:nil]];
    }
    if (self.avSession) {
        //[self.avSession setActive:NO error:nil];
    }
    [self.commandDelegate evalJs:jsString];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer*)player successfully:(BOOL)flag
{
    //    CDVAudioPlayer* aPlayer = (CDVAudioPlayer*)player;
    NSString* mediaId = self.currMediaId;
    CDVAudioFile* audioFile = [[self soundCache] objectForKey:mediaId];
    NSString* jsString = nil;
    
    if (audioFile != nil) {
        NSLog(@"Finished playing audio sample '%@'", audioFile.resourcePath);
    }
    if (flag) {
        audioFile.player.currentTime = 0;
        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_STOPPED];
    } else {
        // jsString = [NSString stringWithFormat: @"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_ERROR, MEDIA_ERR_DECODE];
        jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%@);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_ERROR, [self createMediaErrorWithCode:MEDIA_ERR_DECODE message:nil]];
    }
    if (self.avSession) {
        //[self.avSession setActive:NO error:nil];
    }
    [self.commandDelegate evalJs:jsString];
}

-(void)itemDidFinishPlaying:(NSNotification *) notification {
    // Will be called when AVPlayer finishes playing playerItem
    NSString* mediaId = self.currMediaId;
    NSString* jsString = nil;
    jsString = [NSString stringWithFormat:@"%@(\"%@\",%d,%d);", @"cordova.require('cordova-plugin-media.Media').onStatus", mediaId, MEDIA_STATE, MEDIA_STOPPED];
    [self.commandDelegate evalJs:jsString];
}

- (void)onMemoryWarning
{
    [[self soundCache] removeAllObjects];
    [self setSoundCache:nil];
    [self setAvSession:nil];
    
    [super onMemoryWarning];
}

- (void)dealloc
{
    [[self soundCache] removeAllObjects];
}

- (void)onReset
{
    for (CDVAudioFile* audioFile in [[self soundCache] allValues]) {
        if (audioFile != nil) {
            if (audioFile.player != nil) {
                [audioFile.player stop];
                audioFile.player.currentTime = 0;
            }
            if (audioFile.recorder != nil) {
                [audioFile.recorder stop];
            }
        }
    }
    
    [[self soundCache] removeAllObjects];
}

- (void)resetAll:(CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        if (avPlayer != nil) {
            [avPlayer pause];
        }
        avPlayer = nil;
        avPlayerId = nil;
        
        if (self.avSession) {
            [self.avSession setActive:NO error:nil];
        }
        
        [[self soundCache] removeAllObjects];
        [self setSoundCache:nil];
        [self setAvSession:nil];

        NSLog(@"Plugin Reset");
    }];
}

@end

@implementation CDVAudioFile

@synthesize resourcePath;
@synthesize resourceURL;
@synthesize player, volume;
@synthesize recorder;

@end
@implementation CDVAudioPlayer
@synthesize mediaId;

@end

@implementation CDVAudioRecorder
@synthesize mediaId;

@end
