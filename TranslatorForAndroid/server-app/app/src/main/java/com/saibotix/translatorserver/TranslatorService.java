package com.saibotix.translatorserver;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.res.AssetManager;
import android.os.IBinder;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.List;

/**
 * Foreground service that owns the translation engine: extracts the bundled
 * GGUF model on first run, then execs llama.cpp's llama-server (shipped as
 * jniLibs/arm64-v8a/libllamaserver.so — the only place Android allows exec
 * from) bound to 127.0.0.1:8087, and babysits the process (restarts it a few
 * times if it dies) until stopped. KOReader's japanese.koplugin
 * localtranslator.lua speaks to the OpenAI-compatible endpoint it serves.
 * START_STICKY so the system restarts the service if killed.
 */
public class TranslatorService extends Service {

    public static final String ACTION_STOP = "com.saibotix.translatorserver.STOP";
    public static final int PORT = 8087;
    public static final String MODEL_ASSET = "models/LFM2-350M-ENJP-MT-Q4_K_M.gguf";

    private static final String TAG = "TranslatorService";
    private static final String CHANNEL_ID = "translator_server";
    private static final int NOTIFICATION_ID = 1;
    private static final int MAX_RESTARTS = 3;
    private static final int HEALTH_TIMEOUT_S = 300; // model load on slow eMMC
    private static final int ENGINE_LOG_LINES = 20;

    /** Simple state the activity polls; avoids any binding machinery. */
    public static volatile boolean running = false;
    public static volatile String status = "stopped";

    /** Ring of the engine's most recent output lines (diagnostics on-device). */
    private static final java.util.ArrayDeque<String> engineLog = new java.util.ArrayDeque<>();

    private static void engineLogAdd(String line) {
        synchronized (engineLog) {
            engineLog.addLast(line);
            while (engineLog.size() > ENGINE_LOG_LINES) {
                engineLog.removeFirst();
            }
        }
    }

    /** The last few engine output lines, newest last (empty when none). */
    public static String engineTail(int max) {
        synchronized (engineLog) {
            StringBuilder sb = new StringBuilder();
            int skip = Math.max(0, engineLog.size() - max);
            int i = 0;
            for (String line : engineLog) {
                if (i++ < skip) continue;
                if (sb.length() > 0) sb.append('\n');
                sb.append(line);
            }
            return sb.toString();
        }
    }

