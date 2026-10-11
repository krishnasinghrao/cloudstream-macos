package com.lagradost.macos;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;

/**
 * {@code fcntl(F_FULLFSYNC)} for a path, through JDK 17's foreign-function
 * API ({@code jdk.incubator.foreign}). On macOS {@code fsync} (what
 * {@code FileChannel.force} calls) leaves data in the drive's write cache, so
 * a power loss can still lose a "durable" commit; F_FULLFSYNC asks the drive
 * to write its cache to the medium. It applies to the device, so any
 * descriptor of the file will do: the file is opened read-only for the call.
 *
 * <p>The engine runs with {@code --add-modules=jdk.incubator.foreign
 * --enable-native-access=ALL-UNNAMED}. Without them (or off macOS) the
 * calls report unavailable and callers keep {@code force} alone.
 */
public final class FullFsync {
    private static final int O_RDONLY = 0;
    private static final int F_FULLFSYNC = 51;

    private FullFsync() {}

    /** The native entry points; incubator types appear only here. */
    private static final class Native {
        static final MethodHandle OPEN;
        static final MethodHandle FCNTL;
        static final MethodHandle CLOSE;
        static final Throwable FAILURE;

        static {
            MethodHandle open = null, fcntl = null, close = null;
            Throwable failure = null;
            try {
                if (!System.getProperty("os.name", "").startsWith("Mac")) throw new UnsupportedOperationException("not macOS");
                jdk.incubator.foreign.CLinker linker = jdk.incubator.foreign.CLinker.getInstance();
                jdk.incubator.foreign.SymbolLookup lookup = jdk.incubator.foreign.CLinker.systemLookup();
                open = linker.downcallHandle(lookup.lookup("open").orElseThrow(),
                    MethodType.methodType(int.class, jdk.incubator.foreign.MemoryAddress.class, int.class),
                    jdk.incubator.foreign.FunctionDescriptor.of(jdk.incubator.foreign.CLinker.C_INT,
                        jdk.incubator.foreign.CLinker.C_POINTER, jdk.incubator.foreign.CLinker.C_INT));
                fcntl = linker.downcallHandle(lookup.lookup("fcntl").orElseThrow(),
                    MethodType.methodType(int.class, int.class, int.class),
                    jdk.incubator.foreign.FunctionDescriptor.of(jdk.incubator.foreign.CLinker.C_INT,
                        jdk.incubator.foreign.CLinker.C_INT, jdk.incubator.foreign.CLinker.C_INT));
                close = linker.downcallHandle(lookup.lookup("close").orElseThrow(),
                    MethodType.methodType(int.class, int.class),
                    jdk.incubator.foreign.FunctionDescriptor.of(jdk.incubator.foreign.CLinker.C_INT, jdk.incubator.foreign.CLinker.C_INT));
            } catch (Throwable unavailable) {
                failure = unavailable;
            }
            OPEN = open;
            FCNTL = fcntl;
            CLOSE = close;
            FAILURE = failure;
        }
    }

    /** Whether F_FULLFSYNC can be issued in this process. */
    public static boolean available() {
        try {
            return Native.FAILURE == null;
        } catch (LinkageError missingModule) {
            return false;
        }
    }

    /** Why it cannot be issued, or null. */
    public static String unavailableReason() {
        try {
            return Native.FAILURE == null ? null : Native.FAILURE.toString();
        } catch (LinkageError missingModule) {
            return missingModule.toString();
        }
    }

    /** Flushes the drive cache for [path]'s device; false when unavailable or the call failed. */
    public static boolean flush(String path) {
        if (!available()) return false;
        try (jdk.incubator.foreign.ResourceScope scope = jdk.incubator.foreign.ResourceScope.newConfinedScope()) {
            jdk.incubator.foreign.MemorySegment cPath = jdk.incubator.foreign.CLinker.toCString(path, scope);
            int fd = (int) Native.OPEN.invokeExact(cPath.address(), O_RDONLY);
            if (fd < 0) return false;
            try {
                return (int) Native.FCNTL.invokeExact(fd, F_FULLFSYNC) == 0;
            } finally {
                int ignored = (int) Native.CLOSE.invokeExact(fd);
            }
        } catch (Throwable failure) {
            return false;
        }
    }
}
