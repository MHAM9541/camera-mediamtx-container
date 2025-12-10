import 'package:flutter/services.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'dart:io';

class MQTTService {
  late MqttServerClient client;

  Future<void> connect({
    required String server,
    required String clientId,
    required String clientCertAsset,
    required String clientKeyAsset,
    required String caCertAsset,
  }) async {
    client = MqttServerClient.withPort(server, clientId, 8883);
    client.secure = true;
    client.logging(on: true);
    client.keepAlivePeriod = 20;

    final context = SecurityContext(withTrustedRoots: true);

    // Load certificates
    final clientCert = (await rootBundle.load(clientCertAsset)).buffer.asUint8List();
    final clientKey = (await rootBundle.load(clientKeyAsset)).buffer.asUint8List();
    final caCert = (await rootBundle.load(caCertAsset)).buffer.asUint8List();

    context.useCertificateChainBytes(clientCert);
    context.usePrivateKeyBytes(clientKey);
    context.setTrustedCertificatesBytes(caCert);

    client.securityContext = context;

    client.onConnected = () => print("MQTT connected");
    client.onDisconnected = () => print("MQTT disconnected");

    try {
      await client.connect();
    } catch (e) {
      print("MQTT connect failed: $e");
      client.disconnect();
    }
  }

  void publish(String topic, String message) {
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);
    client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }

  void subscribe(String topic, Function(String) onMessage) {
    client.subscribe(topic, MqttQos.atLeastOnce);
    client.updates!.listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final recMess = c[0].payload as MqttPublishMessage;
      final msg = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
      onMessage(msg);
    });
  }
}
