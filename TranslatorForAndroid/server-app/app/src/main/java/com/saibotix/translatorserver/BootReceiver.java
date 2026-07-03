package com.saibotix.translatorserver;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Starts the translation server on boot when the autostart toggle is on. */
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
            TranslatorService.start(context);
        }
    }
}
