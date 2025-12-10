# CAMERA SETUP CONTAINERIZATION

## Authors

| Verions | Author | Date | Time |
|---------|--------|------|------|
| 1.0     | Hamshica Mohanathas | 2025/11/27 | 10.45 AM |

-----
-----

## Introduction

### Containerization

This project uses containerization to package all components of the camera-control system—including the Go backend, MQTT/MQTTs broker, and MediaMTX RTSP server into isolated and reproducible environments. By using Podman, each service runs inside its own container with its own dependencies, configurations, and runtime environment. This eliminates system-level conflicts, simplifies installation, and ensures that the entire application behaves consistently across development, testing, and production. Also, the Flutter frontend will run outside the container by connecting to the containers using ports mapping.

Containerization enables:

- Portability – the full system can run on any machine that supports Podman without additional setup.
- Isolation – backend, streaming engine, and frontend run independently, improving stability.
- Security – TLS certificates for MQTTs and mutual TLS (mTLS) are mounted securely into the containers.
- Ease of Deployment – each service can be built, updated, and restarted separately without affecting the rest of the system.
- Scalability & Maintainability – services are grouped logically and can be orchestrated or extended in future versions.

With this approach, the system becomes easier to manage, upgrade, and distribute, while maintaining predictable behavior across all environments. This foundation also prepares the project for future enhancements such as CI/CD pipelines, container orchestration, and automated certificate rotation.

-----
-----

## Features

- Secure camera control system with MQTTs (TLS) and optional Mutual TLS (mTLS)
- Go backend service for camera control, RTSP stream management, and MQTT communication
- Flutter-based frontend for cross-platform UI (Web, Desktop, Mobile)
- MediaMTX for RTSP streaming, transcoding, and multi-protocol video delivery
- Podman-based containerization for backend, frontend, MQTT broker, and MediaMTX
- Automated certificate generation workflow for TLS/mTLS security
- Modular architecture where each service runs independently
- Single-command deployment capability using Podman scripts or Podman Compose

-----
-----

## System Architecture

The system follows a modular microservice-style architecture:

1. **Flutter Frontend**
   - Provides a user interface to display the camera feed and send control commands.
   - Uses MQTTs (TLS) to securely communicate with the backend.

2. **Go Backend**
   - Handles MQTT messages, camera control, and system logic.
   - Interfaces with the MediaMTX RTSP server and local camera hardware.
   - Uses mutual TLS (mTLS) to authenticate with the MQTT broker.

3. **MQTT/MQTTs Broker**
   - Manages publish–subscribe communication between devices.
   - TLS-enabled for encrypted communication.
   - Acts as the core messaging backbone.

4. **MediaMTX Server**
   - Provides RTSP streaming for camera video.
   - Streams can be consumed by the Flutter frontend or other services.

5. **Podman Containers**
   - Each service runs in an isolated container.
   - Certificates and configuration files are mounted securely.
   - Services communicate over a private Podman network.

```pgsql
                     ┌──────────────────────────────────────┐
                     │          Host / Flutter App          │
                     │                                      │
                     │   MQTTs → 127.0.0.1:8883             │
                     │   RTSP  → rtsp://127.0.0.1:8554/live │
                     └──────────────────────────────────────┘
                                      ▲
                                      │ (Pod-level port mapping)
                                      ▼
                 ┌───────────────────────────────────────────────────┐
                 │               Podman Pod                          │
                 │        (Shared network + localhost)               │
                 │                                                   │
                 │   All containers share:                           │
                 │     - One IP                                      │
                 │     - One network namespace                       │
                 │     - localhost between containers                │
                 │     - Ports mapped only once at pod level         │
                 │                                                   │
                 │   ┌────────────────┐       ┌──────────────────┐   │
                 │   │  Mosquitto     │◄─────►│     Backend      │   │
                 │   │  (mosquitto)   │       │  (camera-backend)│   │
                 │   └────────────────┘       └──────────────────┘   │
                 │          ▲                        │               │
                 │          │                        ▼               │
                 │   MQTT + MQTTs         Camera control, capture,   │
                 │                        and RTSP publishing        │
                 │                                                   │
                 │               ┌─────────────────────────────┐     │
                 │               │          MediaMTX           │     │
                 │               │     (camera-mediamtx)       │     │
                 │               └─────────────────────────────┘     │
                 │                  Provides RTSP stream             │
                 └───────────────────────────────────────────────────┘
```

-----
-----

## Prerequisites

Before running this project, ensure that the following are installed:

