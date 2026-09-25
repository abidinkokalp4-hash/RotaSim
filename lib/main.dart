import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const RotaSimApp());

class RotaSimApp extends StatelessWidget {
  const RotaSimApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'RotaSim',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const RouteScreen(),
  );
}

class RouteScreen extends StatefulWidget {
  const RouteScreen({super.key});
  @override State<RouteScreen> createState() => _RouteScreenState();
}

class _RouteScreenState extends State<RouteScreen> {
  final points = <LatLng>[];
  DateTime start = DateTime.now();
  DateTime end = DateTime.now().add(const Duration(hours: 1));
  final dist = const Distance();

  double get km {
    double m = 0;
    for (var i=1;i<points.length;i++) { m += dist(points[i-1], points[i]); }
    return m/1000;
  }
  double get speed => end.isAfter(start) ? km/(end.difference(start).inSeconds/3600) : 0;

  Future<void> pick(bool isStart) async {
    final base = isStart ? start : end;
    final d = await showDatePicker(context: context, initialDate: base, firstDate: DateTime(2020), lastDate: DateTime(2035));
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(base));
    if (t == null) return;
    final v = DateTime(d.year,d.month,d.day,t.hour,t.minute);
    setState(() { if(isStart) start=v; else end=v; });
  }

  String gpx() {
    final total = points.length < 2 ? 1.0 : points.asMap().entries.skip(1).fold<double>(0,(s,e)=>s+dist(points[e.key-1],e.value));
    double acc=0;
    final b=StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="RotaSim" xmlns="http://www.topografix.com/GPX/1/1">\n<trk><name>RotaSim Rotasi</name><trkseg>\n');
    for(int i=0;i<points.length;i++) {
      if(i>0) acc += dist(points[i-1],points[i]);
      final ratio=total==0?0:acc/total;
      final ts=start.add(Duration(milliseconds:(end.difference(start).inMilliseconds*ratio).round())).toUtc().toIso8601String();
      b.writeln('<trkpt lat="${points[i].latitude}" lon="${points[i].longitude}"><time>$ts</time></trkpt>');
    }
    b.write('</trkseg></trk></gpx>'); return b.toString();
  }

  Future<void> export() async {
    if(points.length<2) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('En az iki rota noktasi ekleyin.'))); return; }
    if(!end.isAfter(start)) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Bitis zamani baslangictan sonra olmali.'))); return; }
    final dir=await getTemporaryDirectory();
    final f=File('${dir.path}/RotaSim_${DateFormat('yyyyMMdd_HHmm').format(start)}.gpx');
    await f.writeAsString(gpx());
    await Share.shareXFiles([XFile(f.path)], text:'RotaSim GPX rotasi');
  }

  @override Widget build(BuildContext context) {
    final fmt=DateFormat('dd.MM.yyyy HH:mm');
    return Scaffold(
      appBar: AppBar(title: const Text('RotaSim'), actions:[IconButton(onPressed: points.isEmpty?null:()=>setState(points.clear), icon:const Icon(Icons.delete_outline))]),
      body: Column(children:[
        Expanded(child: FlutterMap(options: MapOptions(initialCenter: const LatLng(39.93,32.86), initialZoom: 12, onTap:(_,p)=>setState(()=>points.add(p))), children:[
          TileLayer(urlTemplate:'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName:'com.rotasim.app'),
          if(points.isNotEmpty) PolylineLayer(polylines:[Polyline(points:points, strokeWidth:5)]),
          MarkerLayer(markers:points.asMap().entries.map((e)=>Marker(point:e.value,width:34,height:34,child:CircleAvatar(child:Text('${e.key+1}',style:const TextStyle(fontSize:11))))).toList()),
        ])),
        Padding(padding:const EdgeInsets.all(12),child:Column(children:[
          Row(children:[Expanded(child:OutlinedButton.icon(onPressed:()=>pick(true),icon:const Icon(Icons.play_arrow),label:Text('Baslangic\n${fmt.format(start)}'))),const SizedBox(width:8),Expanded(child:OutlinedButton.icon(onPressed:()=>pick(false),icon:const Icon(Icons.flag),label:Text('Bitis\n${fmt.format(end)}')))]),
          const SizedBox(height:8),
          Row(mainAxisAlignment:MainAxisAlignment.spaceAround,children:[Text('Mesafe: ${km.toStringAsFixed(2)} km'),Text('Ort. hiz: ${speed.toStringAsFixed(1)} km/sa')]),
          const SizedBox(height:8),
          SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:export,icon:const Icon(Icons.file_upload_outlined),label:const Text('Zaman Damgali GPX Olustur / Paylas'))),
          const SizedBox(height:4),const Text('Haritaya dokunarak rota noktalarini sirayla ekleyin.',style:TextStyle(fontSize:12)),
        ]))
      ]),
    );
  }
}