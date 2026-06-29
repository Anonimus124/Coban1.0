import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const appTitle = 'Coban';
const targetDeviceName = 'Coban';
const solenoidPins = [1, 6, 5, 2, 3, 4];
const maxActiveSolenoids = 6;
const solenoidBridgeHoldMs = 750;
const savedSongsStorageKey = 'coban_saved_songs_v1';

// Friend-project BLE style: one custom service and one JSON characteristic.
final recorderServiceUuid = Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');
final recorderCommandCharacteristicUuid = Guid(
  'beb5483e-36e1-4688-b7f5-ea07361b26a8',
);

const geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');
const geminiModel = String.fromEnvironment(
  'GEMINI_MODEL',
  defaultValue: 'gemini-2.5-flash',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterBluePlus.setOperationQueueMode(OperationQueueMode.perDevice);
  runApp(const CobanApp());
}

enum RecorderConnectionStatus { disconnected, scanning, connecting, connected }

extension RecorderConnectionStatusLabel on RecorderConnectionStatus {
  String get label => switch (this) {
    RecorderConnectionStatus.disconnected => 'Disconnected',
    RecorderConnectionStatus.scanning => 'Scanning',
    RecorderConnectionStatus.connecting => 'Connecting',
    RecorderConnectionStatus.connected => 'Connected',
  };
}

enum NoteDuration { eighth, quarter, half, whole }

extension NoteDurationTiming on NoteDuration {
  int get milliseconds => switch (this) {
    NoteDuration.eighth => 250,
    NoteDuration.quarter => 500,
    NoteDuration.half => 1000,
    NoteDuration.whole => 2000,
  };

  String get apiName => switch (this) {
    NoteDuration.eighth => 'EIGHTH',
    NoteDuration.quarter => 'QUARTER',
    NoteDuration.half => 'HALF',
    NoteDuration.whole => 'WHOLE',
  };
}

class CobanColors {
  static const linen = Color(0xfff7f1e7);
  static const ivory = Color(0xfffffcf5);
  static const cream = Color(0xffeadfc9);
  static const warmTan = Color(0xffb99b73);
  static const wood = Color(0xff7b5938);
  static const burgundy = Color(0xff5b1731);
  static const softGreen = Color(0xff6f8f62);
  static const gold = Color(0xffd7a63f);
  static const red = Color(0xffb43f32);
  static const ink = Color(0xff2f261d);
}

class RecorderFingering {
  const RecorderFingering({
    required this.note,
    required this.midiPitch,
    required this.holes,
    required this.breath,
  });

  final String note;
  final int? midiPitch;
  final List<int> holes;
  final double breath;
}

const recorderFingerings = [
  RecorderFingering(
    note: 'E4',
    midiPitch: 64,
    holes: [1, 1, 1, 1, 1, 1],
    breath: 0.34,
  ),
  RecorderFingering(
    note: 'F4',
    midiPitch: 65,
    holes: [1, 1, 1, 1, 1, 0],
    breath: 0.38,
  ),
  RecorderFingering(
    note: 'F#4',
    midiPitch: 66,
    holes: [1, 1, 1, 1, 0, 0],
    breath: 0.42,
  ),
  RecorderFingering(
    note: 'G4',
    midiPitch: 67,
    holes: [1, 1, 1, 0, 0, 0],
    breath: 0.48,
  ),
  RecorderFingering(
    note: 'G#4',
    midiPitch: 68,
    holes: [1, 1, 0, 1, 1, 0],
    breath: 0.50,
  ),
  RecorderFingering(
    note: 'Ab4',
    midiPitch: 68,
    holes: [1, 1, 0, 1, 1, 0],
    breath: 0.50,
  ),
  RecorderFingering(
    note: 'A4',
    midiPitch: 69,
    holes: [1, 1, 0, 0, 0, 0],
    breath: 0.56,
  ),
  RecorderFingering(
    note: 'A#4',
    midiPitch: 70,
    holes: [1, 1, 0, 1, 0, 0],
    breath: 0.60,
  ),
  RecorderFingering(
    note: 'Bb4',
    midiPitch: 70,
    holes: [1, 1, 0, 1, 0, 0],
    breath: 0.60,
  ),
  RecorderFingering(
    note: 'B4',
    midiPitch: 71,
    holes: [1, 0, 0, 0, 0, 0],
    breath: 0.66,
  ),
  RecorderFingering(
    note: 'C5',
    midiPitch: 72,
    holes: [0, 0, 0, 0, 0, 0],
    breath: 0.74,
  ),
  RecorderFingering(
    note: 'C#5',
    midiPitch: 73,
    holes: [0, 1, 1, 1, 1, 1],
    breath: 0.45,
  ),
  RecorderFingering(
    note: 'REST',
    midiPitch: null,
    holes: [0, 0, 0, 0, 0, 0],
    breath: 0,
  ),
];

RecorderFingering fingeringForNote(String note) {
  return recorderFingerings.firstWhere(
    (fingering) => fingering.note == note,
    orElse: () => throw FormatException('Unsupported note: $note'),
  );
}

RecorderFingering fingeringForPitch(int pitch) {
  return recorderFingerings.firstWhere(
    (fingering) => fingering.midiPitch == pitch,
    orElse: () => throw FormatException('Unsupported MIDI pitch: $pitch'),
  );
}

RecorderFingering closestFingeringForHoles(List<int> holes) {
  FingeringEvent.validateHoles(holes);

  final candidates = recorderFingerings.where(
    (fingering) => fingering.note != 'REST',
  );

  return candidates.reduce((best, candidate) {
    final bestScore = _holeMatchScore(holes, best.holes);
    final candidateScore = _holeMatchScore(holes, candidate.holes);
    if (candidateScore == bestScore) {
      final active = holes.where((value) => value == 1).length;
      final bestActiveDistance =
          best.holes.where((value) => value == 1).length - active;
      final candidateActiveDistance =
          candidate.holes.where((value) => value == 1).length - active;
      return candidateActiveDistance.abs() < bestActiveDistance.abs()
          ? candidate
          : best;
    }
    return candidateScore < bestScore ? candidate : best;
  });
}

int _holeMatchScore(List<int> a, List<int> b) {
  var score = 0;
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) {
      score++;
    }
  }
  return score;
}

Iterable<int> get playableMidiPitches {
  return recorderFingerings
      .map((fingering) => fingering.midiPitch)
      .whereType<int>();
}

class FingeringEvent {
  FingeringEvent({
    required this.note,
    required this.durationMs,
    required this.breath,
    required List<int> holes,
  }) : holes = List.unmodifiable(holes) {
    if (!allowedNotes.contains(note)) {
      throw FormatException('Unsupported note: $note');
    }
    validateHoles(this.holes);
    if (!isManual) {
      validateFingeringMatches(note, this.holes);
    }
    validateBreath(breath);
  }

  factory FingeringEvent.manual({
    required int durationMs,
    required List<int> holes,
  }) {
    return FingeringEvent(
      note: manualNoteName,
      durationMs: durationMs,
      breath: 0,
      holes: holes,
    );
  }

  factory FingeringEvent.rest() {
    return FingeringEvent(
      note: 'REST',
      durationMs: 500,
      breath: 0,
      holes: List.filled(solenoidPins.length, 0),
    );
  }