- Go 1.21 or newer
- Flutter SDK (stable channel)
- Podman 5.x or newer
- OpenSSL (for certificate generation)
- MediaMTX (or containerized MediaMTX image)
- Mosquitto / EMQX / HiveMQ (for MQTTs broker, or use containerized version)
- Git for version control

You may also need system access to camera hardware (v4l2 for Linux systems).

-----
-----

## MQTTs Setup

1. Generate TLS certificates

   Following the PKI structure, we will create 4 certificates here.
   - Root CA:  The main Certificate Authority for the PKI Structure.
   - Intermediate CA: The Signing Certificate Authority for the certiicates.
   - Server Certificate: The certificate signed by the Intermediate CA for the MQTT.
   - Client Certificate: The certificate signed by the Intermediate CA for the frontend (flutter) and the backend (Go).

   The configuration for each certificate is under the config folder. You can refer to any PKI structure building tutorials to create a certificate management. These certificates are produced here to build a Mutual TLS setup with MQTTs.

2. Configure the backend for TLS.

   The old main.go didn't have any TLS configuration. Therefore, we need to add TLS configuration to make MQTTs work:

   ```go
   /*
      Old main.go file
   */
   package main

   import (
      "context" // 🛑 REQUIRED IMPORT
      "fmt"
      "log"
      "os"
      "os/exec"
      "path/filepath"
      "strconv"
      "strings"
      "time"

      //"regexp" // Kept for listV4L2Devices, although it's not used in this final version

      mqtt "github.com/eclipse/paho.mqtt.golang"
      )

   const (
      Broker        = "tcp://127.0.0.1:1883"
      ClientID      = "GoCamController"
      SettingsTopic = "camera/control/settings"
      ActionTopic   = "camera/control/action"
      StatusTopic   = "camera/status"
      CapturesDir   = "./captures"
   )

   // 🛑 HARDCODED FOR RELIABILITY
   // var sps, pps []byte
   // var cameraReady bool = false
   var activeDevice = "/dev/video0"
   var recordCmd *exec.Cmd
   var isRecording bool = false
   var recordCancel context.CancelFunc

   func main() {
      log.SetFlags(log.Ldate | log.Ltime)

      os.MkdirAll(CapturesDir, 0755)

      // AGGRESSIVE RESET: Kill any external lock immediately on startup
      resetCamera(activeDevice)
      time.Sleep(500 * time.Millisecond)

      opts := mqtt.NewClientOptions().AddBroker(Broker).SetClientID(ClientID)
      opts.OnConnect = func(client mqtt.Client) {
         log.Println("Connected to MQTT Broker. Subscribing...")
         if token := client.Subscribe(SettingsTopic, 0, settingsHandler); token.Wait() && token.Error() != nil {
            log.Fatalf("Settings subscribe failed: %v", token.Error())
         }
         if token := client.Subscribe(ActionTopic, 0, actionHandler); token.Wait() && token.Error() != nil {
            log.Fatalf("Action subscribe failed: %v", token.Error())
         }
         log.Println("Subscriptions successful. Ready.")
      }

      opts.OnConnectionLost = func(client mqtt.Client, err error) {
         log.Printf("Connection lost: %v", err)
      }

      client := mqtt.NewClient(opts)
      if token := client.Connect(); token.Wait() && token.Error() != nil {
         log.Fatalf("MQTT connection failed: %v", token.Error())
      }

      time.Sleep(500 * time.Millisecond)
      go startMediaMTXStream(activeDevice)
      //go monitorCameraWarmup(client, "rtsp://127.0.0.1:8554/webcam")

      select {} // keep running
   }

   // --- HANDLERS (omitted for space, assume working) ---

   var settingsHandler mqtt.MessageHandler = func(client mqtt.Client, msg mqtt.Message) {
      payload := string(msg.Payload())
      parts := strings.Fields(payload)
      if len(parts) != 2 {
         client.Publish(StatusTopic, 0, false, "ERROR: Invalid setting format. Expected <control> <value>")
         return
      }
      setControl(parts[0], parts[1], client)
   }

   var actionHandler mqtt.MessageHandler = func(client mqtt.Client, msg mqtt.Message) {
      payload := strings.TrimSpace(string(msg.Payload()))
      if payload == "" {
         return
      }

      parts := strings.Fields(payload)
      action := parts[0]

      switch action {
      case "picture":
         captureImage(client)
      case "record":
         var duration string
         if len(parts) > 1 {
            duration = parts[1]
         }
         startRecording(client, duration)
      case "stop":
         stopRecording(client)
      default:
         client.Publish(StatusTopic, 0, false, "ERROR: Unknown action: "+payload)
      }
   }

   // --- Force Camera Release ---
   func resetCamera(device string) {
      log.Printf("INFO: Attempting to reset/unclog camera %s...", device)
      // Use a 2-second timeout context for safety
      ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
      defer cancel()
      cmd := exec.CommandContext(ctx, "v4l2-ctl", "-d", device, "--get-fmt-video")
      cmd.Run()
      log.Println("INFO: Camera reset attempt complete.")
   }

   // --- FINALIZED setControl FUNCTION (omitted for space, assume working) ---
   func setControl(control, value string, client mqtt.Client) {
      controlAssignment := fmt.Sprintf("%s=%s", control, value)
      cmd := exec.Command("v4l2-ctl", "-d", activeDevice, "-c", controlAssignment)
      out, err := cmd.CombinedOutput()
      if err != nil {
         var friendlyMessage string
         switch control {
         case "focus_automatic_continuous":
            friendlyMessage = fmt.Sprintf("ERROR: Auto Focus toggle failed. Output: %s", out)
         case "white_balance_automatic":
            friendlyMessage = fmt.Sprintf("ERROR: Auto WB toggle failed. Output: %s", out)
         case "focus_absolute":
            friendlyMessage = "ERROR: Focus adjustment blocked. Please click 'Manual Focus' first."
         case "white_balance_temperature":
            friendlyMessage = "ERROR: White Balance adjustment blocked. Please click 'Manual WB (Disable Auto)' first."
         case "pan_absolute":
            friendlyMessage = "ERROR: Pan adjustment blocked. The feature may be unsupported or require manual focus/zoom to be disabled."
         default:
            friendlyMessage = fmt.Sprintf("ERROR: Setting %s failed. Output: %s", control, out)
         }
         client.Publish(StatusTopic, 0, false, friendlyMessage)
      } else {
         var successMessage string
         switch control {
         case "focus_automatic_continuous":
            if value == "1" {
               successMessage = "SUCCESS: Auto Focus ENABLED. Manual slider is now ignored."
            } else {
               successMessage = "SUCCESS: Manual Focus ENABLED. Use the slider to adjust focus."
            }
         case "white_balance_automatic":
            if value == "1" {
               successMessage = "SUCCESS: Auto White Balance ENABLED. Manual slider is now ignored."
            } else {
               successMessage = "SUCCESS: Manual WB ENABLED. Use the slider to adjust temperature."
            }
         default:
            successMessage = fmt.Sprintf("SUCCESS: %s set to %s", control, value)
         }
         client.Publish(StatusTopic, 0, false, successMessage)
      }
   }

   // --- CAPTURE/RECORD FUNCTIONS (Assume working with RTSP input fix) ---
   func captureImage(client mqtt.Client) {
      timestamp := time.Now().Format("20060102_150405")
      filename := filepath.Join(CapturesDir, fmt.Sprintf("picture_%s.jpg", timestamp))
      rtspUrl := "rtsp://127.0.0.1:8554/webcam"
      cmd := exec.Command("ffmpeg", "-i", rtspUrl, "-frames:v", "1", "-f", "image2", filename, "-loglevel", "error", "-y")
      detectStartOffset(rtspUrl)
      client.Publish(StatusTopic, 0, false, "Image capturing started now!")
      if out, err := cmd.CombinedOutput(); err != nil {
         client.Publish(StatusTopic, 0, false, fmt.Sprintf("ERROR: Capture failed: %s", out))
      } else {
         wd, _ := os.Getwd()
         absolutePath := filepath.Join(wd, filename)
         chownFileToUser(absolutePath)
         client.Publish(StatusTopic, 0, false, fmt.Sprintf("SUCCESS: Image saved to %s", absolutePath))
      }
   }

   func startRecording(client mqtt.Client, duration string) {
      if isRecording {
         client.Publish(StatusTopic, 0, false, "Recording already in progress")
         return
      }

      // Proceed with ffmpeg recording as before
      timestamp := time.Now().Format("20060102_150405")
      filename := filepath.Join(CapturesDir, fmt.Sprintf("video_%s.mp4", timestamp))
      rtspUrl := "rtsp://127.0.0.1:8554/webcam"

      args := []string{
         "-rtsp_transport", "tcp",

         //"-ss", fmt.Sprintf("%.3f", firstNonBlack), // skip initial black frames

         "-t", duration,
         "-i", rtspUrl,

         "-vcodec", "libx264",
         //"-preset", "ultrafast",
         //"-tune", "zerolatency",
         "-pix_fmt", "yuv420p",
         filename,
         "-y",
      }

      recordCmd = exec.Command("ffmpeg", args...)
      if err := recordCmd.Start(); err != nil {
         client.Publish(StatusTopic, 0, false, fmt.Sprintf("ERROR: Failed to start recording: %v", err))
         return
      }

      isRecording = true

      // Wait for first non-black frame
      startOffset := detectStartOffset(rtspUrl)
      log.Println(startOffset)
      //detectStartOffset(rtspUrl)
      client.Publish(StatusTopic, 0, false, "The Recording Starts Now!")
      go func() {
         recordCmd.Wait()
         isRecording = false
         client.Publish(StatusTopic, 0, false, "The Recording Stops Now!")
         wd, _ := os.Getwd()
         absolutePath := filepath.Join(wd, filename)
         chownFileToUser(absolutePath)
         if err := trimVideo(absolutePath, startOffset); err != nil {
            log.Printf("ERROR trimming video: %v", err)
            client.Publish(StatusTopic, 0, false, fmt.Sprintf("ERROR trimming video: %v", err))
         } else {
            client.Publish(StatusTopic, 0, false, fmt.Sprintf("Trimmed video saved: %s", absolutePath))
         }
         client.Publish(StatusTopic, 0, false, fmt.Sprintf("Recording stopped: %s", absolutePath))
      }()
   }

   func getFirstNonBlack(output string) float64 {
      var lastBlackEnd float64 = 0
      lines := strings.Split(output, "\n")
      for _, line := range lines {
         if strings.Contains(line, "black_end:") {
            parts := strings.Split(line, "black_end:")
            if len(parts) > 1 {
               endPart := strings.Fields(parts[1])[0]
               t, err := strconv.ParseFloat(endPart, 64)
               if err == nil {
                  lastBlackEnd = t
               }
            }
         }
      }
      return lastBlackEnd
   }

   // Returns the timestamp in seconds where the first non-black frame appears
   func detectStartOffset(rtspURL string) float64 {
      for {
         cmd := exec.Command("ffmpeg",
            "-rtsp_transport", "tcp",
            "-i", rtspURL,
            "-vframes", "1",
            "-vf", "blackdetect=d=0.1:pix_th=0.01",
            "-an",
            "-f", "null",
            "-",
         )
         outBytes, _ := cmd.CombinedOutput()
         out := string(outBytes)

         // If ffmpeg reports no black_start → first non-black frame found
         if !strings.Contains(out, "black_start") {
            // Optionally, parse for "pts_time" if you want exact timestamp
            return 0.0 // simple case: just 0 seconds offset
         } else {
            // Parse last black_end to get exact black duration
            lines := strings.Split(out, "\n")
            for _, line := range lines {
               if strings.Contains(line, "black_end:") {
                  parts := strings.Split(line, "black_end:")
                  if len(parts) > 1 {
                     endPart := strings.Fields(parts[1])[0]
                     t, err := strconv.ParseFloat(endPart, 64)
                     if err == nil {
                        return t
                     }
                  }
               }
            }
         }

         time.Sleep(200 * time.Millisecond) // avoid busy loop
      }
   }

   func stopRecording(client mqtt.Client) {
      if !isRecording || recordCmd == nil || recordCmd.Process == nil {
         client.Publish(StatusTopic, 0, false, "No recording in progress")
         return
      }
      if err := recordCmd.Process.Signal(os.Interrupt); err != nil {
         client.Publish(StatusTopic, 0, false, fmt.Sprintf("ERROR stopping recording: %v", err))
      } else {
         client.Publish(StatusTopic, 0, false, "Recording stopping...")
      }
   }

   func trimVideo(filePath string, startOffset float64) error {
      // Temporary file for trimming
      dir := filepath.Dir(filePath)
      tempFile := filepath.Join(dir, "temp_trimmed.mp4")

      // Build ffmpeg command
      cmd := exec.Command("ffmpeg", "-i", filePath, "-ss", fmt.Sprintf("%.3f", startOffset-1), "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", tempFile, "-y")

      out, err := cmd.CombinedOutput()
      if err != nil {
         return fmt.Errorf("ffmpeg trim error: %s, %v", string(out), err)
      }

      // Overwrite original file
      if err := os.Rename(tempFile, filePath); err != nil {
         return fmt.Errorf("failed to overwrite original file: %v", err)
      }

      return nil
   }

   func chownFileToUser(filePath string) {
      targetUser := os.Getenv("SUDO_USER")
      if targetUser == "" {
         targetUser = os.Getenv("USER")
      }
      if targetUser == "" {
         log.Printf("CRITICAL WARNING: Cannot determine target user for file %s. Ownership remains root.", filePath)
         return
      }
      cmd := exec.Command("chown", targetUser+":"+targetUser, filePath)
      if _, err := cmd.CombinedOutput(); err != nil {
         log.Printf("WARNING: Failed to change ownership of %s to %s: %v", filePath, targetUser, err)
      } else {
         log.Printf("SUCCESS: Changed ownership of %s to %s.", filePath, targetUser)
      }
   }

   func startMediaMTXStream(device string) {
      rtspUrl := "rtsp://localhost:8554/webcam"

      cmd := exec.Command("ffmpeg",
         "-f", "v4l2",
         "-input_format", "mjpeg",
         "-framerate", "15",
         "-video_size", "1280x720",
         "-i", device,
         "-vcodec", "libx264",
         "-preset", "ultrafast",
         "-pix_fmt", "yuv420p",

         "-f", "rtsp",
         rtspUrl,
         "-loglevel", "info",
         "-nostdin",
         "-g", "15", // keyframe every 1 second at 15 FPS
         "-keyint_min", "15",
         "-force_key_frames", "expr:gte(t,n_forced*1)",
      )

      log.Println("Starting live stream to MediaMTX...")

      if err := cmd.Start(); err != nil {
         log.Fatalf("Failed to start FFmpeg stream: %v", err)
      }

      go func() {
         err := cmd.Wait()
         if err != nil {
            log.Printf("CRITICAL: FFmpeg stream exited with error: %v", err)
         } else {
            log.Println("FFmpeg stream exited normally.")
         }
      }()
   }
   ```

   The changes that are needed to be done:

   ```go
   //Adding import
   import (
      "crypto/tls"
      "crypto/x509"
      "io/ioutil"
   )

   //Add a new function (We have to make sure that all the necessary certificates are kept correctly inside the folders):
   func createTLSConfig() *tls.Config {
      // Load server certificate & key
      cert, err := tls.LoadX509KeyPair(
         "/home/jetson/Documents/Hamshica/camera-container/backend/certs/crt/client_chain.crt",
         "/home/jetson/Documents/Hamshica/camera-container/backend/certs/private/client_decrypted.key",
      )
      if err != nil {
         log.Fatalf("Failed to load server certificate: %v", err)
      }

      // Load CA certs to verify connecting clients
      caCert, err := ioutil.ReadFile("/home/jetson/Documents/Hamshica/camera-container/certs/ca_chain.crt")
      if err != nil {
         log.Fatalf("Failed to read CA cert: %v", err)
      }

      caCertPool := x509.NewCertPool()
      if !caCertPool.AppendCertsFromPEM(caCert) {
         log.Fatalf("Failed to append CA certs")
      }

      tlsConfig := &tls.Config{
         Certificates:       []tls.Certificate{cert},
         RootCAs:            caCertPool,
         ServerName:         "127.0.0.1", // MUST match server cert CN or SAN - without proper SAN name the connection will not be authorised
         MinVersion:         tls.VersionTLS12,
         InsecureSkipVerify: false,
      }

      return tlsConfig
   }

   //Change the const:
   Broker        = "tls://127.0.0.1:8883" // TLS port for MQTT

   //Change the main function:
   opts := mqtt.NewClientOptions().AddBroker(Broker).SetClientID(ClientID).SetTLSConfig(createTLSConfig())
   ```

