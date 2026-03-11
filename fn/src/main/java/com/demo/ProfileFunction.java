package com.demo;

import com.sun.net.httpserver.HttpServer;
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.JedisPoolConfig;

import java.io.IOException;
import java.io.OutputStream;
import java.lang.reflect.Method;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

public class ProfileFunction {

    private static final String POD_UID     = env("POD_UID",     "unknown");
    private static final String REDIS_HOST  = env("REDIS_HOST",  "redis.openfaas.svc.cluster.local");
    private static final int    REDIS_PORT  = Integer.parseInt(env("REDIS_PORT", "6379"));
    private static final String FN_NAME     = env("FN_NAME",     "profile-fn");
    private static final String FN_VERSION  = env("FN_VERSION",  "v1");
    private static final Path   MDOX_PATH   = Paths.get("/profiles/profile.mdox");

    public static void main(String[] args) throws Exception {
        long startMs = System.currentTimeMillis();

        // Check if an MDOX profile was loaded by the JVM (via -XX:+LoadMDOAtStartup)
        boolean profileLoaded = Files.exists(MDOX_PATH) && Files.size(MDOX_PATH) > 0;
        long profileSize = profileLoaded ? Files.size(MDOX_PATH) : 0;
        String profileHash = profileLoaded ? sha256Prefix(MDOX_PATH, 12) : "none";

        System.out.printf("JAVA_STARTED pod=%s profile_loaded=%s profile_hash=%s profile_size=%d t=%d%n",
                POD_UID, profileLoaded, profileHash, profileSize, startMs);

        JedisPool pool = buildPool();

        // Write started key and increment run sequence
        String runseq;
        try (Jedis j = pool.getResource()) {
            runseq = String.valueOf(j.incr("runseq:" + FN_NAME + ":" + FN_VERSION));
            j.set("started:" + POD_UID,
                  fmt("{\"pod\":\"%s\",\"started_ms\":%d,\"profile_hash\":\"%s\",\"profile_size\":%d,\"profile_loaded\":%s,\"runseq\":%s}",
                      POD_UID, startMs, profileHash, profileSize, profileLoaded, runseq));
        }

        // On SIGTERM: JVM will auto-dump MDOX via -XX:+DumpMDOAtExit
        // entrypoint.sh then pushes the file to Redis
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            // Trigger explicit dump via the Java API as a safety net
            try {
                dumpProfile(MDOX_PATH);
                long dumpSize = Files.exists(MDOX_PATH) ? Files.size(MDOX_PATH) : 0;
                System.out.printf("JAVA_SHUTDOWN_DUMP pod=%s dump_size=%d t=%d%n",
                        POD_UID, dumpSize, System.currentTimeMillis());
            } catch (Exception e) {
                System.err.printf("JAVA_SHUTDOWN_DUMP_FAILED pod=%s error=%s%n", POD_UID, e.getMessage());
            }
            System.out.printf("JAVA_SIGTERM pod=%s t=%d%n", POD_UID, System.currentTimeMillis());
        }));

        // HTTP handler — returns profile metadata for verification
        final boolean loaded = profileLoaded;
        final long pSize = profileSize;
        final String pHash = profileHash;
        final String seq = runseq;
        final long start = startMs;

        HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);
        server.createContext("/", exchange -> {
            String body = fmt(
                "{\"pod\":\"%s\",\"start_ms\":%d,\"profile_hash\":\"%s\"," +
                "\"profile_size\":%d,\"profile_loaded\":%s,\"runseq\":%s}",
                POD_UID, start, pHash, pSize, loaded, seq);
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, bytes.length);
            try (OutputStream os = exchange.getResponseBody()) { os.write(bytes); }
        });
        server.setExecutor(null);
        server.start();
        System.out.println("HTTP listening on :8080");

        // Block until the JVM is killed
        Thread.currentThread().join();
    }

    // ── ProfileCheckpoint Java API (reflective to avoid compile-time dep) ────

    private static void dumpProfile(Path path) {
        try {
            Class<?> pc = Class.forName("jdk.internal.profilecheckpoint.ProfileCheckpoint");
            Method dump = pc.getMethod("dump", Path.class);
            dump.invoke(null, path);
        } catch (Exception e) {
            System.err.println("ProfileCheckpoint.dump unavailable: " + e.getMessage());
        }
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    private static String sha256Prefix(Path path, int len) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] hash = md.digest(Files.readAllBytes(path));
            StringBuilder sb = new StringBuilder();
            for (byte b : hash) sb.append(String.format("%02x", b));
            return sb.substring(0, Math.min(len, sb.length()));
        } catch (Exception e) {
            return "nohash";
        }
    }

    private static JedisPool buildPool() {
        JedisPoolConfig cfg = new JedisPoolConfig();
        cfg.setMaxTotal(4);
        return new JedisPool(cfg, REDIS_HOST, REDIS_PORT, 3000);
    }

    private static String fmt(String template, Object... args) {
        return String.format(template, args);
    }

    private static String env(String key, String fallback) {
        String v = System.getenv(key);
        return (v != null && !v.isEmpty()) ? v : fallback;
    }
}