  factory FingeringEvent.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Expected a fingering object.');
    }

    final map = Map<String, Object?>.from(value);
    final note = map['note'];
    final duration = map['duration'];
    final durationMs = map['durationMs'];
    final breath = map['breath'];
    final holes = map['holes'];

    if (note is! String || holes is! List) {
      throw const FormatException('Each event needs note and holes fields.');
    }
    if (allowedNotes.contains(note) &&
        note != manualNoteName &&
        breath is! num) {
      throw const FormatException('Each non-manual event needs breath.');
    }

    final resolvedDurationMs = _resolveDurationMs(durationMs, duration);
    final resolvedHoles = holes
        .map((value) {
          if (value is! num) {
            throw const FormatException('Hole values must be numbers.');
          }
          return value.toInt();
        })
        .toList(growable: false);

    if (!allowedNotes.contains(note)) {
      return FingeringEvent.manual(
        durationMs: resolvedDurationMs,
        holes: resolvedHoles,
      );
    }

    try {
      return FingeringEvent(
        note: note,
        durationMs: resolvedDurationMs,
        breath: breath is num ? breath.toDouble() : 0,
        holes: resolvedHoles,
      );
    } on FormatException {
      return FingeringEvent.manual(
        durationMs: resolvedDurationMs,
        holes: resolvedHoles,
      );
    }
  }

  static const allowedNotes = {
    'E4',
    'F4',
    'F#4',
    'G4',
    'G#4',
    'Ab4',
    'A4',
    'A#4',
    'Bb4',
    'B4',
    'C5',
    'C#5',
    'REST',
    manualNoteName,
  };

  static const melodicNotes = {
    'E4',
    'F4',
    'F#4',
    'G4',
    'G#4',
    'Ab4',
    'A4',
    'A#4',
    'Bb4',
    'B4',
    'C5',
    'C#5',
    'REST',
  };

  static const manualNoteName = 'MANUAL';

  final String note;
  final int durationMs;
  final double breath;
  final List<int> holes;

  bool get isManual => note == manualNoteName;
  int get activeCount => holes.where((value) => value == 1).length;
  int get breathPercent => (breath * 100).round();
  int get safeDurationMs => durationMs.clamp(40, 30000).toInt();

  int get bitMask {
    var mask = 0;
    for (var i = 0; i < holes.length; i++) {
      if (holes[i] == 1) {
        mask |= 1 << i;
      }
    }
    return mask;
  }

  Map<String, Object> toJson() {
    return {
      'note': note,
      'durationMs': safeDurationMs,
      'breath': breath,
      'holes': holes,
    };
  }

  Map<String, Object> toBleJson({
    required double tempoMultiplier,
    bool bridgeToNext = false,
  }) {
    final scaledDuration = bleDurationMs(
      tempoMultiplier,
      bridgeToNext: bridgeToNext,
    );
    return {
      't': 'note',
      'n': note,
      'm': bitMask,
      'd': scaledDuration,
      'b': breath,
    };
  }

  int bleDurationMs(double tempoMultiplier, {bool bridgeToNext = false}) {
    final scaledDuration = scaledDurationMs(tempoMultiplier);
    if (!bridgeToNext || activeCount == 0) {
      return scaledDuration;
    }
    return (scaledDuration + solenoidBridgeHoldMs).clamp(35, 60000).toInt();
  }

  int scaledDurationMs(double tempoMultiplier) {
    final safeTempo = tempoMultiplier.clamp(0.35, 2.5).toDouble();
    return (safeDurationMs / safeTempo).round().clamp(35, 30000).toInt();
  }

  static int _resolveDurationMs(Object? durationMs, Object? duration) {
    if (durationMs is num) {
      final value = durationMs.round();
      if (value <= 0) {
        throw FormatException('durationMs must be positive. Got $durationMs.');
      }
      return value;
    }

    if (duration is String) {
      return NoteDuration.values
          .firstWhere(
            (candidate) => candidate.apiName == duration,
            orElse: () =>
                throw FormatException('Unsupported duration: $duration'),
          )
          .milliseconds;
    }

    throw const FormatException(
      'Each event needs durationMs or a duration name.',
    );
  }

  static void validateHoles(List<int> holes) {
    if (holes.length != solenoidPins.length) {
      throw FormatException('Expected ${solenoidPins.length} hole values.');
    }

    if (holes.any((value) => value != 0 && value != 1)) {
      throw const FormatException('Hole values must be 0 or 1.');
    }

    final active = holes.where((value) => value == 1).length;
    if (active > maxActiveSolenoids) {
      throw FormatException(
        'Invalid fingering: $active active solenoids exceeds $maxActiveSolenoids.',
      );
    }
  }

  static void validateFingeringMatches(String note, List<int> holes) {
    final expected = fingeringForNote(note).holes;
    for (var i = 0; i < expected.length; i++) {
      if (expected[i] != holes[i]) {
        throw FormatException(
          'Fingering for $note must be $expected. Got $holes.',
        );
      }
    }
  }

  static void validateBreath(double breath) {
    if (!breath.isFinite || breath < 0 || breath > 1) {
      throw FormatException(
        'Breath intensity must be a number from 0.0 to 1.0. Got $breath.',
      );
    }
  }
}

class SavedSong {
  const SavedSong({
    required this.title,
    required this.events,
    this.source = '',
    this.isBuiltIn = false,
  });

  factory SavedSong.fromJson(Object? value, {bool isBuiltIn = false}) {
    if (value is! Map) {
      throw const FormatException('Expected a song object.');
    }

    final map = Map<String, Object?>.from(value);
    final title = map['title'];
    final source = map['source'];
    final events = map['events'];

    if (title is! String || events is! List) {
      throw const FormatException('Song needs title and events.');
    }

    return SavedSong(
      title: title.trim().isEmpty ? 'Untitled song' : title.trim(),
      source: source is String ? source : '',
      isBuiltIn: isBuiltIn,
      events: events.map(FingeringEvent.fromJson).toList(growable: false),
    );
  }

  final String title;
  final String source;
  final bool isBuiltIn;
  final List<FingeringEvent> events;

  Map<String, Object> toJson() {
    return {
      'title': title,
      'source': source,
      'events': events.map((event) => event.toJson()).toList(),
    };
  }

  SavedSong copyWith({
    String? title,
    String? source,
    bool? isBuiltIn,
    List<FingeringEvent>? events,
  }) {
    return SavedSong(
      title: title ?? this.title,
      source: source ?? this.source,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      events: events ?? this.events,
    );
  }
}

class SheetMusicPhoto {
  const SheetMusicPhoto({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
}

class _ManualFingeringStep {
  _ManualFingeringStep({required this.durationMs, required List<int> holes})
    : holes = List.unmodifiable(holes);

  final int durationMs;
  final List<int> holes;

  _ManualFingeringStep copyWith({int? durationMs, List<int>? holes}) {
    return _ManualFingeringStep(
      durationMs: durationMs ?? this.durationMs,
      holes: holes ?? this.holes,
    );
  }

  FingeringEvent toEvent() {
    return FingeringEvent.manual(
      durationMs: durationMs.clamp(40, 30000).toInt(),
      holes: holes,
    );
  }
}

class GeminiTranslationService {
  GeminiTranslationService({
    required String apiKey,
    String modelName = geminiModel,
  }) : _model = GenerativeModel(
         model: modelName,
         apiKey: apiKey,
         systemInstruction: Content.system(_systemInstruction),
         generationConfig: GenerationConfig(
           temperature: 0.1,
           responseMimeType: 'application/json',
           responseSchema: _responseSchema,
         ),
       );

  final GenerativeModel _model;

  Future<List<FingeringEvent>> translateSheetPhotos(
    List<SheetMusicPhoto> photos,
  ) async {
    if (photos.isEmpty) {
      throw const FormatException('Choose at least one sheet music photo.');
    }

    final parts = <Part>[
      TextPart(
        'Analyze these sheet music photos in order. Read the main melody, '
        'transpose/simplify it for the Coban six-hole recorder, and return '
        'note timing, exact fingering, and breath intensity as the JSON array only.',
      ),
    ];

    for (var i = 0; i < photos.length; i++) {
      final photo = photos[i];
      parts.add(TextPart('\nPhoto ${i + 1}: ${photo.name}\n'));
      parts.add(DataPart(photo.mimeType, photo.bytes));
    }

    final response = await _model.generateContent([Content.multi(parts)]);

    final rawText = response.text?.trim();
    if (rawText == null || rawText.isEmpty) {
      throw StateError('Gemini returned an empty response.');
    }

    final decoded = jsonDecode(_stripMarkdownFence(rawText));
    if (decoded is! List) {
      throw const FormatException('Gemini response must be a JSON array.');
    }

    final events = decoded.map(FingeringEvent.fromJson).toList(growable: false);
    if (events.isEmpty) {
      throw const FormatException('Gemini returned no melody events.');
    }
    return events;
  }

  Future<List<FingeringEvent>> translateUrl(String sourceUrl) async {
    final trimmedUrl = sourceUrl.trim();
    final uri = Uri.tryParse(trimmedUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException('Enter a complete URL.');
    }

    final response = await _model.generateContent([
      Content.text(
        'Source URL: $trimmedUrl\n'
        'Analyze the main melody if accessible and return note timing, fingering, and breath intensity as the JSON array only.',
      ),
    ]);

    final rawText = response.text?.trim();
    if (rawText == null || rawText.isEmpty) {
      throw StateError('Gemini returned an empty response.');
    }

    final decoded = jsonDecode(_stripMarkdownFence(rawText));
    if (decoded is! List) {
      throw const FormatException('Gemini response must be a JSON array.');
    }

    final events = decoded.map(FingeringEvent.fromJson).toList(growable: false);
    if (events.isEmpty) {
      throw const FormatException('Gemini returned no melody events.');
    }
    return events;
  }

  static final _responseSchema = Schema.array(
    items: Schema.object(
      properties: {
        'note': Schema.enumString(
          enumValues: FingeringEvent.melodicNotes.toList(),
        ),
        'durationMs': Schema.integer(
          description:
              'Playable note duration in milliseconds. Use 120-3000 ms.',
        ),
        'breath': Schema.number(
          format: 'float',
          description: 'Human breath intensity from 0.0 to 1.0.',
        ),
        'holes': Schema.array(items: Schema.integer()),
      },
      requiredProperties: ['note', 'durationMs', 'breath', 'holes'],
    ),
  );

  static const _systemInstruction = '''
You translate source material, including sheet music photos, into a monophonic robotic recorder melody.
Return only a raw JSON array. No markdown, prose, comments, or code fences.

Each array item must be an object:
{"note":"A4","durationMs":500,"breath":0.58,"holes":[1,1,0,0,0,0]}

Allowed note values:
E4, F4, F#4, G4, G#4, Ab4, A4, A#4, Bb4, B4, C5, C#5, REST.

This custom six-hole recorder has hole 7 and the thumb hole blocked. It cannot play a normal full recorder scale. Use this practical E4-up chromatic-ish ladder and transpose the melody into it:
E4, F4, F#4, G4, G#4/Ab4, A4, A#4/Bb4, B4, C5, C#5.

For do-re-mi thinking, choose the closest transposition where Do/Re/Mi/Fa/Sol/La/Ti/Do mostly lands on that ladder. If the original key would require missing notes, transpose the whole melody first, then snap any remaining impossible notes to the nearest allowed note.

Use durationMs for timing. Start with 250 ms for quick notes, 500 ms for normal notes, 750 ms for dotted-quarter notes, and 1000 ms for half notes. Keep values between 120 and 3000 ms.

The holes array order is the physical recorder order from mouthpiece to foot:
hole 1 GPIO 1, hole 2 GPIO 6, hole 3 GPIO 5, hole 4 GPIO 2, hole 5 GPIO 3, hole 6 GPIO 4.
Each holes value must be 0 or 1, where 1 means the solenoid covers the hole.

Use this exact six-hole fingering table. Do not invent half holes; every value must be 0 or 1:
E4  = [1,1,1,1,1,1]
F4  = [1,1,1,1,1,0]
F#4 = [1,1,1,1,0,0]
G4  = [1,1,1,0,0,0]
G#4 = [1,1,0,1,1,0]
Ab4 = [1,1,0,1,1,0]
A4  = [1,1,0,0,0,0]
A#4 = [1,1,0,1,0,0]
Bb4 = [1,1,0,1,0,0]
B4  = [1,0,0,0,0,0]
C5  = [0,0,0,0,0,0]
C#5 = [0,1,1,1,1,1]
REST = [0,0,0,0,0,0]

Use 0.0 for no blowing, 0.30 to 0.45 for E4-F#4, 0.45 to 0.65 for G4-A#4/Bb4, 0.65 to 0.80 for B4-C5, and around 0.45 with soft pressure for C#5.
If the source contains chords or dense music, simplify to the most recognizable melody and keep timing playable.
If a photo contains multiple staffs, prefer the top melody staff or the part most likely to be sung/played as the tune.
If the photos are unreadable, return one REST event instead of guessing wildly.
''';

  static String _stripMarkdownFence(String value) {
    final trimmed = value.trim();
    if (!trimmed.startsWith('```')) {
      return trimmed;
    }

    final firstLineBreak = trimmed.indexOf('\n');
    final lastFence = trimmed.lastIndexOf('```');
    if (firstLineBreak == -1 || lastFence <= firstLineBreak) {
      return trimmed;
    }
    return trimmed.substring(firstLineBreak + 1, lastFence).trim();
  }
}

class MidiSongImportService {
  SavedSong importFromBytes(Uint8List bytes, {required String fileName}) {
    if (!_startsWithMidiHeader(bytes)) {
      throw const FormatException('Selected file is not a standard MIDI file.');
    }

    final midi = _MidiFile.parse(bytes);
    final events = _convertMidiToEvents(midi);

    if (events.isEmpty) {
      throw const FormatException('MIDI did not contain a playable melody.');
    }

    return SavedSong(
      title: _titleFromFileName(fileName),
      source: 'MIDI file: $fileName',
      events: events,
    );
  }

  Future<SavedSong> importFromUrl(String sourceUrl) async {
    final sourceUri = Uri.tryParse(sourceUrl.trim());
    if (sourceUri == null || !sourceUri.hasScheme || sourceUri.host.isEmpty) {
      throw const FormatException('Enter a complete URL.');
    }

    final midiUri = await _resolveMidiUri(sourceUri);
    final bytes = await _downloadMidi(midiUri);
    final midi = _MidiFile.parse(bytes);
    final events = _convertMidiToEvents(midi);

    if (events.isEmpty) {
      throw const FormatException('MIDI did not contain a playable melody.');
    }

    return SavedSong(
      title: _titleFromUri(midiUri),
      source: 'MIDI import: $midiUri',
      events: events,
    );
  }

  Future<Uri> _resolveMidiUri(Uri uri) async {
    if (_looksLikeMidiUri(uri)) {
      return uri;
    }

    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('Page request failed: HTTP ${response.statusCode}');
    }

    final contentType = response.headers['content-type'] ?? '';
    if (contentType.toLowerCase().contains('audio/mid') ||
        _startsWithMidiHeader(response.bodyBytes)) {
      return uri;
    }

    final html = utf8.decode(response.bodyBytes, allowMalformed: true);
    final midiLinks =
        RegExp(
              r'''(?:href|src)\s*=\s*["']([^"']+\.midi?(?:\?[^"']*)?)["']''',
              caseSensitive: false,
            )
            .allMatches(html)
            .map((match) => match.group(1))
            .whereType<String>()
            .map(uri.resolve)
            .toList();

    if (midiLinks.isEmpty) {
      throw const FormatException('No MIDI link found on the page.');
    }

    midiLinks.sort((a, b) {
      final aText = a.toString().toLowerCase();
      final bText = b.toString().toLowerCase();
      final aScore = aText.contains('recorder') ? 0 : 1;
      final bScore = bText.contains('recorder') ? 0 : 1;
      return aScore.compareTo(bScore);
    });

    return midiLinks.first;
  }

  Future<Uint8List> _downloadMidi(Uri uri) async {
    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('MIDI request failed: HTTP ${response.statusCode}');
    }
    final bytes = response.bodyBytes;
    if (!_startsWithMidiHeader(bytes)) {
      throw const FormatException(
        'Downloaded file is not a standard MIDI file.',
      );
    }
    return bytes;
  }

