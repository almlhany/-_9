import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:alarm/alarm.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const blue = Color(0xFF1E6BFF), sky = Color(0xFF5CC8FF), ink = Color(0xFF0B2A5B), mute = Color(0xFF6B83A8), bg = Color(0xFFF3F8FF);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alarm.init();
  runApp(const SkyApp());
}

class Tone {
  final String name, path;
  Tone(this.name, this.path);
}

class Al {
  int id, h, m;
  String label, tone;
  bool on;
  Al(this.id, this.h, this.m, this.label, this.tone, this.on);
  Map<String, dynamic> toJson() => {'id': id, 'h': h, 'm': m, 'l': label, 't': tone, 'on': on};
  factory Al.fromJson(Map<String, dynamic> j) => Al(j['id'], j['h'], j['m'], j['l'], j['t'], j['on']);
}

Uint8List _wav(List<List<double>> notes, double total) {
  const sr = 22050;
  final n = (sr * total).toInt();
  final pcm = Int16List(n);
  for (final nt in notes) {
    final s0 = (nt[1] * sr).toInt(), len = (nt[2] * sr).toInt();
    for (var i = 0; i < len && s0 + i < n; i++) {
      final t = i / sr;
      final env = min(1.0, i / (sr * 0.01)) * exp(-3 * t / nt[2]);
      pcm[s0 + i] = (pcm[s0 + i] + (sin(2 * pi * nt[0] * t) * env * 14000).toInt()).clamp(-32768, 32767).toInt();
    }
  }
  final data = pcm.buffer.asUint8List();
  final h = ByteData(44);
  void s(int o, String t) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(o + i, t.codeUnitAt(i));
    }
  }
  s(0, 'RIFF');
  h.setUint32(4, 36 + data.length, Endian.little);
  s(8, 'WAVE');
  s(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, sr, Endian.little);
  h.setUint32(28, sr * 2, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  s(36, 'data');
  h.setUint32(40, data.length, Endian.little);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...data]);
}

