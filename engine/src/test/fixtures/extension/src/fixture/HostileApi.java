package fixture;

import com.lagradost.cloudstream3.HomePageList;
import com.lagradost.cloudstream3.HomePageResponse;
import com.lagradost.cloudstream3.MainAPI;
import com.lagradost.cloudstream3.MainPageData;
import com.lagradost.cloudstream3.MainPageRequest;
import java.io.File;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import kotlin.coroutines.Continuation;

/**
 * search("block") spins forever ignoring interruption; search("oom") exhausts
 * the heap; search("exit") kills its own process. The "probe" shelf acts on
 * files/probe-target.txt and reports whether it could:
 * - a plain path: read that file;
 * - "stat:<path>": check whether the path exists (metadata only);
 * - "unix:<path>": connect to a Unix-domain socket;
 * - "tcp:<host>:<port>": connect over TCP (through the JDK's proxy selection);
 * - "direct:<host>:<port>": connect over TCP bypassing any proxy;
 * - "env:<name>": read an environment variable ("read:<unset>" when absent);
 * - "args:<pid>": read another process's command line.
 */
public class HostileApi extends MainAPI {
    private final File files;

    public HostileApi(File files) {
        this.files = files;
        setName("Hostile");
        setMainUrl("https://hostile.invalid");
    }

    @Override
    public boolean getHasMainPage() {
        return true;
    }

    @Override
    public List<MainPageData> getMainPage() {
        return Collections.singletonList(new MainPageData("probe", "probe", false));
    }

    @Override
    public Object search(String query, Continuation<? super List<? extends com.lagradost.cloudstream3.SearchResponse>> continuation) {
        if ("block".equals(query)) {
            while (true) {
                try { Thread.sleep(1000); } catch (InterruptedException ignored) { }
            }
        }
        if ("oom".equals(query)) {
            List<byte[]> hog = new ArrayList<>();
            while (true) hog.add(new byte[8 * 1024 * 1024]);
        }
        if ("exit".equals(query)) {
            Runtime.getRuntime().halt(3);
        }
        return Collections.emptyList();
    }

    @Override
    public Object getMainPage(int page, MainPageRequest request, Continuation<? super HomePageResponse> continuation) {
        String outcome;
        try {
            outcome = "read:" + probe(new String(Files.readAllBytes(new File(files, "probe-target.txt").toPath())).trim());
        } catch (Throwable failure) {
            String message = failure.getMessage() == null ? "" : failure.getMessage();
            outcome = "denied:" + failure.getClass().getSimpleName() + ":" + message.substring(0, Math.min(message.length(), 120));
        }
        return new HomePageResponse(Collections.singletonList(new HomePageList(outcome, Collections.emptyList(), false)), false);
    }

    private static String probe(String target) throws Exception {
        if (target.startsWith("stat:")) {
            java.nio.file.Path path = new File(target.substring(5)).toPath();
            if (!Files.exists(path) && !Files.notExists(path)) throw new SecurityException("existence unknown");
            Files.readAttributes(path, java.nio.file.attribute.BasicFileAttributes.class);
            return "exists";
        }
        if (target.startsWith("unix:")) {
            try (java.nio.channels.SocketChannel channel = java.nio.channels.SocketChannel.open(java.net.StandardProtocolFamily.UNIX)) {
                channel.connect(java.net.UnixDomainSocketAddress.of(target.substring(5)));
                java.nio.ByteBuffer buffer = java.nio.ByteBuffer.allocate(256);
                channel.read(buffer);
                return new String(buffer.array(), 0, buffer.position()).trim();
            }
        }
        if (target.startsWith("tcp:") || target.startsWith("direct:")) {
            boolean direct = target.startsWith("direct:");
            String address = target.substring(direct ? 7 : 4);
            int colon = address.lastIndexOf(':');
            try (java.net.Socket socket = direct ? new java.net.Socket(java.net.Proxy.NO_PROXY) : new java.net.Socket()) {
                socket.connect(new java.net.InetSocketAddress(address.substring(0, colon), Integer.parseInt(address.substring(colon + 1))), 5000);
                socket.setSoTimeout(2000);
                byte[] buffer = new byte[256];
                int read;
                try { read = socket.getInputStream().read(buffer); } catch (java.net.SocketTimeoutException quiet) { return "connected"; }
                return read <= 0 ? "connected" : new String(buffer, 0, read).trim();
            }
        }
        if (target.startsWith("env:")) {
            String value = System.getenv(target.substring(4));
            return value == null ? "<unset>" : value;
        }
        if (target.startsWith("args:")) {
            // Reflection: d8 would otherwise try to desugar the static interface call.
            Class<?> handles = Class.forName("java.lang.ProcessHandle");
            java.util.Optional<?> process = (java.util.Optional<?>) handles.getMethod("of", long.class)
                .invoke(null, Long.parseLong(target.substring(5)));
            if (!process.isPresent()) throw new SecurityException("no such process");
            Object info = handles.getMethod("info").invoke(process.get());
            java.util.Optional<?> arguments = (java.util.Optional<?>) Class.forName("java.lang.ProcessHandle$Info")
                .getMethod("arguments").invoke(info);
            if (!arguments.isPresent()) throw new SecurityException("arguments hidden");
            return String.join(" ", (String[]) arguments.get());
        }
        return new String(Files.readAllBytes(new File(target).toPath())).trim();
    }
}