  bool _looksLikeMidiUri(Uri uri) {
    final path = uri.path.toLowerCase();
    return path.endsWith('.mid') || path.endsWith('.midi');
  }

  bool _startsWithMidiHeader(List<int> bytes) {
    return bytes.length >= 4 &&
        bytes[0] == 0x4d &&
        bytes[1] == 0x54 &&
        bytes[2] == 0x68 &&
        bytes[3] == 0x64;
  }

  List<FingeringEvent> _convertMidiToEvents(_MidiFile midi) {
    final notes = _selectMelodyNotes(midi);
    if (notes.isEmpty) {
      return const [];
    }

    final gridTicks = (midi.ticksPerQuarter / 2).round().clamp(1, 1 << 30);
    final firstUnit = notes
        .map((note) => (note.start / gridTicks).round())
        .reduce((a, b) => a < b ? a : b);

    final grouped = <int, List<_MidiNote>>{};
    for (final note in notes) {
      final bucket = (note.start / gridTicks).round() - firstUnit;
      grouped.putIfAbsent(bucket, () => []).add(note);
    }

    final chosen = grouped.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final rawEvents = <_RawMidiEvent>[];
    var cursor = 0;

    for (var i = 0; i < chosen.length; i++) {
      final start = chosen[i].key;
      final note = chosen[i].value.reduce((a, b) => a.pitch >= b.pitch ? a : b);
      var end = (note.end / gridTicks).round() - firstUnit;
      if (i + 1 < chosen.length) {
        end = end.clamp(start + 1, chosen[i + 1].key);
      }
      final units = (end - start).clamp(1, 32);

      if (start > cursor) {
        rawEvents.add(_RawMidiEvent(units: start - cursor, pitch: null));
      }
      rawEvents.add(_RawMidiEvent(units: units, pitch: note.pitch));
      cursor = start + units;
    }

    final transpose = _bestTranspose(rawEvents);
    final eighthMs = (midi.tempoUsPerQuarter / 2000).round().clamp(80, 1000);

    return rawEvents
        .map((event) {
          final pitch = event.pitch;
          if (pitch == null) {
            final rest = fingeringForNote('REST');
            return FingeringEvent(
              note: rest.note,
              durationMs: event.units * eighthMs,
              breath: rest.breath,
              holes: rest.holes,
            );
          }

          final playablePitch = _nearestPlayablePitch(pitch + transpose);
          final fingering = fingeringForPitch(playablePitch);
          return FingeringEvent(
            note: fingering.note,
            durationMs: event.units * eighthMs,
            breath: fingering.breath,
            holes: fingering.holes,
          );
        })
        .toList(growable: false);
  }

  List<_MidiNote> _selectMelodyNotes(_MidiFile midi) {
    final trackScores = <int, int>{};
    for (final note in midi.notes) {
      trackScores[note.track] = (trackScores[note.track] ?? 0) + 1;
    }
    if (trackScores.isEmpty) {
      return const [];
    }

    int? selectedTrack;
    var selectedScore = -1;
    for (final entry in trackScores.entries) {
      final name = (midi.trackNames[entry.key] ?? '').toLowerCase();
      var score = entry.value;
      if (name.contains('recorder') ||
          name.contains('melody') ||
          name.contains('lead') ||
          name.contains('flute')) {
        score += 10000;
      }
      if (score > selectedScore) {
        selectedScore = score;
        selectedTrack = entry.key;
      }
    }

    return midi.notes.where((note) => note.track == selectedTrack).toList()
      ..sort((a, b) {
        final start = a.start.compareTo(b.start);
        return start != 0 ? start : b.pitch.compareTo(a.pitch);
      });
  }

  int _bestTranspose(List<_RawMidiEvent> events) {
    var bestShift = 0;
    List<int>? bestScore;

    for (var shift = -24; shift <= 24; shift++) {
      var outOfRange = 0;
      var totalDistance = 0;
      for (final event in events) {
        final pitch = event.pitch;
        if (pitch == null) {
          continue;
        }
        final shifted = pitch + shift;
        final nearest = _nearestPlayablePitch(shifted);
        totalDistance += (nearest - shifted).abs();
        if (shifted < _minPlayablePitch || shifted > _maxPlayablePitch) {
          outOfRange += shifted < _minPlayablePitch
              ? _minPlayablePitch - shifted
              : shifted - _maxPlayablePitch;
        }
      }

      final score = [outOfRange, totalDistance, shift.abs()];
      if (bestScore == null || _compareScore(score, bestScore) < 0) {
        bestScore = score;
        bestShift = shift;
      }
    }

    return bestShift;
  }

  int _compareScore(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      final comparison = a[i].compareTo(b[i]);
      if (comparison != 0) {
        return comparison;
      }
    }
    return 0;
  }

  int _nearestPlayablePitch(int pitch) {
    return playableMidiPitches.reduce((best, candidate) {
      final bestDistance = (best - pitch).abs();
      final candidateDistance = (candidate - pitch).abs();
      if (candidateDistance == bestDistance) {
        return candidate < best ? candidate : best;
      }
      return candidateDistance < bestDistance ? candidate : best;
    });
  }

  int get _minPlayablePitch =>
      playableMidiPitches.reduce((a, b) => a < b ? a : b);
  int get _maxPlayablePitch =>
      playableMidiPitches.reduce((a, b) => a > b ? a : b);

  String _titleFromUri(Uri uri) {
    final last = uri.pathSegments.isEmpty ? uri.host : uri.pathSegments.last;
    return _cleanTitle(last, fallback: uri.host);
  }

  String _titleFromFileName(String fileName) {
    return _cleanTitle(fileName, fallback: 'Imported MIDI song');
  }

  String _cleanTitle(String value, {required String fallback}) {
    final cleaned = Uri.decodeComponent(value)
        .replaceAll(RegExp(r'\.(mid|midi)$', caseSensitive: false), '')
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .trim();
    return cleaned.isEmpty ? fallback : cleaned;
  }
}

