import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:archive/archive_io.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main()=>runApp(const App());
class App extends StatelessWidget{const App({super.key});@override Widget build(BuildContext c)=>MaterialApp(debugShowCheckedModeBanner:false,title:'RotaSim V3',theme:ThemeData(colorSchemeSeed:const Color(0xFF8B3DFF),useMaterial3:true,brightness:Brightness.dark),home:const Home());}
class Stop{final int index;final int sec;Stop(this.index,this.sec);Map<String,dynamic> toJson()=>{'i':index,'s':sec};}
class Home extends StatefulWidget{const Home({super.key});@override State<Home> createState()=>_Home();}
class _Home extends State<Home>{
 final mc=MapController(); final pts=<LatLng>[]; final stops=<Stop>[]; final undo=<LatLng>[]; final D=const Distance();
 int mapMode=0; // 0 Yol, 1 Uydu HD (Esri), 2 Güncel Uydu (NASA VIIRS)
 bool drawing=false,playing=false,smooth=true,freehandActive=false,autoEnd=true,routeFinished=false,addingStop=false,mapError=false; int activePointers=0,flowStep=0,mapRetry=0; LatLng? me; int playIndex=0; Timer? timer;
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

 void retryMap(){setState((){mapError=false;mapRetry++;});}
 Future<void> selectStopAt(LatLng point)async{
  if(pts.length<3)return;
  var nearest=-1;var distance=double.infinity;
  for(var i=0;i<pts.length;i++){
   final candidate=D(point,pts[i]);
   if(candidate<distance){distance=candidate;nearest=i;}
  }
  if(nearest<0||distance>150){
   if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Durak eklemek için çizilen rotanın üzerindeki bir noktaya dokunun.')));
   return;
  }
  setState(()=>addingStop=false);
  await stopAt(nearest);
 }
 void fitRoute(){
  if(pts.length<2)return;
  WidgetsBinding.instance.addPostFrameCallback((_){
   if(!mounted)return;
   mc.fitCamera(CameraFit.coordinates(coordinates:List<LatLng>.of(pts),padding:const EdgeInsets.all(48),maxZoom:17,minZoom:5));
  });
 }
 void nextToPreview(){setState(()=>flowStep=2);fitRoute();}
 void restoreRoute(Map<String,dynamic> j,{bool edit=false}){
  setState((){
   pts..clear()..addAll((j['pts'] as List).map((e)=>LatLng((e[0] as num).toDouble(),(e[1] as num).toDouble())));
   stops..clear()..addAll((j['stops'] as List? ?? const []).map((e)=>Stop((e['i'] as num).toInt(),(e['s'] as num).toInt())));
   start=DateTime.parse(j['start']);end=DateTime.parse(j['end']);
   speedC.text=(j['speed']??'5.0').toString();distanceC.text=(j['distance']??actualKm.toStringAsFixed(2)).toString();
   autoEnd=(j['autoEnd'] as bool?)??false;drawing=edit;routeFinished=!edit;addingStop=false;flowStep=0;
  });
  fitRoute();
 }

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