3. Frontend TLS Configuration

   After setting up the backend for TLS configuration for Mutual TLS, we have to setup the flutter frontend.

   We have to check the `pubsec.yaml` file and make sure that the certificates and keys mentioned under the `flutter -> asset` section are available correctly in the position.
   Also check the file whether the MQTT is added as a dependency.

   ```yaml
   dependencies:
      flutter:
         sdk: flutter
      mqtt_client: ^9.0.6   # MQTT client for Dart/Flutter
      flutter_vlc_player: ^7.4.4
      video_player: ^2.5.0
   
   flutter:
      assets:
         - assets/certs/crt/client_chain.crt
         - assets/certs/crt/ca_chain.crt
         - assets/certs/crt/client.crt
         - assets/certs/private/client_decrypted.key
   ```

   After that, check whether the certificates are called correctly in the `mqtt_service.dart` file.

   **Note:** We use client_decrypted.key in both because both Go and Flutter can't read encrypted keys. Therefore, we are decrypting them. We can also stop encryption while creating the certificate.

4. mosquitto.conf file

   We will create a new mosquitto.conf file in our folder so it won't collapse with the original mosquitto server and using that configuration we can start our MQTT. This MQTT won't collapse with the MQTT service in the PC.

   ```ini
   # TLS listener
   protocol mqtt
   listener 8883
   cafile /home/jetson/Documents/Hamshica/camera-container/certs/ca_chain.crt
   certfile /home/jetson/Documents/Hamshica/camera-container/certs/server/crt/server_chain.crt
   keyfile /home/jetson/Documents/Hamshica/camera-container/certs/server/private/server.key

   # Require client certificate for authentication
   require_certificate true
   use_identity_as_username true   #  (Use when the CN or SAN name needs to be matched)

   tls_version tlsv1.2

   # Optional logging
   log_type all
   ```

