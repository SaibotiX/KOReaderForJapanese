package com.saibotix.voicevoxserver;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.util.TypedValue;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/**
 * One-screen control panel: start/stop the engine service, show its status,
 * toggle start-on-boot, and request exclusion from battery optimization
 * (important on Boox e-ink devices, which kill background apps eagerly).
 */
public class MainActivity extends Activity {

    public static final String PREFS = "voicevox";
    public static final String PREF_AUTOSTART = "autostart";

    private TextView statusView;
    private Button batteryButton;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable refresher = new Runnable() {
        @Override
        public void run() {
            refresh();
            handler.postDelayed(this, 1500);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        int pad = dp(16);
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        column.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText(R.string.app_name);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        column.addView(title);

        statusView = new TextView(this);
        statusView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        statusView.setPadding(0, pad, 0, pad);
        column.addView(statusView);

        Button start = new Button(this);
        start.setText(R.string.start_server);
        start.setOnClickListener(v -> VoicevoxService.start(this));
        column.addView(start);

        Button stop = new Button(this);
        stop.setText(R.string.stop_server);
        stop.setOnClickListener(v -> stopService(
                new Intent(this, VoicevoxService.class)));
        column.addView(stop);

        CheckBox autostart = new CheckBox(this);
        autostart.setText(R.string.autostart);
        SharedPreferences prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        autostart.setChecked(prefs.getBoolean(PREF_AUTOSTART, true));
        autostart.setOnCheckedChangeListener((v, checked) ->
                prefs.edit().putBoolean(PREF_AUTOSTART, checked).apply());
        column.addView(autostart);

        batteryButton = new Button(this);
        batteryButton.setOnClickListener(v -> requestBatteryExemption());
        column.addView(batteryButton);

        TextView credits = new TextView(this);
        credits.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        credits.setPadding(0, pad, 0, 0);
        credits.setText(R.string.credits);
        column.addView(credits);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(column);
        setContentView(scroll);

        // Needed to read user-managed voices from /sdcard/voicevox/vvms.
        if (checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            requestPermissions(
                    new String[] { android.Manifest.permission.READ_EXTERNAL_STORAGE }, 0);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        handler.post(refresher);
    }

    @Override
    protected void onPause() {
        super.onPause();
        handler.removeCallbacks(refresher);
    }

    private void refresh() {
        StringBuilder sb = new StringBuilder();
        sb.append(getString(R.string.status_prefix)).append(VoicevoxService.status);
        if (VoicevoxService.running) {
            sb.append("\n\nKOReader server URL: http://127.0.0.1:")
              .append(EngineHttpServer.DEFAULT_PORT);
            if (!VoicevoxService.speakers.isEmpty()) {
                sb.append("\n\nSpeakers (style ids):\n").append(VoicevoxService.speakers);
            }
        }
        statusView.setText(sb.toString());

        PowerManager pm = getSystemService(PowerManager.class);
        boolean exempt = pm != null && pm.isIgnoringBatteryOptimizations(getPackageName());
        batteryButton.setText(exempt
                ? R.string.battery_exempt_ok
                : R.string.battery_exempt_request);
        batteryButton.setEnabled(!exempt);
    }

    private void requestBatteryExemption() {
        try {
            Intent intent = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:" + getPackageName()));
            startActivity(intent);
        } catch (Exception e) {
            Toast.makeText(this, "Not supported on this device: " + e,
                    Toast.LENGTH_LONG).show();
        }
    }

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                getResources().getDisplayMetrics());
    }
}