    private Thread runThread;
    private volatile Process server;
    private volatile boolean stopping = false;

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
        if (runThread == null) {
            stopping = false;
            runThread = new Thread(this::bringUp, "translator-run");
            runThread.start();
        }
        return START_STICKY;
    }

    private void bringUp() {
        try {
            setStatus("extracting model…");
            File model = extractModelOnce();

            for (int attempt = 0; attempt <= MAX_RESTARTS && !stopping; attempt++) {
                if (attempt > 0) {
                    setStatus("engine not ready — retrying (" + attempt + "/" + MAX_RESTARTS + ")…");
                    Thread.sleep(2000L * attempt);
                }
                Process p = launchServer(model);
                server = p;
                if (waitHealthy(p)) {
                    running = true;
                    setStatus("running on http://127.0.0.1:" + PORT
                            + "\nmodel: LFM2-350M-ENJP-MT (Q4_K_M)");
                    p.waitFor(); // block until it exits (stop or crash)
                    running = false;
                    if (stopping) {
                        break;
                    }
                    Log.w(TAG, "engine exited with " + p.exitValue());
                } else {
                    boolean died = !p.isAlive();
                    p.destroyForcibly();
                    p.waitFor();
                    Log.w(TAG, died
                            ? "engine exited during startup: " + p.exitValue()
                            : "engine never became healthy; killed");
                }
            }
            if (!stopping) {
                String tail = engineTail(4);
                setStatus("ERROR: engine did not come up.\n"
                        + (tail.isEmpty() ? "(no engine output)" : "engine said:\n" + tail));
            } else {
                setStatus("stopped");
            }
        } catch (Throwable e) {
            Log.e(TAG, "engine startup failed", e);
            running = false;
            setStatus("ERROR: " + e);
        }
    }

    /**
     * Number of "big" cores (cores whose max cpufreq equals the fastest
     * core's). llama.cpp splits every matrix multiplication evenly across its
     * threads and synchronizes per op, so on the big.LITTLE SoCs common in
     * e-readers the little cores become the critical path: 4 big-core
     * threads finish a token well before 8 mixed ones. Returns 0 when the
     * cores are uniform or sysfs is unreadable (then llama-server's own
     * default is used).
     */
    private static int bigCoreCount() {
        int total = Runtime.getRuntime().availableProcessors();
        long[] freqs = new long[total];
        long maxFreq = 0;
        for (int i = 0; i < total; i++) {
            try (BufferedReader r = new BufferedReader(new FileReader(
                    "/sys/devices/system/cpu/cpu" + i + "/cpufreq/cpuinfo_max_freq"))) {
                freqs[i] = Long.parseLong(r.readLine().trim());
            } catch (Exception e) {
                freqs[i] = 0;
            }
            maxFreq = Math.max(maxFreq, freqs[i]);
        }
        if (maxFreq <= 0) {
            return 0;
        }
        int big = 0;
        for (long f : freqs) {
            if (f == maxFreq) {
                big++;
            }
        }
        return (big > 0 && big < total) ? big : 0;
    }

    /** Exec llama-server from the native lib dir with the extracted model. */
    private Process launchServer(File model) throws IOException {
        String exe = getApplicationInfo().nativeLibraryDir + "/libllamaserver.so";
        List<String> cmd = new ArrayList<>();
        cmd.add(exe);
        cmd.add("-m");
        cmd.add(model.getAbsolutePath());
        cmd.add("--host");
        cmd.add("127.0.0.1");
        cmd.add("--port");
        cmd.add(String.valueOf(PORT));
        cmd.add("-c");
        cmd.add("4096");
        // One sentence at a time from KOReader: a single slot keeps RAM flat.
        cmd.add("--parallel");
        cmd.add("1");
        // Pin the worker threads to the big-core count: with the default
        // (all cores) every token waits for the slowest little core.
        int threads = bigCoreCount();
        if (threads > 0) {
            cmd.add("-t");
            cmd.add(String.valueOf(threads));
        }
        // Read the model into RAM sequentially instead of mmap: on e-reader
        // flash (+ file-based encryption) mmap page-ins can stall the load
        // for minutes, which showed up as "loading model…" forever.
        cmd.add("--no-mmap");
        ProcessBuilder pb = new ProcessBuilder(cmd);
        pb.redirectErrorStream(true);
        pb.environment().put("TMPDIR", getCacheDir().getAbsolutePath());
        pb.environment().put("HOME", getFilesDir().getAbsolutePath());
        Process p = pb.start();
        // Drain (and log) the engine output so the pipe never fills up.
        Thread drainer = new Thread(() -> {
            try (BufferedReader r = new BufferedReader(
                    new InputStreamReader(p.getInputStream()))) {
                String line;
                while ((line = r.readLine()) != null) {
                    Log.i("llama-server", line);
                    engineLogAdd(line);
                }
            } catch (IOException ignored) {
            }
        }, "llama-server-log");
        drainer.setDaemon(true);
        drainer.start();
        return p;
    }

    /** Poll /health until the model is loaded (llama-server answers 200). */
    private boolean waitHealthy(Process p) throws InterruptedException {
        String health = "";
        for (int i = 0; i < HEALTH_TIMEOUT_S && !stopping; i++) {
            if (!p.isAlive()) {
                return false;
            }
            try {
                HttpURLConnection c = (HttpURLConnection)
                        new URL("http://127.0.0.1:" + PORT + "/health").openConnection();
                c.setConnectTimeout(1000);
                c.setReadTimeout(1000);
                int code = c.getResponseCode();
                c.disconnect();
                if (code == 200) {
                    return true;
                }
                health = "health: HTTP " + code;
            } catch (IOException e) {
                // Surface the reason: a swallowed exception here once hid a
                // cleartext-HTTP policy block while the engine ran fine.
                health = "health: " + e;
            }
            String last = engineTail(1);
            setStatus("loading model… (" + i + "s)"
                    + (last.isEmpty() ? "" : "\n" + last)
                    + (health.isEmpty() ? "" : "\n" + health));
            Thread.sleep(1000);
        }
        return false;
    }

    /**
     * Copy the bundled GGUF into the app's files dir once per versionCode
     * (stored uncompressed in the APK, so this is a plain copy).
     */
    private File extractModelOnce() throws IOException {
        File root = getFilesDir();
        File modelDir = new File(root, "models");
        File model = new File(modelDir, new File(MODEL_ASSET).getName());
        File stamp = new File(root, ".model-v" + BuildConfig.VERSION_CODE);
        if (stamp.exists() && model.isFile()) {
            return model;
        }
        if (!modelDir.isDirectory() && !modelDir.mkdirs()) {
            throw new IOException("cannot create " + modelDir);
        }
        AssetManager assets = getAssets();
        File tmp = new File(modelDir, model.getName() + ".part");
        try (InputStream in = assets.open(MODEL_ASSET);
                OutputStream out = new FileOutputStream(tmp)) {
            byte[] buf = new byte[1 << 16];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
            }
        }
        if (!tmp.renameTo(model)) {
            throw new IOException("cannot move " + tmp + " to " + model);
        }
        if (!stamp.createNewFile()) {
            throw new IOException("cannot write " + stamp);
        }
        return model;
    }

    private void setStatus(String s) {
        status = s;
        Log.i(TAG, s);
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null) {
            nm.notify(NOTIFICATION_ID, buildNotification(s));
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
        Intent stop = new Intent(this, TranslatorService.class).setAction(ACTION_STOP);
        PendingIntent stopPi = PendingIntent.getService(this, 1, stop,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_translator)
                .setContentTitle(getString(R.string.app_name))
                .setContentText(text)
                .setOngoing(true)
                .setContentIntent(openPi)
                .addAction(new Notification.Action.Builder(null, "Stop", stopPi).build())
                .build();
    }

    @Override
    public void onDestroy() {
        stopping = true;
        Process p = server;
        if (p != null) {
            p.destroy();
            try {
                if (!p.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)) {
                    p.destroyForcibly();
                }
            } catch (InterruptedException e) {
                p.destroyForcibly();
            }
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
        context.startForegroundService(new Intent(context, TranslatorService.class));
    }
}
