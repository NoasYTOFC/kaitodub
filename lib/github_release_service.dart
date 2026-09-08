import 'dart:convert';
import 'dart:io';

class GithubRelease {
  const GithubRelease({required this.version, required this.name, required this.url, this.apkUrl});

  final String version;
  final String name;
  final String url;
  final String? apkUrl;
}

class GithubReleaseService {
  const GithubReleaseService();

  Future<GithubRelease?> latestRelease({required String owner, required String repository}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('https://api.github.com/repos/$owner/$repository/releases/latest'));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'KaitoDub');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final data = jsonDecode(await response.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final tag = data['tag_name'] as String?;
      final url = data['html_url'] as String?;
      if (tag == null || url == null) return null;
        final assets = (data['assets'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .where((asset) => (asset['name'] as String? ?? '').toLowerCase().endsWith('.apk'));
        final apkUrl = assets.isEmpty ? null : assets.first['browser_download_url'] as String?;
        return GithubRelease(version: tag.replaceFirst(RegExp(r'^v'), ''), name: data['name'] as String? ?? tag, url: url, apkUrl: apkUrl);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

bool isNewerVersion(String available, String installed) {
  List<int> parse(String value) => value.split('+').first.split('-').first.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  final availableParts = parse(available);
  final installedParts = parse(installed);
  for (var index = 0; index < 3; index++) {
    final availablePart = index < availableParts.length ? availableParts[index] : 0;
    final installedPart = index < installedParts.length ? installedParts[index] : 0;
    if (availablePart != installedPart) return availablePart > installedPart;
  }
  return false;
}