import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main()=>runApp(const App());
class App extends StatelessWidget{const App({super.key});@override Widget build(BuildContext c)=>MaterialApp(debugShowCheckedModeBanner:false,title:'RotaSim V2',theme:ThemeData(colorSchemeSeed:Colors.teal,useMaterial3:true,brightness:Brightness.dark),home:const Home());}
class Stop{final int index;final int sec;Stop(this.index,this.sec);Map<String,dynamic> toJson()=>{'i':index,'s':sec};}
class Home extends StatefulWidget{const Home({super.key});@override State<Home> createState()=>_Home();}
class _Home extends State<Home>{
 final mc=MapController(); final pts=<LatLng>[]; final stops=<Stop>[]; final undo=<LatLng>[]; final D=const Distance();
 bool sat=false,drawing=true,playing=false; LatLng? me; int playIndex=0; Timer? timer;
 DateTime start=DateTime.now(),end=DateTime.now().add(const Duration(hours:1));
 final speedC=TextEditingController(text:'5.0'),distanceC=TextEditingController(),nameC=TextEditingController(text:'Yeni Rota');
 double get actualKm{double m=0;for(int i=1;i<pts.length;i++)m+=D(pts[i-1],pts[i]);return m/1000;}
 int get stopSec=>stops.fold(0,(a,b)=>a+b.sec);
 double get manualSpeed=>double.tryParse(speedC.text.replaceAll(',','.'))??0;
 String get tile=>sat?'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}':'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

