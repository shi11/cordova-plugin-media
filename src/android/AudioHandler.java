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
package org.apache.cordova.media;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.CordovaResourceApi;

import android.content.Context;
import android.media.AudioManager;
import android.net.Uri;
import android.util.Log;

import java.util.ArrayList;

import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.HashMap;

/**
 * This class called by CordovaActivity to play and record audio.
 * The file can be local or over a network using http.
 *
 * Audio formats supported (tested):
 *  .mp3, .wav
 *
 * Local audio files must reside in one of two places:
 *      android_asset:      file name must start with /android_asset/sound.mp3
 *      sdcard:             file name is just sound.mp3
 */
public class AudioHandler extends CordovaPlugin {

    public static String TAG = "AudioHandler";
    HashMap<String, AudioPlayer> players;   // Audio player object
    ArrayList<AudioPlayer> pausedForPhone;     // Audio players that were paused when phone call came in
    private int origVolumeStream = -1;
    private CallbackContext messageChannel;

    /**
     * Constructor.
     */
    public AudioHandler() {
        this.players = new HashMap<String, AudioPlayer>();
        this.pausedForPhone = new ArrayList<AudioPlayer>();
    }

    /**
     * Executes the request and returns PluginResult.
     * @param action        The action to execute.
     * @param args          JSONArry of arguments for the plugin.
     * @param callbackContext       The callback context used when calling back into JavaScript.
     * @return              A PluginResult object with a status and message.
     */
    public boolean execute(String action, final JSONArray args, final CallbackContext callbackContext) throws JSONException {
        final CordovaResourceApi resourceApi = webView.getResourceApi();

        if (action.equals("startRecordingAudio")) {
            final String target = args.getString(1);
            cordova.getThreadPool().execute(new Runnable() {
                @Override
                public void run() {
                    String fileUriStr;
                    try {
                        Uri targetUri = resourceApi.remapUri(Uri.parse(target));
                        fileUriStr = targetUri.toString();
                    } catch (IllegalArgumentException e) {
                        fileUriStr = target;
                    }
                    
                    startRecordingAudio(target, FileHelper.stripFileProtocol(fileUriStr));
                    
                    PluginResult result = new PluginResult(PluginResult.Status.OK, "");
                    result.setKeepCallback(true);
                    callbackContext.sendPluginResult(result);
                }
            });
            return true;
        }
        else if (action.equals("stopRecordingAudio")) {
            final String target = args.getString(1);
            cordova.getThreadPool().execute(new Runnable() {
                @Override
                public void run() {
                    stopRecordingAudio(target);
                    
                    PluginResult result = new PluginResult(PluginResult.Status.OK, "");
                    result.setKeepCallback(true);
                    callbackContext.sendPluginResult(result);
                }
            });
            return true;
        }
        else if (action.equals("startPlayingAudio")) {
            final String target = args.getString(1);
            final String id = args.getString(0);
            cordova.getThreadPool().execute(new Runnable() {
                @Override
                public void run() {
                    String fileUriStr;
                    try {
                        Uri targetUri = resourceApi.remapUri(Uri.parse(target));
                        fileUriStr = targetUri.toString();
                    } catch (IllegalArgumentException e) {
                        fileUriStr = target;
                    }
                    
                    startPlayingAudio(id, FileHelper.stripFileProtocol(fileUriStr));
                    PluginResult result = new PluginResult(PluginResult.Status.OK, "");
                    result.setKeepCallback(true);
                    callbackContext.sendPluginResult(result);
                }
            });
            return true;
        }
        else if (action.equals("seekToAudio")) {
            final String id = args.getString(0);
            final int position = args.getInt(1);
            cordova.getThreadPool().execute(new Runnable() {
                @Override
                public void run() {
                    seekToAudio(id, position);
                    PluginResult result = new PluginResult(PluginResult.Status.OK, "");
                    result.setKeepCallback(true);
                    callbackContext.sendPluginResult(result);
                }
            });
            return true;
        }
        else if (action.equals("pausePlayingAudio")) {
            final String id = args.getString(0);
            cordova.getThreadPool().execute(new Runnable() {
                @Override
                public void run() {
                    pausePlayingAudio(id);
                    PluginResult result = new PluginResult(PluginResult.Status.OK, "");
                    result.setKeepCallback(true);
                    callbackContext.sendPluginResult(result);
                }
            });
            return true;
        }
        else if (action.equals("stopPlayingAudio")) {
            final String id = args.getString(0);
            cordova.getThreadPool().execute(new Runnable() {
                @Override
                public void run() {
                    stopPlayingAudio(id);
                    PluginResult result = new PluginResult(PluginResult.Status.OK, "");
                    result.setKeepCallback(true);
                    callbackContext.sendPluginResult(result);
                }
            });
            return true;
        } 
        else if (action.equals("setVolume")) {
            final String id = args.getString(0);
            final String secondArg = args.getString(1);
            cordova.getThreadPool().execute(new Runnable() {
                @Override
                public void run() {
                    try {
                        setVolume(id, Float.parseFloat(secondArg));
                    } catch (NumberFormatException nfe) {
                        //no-op
                    }
                    PluginResult result = new PluginResult(PluginResult.Status.OK, "");
                    result.setKeepCallback(true);
                    callbackContext.sendPluginResult(result);
                }
            });
            return true;
        } 
        else if (action.equals("getCurrentPositionAudio")) {
            final String id = args.getString(0);
            cordova.getThreadPool().execute(new Runnable() {
                @Override
                public void run() {
                    float f = getCurrentPositionAudio(id);
                    PluginResult result = new PluginResult(PluginResult.Status.OK, f);
                    result.setKeepCallback(true);
                    callbackContext.sendPluginResult(result);
                }
            });
            return true;
        }
        else if (action.equals("getDurationAudio")) {
            final String id = args.getString(0);
            final String secondArg = args.getString(1);
            cordova.getThreadPool().execute(new Runnable() {
                @Override
                public void run() {
                    float f = getDurationAudio(id, secondArg);
                    PluginResult result = new PluginResult(PluginResult.Status.OK, f);
                    result.setKeepCallback(true);
                    callbackContext.sendPluginResult(result);
                }
            });
            return true;
        }
        else if (action.equals("create")) {
            final String id = args.getString(0);
            final String secondArg = args.getString(1);       
            cordova.getThreadPool().execute(new Runnable() {
                @Override
                public void run() {
                    String src = FileHelper.stripFileProtocol(secondArg);
                    getOrCreatePlayer(id, src);
                    PluginResult result = new PluginResult(PluginResult.Status.OK, "");
                    result.setKeepCallback(true);
                    callbackContext.sendPluginResult(result);
                }
            });
            return true;
        }
        else if (action.equals("release")) {
            final String id = args.getString(0);
            cordova.getThreadPool().execute(new Runnable() {
                @Override
                public void run() {
                    boolean b = release(id);
                    PluginResult result = new PluginResult(PluginResult.Status.OK, b);
                    result.setKeepCallback(true);
                    callbackContext.sendPluginResult(result);
                }
            });
            return true;
        }
        else if (action.equals("messageChannel")) {
            cordova.getThreadPool().execute(new Runnable() {
                @Override
                public void run() {
                    messageChannel = callbackContext;
                    PluginResult result = new PluginResult(PluginResult.Status.OK, "");
                    result.setKeepCallback(true);
                    callbackContext.sendPluginResult(result);
                }
            });
            return true;
        }
        else { // Unrecognized action.
            return false;
        }
    }