-----
-----

## Running the Project

You can run the project manually.

1. Start MQTTs broker by the command:

   ```bash
   mosquitto -c mosquitto.conf -v
   ```

2. Start MediaMTX server: We can start this as a service

3. Start Go backend container by the below command:

   ```bash
   go run ./backend/cmd/main.go
   ```

4. Start Flutter frontend container

   ```bash
   flutter run -d linux
   ```

-----
-----

## Podman Setup Using Pod Port Mapping (Method I)

### Starting with Podman

1. Install Podman:

   ```bash
   sudo apt update
   sudo apt install podman -y
   podman --version
   ```

2. Creating four containers for 4 services: Frontend, Backend, Mosquitto, MediaMTX. For that, we need to create a Podman pod which will let containers share the same network and localhost-like access.

   ```bash
   podman pod create --name camera-pod -p 8883:8883 -p 1883:1883 -p 8554:8554
   ```

   - `-p` maps host ports → pod ports.
   - `8883` → MQTT TLS
   - `1883` → MQTT non-TLS (optional)
   - `8554` → RTSP (MediaMTX)
   - Add `1935` if you plan to use RTMP.

3. Create Backend dockerfile (Podman uses dockerfiles)

   ```Dockerfile
   # ---------------------------------------
   # STAGE 1 — Build Go binary
   # ---------------------------------------
   FROM docker.io/library/golang:1.24-bullseye AS builder

   WORKDIR /app

   COPY go.mod go.sum ./
   RUN go mod download

   # Copy backend source
   COPY . .

   # Build static binary
   RUN go build -o backend ./cmd/main.go


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

   # Copy certs folder
   COPY certs ./certs

   # Make captures directory ahead of time (in case)
   RUN mkdir -p /app/captures

   CMD ["./backend"]
   ```

