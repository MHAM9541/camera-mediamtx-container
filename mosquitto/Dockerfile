# mosquitto/Dockerfile
FROM docker.io/eclipse-mosquitto:2.0

# Your custom config goes into a separate directory
COPY tls-mosquitto.conf /mosquitto/config/mosquitto.conf
COPY certs/ /mosquitto/config/certs/
RUN chown -R mosquitto:mosquitto /mosquitto/config/certs

# CMD ["mosquitto", "-c", "/mosquitto/config/tls-mosquitto.conf"]