    /**
     * Stop all audio players and recorders.
     */
    public void onDestroy() {
        if (!players.isEmpty()) {
            onLastPlayerReleased();
        }
        for (AudioPlayer audio : this.players.values()) {
            audio.destroy();
        }
        this.players.clear();
    }

    /**
     * Stop all audio players and recorders on navigate.
     */
    @Override
    public void onReset() {
        onDestroy();
    }

    /**
     * Called when a message is sent to plugin.
     *
     * @param id            The message id
     * @param data          The message data
     * @return              Object to stop propagation or null
     */
    public Object onMessage(String id, Object data) {

        // If phone message
        if (id.equals("telephone")) {

            // If phone ringing, then pause playing
            if ("ringing".equals(data) || "offhook".equals(data)) {

                // Get all audio players and pause them
                for (AudioPlayer audio : this.players.values()) {
                    if (audio.getState() == AudioPlayer.STATE.MEDIA_RUNNING.ordinal()) {
                        this.pausedForPhone.add(audio);
                        audio.pausePlaying();
                    }
                }

            }

            // If phone idle, then resume playing those players we paused
            else if ("idle".equals(data)) {
                for (AudioPlayer audio : this.pausedForPhone) {
                    audio.startPlaying(null);
                }
                this.pausedForPhone.clear();
            }
        }
        return null;
    }

    //--------------------------------------------------------------------------
    // LOCAL METHODS
    //--------------------------------------------------------------------------

    private AudioPlayer getOrCreatePlayer(String id, String file) {
        AudioPlayer ret = players.get(id);
        if (ret == null) {
            if (players.isEmpty()) {
                onFirstPlayerCreated();
            }
            ret = new AudioPlayer(this, id, file);
            players.put(id, ret);
        }
        return ret;
    }

    /**
     * Release the audio player instance to save memory.
     * @param id                The id of the audio player
     */
    private boolean release(String id) {
        AudioPlayer audio = players.remove(id);
        if (audio == null) {
            return false;
        }
        if (players.isEmpty()) {
            onLastPlayerReleased();
        }
        audio.destroy();
        return true;
    }

    /**
     * Start recording and save the specified file.
     * @param id                The id of the audio player
     * @param file              The name of the file
     */
    public void startRecordingAudio(String id, String file) {
        AudioPlayer audio = getOrCreatePlayer(id, file);
        audio.startRecording(file);
    }

