import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/flutter_map_maplibre.dart';
import 'package:archive/archive_io.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main()=>runApp(const App());
class App extends StatelessWidget{const App({super.key});@override Widget build(BuildContext c)=>MaterialApp(debugShowCheckedModeBanner:false,title:'RotaSim V3',theme:ThemeData(colorSchemeSeed:Colors.teal,useMaterial3:true,brightness:Brightness.dark),home:const Home());}
class Stop{final int index;final int sec;Stop(this.index,this.sec);Map<String,dynamic> toJson()=>{'i':index,'s':sec};}
class Home extends StatefulWidget{const Home({super.key});@override State<Home> createState()=>_Home();}
class _Home extends State<Home>{
 final mc=MapController(); final pts=<LatLng>[]; final stops=<Stop>[]; final undo=<LatLng>[]; final D=const Distance();
 int mapMode=0; // 0 Yol, 1 Uydu HD (Esri), 2 Güncel Uydu (NASA VIIRS)
 bool drawing=false,playing=false,smooth=true,freehandActive=false,autoEnd=true,routeFinished=false; int activePointers=0; LatLng? me; int playIndex=0; Timer? timer;
 DateTime start=DateTime.now(),end=DateTime.now().add(const Duration(hours:1));
 final speedC=TextEditingController(text:'5.0'),distanceC=TextEditingController();
 double get actualKm{double m=0;for(int i=1;i<pts.length;i++)m+=D(pts[i-1],pts[i]);return m/1000;}
 int get stopSec=>stops.fold(0,(a,b)=>a+b.sec);
 double get manualSpeed=>double.tryParse(speedC.text.replaceAll(',','.'))??0;
 double get effectiveKm=>double.tryParse(distanceC.text.replaceAll(',','.'))??actualKm;
 Duration get estimatedMove=>manualSpeed>0?Duration(seconds:((effectiveKm/manualSpeed)*3600).round()):Duration.zero;
 Duration get estimatedTotal=>estimatedMove+Duration(seconds:stopSec);
 DateTime get estimatedEnd=>start.add(estimatedTotal);
 String durationText(Duration d){final h=d.inHours;final m=d.inMinutes.remainder(60);final s=d.inSeconds.remainder(60);return '${h}sa ${m}dk ${s}sn';}
 bool get timeMismatch=>(end.difference(estimatedEnd).inSeconds).abs()>60;
 String get routeLabel=>DateFormat('dd.MM.yyyy • HH:mm:ss').format(start);
 void syncEnd(){if(autoEnd)end=estimatedEnd;}
 bool get nearStart=>pts.length>3&&D(pts.first,pts.last)<=25;