class _MidiFile {
  const _MidiFile({
    required this.ticksPerQuarter,
    required this.tempoUsPerQuarter,
    required this.trackNames,
    required this.notes,
  });

  factory _MidiFile.parse(Uint8List bytes) {
    final reader = _MidiReader(bytes);
    if (reader.readAscii(4) != 'MThd') {
      throw const FormatException('Not a standard MIDI file.');
    }
    final headerLength = reader.readU32();
    final header = _MidiReader(reader.readBytes(headerLength));
    header.readU16(); // format
    final trackCount = header.readU16();
    final division = header.readU16();
    if ((division & 0x8000) != 0) {
      throw const FormatException('SMPTE MIDI timing is not supported.');
    }

    final notes = <_MidiNote>[];
    final trackNames = <int, String>{};
    var tempoUsPerQuarter = 500000;

    for (var track = 0; track < trackCount; track++) {
      if (reader.readAscii(4) != 'MTrk') {
        throw const FormatException('Invalid MIDI track header.');
      }
      final trackReader = _MidiReader(reader.readBytes(reader.readU32()));
      var tick = 0;
      int? runningStatus;
      final active = <String, List<int>>{};

      while (!trackReader.isDone) {
        tick += trackReader.readVarLen();
        var status = trackReader.readU8();
        if (status < 0x80) {
          if (runningStatus == null) {
            throw const FormatException('Invalid MIDI running status.');
          }
          trackReader.rewind(1);
          status = runningStatus;
        } else if (status < 0xF0) {
          runningStatus = status;
        }

        if (status == 0xFF) {
          final metaType = trackReader.readU8();
          final length = trackReader.readVarLen();
          final payload = trackReader.readBytes(length);
          if (metaType == 0x03) {
            trackNames[track] = latin1.decode(payload, allowInvalid: true);
          } else if (metaType == 0x51 && payload.length == 3) {
            tempoUsPerQuarter =
                (payload[0] << 16) | (payload[1] << 8) | payload[2];
          } else if (metaType == 0x2F) {
            break;
          }
          runningStatus = null;
          continue;
        }

        if (status == 0xF0 || status == 0xF7) {
          trackReader.readBytes(trackReader.readVarLen());
          runningStatus = null;
          continue;
        }

        final eventType = status & 0xF0;
        final channel = status & 0x0F;
        if (eventType == 0xC0 || eventType == 0xD0) {
          trackReader.readU8();
          continue;
        }

        final data1 = trackReader.readU8();
        final data2 = trackReader.readU8();
        final key = '$channel:$data1';

        if (eventType == 0x90 && data2 > 0) {
          active.putIfAbsent(key, () => <int>[]).add(tick);
        } else if (eventType == 0x80 || (eventType == 0x90 && data2 == 0)) {
          final starts = active[key];
          if (starts != null && starts.isNotEmpty) {
            final start = starts.removeAt(0);
            if (tick > start) {
              notes.add(
                _MidiNote(track: track, pitch: data1, start: start, end: tick),
              );
            }
          }
        }
      }
    }

    return _MidiFile(
      ticksPerQuarter: division,
      tempoUsPerQuarter: tempoUsPerQuarter,
      trackNames: trackNames,
      notes: notes,
    );
  }

  final int ticksPerQuarter;
  final int tempoUsPerQuarter;
  final Map<int, String> trackNames;
  final List<_MidiNote> notes;
}

class _MidiNote {
  const _MidiNote({
    required this.track,
    required this.pitch,
    required this.start,
    required this.end,
  });

  final int track;
  final int pitch;
  final int start;
  final int end;
}

class _RawMidiEvent {
  const _RawMidiEvent({required this.units, required this.pitch});

  final int units;
  final int? pitch;
}

class _MidiReader {
  _MidiReader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  bool get isDone => offset >= bytes.length;

  void rewind(int count) {
    offset = (offset - count).clamp(0, bytes.length).toInt();
  }

  int readU8() {
    if (offset >= bytes.length) {
      throw const FormatException('Unexpected end of MIDI file.');
    }
    return bytes[offset++];
  }

  int readU16() {
    return (readU8() << 8) | readU8();
  }

  int readU32() {
    return (readU8() << 24) | (readU8() << 16) | (readU8() << 8) | readU8();
  }

  Uint8List readBytes(int count) {
    if (offset + count > bytes.length) {
      throw const FormatException('Unexpected end of MIDI file.');
    }
    final out = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return out;
  }

  String readAscii(int count) {
    return ascii.decode(readBytes(count), allowInvalid: true);
  }

  int readVarLen() {
    var value = 0;
    for (var i = 0; i < 4; i++) {
      final byte = readU8();
      value = (value << 7) | (byte & 0x7F);
      if ((byte & 0x80) == 0) {
        return value;
      }
    }
    throw const FormatException('Invalid MIDI variable-length value.');
  }
}

class ScannedRecorderDevice {
  const ScannedRecorderDevice({
    required this.device,
    required this.name,
    required this.remoteId,
    required this.rssi,
    required this.isLikelyCoban,
  });

  final BluetoothDevice device;
  final String name;
  final String remoteId;
  final int rssi;
  final bool isLikelyCoban;
}

class BleRecorderController extends ChangeNotifier {
  RecorderConnectionStatus status = RecorderConnectionStatus.disconnected;
  String statusDetail = 'Ready to scan';
  List<int> activeHoles = List.filled(solenoidPins.length, 0);
  double activeBreath = 0;
  String activeNote = 'REST';
  bool isPlaying = false;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _commandCharacteristic;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _notifySubscription;
  int _previewRunId = 0;

  bool get isConnected {
    return status == RecorderConnectionStatus.connected &&
        _commandCharacteristic != null;
  }

  Future<List<ScannedRecorderDevice>> scanDevices() async {
    final found = <String, ScanResult>{};

    try {
      await _requestBlePermissions();
      _setStatus(RecorderConnectionStatus.scanning, 'Scanning nearby devices');

      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        try {
          await FlutterBluePlus.turnOn();
        } catch (_) {}
      }

      await FlutterBluePlus.adapterState
          .where((state) => state == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 8));

      if (await FlutterBluePlus.isScanning.first) {
        await FlutterBluePlus.stopScan();
      }

