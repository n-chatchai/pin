# --- Build Stage ---
FROM rust:1.79-slim-bookworm AS builder

# Install system dependencies (build-essential, python3, pkg-config, libssl-dev)
RUN apt-get update && apt-get install -y \
    build-essential \
    pkg-config \
    libssl-dev \
    python3-dev \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy Cargo configs
COPY Cargo.toml Cargo.lock ./

# Create dummy source to cache dependencies
RUN mkdir src && echo "fn main() {}" > src/main.rs
RUN cargo build --release

# Copy real sources
COPY src ./src
COPY templates ./templates

# Force rebuild with real sources
RUN touch src/main.rs
RUN cargo build --release

# --- Runtime Stage ---
FROM debian:bookworm-slim

# Install runtime dependencies (OpenSSL, Python 3, pip, and utilities)
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install Microsoft markitdown library (using --break-system-packages for system-wide ease in containers)
RUN pip3 install --no-cache-dir --break-system-packages markitdown

WORKDIR /app

# Copy binary and templates from build stage
COPY --from=builder /app/target/release/pin-backend /app/pin-backend
COPY --from=builder /app/templates /app/templates

EXPOSE 8088

# Command to run the application
CMD ["/app/pin-backend"]
