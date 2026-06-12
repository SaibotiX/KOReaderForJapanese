import com.saibotix.voicevoxserver.CoreHolder;
import com.saibotix.voicevoxserver.EngineHttpServer;

import java.io.File;

/**
 * Runs the exact server code the Android app uses, on a desktop JVM, against
 * the desktop voicevox_core jar. Args: dictDir vvmDir onnxruntimePath [port].
 */
public class DesktopMain {
    public static void main(String[] args) throws Exception {
        File dictDir = new File(args[0]);
        File vvmDir = new File(args[1]);
        String onnxruntimePath = args[2];
        int port = args.length > 3 ? Integer.parseInt(args[3]) : 50121;

        CoreHolder core = new CoreHolder();
        EngineHttpServer server = new EngineHttpServer(port, core);
        server.start(EngineHttpServer.SOCKET_READ_TIMEOUT, false);
        System.out.println("listening on " + port);
        core.init(onnxruntimePath, dictDir, java.util.Collections.singletonList(vvmDir),
                msg -> System.out.println("[init] " + msg));
        System.out.println("READY");
        Thread.sleep(Long.MAX_VALUE);
    }
}
