package com.saibotix.voicevoxserver;

import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import jp.hiroshiba.voicevoxcore.AccelerationMode;
import jp.hiroshiba.voicevoxcore.AudioQuery;
import jp.hiroshiba.voicevoxcore.GlobalInfo;
import jp.hiroshiba.voicevoxcore.blocking.Onnxruntime;
import jp.hiroshiba.voicevoxcore.blocking.OpenJtalk;
import jp.hiroshiba.voicevoxcore.blocking.Synthesizer;
import jp.hiroshiba.voicevoxcore.blocking.VoiceModelFile;

/**
 * Owns the voicevox_core synthesizer. All entry points are synchronized: the
 * engine runs one synthesis at a time, which is what a single e-ink device
 * needs and keeps memory in check.
 *
 * Voice models are loaded lazily: init() only scans every *.vvm for its
 * metadata (style ids + speaker names; cheap), and the model weights are
 * loaded into RAM the first time one of their style ids is requested. At most
 * MAX_LOADED_MODELS stay resident (LRU) so a full set of ~25 vvm files works
 * on a 4 GB tablet.
 *
 * No Android imports — this class also runs on a desktop JVM for testing
 * (see desktop-test/).
 */
public final class CoreHolder {

    /** Resident model cap; each loaded model costs several hundred MB of RAM. */
    static final int MAX_LOADED_MODELS = 2;

    public interface Logger {
        void log(String msg);
    }

    /** Plain Gson matches voicevox_core's own JSON layer (internal/Convert.java). */
    private final Gson gson = new Gson();

    private Synthesizer synthesizer;
    private Logger log = msg -> { };

    /** style id -> vvm file containing it (from the metadata scan). */
    private final Map<Integer, File> styleToVvm = new LinkedHashMap<>();
    /** vvm path -> model UUID, in LRU access order. */
    private final LinkedHashMap<String, UUID> loaded =
            new LinkedHashMap<>(16, 0.75f, true);
    /** Union of all scanned metas, engine-shaped (one entry per speaker). */
    private final JsonArray allMetas = new JsonArray();
    private int modelFileCount;

    /**
     * Load ONNX Runtime + Open JTalk dictionary, then scan every *.vvm in the
     * given directories for its style metadata (no model weights are loaded
     * yet). When the same style id appears in several files, the first
     * directory wins.
     *
     * @param onnxruntimePath full path to libvoicevox_onnxruntime.so, or null to
     *        load by library name (the right thing inside an Android app).
     */
    public synchronized void init(String onnxruntimePath, File dictDir, List<File> vvmDirs,
            Logger log) throws Exception {
        if (synthesizer != null) {
            return;
        }
        this.log = log;
        log.log("loading ONNX Runtime");
        Onnxruntime ort = Onnxruntime.get().isPresent()
                ? Onnxruntime.get().get()
                : (onnxruntimePath != null
                        ? Onnxruntime.loadOnce().filename(onnxruntimePath).perform()
                        : Onnxruntime.loadOnce().perform());

        log.log("loading Open JTalk dictionary");
        OpenJtalk openJtalk = new OpenJtalk(dictDir.getAbsolutePath());

        Synthesizer synth = Synthesizer.builder(ort, openJtalk)
                .accelerationMode(AccelerationMode.CPU)
                .build();

        List<File> vvms = new ArrayList<>();
        for (File dir : vvmDirs) {
            File[] found = dir.listFiles((d, name) -> name.endsWith(".vvm"));
            if (found != null) {
                // numeric-aware order so 2.vvm sorts before 10.vvm
                Arrays.sort(found, Comparator.comparing(f -> {
                    String stem = f.getName().replaceFirst("\\.vvm$", "");
                    return stem.matches("\\d+")
                            ? String.format("%09d", Integer.parseInt(stem)) : stem;
                }));
                vvms.addAll(Arrays.asList(found));
            }
        }
        if (vvms.isEmpty()) {
            throw new IllegalStateException("no .vvm voice models in " + vvmDirs);
        }
        for (File vvm : vvms) {
            try (VoiceModelFile model = new VoiceModelFile(vvm.getAbsolutePath())) {
                mergeMetas(gson.toJsonTree(model.metas).getAsJsonArray(), vvm);
                modelFileCount++;
            } catch (Exception e) {
                log.log("skipping " + vvm.getName() + ": " + e);
            }
        }
        if (styleToVvm.isEmpty()) {
            throw new IllegalStateException("could not read any voice model in " + vvmDirs);
        }
        synthesizer = synth;
        log.log(summary() + " (models load on first use)");
    }

