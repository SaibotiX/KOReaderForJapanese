package com.saibotix.voicevoxserver;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.res.AssetManager;
import android.os.Environment;
import android.os.IBinder;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * Foreground service that owns the engine: extracts bundled assets on first
 * run, initializes voicevox_core, and serves the engine HTTP API on :50021
 * until stopped. START_STICKY so the system restarts it if killed.
 */
public class VoicevoxService extends Service {

    public static final String ACTION_STOP = "com.saibotix.voicevoxserver.STOP";

    private static final String TAG = "VoicevoxService";
    private static final String CHANNEL_ID = "voicevox_server";
    private static final int NOTIFICATION_ID = 1;
    private static final String DICT_DIR = "open_jtalk_dic_utf_8-1.11";

    /** Simple state the activity polls; avoids any binding machinery. */
    public static volatile boolean running = false;
    public static volatile String status = "stopped";
    public static volatile String speakers = "";

    private static final CoreHolder core = new CoreHolder();
    private EngineHttpServer server;
    private Thread initThread;

    @Override
    public void onCreate() {
        super.onCreate();
        createChannel();
        startForeground(NOTIFICATION_ID, buildNotification("starting…"));
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stopForeground(true);
            stopSelf();
            return START_NOT_STICKY;
        }
        if (initThread == null) {
            initThread = new Thread(this::bringUp, "voicevox-init");
            initThread.start();
        }
        return START_STICKY;
    }

    private void bringUp() {
        try {
            setStatus("extracting assets…");
            File root = getDataRoot();
            extractAssetsOnce(root);

            setStatus("scanning models…");
            List<File> vvmDirs = new ArrayList<>();
            vvmDirs.add(new File(root, "vvms"));
            // user-managed voices, writable with any file manager and kept
            // across reinstalls (needs READ_EXTERNAL_STORAGE, granted via the
            // app screen)
            vvmDirs.add(new File(Environment.getExternalStorageDirectory(),
                    "voicevox/vvms"));
            // null onnxruntime path: System.loadLibrary finds the bundled
            // libvoicevox_onnxruntime.so in the APK's native lib dir.
            core.init(null, new File(root, DICT_DIR), vvmDirs,
                    msg -> setStatus(msg));
            speakers = core.describeSpeakers();

            if (server == null) {
                server = new EngineHttpServer(EngineHttpServer.DEFAULT_PORT, core);
                server.start(EngineHttpServer.SOCKET_READ_TIMEOUT, false);
            }
            running = true;
            setStatus("running on http://127.0.0.1:" + EngineHttpServer.DEFAULT_PORT
                    + " — " + core.summary());
            // Pre-load the furigana plugin's default voice (ずんだもん ノーマル)
            // so the first tapped word doesn't pay the model-load delay.
            core.warm(3);
        } catch (Throwable e) {
            Log.e(TAG, "engine startup failed", e);
            running = false;
            setStatus("ERROR: " + e);
        }
    }

    private void setStatus(String s) {
        status = s;
        Log.i(TAG, s);
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null) {
            nm.notify(NOTIFICATION_ID, buildNotification(s));
        }
    }

    /** Prefer the user-visible external files dir so vvms/ can be managed by hand. */
    private File getDataRoot() {
        File external = getExternalFilesDir(null);
        return external != null ? external : getFilesDir();
    }

    /**
     * Copy assets (dict + bundled vvms + legal) into the data root once per
     * versionCode. User-added files in vvms/ are left alone; bundled ones are
     * refreshed on app upgrade.
     */
    private void extractAssetsOnce(File root) throws IOException {
        File stamp = new File(root, ".assets-v" + BuildConfig.VERSION_CODE);
        if (stamp.exists()) {
            return;
        }
        copyAssetDir(DICT_DIR, new File(root, DICT_DIR));
        copyAssetDir("vvms", new File(root, "vvms"));
        copyAssetDir("legal", new File(root, "legal"));
        if (!stamp.createNewFile()) {
            throw new IOException("cannot write " + stamp);
        }
    }

    private void copyAssetDir(String assetPath, File outDir) throws IOException {
        AssetManager assets = getAssets();
        String[] children = assets.list(assetPath);
        if (children == null || children.length == 0) {
            return;
        }
        if (!outDir.isDirectory() && !outDir.mkdirs()) {
            throw new IOException("cannot create " + outDir);
        }
        for (String child : children) {
            String childAsset = assetPath + "/" + child;
            String[] grandChildren = assets.list(childAsset);
            File outFile = new File(outDir, child);
            if (grandChildren != null && grandChildren.length > 0) {
                copyAssetDir(childAsset, outFile);
            } else {
                try (InputStream in = assets.open(childAsset);
                        OutputStream out = new FileOutputStream(outFile)) {
                    byte[] buf = new byte[1 << 16];
                    int n;
                    while ((n = in.read(buf)) > 0) {
                        out.write(buf, 0, n);
                    }
                }
            }
        }
    }

    private void createChannel() {
        NotificationChannel channel = new NotificationChannel(CHANNEL_ID,
                getString(R.string.app_name), NotificationManager.IMPORTANCE_LOW);
        channel.setShowBadge(false);
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null) {
            nm.createNotificationChannel(channel);
        }
    }

    private Notification buildNotification(String text) {
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent openPi = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Intent stop = new Intent(this, VoicevoxService.class).setAction(ACTION_STOP);
        PendingIntent stopPi = PendingIntent.getService(this, 1, stop,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_voicevox)
                .setContentTitle(getString(R.string.app_name))
                .setContentText(text)
                .setOngoing(true)
                .setContentIntent(openPi)
                .addAction(new Notification.Action.Builder(null, "Stop", stopPi).build())
                .build();
    }

    @Override
    public void onDestroy() {
        if (server != null) {
            server.stop();
            server = null;
        }
        running = false;
        status = "stopped";
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    public static void start(Context context) {
        context.startForegroundService(new Intent(context, VoicevoxService.class));
    }
}
