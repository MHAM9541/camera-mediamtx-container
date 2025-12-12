# mosquitto/Dockerfile
FROM docker.io/eclipse-mosquitto:2.0

# Your custom config goes into a separate directory
COPY tls-mosquitto.conf /mosquitto/config/mosquitto.conf

# CMD ["mosquitto", "-c", "/mosquitto/config/tls-mosquitto.conf"]