      final subscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          final id = result.device.remoteId.toString();
          if (id.isNotEmpty) {
            found[id] = result;
          }
        }
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
      await FlutterBluePlus.isScanning.where((isScanning) => !isScanning).first;
      await subscription.cancel();

      final devices =
          found.values.map((result) {
            final name = _advertisedName(result);
            final serviceMatch = result.advertisementData.serviceUuids.contains(
              recorderServiceUuid,
            );
            final nameMatch =
                name.toLowerCase().contains('coban') ||
                name == targetDeviceName ||
                name == 'ESP32_RECORDER';
            return ScannedRecorderDevice(
              device: result.device,
              name: name.isEmpty ? 'Unnamed ESP32' : name,
              remoteId: result.device.remoteId.toString(),
              rssi: result.rssi,
              isLikelyCoban: serviceMatch || nameMatch,
            );
          }).toList()..sort((a, b) {
            if (a.isLikelyCoban != b.isLikelyCoban) {
              return a.isLikelyCoban ? -1 : 1;
            }
            return b.rssi.compareTo(a.rssi);
          });

      _setStatus(
        RecorderConnectionStatus.disconnected,
        devices.isEmpty ? 'No BLE devices found' : 'Select a device',
      );
      return devices;
    } catch (error) {
      _setStatus(RecorderConnectionStatus.disconnected, error.toString());
      return const [];
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      await FlutterBluePlus.stopScan();
      await _connect(device);
    } catch (error) {
      _setStatus(RecorderConnectionStatus.disconnected, error.toString());
    }
  }

  Future<void> disconnect() async {
    _previewRunId++;
    isPlaying = false;
    await _notifySubscription?.cancel();
    await _connectionSubscription?.cancel();
    await _device?.disconnect();
    _device = null;
    _commandCharacteristic = null;
    _setActiveEvent(FingeringEvent.rest());
    _setStatus(RecorderConnectionStatus.disconnected, 'Disconnected');
  }

  Future<void> transmitSong(
    List<FingeringEvent> events, {
    required double tempoMultiplier,
  }) async {
    final runId = ++_previewRunId;
    final characteristic = _commandCharacteristic;
    if (!isConnected || characteristic == null) {
      throw StateError('Connect to Coban before transmitting.');
    }

    isPlaying = true;
    _setStatus(status, 'Playing on Coban');

    try {
      for (final event in events) {
        if (runId != _previewRunId) {
          return;
        }

        _setActiveEvent(event);
        await _writeEvent(
          characteristic,
          event,
          tempoMultiplier: tempoMultiplier,
          bridgeToNext: true,
        );
        if (runId != _previewRunId) {
          return;
        }

        await Future<void>.delayed(
          Duration(milliseconds: event.scaledDurationMs(tempoMultiplier)),
        );
      }
    } finally {
      if (runId == _previewRunId) {
        isPlaying = false;
        _setActiveEvent(FingeringEvent.rest());
        await _writeEvent(
          characteristic,
          FingeringEvent.rest(),
          tempoMultiplier: 1,
        );
        _setStatus(status, 'Song complete');
      }
    }
  }

  Future<void> previewSong(
    List<FingeringEvent> events, {
    required double tempoMultiplier,
  }) async {
    final runId = ++_previewRunId;
    isPlaying = true;
    _setStatus(RecorderConnectionStatus.disconnected, 'Preview playback');

    try {
      for (final event in events) {
        if (runId != _previewRunId) {
          return;
        }

        _setActiveEvent(event);
        await Future<void>.delayed(
          Duration(milliseconds: event.scaledDurationMs(tempoMultiplier)),
        );
      }
    } finally {
      if (runId == _previewRunId) {
        isPlaying = false;
        _setActiveEvent(FingeringEvent.rest());
        _setStatus(
          RecorderConnectionStatus.disconnected,
          'Preview complete. Connect when hardware is ready.',
        );
      }
    }
  }

  Future<void> stopPlayback() async {
    _previewRunId++;
    isPlaying = false;
    final rest = FingeringEvent.rest();
    _setActiveEvent(rest);

    final characteristic = _commandCharacteristic;
    if (isConnected && characteristic != null) {
      await _writeEvent(characteristic, rest, tempoMultiplier: 1);
    }

    _setStatus(status, isConnected ? 'Stopped' : 'Preview stopped');
  }

  Future<void> toggleHole(int index) async {
    if (index < 0 || index >= solenoidPins.length) {
      throw RangeError.index(index, solenoidPins, 'index');
    }

    final characteristic = _commandCharacteristic;
    if (!isConnected || characteristic == null) {
      throw StateError('Connect to Coban before testing holes.');
    }

    _previewRunId++;
    isPlaying = false;

    final holes = List<int>.from(activeHoles);
    holes[index] = holes[index] == 1 ? 0 : 1;
    await _writeMask(
      characteristic,
      mask: _maskFromHoles(holes),
      durationMs: 0,
      note: 'MANUAL',
      breath: 0,
    );

    activeHoles = List.unmodifiable(holes);
    activeBreath = 0;
    activeNote = 'Manual';
    _setStatus(
      status,
      'Hole ${index + 1} ${holes[index] == 1 ? 'closed' : 'open'}',
    );
  }

  Future<void> _writeEvent(
    BluetoothCharacteristic characteristic,
    FingeringEvent event, {
    required double tempoMultiplier,
    bool bridgeToNext = false,
  }) {
    return _writeMask(
      characteristic,
      mask: event.bitMask,
      durationMs: event.bleDurationMs(
        tempoMultiplier,
        bridgeToNext: bridgeToNext,
      ),
      note: event.note,
      breath: event.breath,
    );
  }

  Future<void> _writeMask(
    BluetoothCharacteristic characteristic, {
    required int mask,
    required int durationMs,
    required String note,
    required double breath,
  }) {
    final payload = utf8.encode(
      jsonEncode({
        't': 'note',
        'n': note,
        'm': mask & 0x3F,
        'd': durationMs.clamp(0, 60000).toInt(),
        'b': breath.clamp(0.0, 1.0).toDouble(),
      }),
    );
    return characteristic.write(payload, withoutResponse: false, timeout: 3);
  }

  int _maskFromHoles(List<int> holes) {
    var mask = 0;
    for (var i = 0; i < holes.length && i < solenoidPins.length; i++) {
      if (holes[i] == 1) {
        mask |= 1 << i;
      }
    }
    return mask;
  }

  Future<void> _connect(BluetoothDevice device) async {
    final name = device.platformName.isEmpty
        ? 'BLE device'
        : device.platformName;
    _setStatus(RecorderConnectionStatus.connecting, 'Connecting to $name');

    _device = device;
    await _connectionSubscription?.cancel();
    _connectionSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _commandCharacteristic = null;
        _setActiveEvent(FingeringEvent.rest());
        _setStatus(RecorderConnectionStatus.disconnected, 'Connection lost');
      }
    });

    if (device.isDisconnected) {
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
        mtu: 185,
      );
    }

    try {
      await device.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
    } catch (_) {}

    final service = _findService(await device.discoverServices());
    final characteristic = _findCharacteristic(
      service,
      recorderCommandCharacteristicUuid,
    );
    _commandCharacteristic = characteristic;

    if (characteristic.properties.notify ||
        characteristic.properties.indicate) {
      await _notifySubscription?.cancel();
      _notifySubscription = characteristic.onValueReceived.listen(
        _handleEsp32StatusPacket,
      );
      await characteristic.setNotifyValue(true);
    }

    _setStatus(RecorderConnectionStatus.connected, 'Connected to $name');
  }

  Future<void> _requestBlePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final denied = statuses.entries
        .where((entry) => !entry.value.isGranted)
        .map((entry) => entry.key.toString())
        .join(', ');

    if (denied.isNotEmpty) {
      throw StateError('Required permissions denied: $denied');
    }
  }

  BluetoothService _findService(List<BluetoothService> services) {
    for (final service in services) {
      if (service.uuid == recorderServiceUuid) {
        return service;
      }
    }
    throw StateError('Coban BLE service not found: $recorderServiceUuid');
  }

  BluetoothCharacteristic _findCharacteristic(
    BluetoothService service,
    Guid uuid,
  ) {
    for (final characteristic in service.characteristics) {
      if (characteristic.uuid == uuid) {
        return characteristic;
      }
    }
    throw StateError('Coban command characteristic not found: $uuid');
  }

  String _advertisedName(ScanResult result) {
    final advertised = result.advertisementData.advName;
    return advertised.isNotEmpty ? advertised : result.device.platformName;
  }

  void _handleEsp32StatusPacket(List<int> value) {
    if (value.isEmpty) {
      return;
    }

    final text = utf8.decode(value, allowMalformed: true);
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['t'] == 'status') {
        statusDetail = 'ESP32: ${decoded['v']}';
      } else {
        statusDetail = 'ESP32: $text';
      }
    } catch (_) {
      statusDetail = 'ESP32: $text';
    }
    notifyListeners();
  }

  void _setStatus(RecorderConnectionStatus nextStatus, String detail) {
    status = nextStatus;
    statusDetail = detail;
    notifyListeners();
  }

  void _setActiveEvent(FingeringEvent event) {
    activeHoles = List.unmodifiable(event.holes);
    activeBreath = event.breath;
    activeNote = event.note;
    notifyListeners();
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _notifySubscription?.cancel();
    super.dispose();
  }
}

class CobanApp extends StatelessWidget {
  const CobanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appTitle,
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.light,
      theme: _buildTheme(),
      home: const RecorderDashboardPage(),
    );
  }

  ThemeData _buildTheme() {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: CobanColors.burgundy,
      onPrimary: Colors.white,
      primaryContainer: Color(0xfff0d8df),
      onPrimaryContainer: CobanColors.ink,
      secondary: CobanColors.wood,
      onSecondary: Colors.white,
      secondaryContainer: CobanColors.cream,
      onSecondaryContainer: CobanColors.ink,
      tertiary: CobanColors.gold,
      onTertiary: CobanColors.ink,
      tertiaryContainer: Color(0xffffe6aa),
      onTertiaryContainer: CobanColors.ink,
      error: CobanColors.red,
      onError: Colors.white,
      errorContainer: Color(0xffffdad4),
      onErrorContainer: Color(0xff3d0700),
      surface: CobanColors.linen,
      onSurface: CobanColors.ink,
      surfaceContainerLowest: CobanColors.ivory,
      surfaceContainerLow: Color(0xfff3eadc),
      surfaceContainer: CobanColors.linen,
      surfaceContainerHigh: Color(0xffe9dcc7),
      surfaceContainerHighest: Color(0xffdfd1bc),
      onSurfaceVariant: Color(0xff5e5141),
      outline: Color(0xff8b7b68),
      outlineVariant: Color(0xffd2c4ae),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: CobanColors.ink,
      onInverseSurface: CobanColors.ivory,
      inversePrimary: Color(0xffffb1c8),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: const AppBarTheme(
        backgroundColor: CobanColors.ivory,
        foregroundColor: CobanColors.ink,
        centerTitle: false,
        elevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: CobanColors.burgundy,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: CobanColors.wood,
          side: const BorderSide(color: CobanColors.warmTan),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.secondaryContainer,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: CobanColors.ivory,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: CobanColors.burgundy, width: 1.5),
        ),
      ),
    );
  }
}

class RecorderDashboardPage extends StatefulWidget {
  const RecorderDashboardPage({super.key});

  @override
  State<RecorderDashboardPage> createState() => _RecorderDashboardPageState();
}

class _RecorderDashboardPageState extends State<RecorderDashboardPage> {
  late final BleRecorderController _ble = BleRecorderController();
  late final GeminiTranslationService? _gemini = geminiApiKey.isEmpty
      ? null
      : GeminiTranslationService(apiKey: geminiApiKey);

  List<FingeringEvent> _events = const [];
  List<SavedSong> _savedSongs = const [];
  String _currentSongTitle = 'No song loaded';
  String? _errorText;
  double _tempoMultiplier = 1.0;
  bool _isImporting = false;
  bool _isLoadingSongs = true;

  @override
  void initState() {
    super.initState();
    _loadSavedSongs();
  }

  @override
  void dispose() {
    _ble.dispose();
    super.dispose();
  }

  Future<void> _openConnectionPicker() async {
    final devices = await _ble.scanDevices();
    if (!mounted) {
      return;
    }

    final selected = await showDialog<ScannedRecorderDevice>(
      context: context,
      builder: (context) => DevicePickerDialog(devices: devices),
    );

    if (selected != null) {
      await _ble.connectToDevice(selected.device);
    }
  }

  Future<void> _loadSavedSongs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(savedSongsStorageKey);
      final userSongs = <SavedSong>[];

