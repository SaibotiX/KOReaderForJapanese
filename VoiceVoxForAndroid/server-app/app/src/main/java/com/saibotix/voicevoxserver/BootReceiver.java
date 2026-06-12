package com.saibotix.voicevoxserver;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Starts the engine on boot when the in-app autostart toggle is on. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            return;
        }
        boolean autostart = context
                .getSharedPreferences(MainActivity.PREFS, Context.MODE_PRIVATE)
                .getBoolean(MainActivity.PREF_AUTOSTART, true);
        if (autostart) {
            VoicevoxService.start(context);
        }
    }
}
