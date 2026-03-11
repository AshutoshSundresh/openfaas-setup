# ── Stage 1: build fat jar ────────────────────────────────────────────────────
# Use Temurin 24 so source/target 21 compiles cleanly (JDK25 runs >=21 bytecode)
FROM maven:3.9-eclipse-temurin-24 AS builder

WORKDIR /build
COPY pom.xml .
# Pre-fetch deps in a cacheable layer
RUN mvn dependency:go-offline -q
COPY src ./src
RUN mvn package -q -DskipTests

# ── Stage 2: minimal runtime ──────────────────────────────────────────────────
# jdk25-custom is Ubuntu 24.04 (glibc) with custom JDK25 profile-checkpoint build
# Do NOT use Alpine (musl incompatible with glibc JDK)
FROM asundresh/jdk25-custom

# redis-cli for wrapper pull/push; jq for JSON manipulation in entrypoint.sh
RUN apt-get update && apt-get install -y --no-install-recommends \
        redis-tools \
        jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /build/target/function.jar .
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Profile dir for MDOX checkpoint files
RUN mkdir -p /profiles

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