class SkyApp extends StatelessWidget {
  const SkyApp({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'منبّه السماء',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: blue, scaffoldBackgroundColor: bg),
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<Al> alarms = [];
  List<Tone> tones = [];
  Timer? _t;
  DateTime now = DateTime.now();
  SharedPreferences? sp;
  late Directory dir;
  bool ready = false;

  @override
  void initState() {
    super.initState();
    _init();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => now = DateTime.now()));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await [Permission.notification, Permission.scheduleExactAlarm].request();
    } catch (_) {}
    sp = await SharedPreferences.getInstance();
    dir = Directory('${(await getApplicationDocumentsDirectory()).path}/tones');
    await dir.create(recursive: true);
    final built = <String, Uint8List>{
      'كلاسيكي': _wav([[880, 0, .3], [880, .4, .3], [880, .8, .3]], 2.0),
      'نسيم': _wav([[523, 0, .6], [659, .4, .6], [784, .8, .6], [1047, 1.2, .9]], 2.5),
      'شروق': _wav([[400, 0, .3], [500, .25, .3], [600, .5, .3], [800, .75, .5]], 1.8),
      'نجوم': _wav([[784, 0, .3], [988, .2, .3], [1175, .4, .3], [1568, .6, .4], [1175, .9, .5]], 2.2),
    };
    var i = 0;
    for (final e in built.entries) {
      final f = File('${dir.path}/b_${i++}.wav');
      if (!await f.exists()) await f.writeAsBytes(e.value);
      tones.add(Tone(e.key, f.path));
    }
    for (final s in sp!.getStringList('cu') ?? []) {
      final p = s.split('\t');
      if (p.length == 2 && await File(p[1]).exists()) tones.add(Tone(p[0], p[1]));
    }
    final raw = sp!.getString('al');
    if (raw != null) {
      alarms = (jsonDecode(raw) as List).map((e) => Al.fromJson(e)).toList();
    }
    for (final a in alarms.where((a) => a.on)) {
      await _arm(a);
    }
    setState(() => ready = true);
  }

  Future<void> _save() async => sp?.setString('al', jsonEncode(alarms.map((a) => a.toJson()).toList()));

  // يضبط المنبّه للأيام السبعة القادمة (ويتجدد كلما فتحت التطبيق)
  Future<void> _arm(Al a) async {
    final n = DateTime.now();
    for (var d = 0; d < 7; d++) {
      final t = DateTime(n.year, n.month, n.day + d, a.h, a.m);
      if (!t.isAfter(n)) continue;
      await Alarm.set(
        alarmSettings: AlarmSettings(
          id: a.id * 10 + d,
          dateTime: t,
          assetAudioPath: a.tone,
          loopAudio: true,
          vibrate: true,
          androidFullScreenIntent: true,
          volumeSettings: VolumeSettings.fade(volume: 0.9, fadeDuration: const Duration(seconds: 3), volumeEnforced: true),
          notificationSettings: NotificationSettings(
            title: a.label.isEmpty ? 'منبّه' : a.label,
            body: 'حان الوقت!',
            stopButton: 'إيقاف',
          ),
        ),
      );
    }
  }

  Future<void> _disarm(Al a) async {
    for (var d = 0; d < 7; d++) {
      await Alarm.stop(a.id * 10 + d);
    }
  }

  String _toneName(String p) => tones.firstWhere((t) => t.path == p, orElse: () => Tone('نغمة', '')).name;

  Future<Tone?> _pickTone() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.audio);
    final f = r?.files.single;
    if (f?.path == null) return null;
    final dest = File('${dir.path}/c_${DateTime.now().millisecondsSinceEpoch}_${f!.name}');
    await File(f.path!).copy(dest.path);
    final nm = f.name.contains('.') ? f.name.substring(0, f.name.lastIndexOf('.')) : f.name;
    final t = Tone(nm, dest.path);
    tones.add(t);
    await sp!.setStringList('cu', [...(sp!.getStringList('cu') ?? []), '${t.name}\t${t.path}']);
    setState(() {});
    return t;
  }

  Future<void> _add() async {
    final tp = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (tp == null || !mounted) return;
    var sel = tones.first.path;
    final ctl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
      builder: (_) => StatefulBuilder(
        builder: (c, set) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(c).viewInsets.bottom + 20),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('منبّه ${tp.hour.toString().padLeft(2, '0')}:${tp.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: blue)),
              const SizedBox(height: 8),
              TextField(controller: ctl, decoration: const InputDecoration(hintText: 'اسم المنبّه (اختياري)')),
              const SizedBox(height: 12),
              const Text('نغمة الرنين', style: TextStyle(fontWeight: FontWeight.bold, color: ink)),
              ...tones.map((t) => RadioListTile<String>(
                  value: t.path, groupValue: sel, title: Text(t.name), onChanged: (v) => set(() => sel = v!))),
              OutlinedButton.icon(
                onPressed: () async {
                  final t = await _pickTone();
                  if (t != null) set(() => sel = t.path);
                },
                icon: const Icon(Icons.add),
                label: const Text('إضافة نغمة رنين من الجهاز'),
              ),
              const SizedBox(height: 12),
              SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('حفظ'))),
            ]),
          ),
        ),
      ),
    );
    if (ok != true) return;
    final id = alarms.isEmpty ? 1 : alarms.map((a) => a.id).reduce(max) + 1;
    final a = Al(id, tp.hour, tp.minute, ctl.text.trim(), sel, true);
    alarms.add(a);
    await _save();
    await _arm(a);
    setState(() {});
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم ضبط المنبّه ✓')));
  }

  static const days = ['الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'];
  static const months = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
  String p2(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final sorted = [...alarms]..sort((a, b) => (a.h * 60 + a.m).compareTo(b.h * 60 + b.m));
    return Scaffold(
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: GestureDetector(
        onTap: ready ? _add : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [blue, sky]),
            borderRadius: BorderRadius.circular(40),
            boxShadow: [BoxShadow(color: blue.withOpacity(.4), blurRadius: 20, offset: const Offset(0, 8))],
          ),
          child: const Text('＋ منبّه جديد', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
        ),
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 110), children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 30),
            decoration: BoxDecoration(
              gradient: const LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [blue, sky]),
              borderRadius: BorderRadius.circular(32),
              boxShadow: [BoxShadow(color: blue.withOpacity(.3), blurRadius: 24, offset: const Offset(0, 10))],
            ),
            child: Column(children: [
              const Text('منبّه السماء ✦', style: TextStyle(color: Colors.white70, fontSize: 15)),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text('${p2(now.hour)}:${p2(now.minute)}',
                    style: const TextStyle(color: Colors.white, fontSize: 72, fontWeight: FontWeight.w800)),
              ),
              Text('${days[now.weekday - 1]} ${now.day} ${months[now.month - 1]}',
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 24, 4, 12),
            child: Text('المنبّهات', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: ink)),
          ),
          if (sorted.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: Text('⏰\nلا توجد منبّهات بعد', textAlign: TextAlign.center, style: TextStyle(color: mute, fontSize: 16))),
            ),
          ...sorted.map((a) => Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: const Color(0xFFDBE8FF)),
                  boxShadow: [BoxShadow(color: blue.withOpacity(.08), blurRadius: 14, offset: const Offset(0, 6))],
                ),
                child: Row(children: [
                  Text('${p2(a.h)}:${p2(a.m)}',
                      style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: a.on ? blue : mute)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(a.label.isEmpty ? 'منبّه' : a.label, style: const TextStyle(fontSize: 15, color: ink)),
                      Text('🎵 ${_toneName(a.tone)}', style: const TextStyle(fontSize: 12, color: mute)),
                    ]),
                  ),
                  Switch(
                    value: a.on,
                    activeColor: blue,
                    onChanged: (v) async {
                      a.on = v;
                      await _save();
                      v ? await _arm(a) : await _disarm(a);
                      setState(() {});
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: mute),
                    onPressed: () async {
                      await _disarm(a);
                      alarms.remove(a);
                      await _save();
                      setState(() {});
                    },
                  ),
                ]),
              )),
        ]),
      ),
    );
  }
}