      if (stored != null && stored.trim().isNotEmpty) {
        final decoded = jsonDecode(stored);
        if (decoded is List) {
          userSongs.addAll(
            decoded
                .map(SavedSong.fromJson)
                .where((song) => song.events.isNotEmpty),
          );
        }
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _savedSongs = userSongs;
        _events = const [];
        _currentSongTitle = 'No song loaded';
        _isLoadingSongs = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = 'Could not load saved songs: $error';
        _isLoadingSongs = false;
      });
    }
  }

  Future<void> _persistUserSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final userSongs = _savedSongs
        .where((song) => !song.isBuiltIn)
        .map((song) => song.toJson())
        .toList();
    await prefs.setString(savedSongsStorageKey, jsonEncode(userSongs));
  }

  Future<void> _importSheetPhotos() async {
    FocusScope.of(context).unfocus();

    setState(() {
      _isImporting = true;
      _errorText = null;
    });

    try {
      final gemini = _gemini;
      if (gemini == null) {
        throw StateError('Gemini API key is missing from this app build.');
      }

      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
        allowMultiple: true,
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }

      final photos = <SheetMusicPhoto>[];
      for (final picked in result.files) {
        final bytes = picked.bytes ?? await _readPickedFile(picked);
        photos.add(
          SheetMusicPhoto(
            name: picked.name,
            mimeType: _mimeTypeForPhotoFile(picked),
            bytes: bytes,
          ),
        );
      }
      final events = await gemini.translateSheetPhotos(photos);

      if (!mounted) {
        return;
      }

      setState(() {
        _events = events;
        _currentSongTitle = _titleFromPhotoFiles(photos);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _errorText = error.toString());
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  Future<Uint8List> _readPickedFile(PlatformFile picked) async {
    final path = picked.path;
    if (path == null || path.isEmpty) {
      throw const FormatException('Could not read the selected file.');
    }
    return File(path).readAsBytes();
  }

  String _mimeTypeForPhotoFile(PlatformFile picked) {
    final extension = (picked.extension ?? '').toLowerCase();
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => throw FormatException('Unsupported image type: ${picked.name}'),
    };
  }

  String _titleFromPhotoFiles(List<SheetMusicPhoto> photos) {
    if (photos.length != 1) {
      return 'Gemini sheet photos';
    }
    final cleaned = photos.single.name
        .replaceAll(RegExp(r'\.(jpe?g|png|webp)$', caseSensitive: false), '')
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .trim();
    return cleaned.isEmpty ? 'Gemini sheet photo' : cleaned;
  }

  Future<void> _openManualMode() async {
    final events = await showDialog<List<FingeringEvent>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const ManualSongDialog(),
    );
    if (events == null || events.isEmpty || !mounted) {
      return;
    }

    final title = await showDialog<String>(
      context: context,
      builder: (context) => const SaveSongDialog(
        initialTitle: 'Manual song',
        dialogTitle: 'Name manual song',
      ),
    );
    final trimmedTitle = title?.trim();
    if (trimmedTitle == null || trimmedTitle.isEmpty || !mounted) {
      return;
    }

    final song = SavedSong(
      title: trimmedTitle,
      source: 'Manual mode',
      events: events,
    );

    setState(() {
      _events = song.events;
      _currentSongTitle = song.title;
      _savedSongs = [..._savedSongs, song];
      _errorText = null;
    });

    await _persistUserSongs();
  }

  Future<void> _playCurrentSong() async {
    if (_events.isEmpty) {
      return;
    }

    try {
      setState(() => _errorText = null);
      if (_ble.isConnected) {
        await _ble.transmitSong(_events, tempoMultiplier: _tempoMultiplier);
      } else {
        await _ble.previewSong(_events, tempoMultiplier: _tempoMultiplier);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _errorText = error.toString());
    }
  }

  Future<void> _stopPlayback() async {
    try {
      await _ble.stopPlayback();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _errorText = error.toString());
    }
  }

  Future<void> _playSavedSong(SavedSong song) async {
    setState(() {
      _events = song.events;
      _currentSongTitle = song.title;
      _errorText = null;
    });
    await _playCurrentSong();
  }

  Future<void> _saveCurrentSong() async {
    if (_events.isEmpty) {
      setState(() => _errorText = 'Load or generate a song before saving.');
      return;
    }

    final title = await showDialog<String>(
      context: context,
      builder: (context) => SaveSongDialog(initialTitle: _currentSongTitle),
    );
    final trimmedTitle = title?.trim();
    if (trimmedTitle == null || trimmedTitle.isEmpty) {
      return;
    }

    final song = SavedSong(
      title: trimmedTitle,
      source: _currentSongTitle,
      events: _events,
    );

    setState(() {
      _savedSongs = [..._savedSongs, song];
      _currentSongTitle = song.title;
      _errorText = null;
    });

    await _persistUserSongs();
  }

  Future<void> _renameSavedSong(SavedSong song) async {
    if (song.isBuiltIn) {
      return;
    }

    final title = await showDialog<String>(
      context: context,
      builder: (context) => SaveSongDialog(
        initialTitle: song.title,
        dialogTitle: 'Rename song',
        confirmLabel: 'Rename',
      ),
    );
    final trimmedTitle = title?.trim();
    if (trimmedTitle == null || trimmedTitle.isEmpty) {
      return;
    }

    final index = _savedSongs.indexOf(song);
    if (index == -1) {
      return;
    }

    final updatedSong = song.copyWith(title: trimmedTitle);
    final updatedSongs = [..._savedSongs];
    updatedSongs[index] = updatedSong;

    setState(() {
      _savedSongs = updatedSongs;
      if (identical(_events, song.events) || _currentSongTitle == song.title) {
        _currentSongTitle = updatedSong.title;
      }
      _errorText = null;
    });

    await _persistUserSongs();
  }

  Future<void> _deleteSavedSong(SavedSong song) async {
    if (song.isBuiltIn) {
      return;
    }

    setState(() {
      _savedSongs = _savedSongs
          .where((candidate) => candidate != song)
          .toList();
      if (identical(_events, song.events) || _currentSongTitle == song.title) {
        _currentSongTitle = _events.isEmpty ? 'No song loaded' : 'Unsaved song';
      }
    });
    await _persistUserSongs();
  }

  Future<void> _triggerHole(int index) async {
    try {
      await _ble.toggleHole(index);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _errorText = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _ble,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.asset(
                    'assets/images/recorder_icon.png',
                    width: 32,
                    height: 32,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(appTitle),
              ],
            ),
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 32,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ConnectionStatusBar(
                          controller: _ble,
                          onScanConnect: _openConnectionPicker,
                          onDisconnect: _ble.disconnect,
                        ),
                        const SizedBox(height: 16),
                        SourceInputPanel(
                          isBusy: _isImporting,
                          onImportPhotos: _importSheetPhotos,
                          onManualMode: _openManualMode,
                        ),
                        if (_errorText != null) ...[
                          const SizedBox(height: 12),
                          ErrorBanner(message: _errorText!),
                        ],
                        const SizedBox(height: 16),
                        MelodySummary(events: _events),
                        const SizedBox(height: 16),
                        TransportPanel(
                          title: _currentSongTitle,
                          tempoMultiplier: _tempoMultiplier,
                          hasSong: _events.isNotEmpty,
                          isPlaying: _ble.isPlaying,
                          onTempoChanged: (value) {
                            setState(() => _tempoMultiplier = value);
                          },
                          onPlay: _playCurrentSong,
                          onStop: _stopPlayback,
                          onSave: _saveCurrentSong,
                        ),
                        const SizedBox(height: 16),
                        SongLibraryPanel(
                          songs: _savedSongs,
                          isLoading: _isLoadingSongs,
                          onPlaySong: _playSavedSong,
                          onRenameSong: _renameSavedSong,
                          onDeleteSong: _deleteSavedSong,
                        ),
                        const SizedBox(height: 16),
                        BreathGuide(
                          breath: _ble.activeBreath,
                          note: _ble.activeNote,
                        ),
                        const SizedBox(height: 16),
                        FingeringMonitor(
                          activeHoles: _ble.activeHoles,
                          onTriggerHole: _triggerHole,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class ConnectionStatusBar extends StatelessWidget {
  const ConnectionStatusBar({
    required this.controller,
    required this.onScanConnect,
    required this.onDisconnect,
    super.key,
  });

  final BleRecorderController controller;
  final VoidCallback onScanConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isBusy =
        controller.status == RecorderConnectionStatus.scanning ||
        controller.status == RecorderConnectionStatus.connecting;

    return Panel(
      child: Row(
        children: [
          StatusDot(status: controller.status),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.status.label,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  controller.statusDetail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (controller.isConnected)
            OutlinedButton.icon(
              onPressed: onDisconnect,
              icon: const Icon(Icons.link_off),
              label: const Text('Disconnect'),
            )
          else
            FilledButton.icon(
              onPressed: isBusy ? null : onScanConnect,
              icon: const Icon(Icons.bluetooth_searching),
              label: Text(isBusy ? 'Scanning' : 'Connect'),
            ),
        ],
      ),
    );
  }
}

class SourceInputPanel extends StatelessWidget {
  const SourceInputPanel({
    required this.isBusy,
    required this.onImportPhotos,
    required this.onManualMode,
    super.key,
  });

  final bool isBusy;
  final VoidCallback onImportPhotos;
  final VoidCallback onManualMode;

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          FilledButton.icon(
            onPressed: isBusy ? null : onImportPhotos,
            icon: isBusy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.photo_library),
            label: Text(isBusy ? 'Reading photos' : 'Sheet photos'),
          ),
          OutlinedButton.icon(
            onPressed: isBusy ? null : onManualMode,
            icon: const Icon(Icons.touch_app),
            label: const Text('Manual'),
          ),
        ],
      ),
    );
  }
}