 @override void dispose(){timer?.cancel();speedC.dispose();distanceC.dispose();super.dispose();}
 void add(LatLng p){if(!drawing||routeFinished)return;setState((){pts.add(p);undo.clear();if(smooth&&pts.length>2){final a=pts[pts.length-3],b=pts[pts.length-2],d=pts.last;pts[pts.length-2]=LatLng((a.latitude+b.latitude*2+d.latitude)/4,(a.longitude+b.longitude*2+d.longitude)/4);}distanceC.text=actualKm.toStringAsFixed(2);syncEnd();});}
 void freehandPoint(Offset local){if(!drawing||!freehandActive||activePointers!=1)return;final p=mc.camera.screenOffsetToLatLng(local);if(pts.isNotEmpty&&D(pts.last,p)<2)return;add(p);}
 void clearRoute(){setState((){pts.clear();stops.clear();undo.clear();distanceC.clear();routeFinished=false;drawing=false;syncEnd();});}
 void finishHere(){if(pts.length<2)return;setState((){routeFinished=true;drawing=false;freehandActive=false;syncEnd();});}
 void closeAndFinish(){if(pts.length<3)return;setState((){if(D(pts.last,pts.first)>0.5)pts.add(pts.first);distanceC.text=actualKm.toStringAsFixed(2);routeFinished=true;drawing=false;freehandActive=false;syncEnd();});}
 void back(){if(pts.isEmpty)return;setState((){undo.add(pts.removeLast());stops.removeWhere((s)=>s.index>=pts.length);distanceC.text=actualKm.toStringAsFixed(2);});}
 void forward(){if(undo.isEmpty)return;setState((){pts.add(undo.removeLast());distanceC.text=actualKm.toStringAsFixed(2);});}
 Future<void> locate()async{
  if(!await Geolocator.isLocationServiceEnabled()){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Telefon konum servisini açın.')));return;}
  var p=await Geolocator.checkPermission();
  if(p==LocationPermission.denied)p=await Geolocator.requestPermission();
  if(p==LocationPermission.denied||p==LocationPermission.deniedForever){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Konum izni gerekli. Android izin ekranında Kesin konumu etkinleştirin.')));return;}
  try{
    final x=await Geolocator.getCurrentPosition(locationSettings:const LocationSettings(accuracy:LocationAccuracy.bestForNavigation,timeLimit:Duration(seconds:20)));
    if(!mounted)return;
    setState(()=>me=LatLng(x.latitude,x.longitude));
    mc.move(me!,18);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Konum doğruluğu: yaklaşık ±${x.accuracy.toStringAsFixed(0)} m')));
  }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Kesin konum alınamadı. GPS açık ve Kesin konum izni etkin olmalı.')));}
}
 Future<void> pick(bool a)async{final b=a?start:end;final d=await showDatePicker(context:context,initialDate:b,firstDate:DateTime(2020),lastDate:DateTime(2035));if(d==null||!mounted)return;final t=await showTimePicker(context:context,initialTime:TimeOfDay.fromDateTime(b));if(t==null||!mounted)return;
 final sc=TextEditingController(text:b.second.toString().padLeft(2,'0'));
 final ss=await showDialog<int>(context:context,builder:(x)=>AlertDialog(title:const Text('Saniye'),content:TextField(controller:sc,autofocus:true,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'0-59')),actions:[TextButton(onPressed:()=>Navigator.pop(x),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(x,(int.tryParse(sc.text)??0).clamp(0,59)),child:const Text('Tamam'))]));if(ss==null)return;setState((){final v=DateTime(d.year,d.month,d.day,t.hour,t.minute,ss);if(a){start=v;syncEnd();}else{end=v;autoEnd=false;}});}
 Future<void> stopAt(int i)async{
  final old=stops.where((s)=>s.index==i).toList();
  int sec=old.isEmpty?300:old.first.sec;
  final h=TextEditingController(text:(sec~/3600).toString());
  final m=TextEditingController(text:((sec%3600)~/60).toString());
  final s=TextEditingController(text:(sec%60).toString());
  final v=await showDialog<int>(context:context,builder:(x)=>AlertDialog(title:Text('Durak ${i+1}'),content:Row(children:[Expanded(child:TextField(controller:h,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Saat'))),const SizedBox(width:6),Expanded(child:TextField(controller:m,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Dakika'))),const SizedBox(width:6),Expanded(child:TextField(controller:s,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Saniye')))]),actions:[if(old.isNotEmpty)TextButton(onPressed:()=>Navigator.pop(x,-1),child:const Text('Durağı sil')),TextButton(onPressed:()=>Navigator.pop(x),child:const Text('İptal')),FilledButton(onPressed:(){final total=(int.tryParse(h.text)??0)*3600+(int.tryParse(m.text)??0)*60+(int.tryParse(s.text)??0);Navigator.pop(x,total);},child:Text(old.isEmpty?'Ekle':'Güncelle'))]));
  if(v==null)return;setState((){stops.removeWhere((e)=>e.index==i);if(v>0)stops.add(Stop(i,v));syncEnd();});
}
 void animate(){timer?.cancel();if(pts.isEmpty)return;setState((){playing=true;playIndex=0;});timer=Timer.periodic(const Duration(milliseconds:450),(t){if(playIndex>=pts.length-1){t.cancel();setState(()=>playing=false);}else setState(()=>playIndex++);});}
 String timeFor(int i){if(pts.length<2)return start.toUtc().toIso8601String();double total=0,at=0;for(int k=1;k<pts.length;k++){final q=D(pts[k-1],pts[k]);total+=q;if(k<=i)at+=q;}final move=end.difference(start).inSeconds-stopSec;var sec=(move.clamp(0,999999999)*(total==0?0:at/total)).round();for(final s in stops){if(s.index<=i)sec+=s.sec;}return start.add(Duration(seconds:sec)).toUtc().toIso8601String();}
 String gpx(){final b=StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="RotaSim V3" xmlns="http://www.topografix.com/GPX/1/1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd"><metadata><name>$routeLabel</name><time>${start.toUtc().toIso8601String()}</time></metadata><trk><name>$routeLabel</name><type>walking</type><trkseg>\n');for(int i=0;i<pts.length;i++)b.writeln('<trkpt lat="${pts[i].latitude.toStringAsFixed(7)}" lon="${pts[i].longitude.toStringAsFixed(7)}"><time>${timeFor(i)}</time></trkpt>');b.write('</trkseg></trk><rte><name>$routeLabel</name>');for(final p in pts)b.write('<rtept lat="${p.latitude.toStringAsFixed(7)}" lon="${p.longitude.toStringAsFixed(7)}"/>');b.write('</rte></gpx>');return b.toString();}
 String kml(){final coords=pts.map((p)=>'${p.longitude},${p.latitude},0').join(' ');return '<?xml version="1.0" encoding="UTF-8"?><kml xmlns="http://www.opengis.net/kml/2.2"><Document><Placemark><name>$routeLabel</name><LineString><coordinates>$coords</coordinates></LineString></Placemark></Document></kml>';}
 String? validateRoute(){if(pts.length<2)return 'Dışa aktarmak için en az 2 rota noktası gerekli.';if(manualSpeed<=0)return 'Hız 0’dan büyük olmalı.';if(effectiveKm<=0)return 'Mesafe 0’dan büyük olmalı.';if(!end.isAfter(start))return 'Bitiş zamanı başlangıçtan sonra olmalı.';for(final p in pts){if(p.latitude.abs()>90||p.longitude.abs()>180)return 'Geçersiz koordinat bulundu.';}return null;}
 Future<String> writeExport(String type)async{
  final err=validateRoute();if(err!=null)throw Exception(err);
  final dir=await getTemporaryDirectory();final stamp=DateFormat('yyyy-MM-dd HHmmss').format(end);
  String ext=type;List<int> bytes;
  if(type=='gpx-track'){ext='gpx';bytes=utf8.encode(gpxTrack());}
  else if(type=='gpx-route'){ext='gpx';bytes=utf8.encode(gpxRoute());}
  else if(type=='kml'){bytes=utf8.encode(kml());}
  else if(type=='geojson'){bytes=utf8.encode(geoJson());}
  else if(type=='csv'){bytes=utf8.encode(csv());}
  else if(type=='txt'){bytes=utf8.encode(txt());}
  else if(type=='json'||type=='rotasim'){ext=type=='rotasim'?'rotasim':'json';bytes=utf8.encode(routeJson());}
  else if(type=='bin'){bytes=binData();}
  else{throw Exception('Desteklenmeyen format');}
  final f=File('${dir.path}/$stamp.$ext');await f.writeAsBytes(bytes);return f.path;
 }
 String gpxTrack(){final b=StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="RotaSim V3" xmlns="http://www.topografix.com/GPX/1/1"><metadata><name>$routeLabel</name><time>${start.toUtc().toIso8601String()}</time></metadata><trk><name>$routeLabel</name><type>walking</type><trkseg>');for(int i=0;i<pts.length;i++)b.write('<trkpt lat="${pts[i].latitude.toStringAsFixed(7)}" lon="${pts[i].longitude.toStringAsFixed(7)}"><time>${timeFor(i)}</time></trkpt>');b.write('</trkseg></trk></gpx>');return b.toString();}
 String gpxRoute(){final b=StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="RotaSim V3" xmlns="http://www.topografix.com/GPX/1/1"><metadata><name>$routeLabel</name></metadata><rte><name>$routeLabel</name>');for(final p in pts)b.write('<rtept lat="${p.latitude.toStringAsFixed(7)}" lon="${p.longitude.toStringAsFixed(7)}"/>');b.write('</rte></gpx>');return b.toString();}
 String routeJson()=>jsonEncode({'format':'RotaSim V3','start':start.toIso8601String(),'end':end.toIso8601String(),'autoEnd':autoEnd,'speedKmh':manualSpeed,'distanceKm':effectiveKm,'points':pts.map((p)=>{'lat':p.latitude,'lon':p.longitude}).toList(),'stops':stops.map((e)=>e.toJson()).toList()});
 String geoJson()=>jsonEncode({'type':'FeatureCollection','features':[{'type':'Feature','properties':{'start':start.toIso8601String(),'end':end.toIso8601String(),'speedKmh':manualSpeed},'geometry':{'type':'LineString','coordinates':pts.map((p)=>[p.longitude,p.latitude]).toList()}}]});
 String csv(){final b=StringBuffer('index,latitude,longitude,time\\n');for(int i=0;i<pts.length;i++)b.writeln('$i,${pts[i].latitude.toStringAsFixed(7)},${pts[i].longitude.toStringAsFixed(7)},${timeFor(i)}');return b.toString();}
 String txt(){final b=StringBuffer('RotaSim V3\\nBaşlangıç: ${start.toIso8601String()}\\nBitiş: ${end.toIso8601String()}\\nMesafe: ${effectiveKm.toStringAsFixed(3)} km\\nHız: ${manualSpeed.toStringAsFixed(2)} km/sa\\nDurak: ${stops.length}\\n\\n');for(int i=0;i<pts.length;i++)b.writeln('${i+1}. ${pts[i].latitude.toStringAsFixed(7)}, ${pts[i].longitude.toStringAsFixed(7)}  ${timeFor(i)}');return b.toString();}
 List<int> binData(){final payload=utf8.encode(routeJson());return <int>[82,83,73,77,3,...payload];}
 Future<void> shareType(String type)async{try{final p=await writeExport(type);await Share.shareXFiles([XFile(p)]);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}}
 Future<void> shareZip()async{try{final types=['gpx-track','gpx-route','kml','geojson','csv','json','txt','bin','rotasim'];final files=<String>[];for(final t in types)files.add(await writeExport(t));final dir=await getTemporaryDirectory();final stamp=DateFormat('yyyy-MM-dd HHmmss').format(end);final zip='${dir.path}/$stamp.zip';final ar=Archive();for(final p in files){final f=File(p);final data=await f.readAsBytes();ar.addFile(ArchiveFile(p.split('/').last,data.length,data));}await File(zip).writeAsBytes(ZipEncoder().encode(ar));await Share.shareXFiles([XFile(zip)]);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}}
 void exportSheet(){showModalBottomSheet(context:context,builder:(x)=>SafeArea(child:Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[Text('GPX Track',style:Theme.of(context).textTheme.headlineSmall),const SizedBox(height:8),const Text('Çizdiğiniz rotayı zaman bilgileriyle GPX Track olarak paylaşır.'),const SizedBox(height:18),FilledButton.icon(onPressed:(){Navigator.pop(x);shareType('gpx-track');},icon:const Icon(Icons.ios_share),label:const Text('GPX Track Paylaş'))]))));}

 Future<void> save()async{final sp=await SharedPreferences.getInstance();final all=sp.getStringList('routes')??[];all.add(jsonEncode({'name':routeLabel,'pts':pts.map((p)=>[p.latitude,p.longitude]).toList(),'stops':stops.map((s)=>s.toJson()).toList(),'start':start.toIso8601String(),'end':end.toIso8601String(),'speed':speedC.text,'distance':distanceC.text}));await sp.setStringList('routes',all);if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Rota kaydedildi')));}
 Future<void> saved()async{final sp=await SharedPreferences.getInstance();final all=sp.getStringList('routes')??[];if(!mounted)return;showModalBottomSheet(context:context,builder:(x)=>ListView(children:[const ListTile(title:Text('Kayıtlı Rotalar')),for(final raw in all)ListTile(title:Text((jsonDecode(raw)['name']??'Rota').toString()),onTap:(){final j=jsonDecode(raw);setState((){pts..clear()..addAll((j['pts'] as List).map((e)=>LatLng((e[0] as num).toDouble(),(e[1] as num).toDouble())));stops..clear()..addAll((j['stops'] as List).map((e)=>Stop(e['i'],e['s'])));start=DateTime.parse(j['start']);end=DateTime.parse(j['end']);speedC.text=(j['speed']??'5.0').toString();distanceC.text=(j['distance']??actualKm.toStringAsFixed(2)).toString();});Navigator.pop(x);})]));}
 void preview(){showModalBottomSheet(context:context,isScrollControlled:true,builder:(x)=>Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[Text(routeLabel,style:Theme.of(context).textTheme.headlineSmall),const SizedBox(height:12),Text('Mesafe: ${actualKm.toStringAsFixed(2)} km'),Text('Manuel hız: ${manualSpeed.toStringAsFixed(1)} km/sa'),Text('Durak: ${stops.length} • Bekleme: ${durationText(Duration(seconds:stopSec))}'),Text('Tahmini hareket: ${durationText(estimatedMove)}'),Text('Tahmini toplam: ${durationText(estimatedTotal)}'),Text('Başlangıç: ${DateFormat('dd.MM.yyyy HH:mm:ss').format(start)}'),Text('Manuel bitiş: ${DateFormat('dd.MM.yyyy HH:mm:ss').format(end)}'),Text('Tahmini bitiş: ${DateFormat('dd.MM.yyyy HH:mm:ss').format(estimatedEnd)}'),if(timeMismatch)const Text('⚠ Seçilen bitiş, mesafe ve hıza göre tahmini bitişle uyuşmuyor.',style:TextStyle(color:Colors.orange)),const SizedBox(height:12),FilledButton(onPressed:()=>Navigator.pop(x),child:const Text('Tamam'))])));}
 @override Widget build(BuildContext c){final fmt=DateFormat('dd.MM.yyyy HH:mm:ss');return Scaffold(body:Stack(children:[
  Listener(onPointerDown:(e){activePointers++;if(drawing&&activePointers==1){freehandActive=true;freehandPoint(e.localPosition);}else{freehandActive=false;}},onPointerMove:(e){if(activePointers==1)freehandPoint(e.localPosition);},onPointerUp:(_){activePointers=(activePointers-1).clamp(0,10);freehandActive=false;},onPointerCancel:(_){activePointers=(activePointers-1).clamp(0,10);freehandActive=false;},child:FlutterMap(mapController:mc,options:MapOptions(initialCenter:const LatLng(39.93,32.86),initialZoom:12,onLongPress:(_,p){if(pts.isEmpty)return;int best=0;double bd=1e99;for(int i=0;i<pts.length;i++){final d=D(p,pts[i]);if(d<bd){bd=d;best=i;}}stopAt(best);}),children:[
   if(mapMode==0)const MapLibreLayer(initStyle:'https://tiles.openfreemap.org/styles/liberty'),
   if(mapMode==1)TileLayer(urlTemplate:'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',userAgentPackageName:'com.rotasim.rotasim'),
   if(mapMode==2)TileLayer(urlTemplate:'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/VIIRS_SNPP_CorrectedReflectance_TrueColor/default/${DateFormat('yyyy-MM-dd').format(DateTime.now().toUtc().subtract(const Duration(days:1)))}/GoogleMapsCompatible_Level9/{z}/{y}/{x}.jpg',userAgentPackageName:'com.rotasim.rotasim',maxNativeZoom:9),
   if(pts.isNotEmpty)PolylineLayer(polylines:[Polyline(points:pts,strokeWidth:6,color:Colors.cyanAccent)]),
   MarkerLayer(markers:[
    if(me!=null)Marker(point:me!,width:42,height:42,child:const Icon(Icons.my_location,color:Colors.lightBlueAccent,size:32)),
    for(int i=0;i<pts.length;i++)if(i==0||i==pts.length-1||stops.any((s)=>s.index==i))Marker(point:pts[i],width:42,height:42,child:GestureDetector(onTap:()=>stopAt(i),child:CircleAvatar(backgroundColor:i==0?Colors.green:i==pts.length-1?Colors.red:Colors.orange,child:Text(i==0?'B':i==pts.length-1?'S':'D')))),
    if(playing&&pts.isNotEmpty)Marker(point:pts[playIndex],width:48,height:48,child:const Icon(Icons.directions_walk,size:42,color:Colors.white)),
   ])
  ])),
  SafeArea(child:Padding(padding:const EdgeInsets.all(12),child:Row(children:[FilledButton.tonalIcon(onPressed:(){showModalBottomSheet(context:context,builder:(x)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[const ListTile(title:Text('Harita Görünümü')),ListTile(leading:const Icon(Icons.map_outlined),title:const Text('Yol'),subtitle:const Text('Standart yol haritası'),trailing:mapMode==0?const Icon(Icons.check):null,onTap:(){setState(()=>mapMode=0);Navigator.pop(x);}),ListTile(leading:const Icon(Icons.satellite_alt_outlined),title:const Text('Uydu HD'),subtitle:const Text('Esri World Imagery • yüksek detay'),trailing:mapMode==1?const Icon(Icons.check):null,onTap:(){setState(()=>mapMode=1);Navigator.pop(x);}),ListTile(leading:const Icon(Icons.public),title:const Text('Güncel Uydu'),subtitle:const Text('NASA VIIRS • yakın tarihli görüntü • düşük yakınlaştırma detayı'),trailing:mapMode==2?const Icon(Icons.check):null,onTap:(){setState(()=>mapMode=2);Navigator.pop(x);})])));},icon:Icon(mapMode==0?Icons.layers_outlined:Icons.satellite_alt_outlined),label:Text(mapMode==0?'Harita':mapMode==1?'Uydu HD':'Güncel')),const Spacer(),IconButton.filledTonal(onPressed:locate,tooltip:'Konumum',icon:const Icon(Icons.my_location)),const SizedBox(width:6),IconButton.filledTonal(onPressed:saved,tooltip:'Kayıtlı rotalar',icon:const Icon(Icons.folder_outlined))]))),
  Positioned(left:12,right:12,bottom:12,child:Card(elevation:8,clipBehavior:Clip.antiAlias,child:Padding(padding:const EdgeInsets.fromLTRB(14,10,14,12),child:Column(mainAxisSize:MainAxisSize.min,children:[
   Row(children:[Icon(drawing?Icons.edit_road:Icons.map_outlined),const SizedBox(width:8),Expanded(child:Text(drawing?'Çizim Modu':'Harita Modu',style:Theme.of(context).textTheme.titleMedium)),FilledButton.icon(onPressed:()=>setState((){drawing=!drawing;freehandActive=false;if(drawing)routeFinished=false;}),icon:Icon(drawing?Icons.pan_tool_alt:Icons.edit_road),label:Text(drawing?'Haritada Gezin':'Çizime Başla'))]),if(drawing)Row(mainAxisAlignment:MainAxisAlignment.end,children:[IconButton(onPressed:back,tooltip:'Geri al',icon:const Icon(Icons.undo)),IconButton(onPressed:forward,tooltip:'İleri al',icon:const Icon(Icons.redo)),IconButton(onPressed:clearRoute,tooltip:'Rotayı temizle',icon:const Icon(Icons.delete_outline))]),
   const SizedBox(height:6),Row(children:[Expanded(child:TextField(controller:distanceC,onChanged:(_)=>setState(syncEnd),keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Mesafe km',isDense:true))),const SizedBox(width:8),Expanded(child:TextField(controller:speedC,onChanged:(_)=>setState(syncEnd),keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Hız km/sa',isDense:true)))]),
   Row(children:[Expanded(child:TextButton(onPressed:()=>pick(true),child:Text('Başlangıç\n${fmt.format(start)}'))),Expanded(child:TextButton(onPressed:()=>pick(false),child:Text('${autoEnd?'Otomatik':'Manuel'} Bitiş\n${fmt.format(end)}'))),Switch(value:autoEnd,onChanged:(v)=>setState((){autoEnd=v;if(v)syncEnd();}))]),
   if(drawing&&pts.length>1)Row(children:[Expanded(child:FilledButton.tonalIcon(onPressed:finishHere,icon:const Icon(Icons.flag),label:const Text('Burada Bitir'))),if(nearStart)...[const SizedBox(width:8),Expanded(child:FilledButton.icon(onPressed:closeAndFinish,icon:const Icon(Icons.loop),label:const Text('Başlangıca Bağla')))]]) ,
   Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Expanded(child:Text('${actualKm.toStringAsFixed(2)} km • ${stops.length} durak\nTahmini ${durationText(estimatedTotal)} • ${DateFormat('HH:mm:ss').format(estimatedEnd)}',style:const TextStyle(fontSize:12))),Wrap(children:[IconButton(onPressed:animate,icon:Icon(playing?Icons.pause:Icons.play_arrow)),IconButton(onPressed:preview,icon:const Icon(Icons.visibility)),IconButton(onPressed:save,icon:const Icon(Icons.save)),IconButton(onPressed:exportSheet,icon:const Icon(Icons.ios_share))])]),
   Text(routeFinished?'Rota tamamlandı':drawing?'Tek parmak: çiz • İki parmak: yakınlaştır/kaydır':'Haritada serbestçe gezin • Rota çizilmez',style:const TextStyle(fontSize:11))
  ]))))
 ]));}
}