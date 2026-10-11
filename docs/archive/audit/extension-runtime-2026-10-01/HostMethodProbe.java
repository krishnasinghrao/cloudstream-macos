import java.nio.file.Path;
import java.util.TreeSet;
import java.util.zip.ZipFile;
import org.objectweb.asm.*;

/** Resolve method references against host definitions without initializing them. */
public class HostMethodProbe {
    static boolean exists(Class<?> owner, String name, String descriptor) {
        if (name.equals("<init>")) {
            for (var constructor : owner.getDeclaredConstructors())
                if (Type.getConstructorDescriptor(constructor).equals(descriptor)) return true;
            return false;
        }
        for (var method : owner.getDeclaredMethods())
            if (method.getName().equals(name) && Type.getMethodDescriptor(method).equals(descriptor)) return true;
        if (owner.getSuperclass() != null && exists(owner.getSuperclass(), name, descriptor)) return true;
        for (var iface : owner.getInterfaces()) if (exists(iface, name, descriptor)) return true;
        return false;
    }

    public static void main(String[] args) throws Exception {
        for (String argument : args) {
            var missing = new TreeSet<String>();
            var unresolvable = new TreeSet<String>();
            try (var jar = new ZipFile(Path.of(argument).toFile())) {
                var entries = jar.entries();
                while (entries.hasMoreElements()) {
                    var entry = entries.nextElement();
                    if (!entry.getName().endsWith(".class")) continue;
                    new ClassReader(jar.getInputStream(entry)).accept(new ClassVisitor(Opcodes.ASM9) {
                        @Override public MethodVisitor visitMethod(int access, String method, String desc, String sig, String[] exceptions) {
                            return new MethodVisitor(Opcodes.ASM9) {
                                @Override public void visitMethodInsn(int opcode, String owner, String name, String descriptor, boolean iface) {
                                    if (!owner.startsWith("kotlin/") && !owner.startsWith("com/lagradost/cloudstream3/")) return;
                                    try {
                                        Class<?> type = Class.forName(owner.replace('/', '.'), false, HostMethodProbe.class.getClassLoader());
                                        if (!exists(type, name, descriptor)) missing.add(owner + "." + name + descriptor);
                                    } catch (ClassNotFoundException absent) {
                                        // Missing classes are listed by bytecode_probe.py.
                                    } catch (LinkageError error) { unresolvable.add(owner + ": " + error); }
                                }
                            };
                        }
                    }, ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
                }
            }
            System.out.println("ARTIFACT " + Path.of(argument).getFileName());
            missing.forEach(s -> System.out.println("MISSING " + s));
            unresolvable.forEach(s -> System.out.println("UNRESOLVABLE " + s));
        }
    }
}
