import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:just_waveform/just_waveform.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sembast/sembast_io.dart';

void main() => runApp(const KaitoDubsApp());

class KaitoDubsApp extends StatelessWidget {
  const KaitoDubsApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'KaitoDub',
        theme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D7BFF), brightness: Brightness.dark),
          scaffoldBackgroundColor: const Color(0xFF08111F),
          useMaterial3: true,
        ),
        home: const LibraryPage(),
      );
}

class AudioItem {
  AudioItem({required this.id, required this.name, required this.sourcePath, required this.extension, this.durationMs = 0, this.recordingPath, this.confirmed = false});
  final String id;
  final String name;
  final String sourcePath;
  final String extension;
  int durationMs;
  String? recordingPath;
  bool confirmed;
}

class DubSession {
  DubSession({required this.id, required this.name, required this.items});
  final String id;
  final String name;
  final List<AudioItem> items;
}

String formatDuration(int milliseconds) {
  final totalSeconds = (milliseconds / 1000).round();
  final hours = totalSeconds ~/ 3600;
  final minutes = totalSeconds % 3600 ~/ 60;
  final seconds = totalSeconds % 60;
  return hours > 0 ? '${hours}h ${minutes.toString().padLeft(2, '0')}min' : '${minutes}min ${seconds.toString().padLeft(2, '0')}s';
}

int totalDuration(List<AudioItem> items) => items.fold(0, (total, item) => total + item.durationMs);

int confirmedDuration(List<AudioItem> items) => items.where((item) => item.confirmed).fold(0, (total, item) => total + item.durationMs);

final _store = stringMapStoreFactory.store('sessions');