 @override void dispose(){timer?.cancel();speedC.dispose();distanceC.dispose();nameC.dispose();super.dispose();}
 void add(LatLng p){if(!drawing)return;setState((){pts.add(p);undo.clear();distanceC.text=actualKm.toStringAsFixed(2);});}
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
 Future<void> pick(bool a)async{final b=a?start:end;final d=await showDatePicker(context:context,initialDate:b,firstDate:DateTime(2020),lastDate:DateTime(2035));if(d==null||!mounted)return;final t=await showTimePicker(context:context,initialTime:TimeOfDay.fromDateTime(b));if(t==null)return;setState((){final v=DateTime(d.year,d.month,d.day,t.hour,t.minute);if(a)start=v;else end=v;});}
 Future<void> stopAt(int i)async{final c=TextEditingController(text:'5');final v=await showDialog<int>(context:context,builder:(x)=>AlertDialog(title:Text('Durak ${i+1}'),content:TextField(controller:c,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Bekleme süresi (dakika)')),actions:[TextButton(onPressed:()=>Navigator.pop(x),child:const Text('İptal')),FilledButton(onPressed:()=>Navigator.pop(x,(int.tryParse(c.text)??0)*60),child:const Text('Ekle'))]));if(v!=null&&v>0)setState(()=>stops.add(Stop(i,v)));}
 void animate(){timer?.cancel();if(pts.isEmpty)return;setState((){playing=true;playIndex=0;});timer=Timer.periodic(const Duration(milliseconds:450),(t){if(playIndex>=pts.length-1){t.cancel();setState(()=>playing=false);}else setState(()=>playIndex++);});}
 String timeFor(int i){if(pts.length<2)return start.toUtc().toIso8601String();double total=0,at=0;for(int k=1;k<pts.length;k++){final q=D(pts[k-1],pts[k]);total+=q;if(k<=i)at+=q;}final move=end.difference(start).inSeconds-stopSec;var sec=(move.clamp(0,999999999)*(total==0?0:at/total)).round();for(final s in stops){if(s.index<=i)sec+=s.sec;}return start.add(Duration(seconds:sec)).toUtc().toIso8601String();}
 String gpx(){final b=StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="RotaSim V2" xmlns="http://www.topografix.com/GPX/1/1"><trk><name>${nameC.text}</name><trkseg>\n');for(int i=0;i<pts.length;i++)b.writeln('<trkpt lat="${pts[i].latitude}" lon="${pts[i].longitude}"><time>${timeFor(i)}</time></trkpt>');b.write('</trkseg></trk></gpx>');return b.toString();}
 String kml(){final coords=pts.map((p)=>'${p.longitude},${p.latitude},0').join(' ');return '<?xml version="1.0" encoding="UTF-8"?><kml xmlns="http://www.opengis.net/kml/2.2"><Document><Placemark><name>${nameC.text}</name><LineString><coordinates>$coords</coordinates></LineString></Placemark></Document></kml>';}
 Future<void> export(bool asGpx)async{if(pts.length<2)return;final dir=await getTemporaryDirectory();final stamp=DateFormat('yyyy-MM-dd HHmmss').format(end);final f=File('${dir.path}/$stamp.${asGpx?'gpx':'kml'}');await f.writeAsString(asGpx?gpx():kml());await Share.shareXFiles([XFile(f.path)]);}
 Future<void> save()async{final sp=await SharedPreferences.getInstance();final all=sp.getStringList('routes')??[];all.add(jsonEncode({'name':nameC.text,'pts':pts.map((p)=>[p.latitude,p.longitude]).toList(),'stops':stops.map((s)=>s.toJson()).toList(),'start':start.toIso8601String(),'end':end.toIso8601String()}));await sp.setStringList('routes',all);if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Rota kaydedildi')));}
 Future<void> saved()async{final sp=await SharedPreferences.getInstance();final all=sp.getStringList('routes')??[];if(!mounted)return;showModalBottomSheet(context:context,builder:(x)=>ListView(children:[const ListTile(title:Text('Kayıtlı Rotalar')),for(final raw in all)ListTile(title:Text((jsonDecode(raw)['name']??'Rota').toString()),onTap:(){final j=jsonDecode(raw);setState((){pts..clear()..addAll((j['pts'] as List).map((e)=>LatLng((e[0] as num).toDouble(),(e[1] as num).toDouble())));stops..clear()..addAll((j['stops'] as List).map((e)=>Stop(e['i'],e['s'])));start=DateTime.parse(j['start']);end=DateTime.parse(j['end']);nameC.text=j['name'];distanceC.text=actualKm.toStringAsFixed(2);});Navigator.pop(x);})]));}
 void preview(){showModalBottomSheet(context:context,isScrollControlled:true,builder:(x)=>Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[Text(nameC.text,style:Theme.of(context).textTheme.headlineSmall),const SizedBox(height:12),Text('Mesafe: ${actualKm.toStringAsFixed(2)} km'),Text('Manuel hız: ${manualSpeed.toStringAsFixed(1)} km/sa'),Text('Durak: ${stops.length} • Toplam bekleme: ${(stopSec/60).toStringAsFixed(0)} dk'),Text('Başlangıç: ${DateFormat('dd.MM.yyyy HH:mm').format(start)}'),Text('Bitiş: ${DateFormat('dd.MM.yyyy HH:mm').format(end)}'),const SizedBox(height:12),FilledButton(onPressed:()=>Navigator.pop(x),child:const Text('Tamam'))])));}
 @override Widget build(BuildContext c){final fmt=DateFormat('dd.MM.yyyy HH:mm');return Scaffold(body:Stack(children:[
  FlutterMap(mapController:mc,options:MapOptions(initialCenter:const LatLng(39.93,32.86),initialZoom:12,onTap:(_,p)=>add(p),onLongPress:(_,p){if(pts.isEmpty)return;int best=0;double bd=1e99;for(int i=0;i<pts.length;i++){final d=D(p,pts[i]);if(d<bd){bd=d;best=i;}}stopAt(best);}),children:[
   TileLayer(urlTemplate:tile,userAgentPackageName:'com.rotasim.app'),
   if(pts.isNotEmpty)PolylineLayer(polylines:[Polyline(points:pts,strokeWidth:6,color:Colors.cyanAccent)]),
   MarkerLayer(markers:[
    if(me!=null)Marker(point:me!,width:42,height:42,child:const Icon(Icons.my_location,color:Colors.lightBlueAccent,size:32)),
    for(int i=0;i<pts.length;i++)if(i==0||i==pts.length-1||stops.any((s)=>s.index==i))Marker(point:pts[i],width:42,height:42,child:GestureDetector(onTap:()=>stopAt(i),child:CircleAvatar(backgroundColor:i==0?Colors.green:i==pts.length-1?Colors.red:Colors.orange,child:Text(i==0?'B':i==pts.length-1?'S':'D')))),
    if(playing&&pts.isNotEmpty)Marker(point:pts[playIndex],width:48,height:48,child:const Icon(Icons.directions_walk,size:42,color:Colors.white)),
   ])
  ]),
  SafeArea(child:Padding(padding:const EdgeInsets.all(10),child:Row(children:[FilledButton.tonalIcon(onPressed:()=>setState(()=>sat=!sat),icon:Icon(sat?Icons.map:Icons.satellite_alt),label:Text(sat?'Harita':'Uydu')),const Spacer(),IconButton.filledTonal(onPressed:locate,icon:const Icon(Icons.my_location)),IconButton.filledTonal(onPressed:saved,icon:const Icon(Icons.folder))]))),
  Positioned(left:10,right:10,bottom:10,child:Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(mainAxisSize:MainAxisSize.min,children:[
   Row(children:[Expanded(child:TextField(controller:nameC,decoration:const InputDecoration(labelText:'Rota adı',isDense:true))),const SizedBox(width:8),IconButton(onPressed:back,icon:const Icon(Icons.undo)),IconButton(onPressed:forward,icon:const Icon(Icons.redo)),IconButton(onPressed:()=>setState((){pts.clear();stops.clear();undo.clear();distanceC.clear();}),icon:const Icon(Icons.delete_outline))]),
   const SizedBox(height:6),Row(children:[Expanded(child:TextField(controller:distanceC,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Mesafe km',isDense:true))),const SizedBox(width:8),Expanded(child:TextField(controller:speedC,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Hız km/sa',isDense:true)))]),
   Row(children:[Expanded(child:TextButton(onPressed:()=>pick(true),child:Text('Başlangıç\n${fmt.format(start)}'))),Expanded(child:TextButton(onPressed:()=>pick(false),child:Text('Bitiş\n${fmt.format(end)}')))]),
   Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Text('${actualKm.toStringAsFixed(2)} km • ${stops.length} durak'),Wrap(children:[IconButton(onPressed:animate,icon:Icon(playing?Icons.pause:Icons.play_arrow)),IconButton(onPressed:preview,icon:const Icon(Icons.visibility)),IconButton(onPressed:save,icon:const Icon(Icons.save)),PopupMenuButton<String>(onSelected:(v)=>export(v=='gpx'),itemBuilder:(_)=>const [PopupMenuItem(value:'gpx',child:Text('GPX paylaş')),PopupMenuItem(value:'kml',child:Text('KML paylaş'))])])]),
   const Text('Haritaya dokun: rota ekle • Rota üzerinde uzun bas: durak ekle',style:TextStyle(fontSize:11))
  ]))))
 ]));}
}