import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.file.*;
import java.util.*;
import java.util.zip.ZipFile;
import org.objectweb.asm.*;

/** Static Android/CloudStream API references; never loads community classes. */
public class AndroidAbiProbe {
    static final ClassLoader HOST = AndroidAbiProbe.class.getClassLoader();
    static boolean wanted(String owner) {
        return owner.startsWith("android/") || owner.startsWith("androidx/")
            || owner.startsWith("com/lagradost/cloudstream3/");
    }
    static Method method(Class<?> owner, String name, String descriptor) {
        for (Method m : owner.getDeclaredMethods())
            if (m.getName().equals(name) && Type.getMethodDescriptor(m).equals(descriptor)) return m;
        if (owner.getSuperclass() != null) {
            Method m = method(owner.getSuperclass(), name, descriptor);
            if (m != null) return m;
        }
        for (Class<?> iface : owner.getInterfaces()) {
            Method m = method(iface, name, descriptor);
            if (m != null) return m;
        }
        return null;
    }
    static Field field(Class<?> owner, String name, String descriptor) {
        for (Field f : owner.getDeclaredFields())
            if (f.getName().equals(name) && Type.getDescriptor(f.getType()).equals(descriptor)) return f;
        if (owner.getSuperclass() != null) {
            Field f = field(owner.getSuperclass(), name, descriptor);
            if (f != null) return f;
        }
        for (Class<?> iface : owner.getInterfaces()) {
            Field f = field(iface, name, descriptor);
            if (f != null) return f;
        }
        return null;
    }
    static String quote(String s) {
        return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + "\"";
    }
    static String json(Object o) {
        if (o == null) return "null";
        if (o instanceof String s) return quote(s);
        if (o instanceof Map<?,?> m) return "{" + String.join(",", m.entrySet().stream().map(e -> quote(e.getKey().toString()) + ":" + json(e.getValue())).toList()) + "}";
        if (o instanceof Collection<?> c) return "[" + String.join(",", c.stream().map(AndroidAbiProbe::json).toList()) + "]";
        return o.toString();
    }
    static final class Scan {
        final Set<String> own;
        final Map<String, Set<String>> issues = new TreeMap<>();
        final Set<String> references = new TreeSet<>();
        Scan(Set<String> own) { this.own = own; }
        void issue(String kind, String symbol, String caller) {
            issues.computeIfAbsent(kind + "|" + symbol, k -> new TreeSet<>()).add(caller);
        }
        Class<?> type(String owner, String caller) {
            if (!wanted(owner) || own.contains(owner)) return null;
            references.add(owner);
            try { return Class.forName(owner.replace('/', '.'), false, HOST); }
            catch (ClassNotFoundException e) { issue("missing_class", owner, caller); }
            catch (LinkageError e) { issue("host_resolution_error", owner + ": " + e, caller); }
            return null;
        }
        void descriptor(String descriptor, String caller) {
            if (descriptor.startsWith("(")) {
                for (Type t : Type.getArgumentTypes(descriptor)) descriptor(t.getDescriptor(), caller);
                descriptor(Type.getReturnType(descriptor).getDescriptor(), caller);
            } else {
                Type t = Type.getType(descriptor);
                while (t.getSort() == Type.ARRAY) t = t.getElementType();
                if (t.getSort() == Type.OBJECT) type(t.getInternalName(), caller);
            }
        }
        void invoke(int opcode, String owner, String name, String desc, String caller) {
            Class<?> cls = type(owner, caller);
            descriptor(desc, caller);
            if (cls == null) return;
            String symbol = owner + "." + name + desc;
            try {
                if (name.equals("<init>")) {
                    if (Arrays.stream(cls.getDeclaredConstructors()).noneMatch(c -> Type.getConstructorDescriptor(c).equals(desc))) issue("missing_method", symbol, caller);
                } else {
                    Method m = method(cls, name, desc);
                    if (m == null) issue("missing_method", symbol, caller);
                    else if (Modifier.isStatic(m.getModifiers()) != (opcode == Opcodes.INVOKESTATIC)) issue("invocation_kind_mismatch", symbol, caller);
                }
            } catch (LinkageError e) { issue("host_resolution_error", symbol + ": " + e, caller); }
        }
    }
    public static void main(String[] args) throws Exception {
        List<Object> results = new ArrayList<>();
        for (String argument : args) {
            try (ZipFile jar = new ZipFile(argument)) {
                Set<String> own = new HashSet<>();
                jar.stream().filter(e -> e.getName().endsWith(".class")).forEach(e -> own.add(e.getName().substring(0, e.getName().length()-6)));
                Scan scan = new Scan(own);
                var entries = jar.entries();
                while (entries.hasMoreElements()) {
                    var entry = entries.nextElement();
                    if (!entry.getName().endsWith(".class")) continue;
                    String className = entry.getName().substring(0, entry.getName().length()-6);
                    new ClassReader(jar.getInputStream(entry)).accept(new ClassVisitor(Opcodes.ASM9) {
                        @Override public void visit(int v, int a, String n, String s, String parent, String[] interfaces) {
                            if (parent != null) scan.type(parent, className + " [superclass]");
                            for (String iface : interfaces) scan.type(iface, className + " [interface]");
                        }
                        @Override public FieldVisitor visitField(int a, String n, String d, String s, Object v) {
                            scan.descriptor(d, className + "." + n + " [field signature]");
                            return null;
                        }
                        @Override public MethodVisitor visitMethod(int a, String n, String d, String s, String[] exceptions) {
                            String caller = className + "." + n + d;
                            scan.descriptor(d, caller + " [method signature]");
                            if (exceptions != null) for (String e : exceptions) scan.type(e, caller + " [throws]");
                            return new MethodVisitor(Opcodes.ASM9) {
                                @Override public void visitMethodInsn(int op, String o, String m, String desc, boolean iface) { scan.invoke(op, o, m, desc, caller); }
                                @Override public void visitTypeInsn(int op, String t) {
                                    if (t.startsWith("[")) scan.descriptor(t, caller); else scan.type(t, caller);
                                }
                                @Override public void visitLdcInsn(Object c) { if (c instanceof Type t) scan.descriptor(t.getDescriptor(), caller); }
                                @Override public void visitFieldInsn(int op, String o, String f, String desc) {
                                    Class<?> cls = scan.type(o, caller);
                                    scan.descriptor(desc, caller);
                                    if (cls == null) return;
                                    String symbol = o + "." + f + ":" + desc;
                                    try {
                                        Field resolved = field(cls, f, desc);
                                        if (resolved == null) scan.issue("missing_field", symbol, caller);
                                        else if (Modifier.isStatic(resolved.getModifiers()) != (op == Opcodes.GETSTATIC || op == Opcodes.PUTSTATIC)) scan.issue("field_kind_mismatch", symbol, caller);
                                    } catch (LinkageError e) { scan.issue("host_resolution_error", symbol + ": " + e, caller); }
                                }
                            };
                        }
                    }, ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
                }
                List<Object> issues = new ArrayList<>();
                scan.issues.forEach((key, callers) -> {
                    String[] parts = key.split("\\|", 2);
                    issues.add(Map.of("kind", parts[0], "symbol", parts[1], "callers", callers));
                });
                results.add(Map.of("translated_artifact", Path.of(argument).getFileName().toString(), "referenced_host_classes", scan.references, "issues", issues));
            }
        }
        System.out.println(json(Map.of("scope", "Static class, field and exact method-descriptor resolution against packaged host; community classes never loaded. A missing optional UI reference does not prove execution or load failure.", "results", results)));
    }
}
