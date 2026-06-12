package com.saibotix.voicevoxserver;

import fi.iki.elonen.NanoHTTPD;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

/**
 * Minimal VOICEVOX-ENGINE-compatible HTTP server on top of voicevox_core.
 *
 * Implements the endpoints KOReader's furigana plugin uses (the standard
 * two-step flow), plus a couple of read-only extras for debugging:
 *
 *   POST /audio_query?speaker=N&text=...   -> AudioQuery JSON
 *   POST /synthesis?speaker=N  (JSON body) -> WAV bytes
 *   GET  /speakers                         -> loaded speakers/styles JSON
 *   GET  /version                          -> core version JSON string
 *   GET  /                                 -> human-readable status page
 *
 * The /synthesis input is the verbatim output of /audio_query (that is exactly
 * how the plugin calls it), so the JSON dialect is self-consistent by
 * construction. No Android imports — also runs on a desktop JVM (desktop-test/).
 */
public class EngineHttpServer extends NanoHTTPD {

    public static final int DEFAULT_PORT = 50021;

    private final CoreHolder core;

    public EngineHttpServer(int port, CoreHolder core) {
        super(port); // bind all interfaces; reachable via 127.0.0.1 and LAN
        this.core = core;
    }

    @Override
    public Response serve(IHTTPSession session) {
        String uri = session.getUri();
        Method method = session.getMethod();
        try {
            if (method == Method.GET && "/".equals(uri)) {
                return statusPage();
            }
            if (method == Method.GET && "/version".equals(uri)) {
                return json(core.versionJson());
            }
            if (method == Method.GET && "/speakers".equals(uri)) {
                if (!core.isReady()) return notReady();
                return json(core.speakersJson());
            }
            if (method == Method.POST && "/audio_query".equals(uri)) {
                if (!core.isReady()) return notReady();
                String text = param(session, "text");
                if (text == null) {
                    return error(Response.Status.BAD_REQUEST, "missing 'text' query parameter");
                }
                int speaker = intParam(session, "speaker", 3);
                return json(core.audioQueryJson(text, speaker));
            }
            if (method == Method.POST && "/synthesis".equals(uri)) {
                if (!core.isReady()) return notReady();
                int speaker = intParam(session, "speaker", 3);
                boolean upspeak = !"false".equalsIgnoreCase(
                        param(session, "enable_interrogative_upspeak"));
                String body = readBody(session);
                if (body == null || body.isEmpty()) {
                    return error(Response.Status.BAD_REQUEST, "missing AudioQuery JSON body");
                }
                byte[] wav = core.synthesis(body, speaker, upspeak);
                return newFixedLengthResponse(Response.Status.OK, "audio/wav",
                        new ByteArrayInputStream(wav), wav.length);
            }
            return error(Response.Status.NOT_FOUND, "no route: " + method + " " + uri);
        } catch (IllegalArgumentException e) {
            return error(Response.Status.BAD_REQUEST, e.getMessage());
        } catch (Exception e) {
            return error(Response.Status.INTERNAL_ERROR, e.toString());
        }
    }

    private Response statusPage() {
        StringBuilder sb = new StringBuilder();
        sb.append("<!doctype html><html><head><meta charset='utf-8'>")
          .append("<title>VOICEVOX server</title></head><body>")
          .append("<h2>VOICEVOX engine server</h2>");
        if (core.isReady()) {
            sb.append("<p>status: <b>running</b>, core ").append(core.versionJson()).append("</p>")
              .append("<p>").append(core.summary()).append("</p>")
              .append("<pre>").append(core.describeSpeakers()).append("</pre>");
        } else {
            sb.append("<p>status: <b>initializing…</b> (refresh in a few seconds)</p>");
        }
        sb.append("<p>POST /audio_query?speaker=3&amp;text=… → JSON; ")
          .append("POST /synthesis?speaker=3 (JSON body) → WAV; ")
          .append("GET /speakers; GET /version</p>")
          .append("</body></html>");
        return newFixedLengthResponse(Response.Status.OK,
                "text/html; charset=utf-8", sb.toString());
    }

    private static Response json(String body) {
        return newFixedLengthResponse(Response.Status.OK,
                "application/json; charset=utf-8", body);
    }

    private static Response notReady() {
        return error(Response.Status.SERVICE_UNAVAILABLE, "engine still initializing");
    }

    private static Response error(Response.Status status, String detail) {
        // FastAPI-style {"detail": ...} like the real engine
        String body = "{\"detail\": " + quote(detail) + "}";
        return newFixedLengthResponse(status, "application/json; charset=utf-8", body);
    }

    private static String quote(String s) {
        StringBuilder sb = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"' || c == '\\') {
                sb.append('\\').append(c);
            } else if (c == '\n') {
                sb.append("\\n");
            } else if (c < 0x20) {
                sb.append(String.format("\\u%04x", (int) c));
            } else {
                sb.append(c);
            }
        }
        return sb.append('"').toString();
    }

    private static String param(IHTTPSession session, String name) {
        Map<String, List<String>> params = session.getParameters();
        List<String> values = params.get(name);
        return values == null || values.isEmpty() ? null : values.get(0);
    }

    private static int intParam(IHTTPSession session, String name, int fallback) {
        String v = param(session, name);
        if (v == null) {
            return fallback;
        }
        try {
            return Integer.parseInt(v.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    /** Read the raw request body (Content-Length bytes) as UTF-8. */
    private static String readBody(IHTTPSession session) throws IOException {
        String contentLength = session.getHeaders().get("content-length");
        if (contentLength == null) {
            return null;
        }
        int length = Integer.parseInt(contentLength.trim());
        byte[] buf = new byte[length];
        InputStream in = session.getInputStream();
        int off = 0;
        while (off < length) {
            int n = in.read(buf, off, length - off);
            if (n < 0) {
                break;
            }
            off += n;
        }
        return new String(buf, 0, off, StandardCharsets.UTF_8);
    }
}