4. Create a folder for mosquitto

   ```bash
   mkdir mosquitto
   cp mosquitto.conf ./mosquitto/
   ```

   Then, create the Dockerfile:

   ```Dockerfile
   # mosquitto/Dockerfile
   FROM docker.io/eclipse-mosquitto:2.0

   # Your custom config goes into a separate directory
   COPY tls-mosquitto.conf /mosquitto/config/tls-mosquitto.conf
   COPY certs/ /mosquitto/config/certs/
   ```

5. Create MediaMTX Dockerfile

   ```bash
   mkdir mediamtx
   cp mediamtx.yml ./mediamtx/
   ```

   ```Dockerfile
   # mediamtx/Dockerfile
   FROM docker.io/bluenviron/mediamtx:latest

   COPY mediamtx.yml .
   ```

6. Build the images with Podman

   ```bash
   # Run from the root-container
   podman build -t camera-backend -f backend/Dockerfile backend/
   podman build -t camera-mosquitto ./mosquitto
   podman build -t camera-mediamtx ./mediamtx
   ```

7. To check whether an image is built

   ```bash
   podman images
   ```

   To delete an image:

   ```bash
   podman rmi <image ID or the repository>
   ```

8. Run the containers

   ```bash
   podman run -d --pod camera-pod --name camera-mosquitto -v ./mosquitto/tls-mosquitto.conf:/mosquitto/config/mosquitto.conf:ro camera-mosquitto
   podman run -d --pod camera-pod --device /dev/video0 --device /dev/video1 --name mediamtx camera-mediamtx
   podman run -d --pod camera-pod --device /dev/video0 --device /dev/video1 --name backend camera-backend
   ```

   The explanation for the commands:
   - `podman run`:- Run a new container
   - `-d`: Run in detached mode (run in the background)
   - `--pod camera-pod`: Attach this container to an existing pod named `camera-pod`. All containers inside a pod share:
      - network namespace
      - localhost
      - ports exposed by the pod
      - So the Flutter UI, Mosquitto, MediaMTX, etc. can all talk to each other using `localhost`
   - `--device /dev/video0 --device /dev/video1`: Give the container access to GPU hardware acceleration (Direct Rendering Infrastructure).
   - `--name flutter-frontend`: Assign a container name `flutter-frontend`

   To view all the containers (running and exited):

   ```bash
   podman ps -a
   ```

   To remove a container:

   ```bash
   podman rm <Container-ID or container-name>
   ```

   To start an exited container:

   ```bash
   podman start <container-ID or container-name>
   ```

   If you want to start fresh:

   ```bash
   podman restart <container-id or container-name>
   ```

   If the containers are connected to (inside) the pod:

   ```bash
   podman pod start camera-pod      # This will automatically start all the containers
   ```

   To stop a container:

   ```bash
   podman stop <Container-ID or Container-Name>
   ```

   To stop all the containers running:

   ```bash
   podman stop -a
   ```