    /** Merge one vvm's metas into the union, recording which file owns each style. */
    private void mergeMetas(JsonArray metas, File vvm) {
        for (JsonElement el : metas) {
            JsonObject speaker = el.getAsJsonObject();
            JsonObject existing = findSpeaker(speaker.get("speaker_uuid").getAsString());
            JsonArray styles = speaker.getAsJsonArray("styles");
            if (existing == null) {
                allMetas.add(speaker);
                existing = speaker;
            } else {
                Set<Integer> have = new HashSet<>();
                for (JsonElement s : existing.getAsJsonArray("styles")) {
                    have.add(s.getAsJsonObject().get("id").getAsInt());
                }
                for (JsonElement s : styles) {
                    if (!have.contains(s.getAsJsonObject().get("id").getAsInt())) {
                        existing.getAsJsonArray("styles").add(s);
                    }
                }
            }
            for (JsonElement s : styles) {
                styleToVvm.putIfAbsent(s.getAsJsonObject().get("id").getAsInt(), vvm);
            }
        }
    }

    private JsonObject findSpeaker(String uuid) {
        for (JsonElement el : allMetas) {
            if (uuid.equals(el.getAsJsonObject().get("speaker_uuid").getAsString())) {
                return el.getAsJsonObject();
            }
        }
        return null;
    }

    /** Make sure the vvm containing styleId is resident, evicting LRU models. */
    private void ensureStyleLoaded(int styleId) throws Exception {
        File vvm = styleToVvm.get(styleId);
        if (vvm == null) {
            throw new IllegalArgumentException(
                    "unknown speaker/style id " + styleId + " — see /speakers");
        }
        String key = vvm.getAbsolutePath();
        UUID id = loaded.get(key); // touches LRU order
        if (id != null && synthesizer.isLoadedVoiceModel(id)) {
            return;
        }
        loaded.remove(key);
        while (loaded.size() >= MAX_LOADED_MODELS) {
            Map.Entry<String, UUID> eldest = loaded.entrySet().iterator().next();
            try {
                synthesizer.unloadVoiceModel(eldest.getValue());
                log.log("unloaded " + new File(eldest.getKey()).getName());
            } catch (Exception e) {
                log.log("unload failed: " + e);
            }
            loaded.remove(eldest.getKey());
        }
        log.log("loading " + vvm.getName() + "…");
        try (VoiceModelFile model = new VoiceModelFile(key)) {
            synthesizer.loadVoiceModel(model);
            loaded.put(key, model.id);
        }
        log.log("loaded " + vvm.getName());
    }

    /** Best-effort pre-load of the model behind styleId (e.g. the default voice). */
    public synchronized void warm(int styleId) {
        try {
            ensureStyleLoaded(styleId);
        } catch (Exception e) {
            log.log("warm-up skipped: " + e);
        }
    }

    public synchronized boolean isReady() {
        return synthesizer != null;
    }

    /** e.g. "26 speakers, 60 styles, 25 model files". */
    public synchronized String summary() {
        int styles = styleToVvm.size();
        return allMetas.size() + " speakers, " + styles + " styles, "
                + modelFileCount + " model files";
    }

    /** POST /audio_query body: synthesis parameters for text+style as JSON. */
    public synchronized String audioQueryJson(String text, int styleId) throws Exception {
        requireReady();
        ensureStyleLoaded(styleId);
        AudioQuery query = synthesizer.createAudioQuery(text, styleId);
        return gson.toJson(query);
    }

    /** POST /synthesis: AudioQuery JSON (as produced by audioQueryJson) to WAV bytes. */
    public synchronized byte[] synthesis(String audioQueryJson, int styleId,
            boolean interrogativeUpspeak) throws Exception {
        requireReady();
        ensureStyleLoaded(styleId);
        AudioQuery query = gson.fromJson(audioQueryJson, AudioQuery.class);
        return synthesizer.synthesis(query, styleId)
                .interrogativeUpspeak(interrogativeUpspeak)
                .perform();
    }

    /** GET /speakers: union of all scanned models' metas, engine-style JSON. */
    public synchronized String speakersJson() {
        return gson.toJson(allMetas);
    }

    /** GET /version */
    public String versionJson() {
        return gson.toJson(GlobalInfo.getVersion());
    }

    /** Human-readable speaker/style list for the status page and the activity. */
    public synchronized String describeSpeakers() {
        StringBuilder sb = new StringBuilder();
        for (JsonElement el : allMetas) {
            JsonObject speaker = el.getAsJsonObject();
            sb.append(speaker.get("name").getAsString()).append(": ");
            boolean first = true;
            for (JsonElement s : speaker.getAsJsonArray("styles")) {
                JsonObject style = s.getAsJsonObject();
                if (!first) {
                    sb.append(", ");
                }
                sb.append(style.get("name").getAsString())
                  .append("=").append(style.get("id").getAsInt());
                first = false;
            }
            sb.append("\n");
        }
        return sb.toString();
    }

    private void requireReady() {
        if (synthesizer == null) {
            throw new IllegalStateException("engine still initializing");
        }
    }
}
