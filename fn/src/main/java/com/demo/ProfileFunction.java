package com.demo;

import com.sun.net.httpserver.HttpServer;
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.JedisPoolConfig;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

public class ProfileFunction {

    private static final String POD_UID     = env("POD_UID",     "unknown");
    private static final String REDIS_HOST  = env("REDIS_HOST",  "redis.openfaas.svc.cluster.local");
    private static final int    REDIS_PORT  = Integer.parseInt(env("REDIS_PORT", "6379"));
    private static final String FN_NAME     = env("FN_NAME",     "profile-fn");
    private static final String FN_VERSION  = env("FN_VERSION",  "v1");
    private static final String IN_PROFILE  = "/profiles/in.profile";

    public static void main(String[] args) throws Exception {
        long startMs = System.currentTimeMillis();

        // Read the artifact the wrapper placed on disk before us
        String artifactContent = readProfile();
        String artifactHash    = sha256Prefix(artifactContent, 12);

        System.out.printf("JAVA_STARTED pod=%s artifact_hash=%s t=%d%n",
                POD_UID, artifactHash, startMs);

        JedisPool pool = buildPool();

        // Write started key and increment run sequence
        String runseq;
        try (Jedis j = pool.getResource()) {
            runseq = String.valueOf(j.incr("runseq:" + FN_NAME + ":" + FN_VERSION));
            j.set("started:" + POD_UID,
                  fmt("{\"pod\":\"%s\",\"started_ms\":%d,\"artifact_hash\":\"%s\",\"runseq\":%s}",
                      POD_UID, startMs, artifactHash, runseq));
        }

        // Log SIGTERM so it's visible in pod logs (actual push is in entrypoint.sh)
        Runtime.getRuntime().addShutdownHook(new Thread(() ->
            System.out.printf("JAVA_SIGTERM pod=%s t=%d%n", POD_UID, System.currentTimeMillis())
        ));

        // HTTP handler — returns everything needed to verify ordering
        final String artifactJson = artifactContent;
        final String seq          = runseq;
        final long   start        = startMs;
        final String hash         = artifactHash;

        HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);
        server.createContext("/", exchange -> {
            String body = fmt(
                "{\"pod\":\"%s\",\"start_ms\":%d,\"artifact_hash\":\"%s\"," +
                "\"runseq\":%s,\"artifact\":%s}",
                POD_UID, start, hash, seq, artifactJson);
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

    // ── helpers ───────────────────────────────────────────────────────────────

    private static String readProfile() {
        try {
            return new String(Files.readAllBytes(Paths.get(IN_PROFILE)),
                              StandardCharsets.UTF_8).trim();
        } catch (IOException e) {
            System.err.println("WARN: could not read " + IN_PROFILE + ": " + e.getMessage());
            return "{}";
        }
    }

    private static JedisPool buildPool() {
        JedisPoolConfig cfg = new JedisPoolConfig();
        cfg.setMaxTotal(4);
        return new JedisPool(cfg, REDIS_HOST, REDIS_PORT, 3000);
    }

    private static String sha256Prefix(String input, int len) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] hash = md.digest(input.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : hash) sb.append(String.format("%02x", b));
            return sb.substring(0, Math.min(len, sb.length()));
        } catch (NoSuchAlgorithmException e) {
            return "nohash";
        }
    }

    private static String fmt(String template, Object... args) {
        return String.format(template, args);
    }

    private static String env(String key, String fallback) {
        String v = System.getenv(key);
        return (v != null && !v.isEmpty()) ? v : fallback;
    }
}
