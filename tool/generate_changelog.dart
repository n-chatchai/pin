import 'dart:convert';
import 'dart:io';

/// This script fetches recent git commits and uses Gemini API to summarize them 
/// into user-friendly release notes. It writes the result to `changelog.txt`.
Future<void> main() async {
  final apiKey = Platform.environment['GEMINI_API_KEY'];
  
  // 1. Get last 10 git commits (ignore merges)
  final result = await Process.run('git', ['log', '-10', '--no-merges', '--pretty=format:- %s']);
  final commits = result.stdout.toString().trim();
  
  // 2. Read current version from pubspec.yaml
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final versionMatch = RegExp(r'^version:\s+([\d\.]+)\+(\d+)', multiLine: true).firstMatch(pubspec);
  final versionString = versionMatch != null 
      ? 'Release \${versionMatch.group(1)} (Build \${versionMatch.group(2)})'
      : 'Release Update';

  if (commits.isEmpty) {
    File('changelog.txt').writeAsStringSync('\$versionString\nDescription:\n• Minor bug fixes and improvements.');
    return;
  }

  // 3. If no API key, fallback to raw commits
  if (apiKey == null || apiKey.isEmpty) {
    print('⚠️  No GEMINI_API_KEY found. Falling back to raw git commits.');
    File('changelog.txt').writeAsStringSync('\$versionString\nDescription:\n$commits');
    return;
  }
  
  print('🤖 Generating release notes using Gemini LLM...');

  final prompt = '''
Summarize these git commits into a user-friendly release note in Thai for an app update.
Keep it short, friendly, and use 2-3 bullet points starting with •. 
Do not include technical jargon or code names.

Commits:
$commits
''';

  final requestBody = jsonEncode({
    "contents": [
      {
        "parts": [
          {"text": prompt}
        ]
      }
    ]
  });

  try {
    final client = HttpClient();
    final request = await client.postUrl(Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent?key=$apiKey'));
    request.headers.contentType = ContentType.json;
    request.write(requestBody);
    
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    
    if (response.statusCode == 200) {
      final data = jsonDecode(responseBody);
      final text = data['candidates'][0]['content']['parts'][0]['text'];
      final finalChangelog = '\$versionString\nDescription:\n\${text.trim()}';
      File('changelog.txt').writeAsStringSync(finalChangelog);
      print('✅ Changelog generated successfully!');
    } else {
      print('❌ Gemini API error: \${response.statusCode} - $responseBody');
      File('changelog.txt').writeAsStringSync('\$versionString\nDescription:\n$commits');
    }
  } catch (e) {
    print('❌ Failed to call Gemini API: $e');
    File('changelog.txt').writeAsStringSync('\$versionString\nDescription:\n$commits');
  }
}
