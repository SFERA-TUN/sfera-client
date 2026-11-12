package dev.sfera.client;

final class NativeTunnel {
    static { System.loadLibrary("sfera_android"); }
    static native long create();
    static native int run(long handle, int fd, String host, String peer, String token);
    static native int status(long handle);
    static native void stop(long handle);
    static native void free(long handle);
}
