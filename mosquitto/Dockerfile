# mosquitto/Dockerfile
FROM docker.io/eclipse-mosquitto:2.0

# Your custom config goes into a separate directory
COPY tls-mosquitto.conf /app/mosquitto/config

CMD ["mosquitto", "-c", "/app/mosquitto/configtls-mosquitto.conf"]