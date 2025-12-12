# ---------------------------------------
# STAGE 1 — Build Go binary
# ---------------------------------------
FROM --platform=linux/arm64 golang:1.24-bullseye AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

# Copy backend source
COPY . .

# Build static binary
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o backend ./cmd

# ---------------------------------------
# STAGE 2 — Final runtime image
# ---------------------------------------
FROM debian:bullseye-slim

WORKDIR /app

# Install all required packages:
# ffmpeg      -> streaming, recording, trimming
# v4l-utils   -> v4l2-ctl for camera controls
# ca-certificates -> TLS validation
# coreutils   -> chown, etc.
RUN apt-get update && apt-get install -y \
    ffmpeg \
    v4l-utils \
    ca-certificates \
    coreutils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy backend binary
COPY --from=builder /app/backend .

# Make captures directory ahead of time (in case)
RUN mkdir -p /app/captures

CMD ["./backend"]
