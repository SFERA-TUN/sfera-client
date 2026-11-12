#include <jni.h>
#include <stdint.h>
#include "sfera_mobile.h"

static SferaSession *session(jlong handle) {
    return (SferaSession *)(uintptr_t)handle;
}

JNIEXPORT jlong JNICALL Java_dev_sfera_client_NativeTunnel_create(JNIEnv *env, jclass cls) {
    return (jlong)(uintptr_t)sfera_session_new();
}
JNIEXPORT jint JNICALL Java_dev_sfera_client_NativeTunnel_run(
    JNIEnv *env, jclass cls, jlong handle, jint fd, jstring host, jstring peer, jstring token) {
    const char *host_bytes = (*env)->GetStringUTFChars(env, host, NULL);
    if (!host_bytes) return -1;
    const char *peer_bytes = (*env)->GetStringUTFChars(env, peer, NULL);
    if (!peer_bytes) {
        (*env)->ReleaseStringUTFChars(env, host, host_bytes);
        return -1;
    }
    const char *token_bytes = (*env)->GetStringUTFChars(env, token, NULL);
    jint result = token_bytes ? sfera_session_run(session(handle), fd, host_bytes, peer_bytes, token_bytes) : -1;
    if (token_bytes) (*env)->ReleaseStringUTFChars(env, token, token_bytes);
    (*env)->ReleaseStringUTFChars(env, peer, peer_bytes);
    (*env)->ReleaseStringUTFChars(env, host, host_bytes);
    return result;
}
JNIEXPORT jint JNICALL Java_dev_sfera_client_NativeTunnel_status(JNIEnv *env, jclass cls, jlong handle) {
    return sfera_session_status(session(handle));
}
JNIEXPORT void JNICALL Java_dev_sfera_client_NativeTunnel_stop(JNIEnv *env, jclass cls, jlong handle) {
    sfera_session_stop(session(handle));
}
JNIEXPORT void JNICALL Java_dev_sfera_client_NativeTunnel_free(JNIEnv *env, jclass cls, jlong handle) {
    sfera_session_free(session(handle));
}