class TransportPanel extends StatelessWidget {
  const TransportPanel({
    required this.title,
    required this.tempoMultiplier,
    required this.hasSong,
    required this.isPlaying,
    required this.onTempoChanged,
    required this.onPlay,
    required this.onStop,
    required this.onSave,
    super.key,
  });

  final String title;
  final double tempoMultiplier;
  final bool hasSong;
  final bool isPlaying;
  final ValueChanged<double> onTempoChanged;
  final VoidCallback onPlay;
  final VoidCallback onStop;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tempoPercent = (tempoMultiplier * 100).round();

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Current song',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: hasSong && !isPlaying ? onPlay : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play'),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Stop',
                    onPressed: isPlaying ? onStop : null,
                    icon: const Icon(Icons.stop),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.speed, color: scheme.secondary),
              const SizedBox(width: 8),
              Text(
                '$tempoPercent%',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Expanded(
                child: Slider(
                  min: 0.5,
                  max: 1.8,
                  divisions: 26,
                  value: tempoMultiplier,
                  label: '$tempoPercent%',
                  activeColor: CobanColors.burgundy,
                  inactiveColor: scheme.outlineVariant,
                  onChanged: onTempoChanged,
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: hasSong ? onSave : null,
              icon: const Icon(Icons.bookmark_add),
              label: const Text('Save song'),
            ),
          ),
        ],
      ),
    );
  }
}

class SongLibraryPanel extends StatelessWidget {
  const SongLibraryPanel({
    required this.songs,
    required this.isLoading,
    required this.onPlaySong,
    required this.onRenameSong,
    required this.onDeleteSong,
    super.key,
  });

  final List<SavedSong> songs;
  final bool isLoading;
  final ValueChanged<SavedSong> onPlaySong;
  final ValueChanged<SavedSong> onRenameSong;
  final ValueChanged<SavedSong> onDeleteSong;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Panel(
      tone: PanelTone.low,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Saved songs',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Chip(
                label: Text(isLoading ? 'Loading' : '${songs.length}'),
                avatar: const Icon(Icons.library_music, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (isLoading)
            const LinearProgressIndicator()
          else if (songs.isEmpty)
            Text(
              'No songs saved yet.',
              style: Theme.of(context).textTheme.bodyMedium,
            )
          else
            ...songs.map(
              (song) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  song.isBuiltIn ? Icons.star : Icons.music_note,
                  color: song.isBuiltIn ? CobanColors.gold : scheme.secondary,
                ),
                title: Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${song.events.length} events'),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    IconButton(
                      tooltip: 'Play',
                      onPressed: () => onPlaySong(song),
                      icon: const Icon(Icons.play_arrow),
                    ),
                    if (!song.isBuiltIn) ...[
                      IconButton(
                        tooltip: 'Rename',
                        onPressed: () => onRenameSong(song),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        onPressed: () => onDeleteSong(song),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class SaveSongDialog extends StatefulWidget {
  const SaveSongDialog({
    required this.initialTitle,
    this.dialogTitle = 'Save song',
    this.confirmLabel = 'Save',
    super.key,
  });

  final String initialTitle;
  final String dialogTitle;
  final String confirmLabel;

  @override
  State<SaveSongDialog> createState() => _SaveSongDialogState();
}

class _SaveSongDialogState extends State<SaveSongDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialTitle == 'No song loaded' ? '' : widget.initialTitle,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.dialogTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Song name',
          prefixIcon: Icon(Icons.library_music),
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

enum _ManualSongStage { timing, fingerings }

class ManualSongDialog extends StatefulWidget {
  const ManualSongDialog({super.key});

  @override
  State<ManualSongDialog> createState() => _ManualSongDialogState();
}

class _ManualSongDialogState extends State<ManualSongDialog> {
  final _stopwatch = Stopwatch();
  final _delayDivisorController = TextEditingController(text: '1');
  final _delays = <int>[];
  List<_ManualFingeringStep> _steps = const [];
  _ManualSongStage _stage = _ManualSongStage.timing;
  int? _lastTapMs;
  double _delayDivisor = 1;

  @override
  void dispose() {
    _stopwatch.stop();
    _delayDivisorController.dispose();
    super.dispose();
  }

  void _recordTap() {
    if (!_stopwatch.isRunning) {
      _stopwatch.start();
    }

    final now = _stopwatch.elapsedMilliseconds;
    final previous = _lastTapMs;
    setState(() {
      if (previous != null) {
        _delays.add((now - previous).clamp(40, 30000).toInt());
      }
      _lastTapMs = now;
    });
  }

  void _saveDelays() {
    setState(() {
      _steps = _delays
          .map(
            (delay) => _ManualFingeringStep(
              durationMs: _adjustedDelayMs(delay),
              holes: List.filled(solenoidPins.length, 0),
            ),
          )
          .toList(growable: false);
      _stage = _ManualSongStage.fingerings;
    });
  }

  void _setDelayDivisor(double value) {
    final safeValue = _cleanDelayDivisor(value);
    _delayDivisorController.text = _formatDivisor(safeValue);
    _delayDivisorController.selection = TextSelection.collapsed(
      offset: _delayDivisorController.text.length,
    );
    setState(() => _delayDivisor = safeValue);
  }

  void _handleDelayDivisorChanged(String value) {
    final parsed = double.tryParse(value.replaceAll(',', '.'));
    if (parsed == null) {
      return;
    }
    setState(() => _delayDivisor = _cleanDelayDivisor(parsed));
  }

  double _cleanDelayDivisor(double value) {
    if (!value.isFinite || value <= 0) {
      return 1;
    }
    return value.clamp(0.1, 32).toDouble();
  }

  int _adjustedDelayMs(int rawDelayMs) {
    return (rawDelayMs / _cleanDelayDivisor(_delayDivisor))
        .round()
        .clamp(40, 30000)
        .toInt();
  }

  String _formatDivisor(double value) {
    if (value == value.roundToDouble()) {
      return value.round().toString();
    }
    return value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  void _toggleHole(int stepIndex, int holeIndex) {
    final step = _steps[stepIndex];
    final holes = List<int>.from(step.holes);
    holes[holeIndex] = holes[holeIndex] == 1 ? 0 : 1;

    final updatedSteps = [..._steps];
    updatedSteps[stepIndex] = step.copyWith(holes: holes);
    setState(() => _steps = updatedSteps);
  }

  void _updateStepDuration(int stepIndex, int durationMs) {
    final step = _steps[stepIndex];
    final updatedSteps = [..._steps];
    updatedSteps[stepIndex] = step.copyWith(
      durationMs: durationMs.clamp(40, 30000).toInt(),
    );
    setState(() => _steps = updatedSteps);
  }

  void _deleteStep(int index) {
    final updatedSteps = [..._steps]..removeAt(index);
    setState(() => _steps = updatedSteps);
  }

  void _saveSong() {
    final events = _steps.map((step) => step.toEvent()).toList(growable: false);
    Navigator.of(context).pop(events);
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.72;
    final isTiming = _stage == _ManualSongStage.timing;

    return AlertDialog(
      title: Text(isTiming ? 'Manual timing' : 'Manual fingerings'),
      content: SizedBox(
        width: double.maxFinite,
        height: maxHeight.clamp(380.0, 620.0),
        child: isTiming ? _buildTimingStage(context) : _buildFingeringStage(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Discard'),
        ),
        if (isTiming)
          FilledButton.icon(
            onPressed: _delays.isEmpty ? null : _saveDelays,
            icon: const Icon(Icons.check),
            label: const Text('Save delays'),
          )
        else
          FilledButton.icon(
            onPressed: _steps.isEmpty ? null : _saveSong,
            icon: const Icon(Icons.save),
            label: const Text('Save song'),
          ),
      ],
    );
  }

  Widget _buildTimingStage(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tapText = _lastTapMs == null ? 'Tap' : 'Tap again';
    final divisor = _cleanDelayDivisor(_delayDivisor);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: CobanColors.linen,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: _delays.isEmpty
                ? Center(
                    child: Text(
                      _lastTapMs == null
                          ? 'First tap starts timing'
                          : 'Second tap saves delay 1',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _delays.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      return _ManualDelayTile(
                        index: index,
                        rawDurationMs: _delays[index],
                        adjustedDurationMs: _adjustedDelayMs(_delays[index]),
                      );
                    },
                  ),
          ),
        ),
        const SizedBox(height: 12),
        _DelayDividerControl(
          controller: _delayDivisorController,
          divisor: divisor,
          onChanged: _handleDelayDivisorChanged,
          onPreset: _setDelayDivisor,
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 118,
          child: FilledButton(
            onPressed: _recordTap,
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(
              tapText,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: scheme.onPrimary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFingeringStage() {
    return _steps.isEmpty
        ? const Center(child: Text('No delays left.'))
        : ListView.separated(
            itemCount: _steps.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final step = _steps[index];
              return _ManualFingeringStepTile(
                index: index,
                step: step,
                onToggleHole: (holeIndex) => _toggleHole(index, holeIndex),
                onDurationChanged: (durationMs) =>
                    _updateStepDuration(index, durationMs),
                onDelete: () => _deleteStep(index),
              );
            },
          );
  }
}

class _DelayDividerControl extends StatelessWidget {
  const _DelayDividerControl({
    required this.controller,
    required this.divisor,
    required this.onChanged,
    required this.onPreset,
  });

  final TextEditingController controller;
  final double divisor;
  final ValueChanged<String> onChanged;
  final ValueChanged<double> onPreset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 138,
              child: TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Divide by',
                  prefixIcon: Icon(Icons.compress),
                ),
                onChanged: onChanged,
              ),
            ),
            _DelayPresetButton(
              label: '1',
              value: 1,
              selected: divisor == 1,
              onPressed: onPreset,
            ),
            _DelayPresetButton(
              label: '2',
              value: 2,
              selected: divisor == 2,
              onPressed: onPreset,
            ),
            _DelayPresetButton(
              label: '4',
              value: 4,
              selected: divisor == 4,
              onPressed: onPreset,
            ),
          ],
        ),
      ),
    );
  }
}