 Future<void> save()async{final sp=await SharedPreferences.getInstance();final all=sp.getStringList('routes')??[];all.removeWhere((raw){try{return jsonDecode(raw)['name']==routeLabel;}catch(_){return false;}});all.add(jsonEncode({'name':routeLabel,'pts':pts.map((p)=>[p.latitude,p.longitude]).toList(),'stops':stops.map((s)=>s.toJson()).toList(),'start':start.toIso8601String(),'end':end.toIso8601String(),'autoEnd':autoEnd,'speed':speedC.text,'distance':distanceC.text}));await sp.setStringList('routes',all);if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Rota kaydedildi')));}
 Future<void> saved()async{
  final sp=await SharedPreferences.getInstance();
  final all=sp.getStringList('routes')??[];
  if(!mounted)return;
  showModalBottomSheet<void>(
   context:context,
   isScrollControlled:true,
   backgroundColor:const Color(0xFF141A23),
   builder:(sheetContext)=>SafeArea(
    child:StatefulBuilder(builder:(context,setSheetState){
     Future<void> act(int index,String action)async{
      final savedRoute=Map<String,dynamic>.from(jsonDecode(all[index]) as Map);
      if(action=='open'||action=='edit'){
       Navigator.pop(sheetContext);
       restoreRoute(savedRoute,edit:action=='edit');
       return;
      }
      if(action=='copy'){
       final now=DateTime.now();
       final distance=(double.tryParse((savedRoute['distance']??'').toString().replaceAll(',','.'))??0);
       final speed=(double.tryParse((savedRoute['speed']??'5').toString().replaceAll(',','.'))??5);
       final savedStops=(savedRoute['stops'] as List? ?? const []);
       final wait=savedStops.fold<int>(0,(sum,item)=>sum+((item['s'] as num?)?.toInt()??0));
       final movement=speed>0?Duration(seconds:(distance/speed*3600).round()):Duration.zero;
       savedRoute['start']=now.toIso8601String();
       savedRoute['end']=now.add(movement+Duration(seconds:wait)).toIso8601String();
       savedRoute['name']=DateFormat('dd.MM.yyyy • HH:mm:ss').format(now);
       all.insert(index+1,jsonEncode(savedRoute));
       await sp.setStringList('routes',all);
       setSheetState((){});
       if(mounted)ScaffoldMessenger.of(this.context).showSnackBar(const SnackBar(content:Text('Rota kopyalandı.')));
       return;
      }
      if(action=='delete'){
       final confirm=await showDialog<bool>(context:this.context,builder:(dialogContext)=>AlertDialog(
        title:const Text('Rotayı sil?'),
        content:Text('${savedRoute['name']??'Bu rota'} kayıtlı rotalardan kaldırılacak.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(dialogContext,false),child:const Text('VAZGEÇ')),FilledButton(onPressed:()=>Navigator.pop(dialogContext,true),child:const Text('SİL'))],
       ));
       if(confirm==true){all.removeAt(index);await sp.setStringList('routes',all);setSheetState((){});}
      }
     }
     if(all.isEmpty)return const Padding(padding:EdgeInsets.fromLTRB(20,24,20,32),child:Text('Henüz kayıtlı rota yok.'));
     return ListView(
      shrinkWrap:true,
      children:[
       const Padding(padding:EdgeInsets.fromLTRB(20,20,20,8),child:Text('Kayıtlı Rotalar',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold))),
       for(var i=0;i<all.length;i++)...[
        ListTile(
         leading:const CircleAvatar(backgroundColor:Color(0x338B3DFF),child:Icon(Icons.route,color:Color(0xFFB589FF))),
         title:Text((jsonDecode(all[i])['name']??'Rota').toString()),
         subtitle:Text('${(jsonDecode(all[i])['distance']??'—').toString()} km'),
         onTap:()=>act(i,'open'),
         trailing:PopupMenuButton<String>(
          onSelected:(action)=>act(i,action),
          itemBuilder:(_)=>const [
           PopupMenuItem(value:'open',child:Text('Aç')),
           PopupMenuItem(value:'edit',child:Text('Düzenle')),
           PopupMenuItem(value:'copy',child:Text('Kopyala')),
           PopupMenuItem(value:'delete',child:Text('Sil')),
          ],
         ),
        ),
        const Divider(height:1),
       ],
      ],
     );
    }),
   ),
  );
 }
 void preview(){showModalBottomSheet(context:context,isScrollControlled:true,builder:(x)=>Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[Text(routeLabel,style:Theme.of(context).textTheme.headlineSmall),const SizedBox(height:12),Text('Mesafe: ${actualKm.toStringAsFixed(2)} km'),Text('Manuel hız: ${manualSpeed.toStringAsFixed(1)} km/sa'),Text('Durak: ${stops.length} • Bekleme: ${durationText(Duration(seconds:stopSec))}'),Text('Tahmini hareket: ${durationText(estimatedMove)}'),Text('Tahmini toplam: ${durationText(estimatedTotal)}'),Text('Başlangıç: ${DateFormat('dd.MM.yyyy HH:mm:ss').format(start)}'),Text('Manuel bitiş: ${DateFormat('dd.MM.yyyy HH:mm:ss').format(end)}'),Text('Tahmini bitiş: ${DateFormat('dd.MM.yyyy HH:mm:ss').format(estimatedEnd)}'),if(timeMismatch)const Text('⚠ Seçilen bitiş, mesafe ve hıza göre tahmini bitişle uyuşmuyor.',style:TextStyle(color:Colors.orange)),const SizedBox(height:12),FilledButton(onPressed:()=>Navigator.pop(x),child:const Text('Tamam'))])));}
 @override
 Widget build(BuildContext c){
  const purple=Color(0xFF8B3DFF),bg=Color(0xFF090D14),card=Color(0xFF141A23),mapBg=Color(0xFF17212B);
  Widget logo()=>RichText(text:const TextSpan(style:TextStyle(fontSize:24,fontWeight:FontWeight.w800),children:[TextSpan(text:'Rota',style:TextStyle(color:Colors.white)),TextSpan(text:'Sim',style:TextStyle(color:purple))]));
  Widget stepper()=>Padding(padding:const EdgeInsets.fromLTRB(16,8,16,12),child:Row(children:List.generate(4,(i)=>Expanded(child:Column(children:[
   Row(children:[if(i>0)Expanded(child:Container(height:2,color:i<=flowStep?purple:Colors.white24)),CircleAvatar(radius:11,backgroundColor:i<=flowStep?purple:Colors.white24,child:i<flowStep?const Icon(Icons.check,size:13):Text('${i+1}',style:const TextStyle(fontSize:10))),if(i<3)Expanded(child:Container(height:2,color:i<flowStep?purple:Colors.white24))]),
   const SizedBox(height:5),Text(['Rota Çiz','Bilgiler','Önizleme','Paylaş'][i],style:TextStyle(fontSize:9,color:i==flowStep?Colors.white:Colors.white54)),
  ])))));
  Widget navButton(String text,VoidCallback? tap,{bool primary=true,IconData? icon})=>Expanded(child:SizedBox(height:50,child:primary?FilledButton.icon(onPressed:tap,style:FilledButton.styleFrom(backgroundColor:purple),icon:Icon(icon??Icons.arrow_forward),label:Text(text)):OutlinedButton.icon(onPressed:tap,icon:Icon(icon??Icons.arrow_back),label:Text(text))));
  Widget topBar({String? title,bool backBtn=false})=>SafeArea(bottom:false,child:Container(height:58,padding:const EdgeInsets.symmetric(horizontal:10),decoration:BoxDecoration(color:bg.withValues(alpha:.93)),child:Row(children:[
   if(backBtn)IconButton(tooltip:'Geri',onPressed:()=>setState(()=>flowStep=flowStep>0?flowStep-1:0),icon:const Icon(Icons.arrow_back)),
   if(title!=null)Text(title,style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold))else logo(),
   const Spacer(),
   TextButton.icon(onPressed:()=>setState((){mapMode=mapMode==0?1:0;mapError=false;}),icon:Icon(mapMode==0?Icons.satellite_alt_outlined:Icons.map_outlined),label:Text(mapMode==0?'Uydu':'Harita')),
   IconButton(tooltip:'Kayıtlı Rotalar',onPressed:saved,icon:const Icon(Icons.bookmarks_outlined)),
  ])));
  Widget metric(String value,String label)=>Column(mainAxisAlignment:MainAxisAlignment.center,children:[Text(value,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:14),maxLines:1,overflow:TextOverflow.ellipsis),const SizedBox(height:2),Text(label,style:const TextStyle(fontSize:8,color:Colors.white54),maxLines:1,overflow:TextOverflow.ellipsis)]);
  Widget summary()=>Container(padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:card,borderRadius:BorderRadius.circular(12)),child:GridView.count(
   crossAxisCount:3,shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),mainAxisSpacing:4,crossAxisSpacing:4,childAspectRatio:2.15,
   children:[metric('${effectiveKm.toStringAsFixed(2)} km','MESAFE'),metric('${manualSpeed.toStringAsFixed(1)} km/sa','ORT. HIZ'),metric(durationText(estimatedMove),'HAREKET'),metric(durationText(Duration(seconds:stopSec)),'BEKLEME'),metric(durationText(estimatedTotal),'TOPLAM'),metric('${stops.length}','DURAK')],
  ));
  Widget mapWidget()=>Listener(
   behavior:HitTestBehavior.opaque,
   onPointerDown:(e){activePointers++;if(drawing&&activePointers==1){freehandActive=true;freehandPoint(e.localPosition);}else{freehandActive=false;}},
   onPointerMove:(e){if(activePointers==1)freehandPoint(e.localPosition);},
   onPointerUp:(_){activePointers=(activePointers-1).clamp(0,10);freehandActive=false;},
   onPointerCancel:(_){activePointers=(activePointers-1).clamp(0,10);freehandActive=false;},
   child:SizedBox.expand(child:FlutterMap(
    key:ValueKey('rotasim-map-retry-$mapRetry'),
    mapController:mc,
    options:MapOptions(
     initialCenter:pts.isNotEmpty?pts.first:(me??const LatLng(39.93,32.86)),
     initialZoom:pts.isNotEmpty?14:(me!=null?16:12),
     backgroundColor:mapBg,
     interactionOptions:InteractionOptions(flags:drawing&&flowStep==0?(InteractiveFlag.pinchMove|InteractiveFlag.pinchZoom):InteractiveFlag.all,enableMultiFingerGestureRace:true),
     onTap:(position,point){if(addingStop)unawaited(selectStopAt(point));},
    ),
    children:[
     if(mapMode==0)TileLayer(
      urlTemplate:'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName:'com.rotasim.rotasim',maxZoom:19,tileDisplay:const TileDisplay.fadeIn(),
      evictErrorTileStrategy:EvictErrorTileStrategy.notVisibleRespectMargin,
      errorTileCallback:(tile,error,stack){if(mounted&&!mapError)setState(()=>mapError=true);},
     ),
     if(mapMode==1)TileLayer(
      urlTemplate:'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      userAgentPackageName:'com.rotasim.rotasim',
      evictErrorTileStrategy:EvictErrorTileStrategy.notVisibleRespectMargin,
      errorTileCallback:(tile,error,stack){if(mounted&&!mapError)setState(()=>mapError=true);},
     ),
     if(pts.isNotEmpty)PolylineLayer(polylines:[Polyline(points:pts,strokeWidth:9,color:const Color(0x558B3DFF)),Polyline(points:pts,strokeWidth:4,color:purple)]),
     MarkerLayer(markers:[
      if(me!=null)Marker(point:me!,width:38,height:38,child:const Icon(Icons.my_location,color:Colors.blueAccent)),
      if(pts.isNotEmpty)Marker(point:pts.first,width:36,height:36,child:const Icon(Icons.circle,color:Colors.greenAccent,size:28)),
      if(pts.length>1)Marker(point:pts.last,width:36,height:36,child:const Icon(Icons.location_on,color:Colors.redAccent,size:34)),
      for(final st in stops)if(st.index>=0&&st.index<pts.length)Marker(point:pts[st.index],width:34,height:34,child:const Icon(Icons.circle,color:Colors.orangeAccent,size:24)),
      if(playing&&pts.isNotEmpty)Marker(point:pts[playIndex.clamp(0,pts.length-1).toInt()],width:38,height:38,child:const Icon(Icons.directions_walk,color:Colors.white,size:34)),
     ]),
    ],
   )),
  );
  if(flowStep==0){
   return Scaffold(
    backgroundColor:mapBg,
    body:SizedBox.expand(child:Stack(fit:StackFit.expand,clipBehavior:Clip.hardEdge,children:[
     Positioned.fill(child:RepaintBoundary(child:mapWidget())),
     Positioned(left:0,right:0,top:0,child:topBar()),
     if(!drawing&&!addingStop)Positioned(left:10,top:0,child:SafeArea(child:Padding(padding:const EdgeInsets.only(top:64),child:DecoratedBox(decoration:BoxDecoration(color:bg.withValues(alpha:.58),borderRadius:BorderRadius.circular(6)),child:Padding(padding:const EdgeInsets.symmetric(horizontal:6,vertical:3),child:Text(mapMode==0?'© OpenStreetMap contributors':'© Esri World Imagery',style:const TextStyle(fontSize:9,color:Colors.white70))))))),
     Positioned(right:10,top:0,child:SafeArea(child:Padding(padding:const EdgeInsets.only(top:68),child:Column(children:[
      IconButton.filledTonal(tooltip:'Konumuma git',onPressed:locate,icon:const Icon(Icons.my_location)),
      IconButton.filledTonal(tooltip:'Yakınlaştır',onPressed:()=>mc.move(mc.camera.center,mc.camera.zoom+1),icon:const Icon(Icons.add)),
      IconButton.filledTonal(tooltip:'Uzaklaştır',onPressed:()=>mc.move(mc.camera.center,mc.camera.zoom-1),icon:const Icon(Icons.remove)),
     ])))),
     if(drawing)Positioned(left:8,top:0,child:SafeArea(child:Padding(padding:const EdgeInsets.only(top:68),child:Column(children:[
      IconButton.filledTonal(tooltip:'Geri al',onPressed:back,icon:const Icon(Icons.undo)),
      IconButton.filledTonal(tooltip:'İleri al',onPressed:forward,icon:const Icon(Icons.redo)),
      IconButton.filledTonal(tooltip:'Duraklat',onPressed:()=>setState((){drawing=false;routeFinished=false;}),icon:const Icon(Icons.pause)),
      IconButton.filled(tooltip:'Bitir',onPressed:finishHere,style:IconButton.styleFrom(backgroundColor:purple),icon:const Icon(Icons.check)),
      IconButton.filledTonal(tooltip:'Temizle',onPressed:clearRoute,icon:const Icon(Icons.delete_outline)),
     ])))),
     if(addingStop)Positioned(left:16,right:16,top:0,child:SafeArea(child:Container(margin:const EdgeInsets.only(top:68),padding:const EdgeInsets.symmetric(horizontal:14,vertical:10),decoration:BoxDecoration(color:bg.withValues(alpha:.92),borderRadius:BorderRadius.circular(12)),child:const Text('Durak eklemek için çizilen rotanın üzerindeki noktaya dokunun.',textAlign:TextAlign.center,style:TextStyle(fontSize:13))))),
     if(mapError)Positioned(left:20,right:20,top:0,child:SafeArea(child:Container(margin:const EdgeInsets.only(top:72),padding:const EdgeInsets.symmetric(horizontal:14,vertical:10),decoration:BoxDecoration(color:bg.withValues(alpha:.94),borderRadius:BorderRadius.circular(14),border:Border.all(color:Colors.white12)),child:Row(children:[const Expanded(child:Text('Harita yüklenemedi. İnternet bağlantınızı kontrol edip yeniden deneyin.',style:TextStyle(fontSize:13))),TextButton(onPressed:retryMap,child:const Text('YENİDEN DENE'))])))),
     Positioned(left:16,right:16,bottom:0,child:SafeArea(top:false,child:Padding(padding:const EdgeInsets.only(bottom:12),child:Column(mainAxisSize:MainAxisSize.min,children:[
      if(pts.isNotEmpty&&!addingStop)Container(margin:const EdgeInsets.only(bottom:8),padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),decoration:BoxDecoration(color:bg.withValues(alpha:.91),borderRadius:BorderRadius.circular(12)),child:Row(children:[const Icon(Icons.alt_route,color:purple),const SizedBox(width:8),Text('${actualKm.toStringAsFixed(2)} km'),const Spacer(),if(!drawing)TextButton(onPressed:()=>setState((){drawing=true;routeFinished=false;}),child:Text(routeFinished?'DÜZENLE':'DEVAM ET'))])),
      if(addingStop)Container(margin:const EdgeInsets.only(bottom:8),padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),decoration:BoxDecoration(color:bg.withValues(alpha:.91),borderRadius:BorderRadius.circular(12)),child:const Text('Durak yerini seçin',textAlign:TextAlign.center)),
      SizedBox(width:double.infinity,height:54,child:FilledButton(
       onPressed:addingStop?()=>setState(()=>addingStop=false):pts.length>=2?(){finishHere();setState(()=>flowStep=1);}:()=>setState((){drawing=true;routeFinished=false;}),
       style:FilledButton.styleFrom(backgroundColor:purple),
       child:Text(addingStop?'VAZGEÇ':pts.length>=2?(drawing?'BİTİR VE DEVAM ET':'SONRAKİ  →'):(pts.isEmpty?'ROTA ÇİZMEYE BAŞLA':'ÇİZİME DEVAM ET'),style:const TextStyle(fontWeight:FontWeight.bold,letterSpacing:.3)),
      )),
     ])))),
    ]))),
   );
  }
  if(flowStep==1){
   return Scaffold(backgroundColor:bg,body:SafeArea(child:Column(children:[
    topBar(title:'Rota Bilgileri',backBtn:true),stepper(),
    Expanded(child:ListView(padding:const EdgeInsets.symmetric(horizontal:14),children:[
     Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:card,borderRadius:BorderRadius.circular(10)),child:Text('${actualKm.toStringAsFixed(2)} km\nHaritadan ölçülen mesafe',style:const TextStyle(fontSize:16,fontWeight:FontWeight.bold))),const SizedBox(height:10),
     _section('BAŞLANGIÇ',[ListTile(title:const Text('Başlangıç tarihi / saati'),subtitle:Text(DateFormat('dd.MM.yyyy • HH:mm:ss').format(start)),trailing:const Icon(Icons.calendar_month),onTap:()=>pick(true))]),const SizedBox(height:8),
     _section('MESAFE',[TextField(controller:distanceC,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(suffixText:'km',hintText:'Haritadan ölçülen mesafe'),onChanged:(_)=>setState(syncEnd))]),const SizedBox(height:8),
     _section('ORTALAMA HIZ',[TextField(controller:speedC,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(suffixText:'km/sa'),onChanged:(_)=>setState(syncEnd))]),const SizedBox(height:8),
     _section('SÜRELER',[ListTile(title:const Text('Tahmini hareket süresi'),subtitle:Text(durationText(estimatedMove))),ListTile(title:const Text('Toplam bekleme'),subtitle:Text(durationText(Duration(seconds:stopSec)))),ListTile(title:const Text('Toplam rota süresi'),subtitle:Text(durationText(estimatedTotal)))]),const SizedBox(height:8),
     _section('DURAKLAR',[Row(children:[Text('${stops.length} durak • ${durationText(Duration(seconds:stopSec))}'),const Spacer(),OutlinedButton.icon(onPressed:pts.length<3?null:(){setState((){addingStop=true;drawing=false;flowStep=0;});},icon:const Icon(Icons.add),label:const Text('Haritadan ekle'))]),for(var i=0;i<stops.length;i++)ListTile(title:Text('Durak ${i+1}'),subtitle:Text('Bekleme: ${durationText(Duration(seconds:stops[i].sec))}'),trailing:IconButton(tooltip:'Bekleme süresini düzenle',onPressed:()=>stopAt(stops[i].index),icon:const Icon(Icons.edit)))]),const SizedBox(height:8),
     _section('TAHMİNİ BİTİŞ',[SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Bitiş zamanını otomatik hesapla'),value:autoEnd,onChanged:(v)=>setState((){autoEnd=v;if(v)syncEnd();})),ListTile(title:Text(autoEnd?'Tahmini bitiş':'Elle seçilen bitiş'),subtitle:Text(DateFormat('dd.MM.yyyy • HH:mm:ss').format(autoEnd?estimatedEnd:end)),trailing:IconButton(onPressed:autoEnd?null:()=>pick(false),icon:const Icon(Icons.edit))) ,Text('Başlangıç + hareket + bekleme = bitiş',style:TextStyle(color:Colors.white.withValues(alpha:.62),fontSize:12))]),const SizedBox(height:20),
    ])),
    Padding(padding:const EdgeInsets.all(14),child:Row(children:[navButton('GERİ',()=>setState(()=>flowStep=0),primary:false),const SizedBox(width:10),navButton('SONRAKİ',nextToPreview)])),
   ])));
  }
  if(flowStep==2){
   return Scaffold(backgroundColor:bg,body:SafeArea(child:Column(children:[
    topBar(title:'Rotayı Önizle',backBtn:true),stepper(),
    Expanded(child:Padding(padding:const EdgeInsets.fromLTRB(14,0,14,8),child:Column(children:[
     Expanded(child:ClipRRect(borderRadius:BorderRadius.circular(14),child:mapWidget())),const SizedBox(height:8),summary(),const SizedBox(height:8),
     Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:9),decoration:BoxDecoration(color:card,borderRadius:BorderRadius.circular(12)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('BAŞLANGIÇ',style:TextStyle(fontSize:9,color:Colors.white54)),Text(DateFormat('dd.MM.yyyy • HH:mm:ss').format(start),style:const TextStyle(fontSize:12,fontWeight:FontWeight.w600))])),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('BİTİŞ',style:TextStyle(fontSize:9,color:Colors.white54)),Text(DateFormat('dd.MM.yyyy • HH:mm:ss').format(autoEnd?estimatedEnd:end),style:const TextStyle(fontSize:12,fontWeight:FontWeight.w600))]))])),const SizedBox(height:8),
     SizedBox(width:double.infinity,height:46,child:FilledButton.icon(onPressed:animate,style:FilledButton.styleFrom(backgroundColor:purple),icon:const Icon(Icons.play_arrow),label:const Text('ROTAYI ÖNİZLE'))),
     if(mapError)TextButton.icon(onPressed:retryMap,icon:const Icon(Icons.refresh),label:const Text('Haritayı yeniden yükle')),
    ]))),
    Padding(padding:const EdgeInsets.fromLTRB(14,4,14,14),child:Row(children:[navButton('DÜZENLE',()=>setState(()=>flowStep=1),primary:false,icon:Icons.arrow_back),const SizedBox(width:10),navButton('DEVAM ET',()=>setState(()=>flowStep=3))])),
   ])));
  }
  return Scaffold(backgroundColor:bg,body:SafeArea(child:Column(children:[
   topBar(title:'Kaydet / Paylaş',backBtn:true),stepper(),
   Expanded(child:ListView(padding:const EdgeInsets.all(14),children:[
    SizedBox(height:220,child:ClipRRect(borderRadius:BorderRadius.circular(14),child:mapWidget())),
    if(mapError)Align(alignment:Alignment.centerLeft,child:TextButton.icon(onPressed:retryMap,icon:const Icon(Icons.refresh),label:const Text('Harita yüklenemedi · Yeniden dene'))),
    const SizedBox(height:10),summary(),const SizedBox(height:10),
    Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:card,borderRadius:BorderRadius.circular(12)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
     Text(routeLabel,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:16)),const SizedBox(height:8),
     Text('Başlangıç: ${DateFormat('HH:mm:ss').format(start)}'),Text('Bitiş: ${DateFormat('HH:mm:ss').format(autoEnd?estimatedEnd:end)}'),Text('Mesafe: ${effectiveKm.toStringAsFixed(2)} km'),Text('Ortalama hız: ${manualSpeed.toStringAsFixed(1)} km/sa'),Text('Hareket: ${durationText(estimatedMove)}'),Text('Durak sayısı: ${stops.length}'),Text('Bekleme: ${durationText(Duration(seconds:stopSec))}'),Text('Toplam süre: ${durationText(estimatedTotal)}'),
    ])),const SizedBox(height:14),
    SizedBox(height:52,child:FilledButton.icon(onPressed:save,style:FilledButton.styleFrom(backgroundColor:purple),icon:const Icon(Icons.save_outlined),label:const Text('ROTAYI KAYDET'))),const SizedBox(height:10),
    SizedBox(height:52,child:FilledButton.icon(onPressed:()=>shareType('gpx-track'),style:FilledButton.styleFrom(backgroundColor:const Color(0xFF5530A8)),icon:const Icon(Icons.share),label:const Text('GPX TRACK PAYLAŞ'))),
    Center(child:TextButton(onPressed:(){clearRoute();setState(()=>flowStep=0);},child:const Text('Yeni Rota Oluştur'))),
   ])),
  ])));
 }
 Widget _section(String title,List<Widget> children)=>Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:const Color(0xFF141A23),borderRadius:BorderRadius.circular(10),border:Border.all(color:Colors.white10)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(fontSize:12,fontWeight:FontWeight.bold,color:Colors.white70)),const SizedBox(height:6),...children]));
}