class DubDatabase {
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    _db = await databaseFactoryIo.openDatabase(p.join(directory.path, 'kaito_dubs.db'));
    return _db!;
  }

  Future<List<DubSession>> load() async {
    final records = await _store.find(await database, finder: Finder(sortOrders: [SortOrder('createdAt', false)]));
    return records.map((record) {
      final data = record.value;
      final items = (data['items'] as List<dynamic>).map((raw) {
        final value = Map<String, dynamic>.from(raw as Map);
        return AudioItem(id: value['id'] as String, name: value['name'] as String, sourcePath: value['sourcePath'] as String, extension: value['extension'] as String, durationMs: value['durationMs'] as int? ?? 0, recordingPath: value['recordingPath'] as String?, confirmed: value['confirmed'] as bool? ?? false);
      }).toList();
      return DubSession(id: record.key, name: data['name'] as String, items: items);
    }).toList();
  }

  Future<void> save(DubSession session) async {
    await _store.record(session.id).put(await database, {
      'name': session.name,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'items': session.items.map((item) => {'id': item.id, 'name': item.name, 'sourcePath': item.sourcePath, 'extension': item.extension, 'durationMs': item.durationMs, 'recordingPath': item.recordingPath, 'confirmed': item.confirmed}).toList(),
    });
  }

  Future<void> delete(String sessionId) async {
    await _store.record(sessionId).delete(await database);
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _database = DubDatabase();
  List<DubSession> _sessions = [];
  bool _busy = false;
  double? _busyProgress;
  String _busyMessage = 'Carregando sessões...';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _busy = true; _busyProgress = null; _busyMessage = 'Carregando sessões...'; });
    _sessions = await _database.load();
    await _hydrateDurations(_sessions.expand((session) => session.items));
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _hydrateDurations(Iterable<AudioItem> items, {void Function(double progress)? onProgress}) async {
    final player = AudioPlayer();
    try {
      final pendingItems = items.where((item) => item.durationMs <= 0).toList();
      for (var index = 0; index < pendingItems.length; index++) {
        final item = pendingItems[index];
        await player.setSource(DeviceFileSource(item.sourcePath));
        final duration = await player.getDuration();
        if (duration != null) item.durationMs = duration.inMilliseconds;
        onProgress?.call((index + 1) / pendingItems.length);
      }
      for (final session in _sessions) {
        await _database.save(session);
      }
    } finally {
      await player.dispose();
    }
  }

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['zip', 'rar'], withData: true);
    if (result == null || result.files.single.bytes == null) return;
    if (p.extension(result.files.single.name).toLowerCase() == '.rar') {
      _message('RAR foi reconhecido, mas a extração RAR ainda não está disponível. Use ZIP.');
      return;
    }
    setState(() { _busy = true; _busyProgress = 0; _busyMessage = 'Extraindo áudios...'; });
    try {
      final archive = ZipDecoder().decodeBytes(result.files.single.bytes!);
      final root = await getApplicationSupportDirectory();
      final sessionId = DateTime.now().microsecondsSinceEpoch.toString();
      final folder = Directory(p.join(root.path, 'sessions', sessionId));
      await folder.create(recursive: true);
      const audioExtensions = {'.mp3', '.wav', '.m4a', '.aac', '.ogg', '.flac', '.opus', '.wma'};
      final items = <AudioItem>[];
      final audioEntries = archive.files.where((entry) => entry.isFile && audioExtensions.contains(p.extension(entry.name).toLowerCase())).toList();
      for (var index = 0; index < audioEntries.length; index++) {
        final entry = audioEntries[index];
        final extension = p.extension(entry.name);
        final path = p.join(folder.path, '${items.length}$extension');
        await File(path).writeAsBytes(entry.content as List<int>);
        items.add(AudioItem(id: '$sessionId-${items.length}', name: p.basenameWithoutExtension(entry.name), sourcePath: path, extension: extension));
        if (mounted) setState(() => _busyProgress = (index + 1) / audioEntries.length * .5);
      }
      if (items.isEmpty) throw const FormatException();
      final session = DubSession(id: sessionId, name: p.basenameWithoutExtension(result.files.single.name), items: items);
      if (mounted) setState(() { _busyMessage = 'Lendo durações dos áudios...'; _busyProgress = .5; });
      await _hydrateDurations(items, onProgress: (progress) {
        if (mounted) setState(() => _busyProgress = .5 + progress * .45);
      });
      await _database.save(session);
      await _load();
    } catch (_) {
      _message('Não foi possível importar este ZIP ou ele não contém áudio.');
      if (mounted) setState(() { _busy = false; _busyProgress = null; });
    }
  }

  Future<void> _deleteSession(DubSession session) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir pasta?'),
        content: Text('A sessão "${session.name}" e todos os seus áudios serão removidos do aplicativo.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (accepted != true) return;
    await _database.delete(session.id);
    final folder = session.items.isEmpty ? null : Directory(p.dirname(session.items.first.sourcePath));
    if (folder != null && await folder.exists()) await folder.delete(recursive: true);
    await _load();
  }

  void _message(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (_busy) {
      content = Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 320, child: LinearProgressIndicator(value: _busyProgress)),
        const SizedBox(height: 12),
        Text(_busyMessage, style: const TextStyle(color: Colors.white70)),
        if (_busyProgress != null) ...[const SizedBox(height: 6), Text('${(_busyProgress! * 100).round()}%', style: const TextStyle(color: Colors.white54))],
      ]));
    } else if (_sessions.isEmpty) {
      content = Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Text('Importe um ZIP para criar sua primeira sessão.', style: TextStyle(color: Colors.white54)),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _busy ? null : _import, icon: const Icon(Icons.file_upload_outlined), label: const Text('Importar arquivo')),
      ]));
    } else {
      content = ListView(children: [
        const Text('Arquivos importados', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('Cada arquivo permanece salvo no aplicativo até ser exportado.', style: TextStyle(color: Colors.white54)),
        const SizedBox(height: 24),
        ..._sessions.map((session) => _librarySummary(session)),
        const SizedBox(height: 10),
        ..._sessions.map((session) => Card(child: ListTile(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SessionPage(session: session, database: _database, onChanged: _load))),
              leading: Icon(Icons.folder_zip_outlined, color: Theme.of(context).colorScheme.primary),
              title: Text(session.name),
              subtitle: Text('${session.items.length} áudio(s)'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(onPressed: _busy ? null : () => _deleteSession(session), tooltip: 'Excluir pasta', icon: const Icon(Icons.delete_outline_rounded)),
                const Icon(Icons.chevron_right_rounded),
              ]),
            )))
      ]);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('KaitoDub', style: TextStyle(fontWeight: FontWeight.w800)), actions: [FilledButton.icon(onPressed: _busy ? null : _import, icon: const Icon(Icons.file_upload_outlined), label: const Text('Importar arquivo')), const SizedBox(width: 12)]),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1050), child: Padding(padding: const EdgeInsets.all(24), child: content))),
    );
  }

  Widget _librarySummary(DubSession session) {
    final total = totalDuration(session.items);
    final done = confirmedDuration(session.items);
    final progress = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Padding(padding: const EdgeInsets.only(bottom: 14), child: Row(children: [
      Expanded(child: Text('${formatDuration(total)}  •  ${(progress * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w700))),
      SizedBox(width: 180, child: LinearProgressIndicator(value: progress)),
    ]));
  }
}

class SessionPage extends StatefulWidget {
  const SessionPage({required this.session, required this.database, required this.onChanged, super.key});
  final DubSession session;
  final DubDatabase database;
  final VoidCallback onChanged;
  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  final _player = AudioPlayer();
  bool _exporting = false;
  double _exportProgress = 0;
  String _exportMessage = '';

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    if (_exporting) return;
    final missing = widget.session.items.where((item) => !item.confirmed).length;
    if (missing > 0) {
      final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('Há dublagens pendentes'), content: Text('$missing áudio(s) ainda não foram confirmados. Exportar mesmo assim?'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Exportar'))]));
      if (accepted != true) return;
    }
    setState(() { _exporting = true; _exportProgress = 0; _exportMessage = 'Preparando exportação...'; });
    try {
      final archive = Archive();
      final items = widget.session.items;
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        final source = item.confirmed && item.recordingPath != null ? item.recordingPath! : item.sourcePath;
        final data = await File(source).readAsBytes();
        final fileName = item.confirmed ? '${item.name}_dubbed.wav' : '${item.name}${item.extension}';
        archive.addFile(ArchiveFile(fileName, data.length, data));
        if (mounted) setState(() { _exportProgress = (index + 1) / items.length * .7; _exportMessage = 'Compactando áudio ${index + 1} de ${items.length}...'; });
      }
      if (mounted) setState(() { _exportProgress = .8; _exportMessage = 'Gerando arquivo ZIP...'; });
      final encoded = Uint8List.fromList(ZipEncoder().encode(archive));
      if (mounted) setState(() { _exportProgress = .9; _exportMessage = 'Salvando exportação...'; });
      final output = await FilePicker.platform.saveFile(
        dialogTitle: 'Escolha onde salvar a exportação',
        fileName: 'exported_${widget.session.name}.zip',
        type: FileType.custom,
        allowedExtensions: ['zip'],
        bytes: encoded,
      );
      if (output == null) return;
      if (mounted) {
        setState(() { _exportProgress = 1; _exportMessage = 'Exportação concluída'; });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exportado para $output')));
      }
    } catch (error) {
      if (mounted) _message('Não foi possível exportar os áudios: $error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _message(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Widget _sessionSummary() {
    final total = totalDuration(widget.session.items);
    final done = confirmedDuration(widget.session.items);
    final remaining = max(0, total - done);
    final progress = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 6), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('Total ${formatDuration(total)}', style: const TextStyle(fontWeight: FontWeight.w700))),
        Text('${(progress * 100).round()}%', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 8),
      LinearProgressIndicator(value: progress),
      const SizedBox(height: 6),
      Text('Dublado ${formatDuration(done)}  •  Falta ${formatDuration(remaining)}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
    ]));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.session.name), actions: [IconButton(onPressed: _exporting ? null : _export, tooltip: 'Exportar', icon: const Icon(Icons.ios_share_rounded))]),
        body: Column(children: [
          if (_exporting) Padding(padding: const EdgeInsets.fromLTRB(24, 12, 24, 0), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(_exportMessage, style: const TextStyle(color: Colors.white70))), Text('${(_exportProgress * 100).round()}%')]),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _exportProgress),
          ])),
          _sessionSummary(), Expanded(child: LayoutBuilder(builder: (context, constraints) {
          final columns = constraints.maxWidth >= 900 ? 5 : constraints.maxWidth >= 600 ? 4 : constraints.maxWidth >= 380 ? 3 : 2;
          final cardWidth = (constraints.maxWidth - (columns - 1) * 14) / columns;
          return GridView.builder(
            padding: const EdgeInsets.all(24),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns, crossAxisSpacing: 14, mainAxisSpacing: 14, mainAxisExtent: max(210.0, cardWidth * 1.2)),
            itemCount: widget.session.items.length,
            itemBuilder: (context, index) {
              final item = widget.session.items[index];
              return Card(child: InkWell(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AudioPage(item: item, database: widget.database, onChanged: () { widget.onChanged(); setState(() {}); }))),
                borderRadius: BorderRadius.circular(12),
                child: Padding(padding: const EdgeInsets.all(14), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Align(alignment: Alignment.topRight, child: Icon(item.confirmed ? Icons.check_circle_rounded : Icons.cancel_rounded, color: item.confirmed ? Colors.greenAccent : Colors.redAccent, size: 22)),
                  const Spacer(),
                  Icon(Icons.volume_up_rounded, color: Theme.of(context).colorScheme.primary, size: 42),
                  const SizedBox(height: 12),
                  Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  FittedBox(fit: BoxFit.scaleDown, child: Text(formatDuration(item.durationMs), maxLines: 1, style: const TextStyle(color: Colors.white60, fontSize: 12))),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: item.confirmed ? 1 : 0, minHeight: 4),
                  const Spacer(),
                ])),
              ));
            },
          );
        }))]),
      );
}