class _DelayPresetButton extends StatelessWidget {
  const _DelayPresetButton({
    required this.label,
    required this.value,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final double value;
  final bool selected;
  final ValueChanged<double> onPressed;

  @override
  Widget build(BuildContext context) {
    return selected
        ? FilledButton(onPressed: () => onPressed(value), child: Text(label))
        : OutlinedButton(onPressed: () => onPressed(value), child: Text(label));
  }
}

class _ManualDelayTile extends StatelessWidget {
  const _ManualDelayTile({
    required this.index,
    required this.rawDurationMs,
    required this.adjustedDurationMs,
  });

  final int index;
  final int rawDurationMs;
  final int adjustedDurationMs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isAdjusted = rawDurationMs != adjustedDurationMs;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Delay ${index + 1}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            Text(
              '$adjustedDurationMs ms',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: CobanColors.burgundy,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (isAdjusted) ...[
              const SizedBox(width: 8),
              Text(
                'raw $rawDurationMs',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ManualFingeringStepTile extends StatelessWidget {
  const _ManualFingeringStepTile({
    required this.index,
    required this.step,
    required this.onToggleHole,
    required this.onDurationChanged,
    required this.onDelete,
  });

  final int index;
  final _ManualFingeringStep step;
  final ValueChanged<int> onToggleHole;
  final ValueChanged<int> onDurationChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final holeEditor = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Alignment ${index + 1}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                Row(
                  children: List.generate(solenoidPins.length, (holeIndex) {
                    final isActive = step.holes[holeIndex] == 1;
                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: holeIndex == solenoidPins.length - 1 ? 0 : 6,
                        ),
                        child: _ManualHoleButton(
                          index: holeIndex,
                          isActive: isActive,
                          onTap: () => onToggleHole(holeIndex),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            );
            final delayControls = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ManualDurationField(
                  durationMs: step.durationMs,
                  onChanged: onDurationChanged,
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Delete alignment',
                  onPressed: onDelete,
                  icon: const Icon(Icons.close),
                ),
              ],
            );

            if (constraints.maxWidth < 420) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  holeEditor,
                  const SizedBox(height: 10),
                  Align(alignment: Alignment.centerRight, child: delayControls),
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: holeEditor),
                const SizedBox(width: 10),
                delayControls,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ManualHoleButton extends StatelessWidget {
  const _ManualHoleButton({
    required this.index,
    required this.isActive,
    required this.onTap,
  });

  final int index;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 58,
          decoration: BoxDecoration(
            color: isActive ? CobanColors.burgundy : CobanColors.ivory,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isActive ? CobanColors.burgundy : scheme.outlineVariant,
              width: isActive ? 2 : 1,
            ),
          ),
          child: Center(
            child: Text(
              '${index + 1}',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: isActive ? Colors.white : CobanColors.ink,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ManualDurationField extends StatefulWidget {
  const _ManualDurationField({
    required this.durationMs,
    required this.onChanged,
  });

  final int durationMs;
  final ValueChanged<int> onChanged;

  @override
  State<_ManualDurationField> createState() => _ManualDurationFieldState();
}

class _ManualDurationFieldState extends State<_ManualDurationField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.durationMs.toString());
    _focusNode = FocusNode()..addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _ManualDurationField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.durationMs != widget.durationMs && !_focusNode.hasFocus) {
      _setControllerText(widget.durationMs.toString());
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _setControllerText(String value) {
    _controller.text = value;
    _controller.selection = TextSelection.collapsed(offset: value.length);
  }

  int? _parseDuration(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null) {
      return null;
    }
    return parsed.clamp(40, 30000).toInt();
  }

  void _handleTextChanged(String value) {
    final durationMs = _parseDuration(value);
    if (durationMs != null) {
      widget.onChanged(durationMs);
    }
  }

  void _handleFocusChanged() {
    if (_focusNode.hasFocus) {
      return;
    }
    final durationMs = _parseDuration(_controller.text) ?? widget.durationMs;
    widget.onChanged(durationMs);
    _setControllerText(durationMs.toString());
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 112,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textAlign: TextAlign.center,
        decoration: const InputDecoration(
          labelText: 'Duration',
          suffixText: 'ms',
          isDense: true,
        ),
        onChanged: _handleTextChanged,
      ),
    );
  }
}

class DevicePickerDialog extends StatelessWidget {
  const DevicePickerDialog({required this.devices, super.key});

  final List<ScannedRecorderDevice> devices;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connect'),
      content: SizedBox(
        width: double.maxFinite,
        child: devices.isEmpty
            ? const Text('No BLE devices found.')
            : ListView.separated(
                shrinkWrap: true,
                itemCount: devices.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final device = devices[index];
                  return ListTile(
                    leading: Icon(
                      device.isLikelyCoban ? Icons.music_note : Icons.bluetooth,
                    ),
                    title: Text(device.name),
                    subtitle: Text(
                      '${device.remoteId}  •  RSSI ${device.rssi}',
                    ),
                    trailing: device.isLikelyCoban
                        ? const Icon(Icons.check_circle)
                        : null,
                    onTap: () => Navigator.of(context).pop(device),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
      ),
    );
  }
}

class MelodySummary extends StatelessWidget {
  const MelodySummary({required this.events, super.key});

  final List<FingeringEvent> events;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeLimitOk = events.every(
      (event) => event.activeCount <= maxActiveSolenoids,
    );

    return Panel(
      tone: PanelTone.low,
      child: Row(
        children: [
          Icon(
            activeLimitOk ? Icons.verified : Icons.warning_amber,
            color: activeLimitOk ? CobanColors.softGreen : scheme.error,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              events.isEmpty
                  ? 'No melody loaded'
                  : '${events.length} events ready',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class BreathGuide extends StatelessWidget {
  const BreathGuide({required this.breath, required this.note, super.key});

  final double breath;
  final String note;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final normalizedBreath = breath.clamp(0.0, 1.0).toDouble();
    final breathPercent = (normalizedBreath * 100).round();
    final isResting = breathPercent == 0 || note == 'REST';
    final fillColor = _breathColor(normalizedBreath, isResting);

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Breath',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Chip(
                avatar: Icon(
                  isResting ? Icons.pause_circle : Icons.air,
                  size: 18,
                  color: isResting ? scheme.outline : fillColor,
                ),
                label: Text(isResting ? 'Rest' : '$breathPercent%'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 220,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: CobanColors.linen,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: AnimatedFractionallySizedBox(
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeInOutCubic,
                          heightFactor: isResting ? 0 : normalizedBreath,
                          widthFactor: 1,
                          alignment: Alignment.bottomCenter,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: fillColor,
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  width: 88,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _BreathMark(label: 'Hard', color: CobanColors.red),
                      _BreathMark(label: 'Medium', color: CobanColors.gold),
                      _BreathMark(label: 'Low', color: CobanColors.softGreen),
                      _BreathMark(label: 'Off', color: scheme.outlineVariant),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            note,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Color _breathColor(double value, bool isResting) {
    if (isResting) {
      return Colors.transparent;
    }
    if (value < 0.43) {
      return CobanColors.softGreen;
    }
    if (value < 0.72) {
      return CobanColors.gold;
    }
    return CobanColors.red;
  }
}

class _BreathMark extends StatelessWidget {
  const _BreathMark({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    );
  }
}

class FingeringMonitor extends StatelessWidget {
  const FingeringMonitor({
    required this.activeHoles,
    required this.onTriggerHole,
    super.key,
  });

  final List<int> activeHoles;
  final ValueChanged<int> onTriggerHole;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeCount = activeHoles.where((value) => value == 1).length;
    final isSafe = activeCount <= maxActiveSolenoids;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Fingering',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Chip(
                avatar: Icon(
                  isSafe ? Icons.check_circle : Icons.error,
                  size: 18,
                  color: isSafe ? CobanColors.softGreen : scheme.error,
                ),
                label: Text('$activeCount / $maxActiveSolenoids'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 1.15,
            ),
            itemCount: solenoidPins.length,
            itemBuilder: (context, index) {
              return HoleTile(
                index: index,
                pin: solenoidPins[index],
                isActive: activeHoles[index] == 1,
                onTap: () => onTriggerHole(index),
              );
            },
          ),
        ],
      ),
    );
  }
}

class HoleTile extends StatelessWidget {
  const HoleTile({
    required this.index,
    required this.pin,
    required this.isActive,
    required this.onTap,
    super.key,
  });

  final int index;
  final int pin;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: isActive
                ? scheme.primaryContainer
                : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isActive ? CobanColors.burgundy : scheme.outlineVariant,
              width: isActive ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive ? CobanColors.burgundy : CobanColors.ivory,
                  border: Border.all(color: scheme.outline),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Hole ${index + 1}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Text('GPIO $pin', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

enum PanelTone { normal, low }

class Panel extends StatelessWidget {
  const Panel({required this.child, this.tone = PanelTone.normal, super.key});

  final Widget child;
  final PanelTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone == PanelTone.normal
            ? scheme.surfaceContainerLowest
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(padding: const EdgeInsets.all(12), child: child),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({required this.status, super.key});

  final RecorderConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      RecorderConnectionStatus.connected => CobanColors.softGreen,
      RecorderConnectionStatus.scanning => CobanColors.gold,
      RecorderConnectionStatus.connecting => CobanColors.gold,
      RecorderConnectionStatus.disconnected => scheme.outline,
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 14,
      height: 14,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}
