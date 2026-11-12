package com.lib.flutter_blue_plus;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;

/** Owns the exact bytes passed to MethodChannel. No upstream array is forwarded. */
final class BleValueSnapshot {
    final byte[] bytes;
    private byte[] original;
    private boolean probe;

    BleValueSnapshot(byte[] value, boolean compareOriginalAtDispatch) {
        // First operation: copy while still in the actual Bluetooth callback.
        bytes = value == null ? null : value.clone();
        probe = compareOriginalAtDispatch;
        // Sole purpose of this temporary reference is a one-shot mutation probe
        // immediately before UI dispatch. It never enters the disk queue.
        original = probe ? value : null;
    }

    Comparison compareAndRelease() {
        final byte[] beforeDispatch = original == null ? null : original.clone();
        original = null;
        final boolean compared = probe;
        probe = false;
        return new Comparison(compared, Arrays.equals(bytes, beforeDispatch), beforeDispatch);
    }

    void releaseWithoutComparison() {
        original = null;
        probe = false;
    }

    static final class Comparison {
        final boolean compared, unchanged;
        final byte[] originalAtDispatch;
        Comparison(boolean compared, boolean unchanged, byte[] originalAtDispatch) {
            this.compared = compared;
            this.unchanged = unchanged;
            this.originalAtDispatch = originalAtDispatch;
        }
    }

    static String hex(byte[] bytes) {
        if (bytes == null) return null;
        char[] result = new char[bytes.length * 2];
        char[] alphabet = "0123456789abcdef".toCharArray();
        for (int i = 0; i < bytes.length; i++) {
            result[2 * i] = alphabet[(bytes[i] & 255) >>> 4];
            result[2 * i + 1] = alphabet[bytes[i] & 15];
        }
        return new String(result);
    }

    static String sha256(byte[] bytes) {
        if (bytes == null) return null;
        try {
            return hex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (NoSuchAlgorithmException impossible) {
            throw new AssertionError(impossible);
        }
    }
}