class AudioPage extends StatefulWidget {
  const AudioPage({required this.item, required this.database, required this.onChanged, super.key});
  final AudioItem item;
  final DubDatabase database;
  final VoidCallback onChanged;
  @override
  State<AudioPage> createState() => _AudioPageState();
}

class _AudioPageState extends State<AudioPage> {
  final _player = AudioPlayer();
  final _recorder = AudioRecorder();
  final _amplitudes = <double>[];
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  List<double> _sourceWaveform = [];
  List<double> _recordedWaveform = [];
  List<InputDevice> _devices = [];
  InputDevice? _selectedDevice;
  bool _timerEnabled = true;
  bool _recording = false;
  int _countdown = 0;
  double _countdownProgress = 0;
  Timer? _timer;
  Timer? _progressTimer;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _extractWaveform();
    _loadDevices();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _progressTimer?.cancel();
    _amplitudeSubscription?.cancel();
    _player.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _extractWaveform() async {
    await _player.setSource(DeviceFileSource(widget.item.sourcePath));
    final playerDuration = await _player.getDuration();
    if (playerDuration != null && mounted) {
      setState(() => widget.item.durationMs = playerDuration.inMilliseconds);
    }
    if (Platform.isWindows || Platform.isLinux) {
      await _extractDesktopWaveform(sourceDurationMs: playerDuration?.inMilliseconds);
      return;
    }
    try {
      final directory = await getTemporaryDirectory();
      final waveformPath = p.join(directory.path, '${widget.item.id}.waveform');
      final progress = JustWaveform.extract(audioInFile: File(widget.item.sourcePath), waveOutFile: File(waveformPath));
      await for (final update in progress) {
        final waveform = update.waveform;
        if (waveform != null && mounted) {
          setState(() {
            _sourceWaveform = waveform.data.map((value) => value.toDouble()).toList();
            if (playerDuration == null) widget.item.durationMs = waveform.duration.inMilliseconds;
          });
        }
      }
    } catch (_) {
      if (mounted) setState(() => _sourceWaveform = const [0.1]);
    }
  }

