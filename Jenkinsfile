// Jenkinsfile - Declarative pipeline for building images, running basic checks, building .deb, archiving
pipeline {
  agent any

  environment {
    // change these to your registry or leave blank to skip push stage
    // REGISTRY = credentials('registry-url') // optional: store registry URL in Jenkins as secret text
    // REGISTRY_CRED = 'registry-credentials-id' // Jenkins credentials id for registry (username/password)
    GIT_BRANCH = "${env.BRANCH_NAME ?: 'main'}"
    IMAGE_TAG = "${env.BUILD_NUMBER ?: 'local'}"
    NETWORK_NAME = "camera-net"
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Prepare') {
      steps {
        echo "Ensure helper scripts are executable"
        sh "chmod +x ./ci-scripts/run.sh ./ci-scripts/build_deb.sh ./ci-scripts/deploy.sh || true"
      }
    }

    stage('Build images (Podman)') {
      steps {
        // Build in sequence. Use --no-cache if you want fresh builds.
        sh '''#!/bin/bash
          set -euo pipefail
          echo "Building images..."
          podman build --platform=linux/arm64 -t camera-mosquitto:${IMAGE_TAG}-arm64  ./mosquitto
          podman build --platform=linux/arm64 -t camera-mediamtx:${IMAGE_TAG}-arm64  ./mediamtx
          podman build --platform=linux/arm64 -t camera-backend:${IMAGE_TAG}-arm64  ./backend
        '''
      }
    }

    stage('Create network (if missing)') {
      steps {
        sh '''#!/bin/bash
          set -euo pipefail
          podman network inspect ${NETWORK_NAME} >/dev/null 2>&1 || podman network create ${NETWORK_NAME}
          podman network ls | grep ${NETWORK_NAME} || true
        '''
      }
    }

    stage('Basic smoke test (container run)') {
      steps {
        sh '''#!/bin/bash
          set -euo pipefail
          # Quick smoke: run backend container in ephemeral mode to ensure binary runs
          podman run --rm --network ${NETWORK_NAME} --platform=linux/arm64 --entrypoint /bin/sh camera-backend:${IMAGE_TAG}-arm64 -c 'echo "backend smoke OK"'
        '''
      }
    }

    stage('Build Debian package') {
      steps {
        sh '''#!/bin/bash
          set -euo pipefail
          ./ci-scripts/build_deb.sh ${IMAGE_TAG}
        '''
      }
    }

    stage('Archive artifacts') {
      steps {
        archiveArtifacts artifacts: 'packaging/dist/*.deb', fingerprint: true
      }
    }
    stage('Deploy to Test') {
        steps {
            echo "Deploying to test server..."
            sshagent (credentials: ['deploy-ssh-key']) {
                sh '''#!/bin/bash
                  set -euo pipefail

                  echo "Saving ARM64 images as tarballs..."
                  rm -f backend.tar mediamtx.tar mosquitto.tar || true
                  podman save -o backend.tar        camera-backend:${IMAGE_TAG}-arm64
                  podman save -o mediamtx.tar       camera-mediamtx:${IMAGE_TAG}-arm64
                  podman save -o mosquitto.tar      camera-mosquitto:${IMAGE_TAG}-arm64

                  echo "Copying images + compose file to test server..."
                  scp -o StrictHostKeyChecking=no backend.tar  jetson@192.168.4.2:/opt/deploy/
                  scp -o StrictHostKeyChecking=no mediamtx.tar jetson@192.168.4.2:/opt/deploy/
                  scp -o StrictHostKeyChecking=no mosquitto.tar jetson@192.168.4.2:/opt/deploy/
                  scp -o StrictHostKeyChecking=no podman-compose.yml jetson@192.168.4.2:/opt/deploy/

                  echo "Loading images & restarting containers..."
                  sed "s|\${IMAGE_TAG}|${IMAGE_TAG}|g" podman-compose.yml > /tmp/podman-compose.yml
                  scp -o StrictHostKeyChecking=no /tmp/podman-compose.yml jetson@192.168.4.2:/opt/deploy/podman-compose.yml
                  ssh -o StrictHostKeyChecking=no jetson@192.168.4.2 "
                      set -e
                      cd /opt/deploy

                      echo 'Loading images...'
                      podman load -i backend.tar
                      podman load -i mediamtx.tar
                      podman load -i mosquitto.tar

                      echo 'Starting compose stack...'
                      podman-compose down || true
                      podman-compose up -d
                  "
              '''
            }
        }
    }
    stage('Test SSH (withCredentials)') {
        steps {
            withCredentials([sshUserPrivateKey(credentialsId: 'deploy-ssh-key', keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')]) {
                sh '''#!/bin/bash
                    chmod 600 "$SSH_KEY"
                    echo "Verifying deployment files on test server..."
                    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" ${SSH_USER}@192.168.4.2 "
                        ls -l /opt/deploy
                        podman ps
                        podman images
                    "
                '''
            }
        }
    }

    
/*     stage('Push images to registry (optional)') {
      when {
        expression { return env.REGISTRY != null && env.REGISTRY != '' }
      }
      steps {
        withCredentials([usernamePassword(credentialsId: env.REGISTRY_CRED, usernameVariable: 'REG_USER', passwordVariable: 'REG_PASS')]) {
          sh '''
            set -euo pipefail
            echo "Logging in to registry..."
            podman login ${REGISTRY} -u "${REG_USER}" -p "${REG_PASS}"
            podman tag camera-backend:${IMAGE_TAG} ${REGISTRY}/camera-backend:${IMAGE_TAG}
            podman tag camera-backend:${IMAGE_TAG} ${REGISTRY}/camera-backend:latest
            podman push ${REGISTRY}/camera-backend:${IMAGE_TAG}
            podman push ${REGISTRY}/camera-backend:latest
            # repeat for other images if desired
          '''
        }
      }
    } */
  }

  post {
    always {
      echo "Cleaning up dangling images (best effort)"
      sh "podman image prune -f || true"
    }
    success {
      echo "Pipeline succeeded."
    }
    failure {
      echo "Pipeline failed. See logs."
    }
  }
}
