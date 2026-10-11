import com.googlecode.d2j.dex.Dex2jar;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.zip.ZipFile;

/** Uses the production translation options; never loads an extension class. */
public class TranslateProbe {
    public static void main(String[] args) throws Exception {
        Path output = Path.of(args[0]);
        Files.createDirectories(output);
        for (int i = 1; i < args.length; i++) {
            Path source = Path.of(args[i]);
            try (ZipFile zip = new ZipFile(source.toFile())) {
                var entries = zip.entries();
                while (entries.hasMoreElements()) {
                    var entry = entries.nextElement();
                    if (!entry.getName().matches("classes[0-9]*\\.dex")) continue;
                    byte[] dex = zip.getInputStream(entry).readAllBytes();
                    Path target = output.resolve(source.getFileName() + "-" + entry.getName() + ".jar");
                    Dex2jar.from(dex).reUseReg(true).topoLogicalSort().optimizeSynchronized().skipDebug().to(target);
                    System.out.println(target);
                }
            }
        }
    }
}
