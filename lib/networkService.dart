import 'dart:convert';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:wear_os/util/loggingclient.dart';

var client = LoggingClient();

class NetworkService {
  final String _baseUrl;

  NetworkService(this._baseUrl);

  /// Sends a flat 600-length list and returns the prediction vector.
  Future<List<dynamic>> fetchPrediction(List<double> flatData, String model) async {
    
    final uri = Uri.parse("$_baseUrl/attention");
    final resp = await client.post(
  uri,
  headers: {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
  },
  body: jsonEncode({'UserID': model ,'data': flatData}), 
);

    if (resp.statusCode != 200) {
      throw Exception(
          "Server error (${resp.statusCode}): ${resp.body}");
    }

    final body = jsonDecode(resp.body);print("🗝️ Keys: ${body.keys.toList()}");

    final List<dynamic> predDyn = body["probabilities"];
    final AttentionStatus = body["attention_status"];
    // cast dynamic → double
    return [predDyn.map((e) => (e as num).toDouble()).toList(), AttentionStatus];
  }
}