### Podman Check

1. To check the backend container connection, we have to start all the containers at first. And then in a terminal, we can run:

   ```bash
   mosquitto_sub -h 127.0.0.1 -p 8883 --cafile certs/ca_chain.crt --cert backend/certs/crt/client_chain.crt --key backend/certs/private/client_decrypted.key -t camera/status -v
   ```

   Then, in another terminal, we can run:

   ```bash
   mosquitto_pub -h 127.0.0.1 -p 8883 --cafile certs/ca_chain.crt --cert backend/certs/crt/client_chain.crt --key backend/certs/private/client_decrypted.key -t camera/control/action -m "record 10"
   ```

   Similarly, any commands we know.

   The captured image or recorded video is saved inside the container in the location:

   ```bash
   /app/captures
   ```

   We can check whether the video exists:

   ```bash
   podman exec -it backend ls /app/captures
   ```

   We can also copy this into our host machine:

   ```bash
   podman cp backend:/app/captures/. ./captures
   ```

-----
-----

## Podman Network SetUp (Method II)

### SetUp Guide

#### Create a Private Podman Network

Create an isolated network for internal container communication:

```bash
podman network create camera-net
```

#### Run Mosquitto (MQTT Broker)

Start the Mosquitto broker with MQTT and MQTTs ports exposed:

