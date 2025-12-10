package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io/ioutil"
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
	Broker        = "tls://camera-mosquitto:8883" // TLS port for MQTT 		// Calling the container
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

//var recordCancel context.CancelFunc

func main() {
	log.SetFlags(log.Ldate | log.Ltime)

	os.MkdirAll(CapturesDir, 0755)

	// AGGRESSIVE RESET: Kill any external lock immediately on startup
	resetCamera(activeDevice)
	time.Sleep(500 * time.Millisecond)

	opts := mqtt.NewClientOptions().AddBroker(Broker).SetClientID(ClientID).SetTLSConfig(createTLSConfig())
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
	//go monitorCameraWarmup(client, "rtsp://mediamtx:8554/webcam")

	select {} // keep running
}

func createTLSConfig() *tls.Config {
	// Load server certificate & key
	cert, err := tls.LoadX509KeyPair(
		"/app/backend-certs/crt/client_chain.crt",
		"/app/backend-certs/private/client_decrypted.key",
	)
	if err != nil {
		log.Fatalf("Failed to load server certificate: %v", err)
	}

	// Load CA certs to verify connecting clients
	caCert, err := ioutil.ReadFile("/app/backend-certs/ca_chain.crt")
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
		ServerName:         "127.0.0.1", // MUST match server cert CN or SAN
		MinVersion:         tls.VersionTLS12,
		InsecureSkipVerify: false,
	}

	return tlsConfig
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
	rtspUrl := "rtsp://camera-mediamtx:8554/webcam"
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
	rtspUrl := "rtsp://camera-mediamtx:8554/webcam"

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
	rtspUrl := "rtsp://camera-mediamtx:8554/webcam"

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
		"-rtsp_transport", "tcp",
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