  Future<void> _extractDesktopWaveform({int? sourceDurationMs}) async {
    final directory = await getTemporaryDirectory();
    final pcmPath = p.join(directory.path, '${widget.item.id}.pcm');
    try {
      final session = await FFmpegKit.execute('-y -i "${widget.item.sourcePath}" -ac 1 -ar 8000 -f s16le "$pcmPath"');
      final code = await session.getReturnCode();
      if (code == null || !ReturnCode.isSuccess(code) || !await File(pcmPath).exists()) throw const FormatException();
      final bytes = await File(pcmPath).readAsBytes();
      final values = <double>[];
      for (var offset = 0; offset + 1 < bytes.length; offset += 2) {
        final sample = (bytes[offset] | (bytes[offset + 1] << 8));
        final signed = sample > 32767 ? sample - 65536 : sample;
        values.add(signed.abs() / 32768);
      }
      if (mounted) {
        setState(() {
          _sourceWaveform = values;
          if (sourceDurationMs == null) {
            widget.item.durationMs = values.length * 1000 ~/ 8000;
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _sourceWaveform = const [0.1]);
    } finally {
      final file = File(pcmPath);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _loadDevices() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;
    try {
      final devices = await _recorder.listInputDevices();
      if (mounted) setState(() { _devices = devices; _selectedDevice = devices.isEmpty ? null : devices.first; });
    } catch (_) {}
  }

  Future<void> _record() async {
    if (!await _recorder.hasPermission()) {
      if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) await Permission.microphone.request();
      if (!await _recorder.hasPermission()) { _message('Autorize o microfone para gravar.'); return; }
    }
    if (_timerEnabled) {
      final startedAt = DateTime.now();
      setState(() { _countdown = 3; _countdownProgress = 0; });
      _timer = Timer.periodic(const Duration(milliseconds: 30), (timer) async {
        final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
        if (elapsed >= 3000) {
          timer.cancel();
          setState(() { _countdown = 0; _countdownProgress = 1; });
          await _startRecording();
        } else {
          setState(() { _countdown = ((3000 - elapsed) / 1000).ceil(); _countdownProgress = elapsed / 3000; });
        }
      });
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    try {
      const recordingSafetyMarginMs = 250;
      final targetDurationMs = max(1, widget.item.durationMs);
      final directory = await getTemporaryDirectory();
      final path = p.join(directory.path, '${widget.item.id}.wav');
      _amplitudes.clear();
      final device = Platform.isWindows || Platform.isMacOS || Platform.isLinux ? _selectedDevice : null;
      await _recorder.start(RecordConfig(encoder: AudioEncoder.wav, sampleRate: 44100, numChannels: 1, device: device), path: path);
      final startedAt = DateTime.now();
      if (mounted) setState(() { _recording = true; _progress = 0; });
      _progressTimer = Timer.periodic(const Duration(milliseconds: 30), (_) {
        final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
        if (mounted) setState(() => _progress = (elapsed / targetDurationMs).clamp(0.0, 1.0));
      });
      _amplitudeSubscription = _recorder.onAmplitudeChanged(const Duration(milliseconds: 60)).listen((value) { if (mounted) setState(() => _amplitudes.add(((value.current + 60) / 60).clamp(0.04, 1.0))); });
      await Future<void>.delayed(Duration(milliseconds: targetDurationMs + recordingSafetyMarginMs));
      final recorded = await _recorder.stop();
      _progressTimer?.cancel();
      await _player.stop();
      await _amplitudeSubscription?.cancel();
      final recordingPath = recorded ?? path;
      if (!await File(recordingPath).exists()) throw const FileSystemException('O arquivo da gravação não foi criado.');
      if (mounted) {
        setState(() { _recording = false; widget.item.recordingPath = recordingPath; });
        await widget.database.save(await _sessionContainingItem());
        widget.onChanged();
        await _padWav(recordingPath);
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          await _normalizeRecording(recordingPath);
          await _padWav(recordingPath);
          await widget.database.save(await _sessionContainingItem());
        }
        await _extractRecordedWaveform(recordingPath);
        widget.onChanged();
      }
    } catch (error) {
      await _amplitudeSubscription?.cancel();
      if (mounted) {
        setState(() => _recording = false);
        _message('Não foi possível iniciar o microfone: $error');
      }
    }
  }

  Future<void> _extractRecordedWaveform(String path) async {
    try {
      final directory = await getTemporaryDirectory();
      final outputPath = p.join(directory.path, '${widget.item.id}.dub.waveform');
      await for (final update in JustWaveform.extract(audioInFile: File(path), waveOutFile: File(outputPath))) {
        if (update.waveform != null && mounted) {
          setState(() => _recordedWaveform = update.waveform!.data.map((value) => value.toDouble()).toList());
        }
      }
    } catch (_) {
      if (mounted) setState(() => _recordedWaveform = const [0.1]);
    }
  }

  Future<double?> _measureMeanVolume(String path) async {
    final session = await FFmpegKit.execute('-hide_banner -i "${_ffmpegPath(path)}" -af volumedetect -f null -');
    final output = await session.getOutput() ?? '';
    final match = RegExp(r'mean_volume:\s*(-?(?:\d+(?:\.\d+)?|\.\d+))\s*dB').firstMatch(output);
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  Future<void> _normalizeRecording(String path) async {
    String? normalizedPath;
    try {
      final originalVolume = await _measureMeanVolume(widget.item.sourcePath);
      final recordedVolume = await _measureMeanVolume(path);
      if (originalVolume == null || recordedVolume == null) return;

      final gain = (originalVolume - recordedVolume).clamp(-18.0, 18.0);
      if (gain.abs() < 0.05) return;

      final directory = await getTemporaryDirectory();
      normalizedPath = p.join(directory.path, '${widget.item.id}.normalized.wav');
      final session = await FFmpegKit.execute('-y -hide_banner -i "${_ffmpegPath(path)}" -af "volume=${gain.toStringAsFixed(2)}dB,alimiter=limit=0.98" -ar 44100 -ac 1 -c:a pcm_s16le "${_ffmpegPath(normalizedPath)}"');
      final code = await session.getReturnCode();
      if (code == null || !ReturnCode.isSuccess(code) || !await File(normalizedPath).exists()) return;

      await File(path).writeAsBytes(await File(normalizedPath).readAsBytes(), flush: true);
    } catch (_) {
    } finally {
      if (normalizedPath != null) {
        final file = File(normalizedPath);
        if (await file.exists()) await file.delete();
      }
    }
  }

  String _ffmpegPath(String path) => path.replaceAll('"', r'\"');

  Future<void> _padWav(String path) async {
    if (widget.item.durationMs <= 0) return;
    final file = File(path);
    final bytes = await file.readAsBytes();
    if (bytes.length < 44) return;
    final targetFrames = (widget.item.durationMs * 44100 / 1000).round();
    final targetLength = targetFrames * 2;
    final currentLength = bytes.length - 44;
    final output = BytesBuilder()..add(bytes.sublist(0, 44))..add(bytes.sublist(44, 44 + min(currentLength, targetLength)));
    if (targetLength > currentLength) output.add(Uint8List(targetLength - currentLength));
    final result = output.takeBytes();
    _writeLittleEndian(result, 4, result.length - 8);
    _writeLittleEndian(result, 40, targetLength);
    await file.writeAsBytes(result);
  }

  void _writeLittleEndian(Uint8List bytes, int offset, int value) {
    for (var index = 0; index < 4; index++) {
      bytes[offset + index] = (value >> (index * 8)) & 0xff;
    }
  }

  Future<DubSession> _sessionContainingItem() async {
    final session = (await widget.database.load()).firstWhere((session) => session.items.any((item) => item.id == widget.item.id));
    final savedItem = session.items.firstWhere((item) => item.id == widget.item.id);
    savedItem.durationMs = widget.item.durationMs;
    savedItem.recordingPath = widget.item.recordingPath;
    savedItem.confirmed = widget.item.confirmed;
    return session;
  }
  void _message(String text) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text))); }

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(widget.item.name)), body: ListView(padding: const EdgeInsets.all(24), children: [const Text('Áudio original', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)), const SizedBox(height: 10), if (_countdown > 0) ...[LinearProgressIndicator(value: _countdownProgress), const SizedBox(height: 8), Text('Começando em $_countdown', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)), const SizedBox(height: 8)], _waveform(_sourceWaveform, Theme.of(context).colorScheme.primary, progress: _recording ? _progress : null), const SizedBox(height: 16), if (_devices.isNotEmpty) DropdownButtonFormField<InputDevice>(initialValue: _selectedDevice, decoration: const InputDecoration(labelText: 'Microfone de gravação'), items: _devices.map((device) => DropdownMenuItem(value: device, child: Text(device.label))).toList(), onChanged: _recording ? null : (device) => setState(() => _selectedDevice = device)), if (_devices.isNotEmpty) const SizedBox(height: 12), Row(children: [IconButton.filled(onPressed: () => _player.play(DeviceFileSource(widget.item.sourcePath)), tooltip: 'Ouvir original', icon: const Icon(Icons.play_arrow_rounded)), IconButton(onPressed: _recording ? null : () => setState(() => _timerEnabled = !_timerEnabled), tooltip: 'Temporizador', color: _timerEnabled ? Theme.of(context).colorScheme.primary : null, icon: const Icon(Icons.timer_outlined)), FilledButton.icon(onPressed: _recording || _countdown > 0 ? null : _record, icon: const Icon(Icons.mic_none_rounded), label: Text(_recording ? 'Gravando...' : _countdown > 0 ? '$_countdown' : 'Gravar'))]), if (_recording) ...[const SizedBox(height: 22), const Text('Gravando agora', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 8), _waveform(_amplitudes, Colors.redAccent)], if (widget.item.recordingPath != null && !_recording) ...[const SizedBox(height: 30), const Text('Sua dublagem', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)), const SizedBox(height: 10), _waveform(_recordedWaveform, Colors.greenAccent), Row(children: [IconButton.filled(onPressed: () => _player.play(DeviceFileSource(widget.item.recordingPath!)), tooltip: 'Ouvir dublagem', icon: const Icon(Icons.play_arrow_rounded)), OutlinedButton.icon(onPressed: () async { setState(() => widget.item.confirmed = true); await widget.database.save(await _sessionContainingItem()); widget.onChanged(); }, icon: const Icon(Icons.check_rounded), label: Text(widget.item.confirmed ? 'Confirmada' : 'Confirmar'))])]]));

  Widget _waveform(List<double> values, Color color, {double? progress}) => Align(alignment: Alignment.center, child: Container(height: 130, width: progress == null ? double.infinity : min(MediaQuery.of(context).size.width - 48, 620) * .72, decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)), child: Stack(children: [CustomPaint(painter: WavePainter(values, color, progress: progress), child: const SizedBox.expand()), if (progress != null) const Positioned.fill(child: CustomPaint(painter: ProgressPainter()))])));
}

class WavePainter extends CustomPainter {
  WavePainter(this.values, this.color, {this.progress});
  final List<double> values;
  final Color color;
  final double? progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: .85)..strokeWidth = 2;
    final count = max(1, min(values.length, (size.width / 4).floor()));
    for (var index = 0; index < count; index++) {
      final value = values[index * values.length ~/ count].abs().clamp(.04, 1.0);
      final height = max(4.0, value * size.height * .9);
      final normalPosition = index / count;
      final x = progress == null ? normalPosition * size.width : size.width / 2 + (normalPosition - (progress ?? 0)) * size.width;
      canvas.drawLine(Offset(x, (size.height - height) / 2), Offset(x, (size.height + height) / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant WavePainter oldDelegate) => oldDelegate.values != values || oldDelegate.color != color || oldDelegate.progress != progress;
}

class ProgressPainter extends CustomPainter {
  const ProgressPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white..strokeWidth = 3;
    final x = size.width / 2;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant ProgressPainter oldDelegate) => false;
}