```bash
podman run -d --name camera-mosquitto --network camera-net -p 1883:1883 -p 8883:8883 -v $(pwd)/mosquitto/tls-mosquitto.conf:/mosquitto/config/mosquitto.conf -v $(pwd)/mosquitto/certs:/mosquitto/certs camera-mosquitto:latest
```

**Notes:**

- `--network camera-net` keeps it inside the private network
- `-p 1883:1883` and `-p 8883:8883` expose MQTT and MQTTs to the Flutter app or host OS
- Volumes mount configuration and certificates

#### Run MediaMTX (RTSP Server)

Start the MediaMTX streaming server:

```bash
podman run -d --name camera-mediamtx --network camera-net -p 8554:8554 -v $(pwd)/mediamtx/mediamtx.yml:/mediamtx.yml camera-mediamtx:latest
```

**Notes:**

- RTSP port `8554` is exposed to the host so the Flutter frontend can connect
- Inside the network, backend will reach it using `rtsp://camera-mediamtx:8554/live`

#### Run Backend (Camera Controller)

Start the backend service with access to the camera device:

```bash
podman run -d --name backend --network camera-net --device /dev/video0:/dev/video0 -v $(pwd)/backend/certs:/app/certs -v $(pwd)/captures:/app/captures camera-backend:latest
```

**Notes:**

- No ports exposed from backend—only internal MQTT messaging
- `--device /dev/video0:/dev/video0` provides access to the camera
- Backend publishes RTSP URL using hostname `camera-mediamtx`

### Internal Communication

Inside the `camera-net` network, all services reach each other by hostname:

| Service   | Container Name      | Internal Hostname    |
|-----------|---------------------|---------------------|
| Mosquitto | camera-mosquitto    | camera-mosquitto    |
| Backend   | backend             | backend             |
| MediaMTX  | camera-mediamtx     | camera-mediamtx     |

**Example internal URLs:**

- MQTT broker: `mqtts://camera-mosquitto:8883`
- RTSP stream: `rtsp://camera-mediamtx:8554/live`

No IP addresses needed for internal communication.

### Flutter Frontend Configuration

The Flutter app is **not** inside the container network. It connects using the host machine's exposed ports:

| Service | Host Address              | Purpose                |
|---------|---------------------------|------------------------|
| MQTTs   | 127.0.0.1:8883            | Control messages       |
| RTSP    | rtsp://127.0.0.1:8554/live | Live video streaming   |

**Flutter app configuration example:**

