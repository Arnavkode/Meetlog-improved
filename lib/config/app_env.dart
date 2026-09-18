import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppEnv {
  static String _value(String key, String fallback) {
    final value = dotenv.env[key]?.trim();
    if (value == null || value.isEmpty) {
      return fallback;
    }
    return value;
  }

  static Uri get attentionUri => Uri.parse(
        _value('API_URL_ATTENTION', 'http://10.6.0.56:8888/attention'),
      );

  static Uri get attentionPokeUri => Uri.parse(
        _value('API_URL_ATTENTION_POKE', 'http://10.6.0.56:8888/attention_poke'),
      );

  static Uri get startMeetingUri => Uri.parse(
        _value('API_URL_START_MEETING', 'http://10.6.0.56:8888/start_meeting'),
      );

  static Uri get endMeetingUri => Uri.parse(
        _value('API_URL_END_MEETING', 'http://10.6.0.56:8888/end_meeting'),
      );
  
  static Uri get liveReportUri  => Uri.parse(
        _value('API_URL_LIVE_REPORT', 'http://10.6.0.56:8888/live_report'),
      );
}