    /**
     * Stop recording and save to the file specified when recording started.
     * @param id                The id of the audio player
     */
    public void stopRecordingAudio(String id) {
        AudioPlayer audio = this.players.get(id);
        if (audio != null) {
            audio.stopRecording();
        }
    }

    /**
     * Start or resume playing audio file.
     * @param id                The id of the audio player
     * @param file              The name of the audio file.
     */
    public void startPlayingAudio(String id, String file) {
        AudioPlayer audio = getOrCreatePlayer(id, file);
        audio.startPlaying(file);
    }

    /**
     * Seek to a location.
     * @param id                The id of the audio player
     * @param milliseconds      int: number of milliseconds to skip 1000 = 1 second
     */
    public void seekToAudio(String id, int milliseconds) {
        AudioPlayer audio = this.players.get(id);
        if (audio != null) {
            audio.seekToPlaying(milliseconds);
        }
    }

    /**
     * Pause playing.
     * @param id                The id of the audio player
     */
    public void pausePlayingAudio(String id) {
        AudioPlayer audio = this.players.get(id);
        if (audio != null) {
            audio.pausePlaying();
        }
    }

    /**
     * Stop playing the audio file.
     * @param id                The id of the audio player
     */
    public void stopPlayingAudio(String id) {
        AudioPlayer audio = this.players.get(id);
        if (audio != null) {
            audio.stopPlaying();
        }
    }

    /**
     * Get current position of playback.
     * @param id                The id of the audio player
     * @return                  position in msec
     */
    public float getCurrentPositionAudio(String id) {
        AudioPlayer audio = this.players.get(id);
        if (audio != null) {
            return (audio.getCurrentPosition() / 1000.0f);
        }
        return -1;
    }

    /**
     * Get the duration of the audio file.
     * @param id                The id of the audio player
     * @param file              The name of the audio file.
     * @return                  The duration in msec.
     */
    public float getDurationAudio(String id, String file) {
        AudioPlayer audio = getOrCreatePlayer(id, file);
        return audio.getDuration(file);
    }

    /**
     * Set the audio device to be used for playback.
     *
     * @param output            1=earpiece, 2=speaker
     */
    @SuppressWarnings("deprecation")
    public void setAudioOutputDevice(int output) {
        AudioManager audiMgr = (AudioManager) this.cordova.getActivity().getSystemService(Context.AUDIO_SERVICE);
        if (output == 2) {
            audiMgr.setRouting(AudioManager.MODE_NORMAL, AudioManager.ROUTE_SPEAKER, AudioManager.ROUTE_ALL);
        }
        else if (output == 1) {
            audiMgr.setRouting(AudioManager.MODE_NORMAL, AudioManager.ROUTE_EARPIECE, AudioManager.ROUTE_ALL);
        }
        else {
            System.out.println("AudioHandler.setAudioOutputDevice() Error: Unknown output device.");
        }
    }

    /**
     * Get the audio device to be used for playback.
     *
     * @return                  1=earpiece, 2=speaker
     */
    @SuppressWarnings("deprecation")
    public int getAudioOutputDevice() {
        AudioManager audiMgr = (AudioManager) this.cordova.getActivity().getSystemService(Context.AUDIO_SERVICE);
        if (audiMgr.getRouting(AudioManager.MODE_NORMAL) == AudioManager.ROUTE_EARPIECE) {
            return 1;
        }
        else if (audiMgr.getRouting(AudioManager.MODE_NORMAL) == AudioManager.ROUTE_SPEAKER) {
            return 2;
        }
        else {
            return -1;
        }
    }

    /**
     * Set the volume for an audio device
     *
     * @param id                The id of the audio player
     * @param volume            Volume to adjust to 0.0f - 1.0f
     */
    public void setVolume(String id, float volume) {
        AudioPlayer audio = this.players.get(id);
        if (audio != null) {
            audio.setVolume(volume);
        } else {
            System.out.println("AudioHandler.setVolume() Error: Unknown Audio Player " + id);
        }
    }

    private void onFirstPlayerCreated() {
        origVolumeStream = cordova.getActivity().getVolumeControlStream();
        cordova.getActivity().setVolumeControlStream(AudioManager.STREAM_MUSIC);
    }

    private void onLastPlayerReleased() {
        if (origVolumeStream != -1) {
            cordova.getActivity().setVolumeControlStream(origVolumeStream);
            origVolumeStream = -1;
        }
    }

    void sendEventMessage(String action, JSONObject actionData) {
        JSONObject message = new JSONObject();
        try {
            message.put("action", action);
            if (actionData != null) {
                message.put(action, actionData);
            }
        } catch (JSONException e) {
            Log.e(TAG, "Failed to create event message", e);
        }

        PluginResult pluginResult = new PluginResult(PluginResult.Status.OK, message);
        pluginResult.setKeepCallback(true);
        if (messageChannel != null) {
            messageChannel.sendPluginResult(pluginResult);
        }
    }
}