```dart
final mqttHost = "127.0.0.1";
final mqttPort = 8883;

final rtspUrl = "rtsp://127.0.0.1:8554/live";
```

This configuration works whether the Flutter app runs on:

- Your development machine (Android Studio/VS Code)
- A real Android/iOS device
- A web browser (for web builds)

### Architecture Overview

```pgsql
       ┌──────────────────────────────────────┐
       │           Host / Flutter App         │
       │                                      │
       │  MQTTs → 127.0.0.1:8883              │
       │  RTSP  → rtsp://127.0.0.1:8554/live  │
       └──────────────────────────────────────┘
                          ▲
                          │ (Port mapping)
                          ▼
┌───────────────────────────────────────────────────────────┐
│          Private Podman Network: camera-net               │
│                                                           │
│   ┌────────────────┐     ┌──────────────────┐             │
│   │ Mosquitto      │◄───►│ Backend          │             │
│   │ (camera-mos...)│     │ (backend)        │             │
│   └────────────────┘     └──────────────────┘             │
│            ▲                     ▲                        │
│            │                     │                        │
│     MQTT + MQTTs         Sets Camera + Publishes RTSP     │
│                                                           │
│                     ┌──────────────────────┐              │
│                     │ MediaMTX             │              │
│                     │ (camera-mediamtx)    │              │
│                     └──────────────────────┘              │
│                         Provides RTSP stream              │
└───────────────────────────────────────────────────────────┘
```

### Network Verification

#### Inspect the network

```bash
podman network inspect camera-net
```

#### List connected containers

```bash
podman ps --filter network=camera-net
```

-----
-----

## Difference between Pod and Network

### Pod

- Shared Network + Port Mapping
- All containers share the same network namespace
  - They see each other as localhost.
- Single IP for all containers in the pod.
- Ports are exposed only once at the pod level (host ↔ pod).
- Simplest for closely coupled containers (backend + broker + media server).
- Flutter app on host connects to pod via mapped ports.

### Network

- Custom Podman Network (Separate Containers)
- Containers get separate IPs inside the same network.
  - You must use container names or IPs to connect (backend, camera-mosquitto, camera-mediamtx).
- No port mapping required for container-to-container communication.
- Flutter app outside the network uses host port mapping if needed.
- Allows more isolation, flexibility, and connecting other containers easily.

-----
-----

## Folder Structure

```pgsql
camera-container/
│
├── backend/                # Go camera-control backend
│   ├── cmd/
│   ├── certs/              # Client certificates, CA, keys
│   └── Dockerfile
│
├── flutter_frontend/               # Flutter application
│   ├── lib/
│   ├── assets/
│   └── certs/              # client certificate for frontend
│
├── certs/               # To store the Root, intermediate CA and Server certificates (PKI Infrastructure)
│   
├── mosquitto/               # mosquitto folder
│   ├── mosquitto.conf            # configuration for mosquitto
│   └── Dockerfile
│   
├── mediamtx/               # mediamtx folder
│   ├── mediamtx.yml            # configuration for running mediamtx for the webcam
│   └── Dockerfile 
│
├── podman-compose.yml      # Optional compose file
│
└── README.md
```

-----
-----

## Trouble Shooting

- MQTTs connection fails:

  → Ensure CA certificate is correct and trusted by both backend and frontend.

  → Verify broker is listening on port 8883.

- mTLS handshake error:

  → Check that client certificate is signed by the correct CA.

  → Ensure broker is configured to require and validate client certificates.

- Flutter cannot play RTSP stream:

  → Verify MediaMTX is reachable from frontend.

  → Check that browser/mobile platform supports RTSP (may require plugin or WebRTC bridge).

- Container cannot access camera hardware:

  → Ensure Podman is configured to provide device access:
      podman run --device /dev/video0 ...

- MediaMTX stream not loading:

  → Verify correct RTSP URL (rtsp://localhost:8554/webcam)
  
  → Validate that camera is detected using v4l2-ctl.

-----
-----

## Limitations

- Browser-based Flutter apps cannot natively decode RTSP streams;  
  additional WebRTC or HLS conversion may be required.
- Running MediaMTX inside containers may limit direct hardware access. (Need to run the containers with added flags)
- Mobile devices may require platform-specific plugins for secure MQTTs.
- Certificate rotation is manual unless integrated with an automated CA.

-----
-----

## License

This project is licensed under the MIT License.  
You are free to modify and distribute the project with attribution.

-----
-----

## References

- [MediaMTX Project](https://github.com/bluenviron/mediamtx)
- [Podman Documentation](https://github.com/containers/podman)

-----
-----
