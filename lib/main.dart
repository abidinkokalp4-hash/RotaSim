import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/flutter_map_maplibre.dart' show MapLibreLayer;
import 'package:archive/archive_io.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

void main()=>runApp(const App());
class App extends StatelessWidget{const App({super.key});@override Widget build(BuildContext c)=>MaterialApp(debugShowCheckedModeBanner:false,title:'RotaSim V3',theme:ThemeData(colorSchemeSeed:const Color(0xFF8B3DFF),useMaterial3:true,brightness:Brightness.dark),home:const Home());}
class Stop{final int index;final int sec;Stop(this.index,this.sec);Map<String,dynamic> toJson()=>{'i':index,'s':sec};}
enum _RouteDragKind{none,point,segment,whole}
class _RouteHit{const _RouteHit(this.index,this.t,this.point,this.distance);final int index;final double t;final Offset point;final double distance;}
class Home extends StatefulWidget{const Home({super.key});@override State<Home> createState()=>_Home();}
class _Home extends State<Home>{
 final _mapControllers=List<MapController>.generate(4,(_)=>MapController());
 MapController get mc=>_mapControllers[flowStep];
 final pts=<LatLng>[]; final stops=<Stop>[]; final undo=<LatLng>[]; final D=const Distance();
 int mapMode=0; // 0 Yol, 1 Uydu HD (Esri), 2 Güncel Uydu (NASA VIIRS)
 bool drawing=false,playing=false,smooth=true,freehandActive=false,autoEnd=true,routeFinished=false,addingStop=false,mapError=false,editingPoints=false,moveWholeRoute=false; int activePointers=0,flowStep=0,mapRetry=0; LatLng? me; int playIndex=0; Timer? timer;
 final mapGestureKeys=List<GlobalKey>.generate(4,(_)=>GlobalKey());
 _RouteDragKind routeDragKind=_RouteDragKind.none; int routeDragIndex=-1; double routeDragT=0,routeDragCenterDistance=0; LatLng? routeDragAnchor; List<LatLng>? routeDragOriginal; List<double> routeDragDistances=const[];
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
  if(pts.length<2)return;
  final screenPoint=mc.camera.latLngToScreenOffset(point);
  final hit=_closestSegment(screenPoint);
  if(hit==null||hit.distance>42){
   if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Durak eklemek için çizginin üzerine veya yakınına dokunun.')));
   return;
  }
  final snapped=mc.camera.screenOffsetToLatLng(hit.point);
  final stopIndex=hit.index+1;
  setState((){
   pts.insert(stopIndex,snapped);
   for(var i=0;i<stops.length;i++){if(stops[i].index>=stopIndex)stops[i]=Stop(stops[i].index+1,stops[i].sec);}
   distanceC.text=actualKm.toStringAsFixed(2);
   addingStop=false;
  });
  await stopAt(stopIndex);
 }
 void fitRoute(){
  if(pts.length<2||actualKm<0.001)return;
  WidgetsBinding.instance.addPostFrameCallback((_){
   if(!mounted)return;
   try{mc.fitCamera(CameraFit.coordinates(coordinates:List<LatLng>.of(pts),padding:flowStep==0?const EdgeInsets.fromLTRB(40,88,40,160):const EdgeInsets.all(20),maxZoom:17,minZoom:5));}catch(_){}
  });
 }
 void goToStep(int step){
  setState((){flowStep=step;mapRetry++;if(step!=0)addingStop=false;if(step!=0)editingPoints=false;});
  if(step==0||step==2||step==3)fitRoute();
 }
 void addStopMode(){
  if(pts.length<2)return;
  setState((){addingStop=true;drawing=false;editingPoints=false;flowStep=0;mapRetry++;});
  fitRoute();
 }
 void nextToPreview(){setState((){flowStep=2;editingPoints=false;mapRetry++;});fitRoute();}
 void restoreRoute(Map<String,dynamic> j,{bool edit=false}){
  setState((){
   pts..clear()..addAll((j['pts'] as List).map((e)=>LatLng((e[0] as num).toDouble(),(e[1] as num).toDouble())));
   stops..clear()..addAll((j['stops'] as List? ?? const []).map((e)=>Stop((e['i'] as num).toInt(),(e['s'] as num).toInt())));
   start=DateTime.parse(j['start']);end=DateTime.parse(j['end']);
   speedC.text=(j['speed']??'5.0').toString();distanceC.text=(j['distance']??actualKm.toStringAsFixed(2)).toString();
   autoEnd=(j['autoEnd'] as bool?)??false;drawing=false;editingPoints=edit;routeFinished=true;addingStop=false;flowStep=0;
  });
  fitRoute();
 }

 List<LatLng> parseTrackFile(String name,String source){
  final ext=name.split('.').last.toLowerCase();
  final xmlPoints=List<LatLng>.empty(growable:true);
  List<LatLng> readXmlPoints(String tag){
   final out=<LatLng>[];
   final tags=RegExp('<(?:[A-Za-z_][\\w.-]*:)?$tag\\b([^>]*)>',caseSensitive:false).allMatches(source);
   for(final match in tags){
    final attributes=match.group(1)??'';
    final lat=RegExp(r'''\blat\s*=\s*["']([^"']+)["']''',caseSensitive:false).firstMatch(attributes)?.group(1);
    final lon=RegExp(r'''\blon\s*=\s*["']([^"']+)["']''',caseSensitive:false).firstMatch(attributes)?.group(1);
    final latitude=double.tryParse(lat??''),longitude=double.tryParse(lon??'');
    if(latitude!=null&&longitude!=null&&latitude.abs()<=90&&longitude.abs()<=180)out.add(LatLng(latitude,longitude));
   }
   return out;
  }
  List<LatLng> readCoordinates(dynamic raw){
   final out=<LatLng>[];
   if(raw is List&&raw.isNotEmpty&&raw.first is List){
    for(final item in raw){
     if(item is List&&item.length>=2){final lon=(item[0] as num).toDouble(),lat=(item[1] as num).toDouble();if(lat.abs()<=90&&lon.abs()<=180)out.add(LatLng(lat,lon));}
    }
   }
   return out;
  }
  if(ext=='gpx'||source.toLowerCase().contains('<gpx')){
   final tracks=readXmlPoints('trkpt');if(tracks.isNotEmpty)return tracks;
   return readXmlPoints('rtept');
  }
  if(ext=='kml'||source.toLowerCase().contains('<kml')){
   final coordinates=RegExp(r'<(?:[A-Za-z_][\w.-]*:)?coordinates\b[^>]*>([\s\S]*?)</(?:[A-Za-z_][\w.-]*:)?coordinates\s*>',caseSensitive:false).firstMatch(source)?.group(1);
   if(coordinates!=null){for(final pair in coordinates.trim().split(RegExp(r'\s+'))){final values=pair.split(',');if(values.length<2)continue;final lon=double.tryParse(values[0]),lat=double.tryParse(values[1]);if(lat!=null&&lon!=null&&lat.abs()<=90&&lon.abs()<=180)xmlPoints.add(LatLng(lat,lon));}}
   return xmlPoints;
  }
  if(ext=='csv'){
   for(final line in const LineSplitter().convert(source).skip(1)){final columns=line.split(',');if(columns.length<3)continue;final lat=double.tryParse(columns[1].trim()),lon=double.tryParse(columns[2].trim());if(lat!=null&&lon!=null&&lat.abs()<=90&&lon.abs()<=180)xmlPoints.add(LatLng(lat,lon));}
   return xmlPoints;
  }
  dynamic decoded;try{decoded=jsonDecode(source);}on FormatException{return xmlPoints;}
  if(decoded is Map){
   if(decoded['points'] is List){for(final point in decoded['points'] as List){if(point is Map&&point['lat'] is num&&point['lon'] is num)xmlPoints.add(LatLng((point['lat'] as num).toDouble(),(point['lon'] as num).toDouble()));}}
   if(xmlPoints.isEmpty&&decoded['pts'] is List){for(final point in decoded['pts'] as List){if(point is List&&point.length>=2&&point[0] is num&&point[1] is num)xmlPoints.add(LatLng((point[0] as num).toDouble(),(point[1] as num).toDouble()));}}
   if(xmlPoints.isEmpty&&decoded['type']=='FeatureCollection'&&decoded['features'] is List){for(final feature in decoded['features'] as List){final geometry=feature is Map?feature['geometry']:null;if(geometry is Map&&geometry['type']=='LineString'){xmlPoints.addAll(readCoordinates(geometry['coordinates']));if(xmlPoints.isNotEmpty)break;}}}
   if(xmlPoints.isEmpty&&decoded['type']=='Feature'&&decoded['geometry'] is Map){final geometry=decoded['geometry'] as Map;if(geometry['type']=='LineString')xmlPoints.addAll(readCoordinates(geometry['coordinates']));}
   if(xmlPoints.isEmpty&&decoded['type']=='LineString')xmlPoints.addAll(readCoordinates(decoded['coordinates']));
  }
  return xmlPoints;
 }
 Future<void> importTrack()async{
  try{
   final file=await FilePicker.pickFile(type:FileType.custom,allowedExtensions:const ['gpx','kml','geojson','csv','json','rotasim']);
   if(file==null)return;
   if(!mounted)return;
   final bytes=await file.readAsBytes();
   if(!mounted)return;
   final imported=parseTrackFile(file.name,utf8.decode(bytes,allowMalformed:false));
   if(imported.length<2)throw const FormatException('Dosyada en az iki geçerli rota noktası bulunamadı.');
   if(pts.isNotEmpty){if(!mounted)return;final replace=await showDialog<bool>(context:context,builder:(dialog)=>AlertDialog(title:const Text('Açık rotayı değiştir?'),content:const Text('İçe aktarılan rota ekranda açılacak. Kayıtlı rotalar ve seçtiğiniz kaynak dosya değiştirilmez.'),actions:[TextButton(onPressed:()=>Navigator.pop(dialog,false),child:const Text('VAZGEÇ')),FilledButton(onPressed:()=>Navigator.pop(dialog,true),child:const Text('ROTAYI AÇ'))]));if(!mounted||replace!=true)return;}
   setState((){pts..clear()..addAll(imported);stops.clear();undo.clear();start=DateTime.now();distanceC.text=actualKm.toStringAsFixed(2);speedC.text='5.0';autoEnd=true;syncEnd();routeFinished=true;drawing=false;editingPoints=true;moveWholeRoute=false;addingStop=false;flowStep=0;mapError=false;mapRetry++;});
   fitRoute();
   if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('${file.name} yüklendi. Çizgiyi sürükleyerek düzenleyin veya tüm rotayı taşıma modunu seçin.')));
  }on FormatException catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.message.toString())));}
  catch(_){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Rota dosyası açılamadı. GPX, KML, GeoJSON, CSV veya RotaSim dosyası seçin.')));}
 }
 _RouteHit? _closestSegment(Offset screen){
  if(pts.length<2)return null;
  _RouteHit? best;
  for(var i=0;i<pts.length-1;i++){
   final a=mc.camera.latLngToScreenOffset(pts[i]),b=mc.camera.latLngToScreenOffset(pts[i+1]),ab=b-a;
   final length=ab.distanceSquared;
   final t=length==0?0.0:(((screen-a).dx*ab.dx+(screen-a).dy*ab.dy)/length).clamp(0.0,1.0).toDouble();
   final projected=a+ab*t,distance=(screen-projected).distance;
   if(best==null||distance<best.distance)best=_RouteHit(i,t,projected,distance);
  }
  return best;
 }
 int? _closestVertex(Offset screen){
  var bestIndex=-1,bestDistance=double.infinity;
  final stride=pts.length>24?(pts.length+23)~/24:1;
  for(var i=0;i<pts.length;i+=stride){final d=(mc.camera.latLngToScreenOffset(pts[i])-screen).distance;if(d<bestDistance){bestIndex=i;bestDistance=d;}}
  if((pts.length-1)%stride!=0){final i=pts.length-1,d=(mc.camera.latLngToScreenOffset(pts[i])-screen).distance;if(d<bestDistance){bestIndex=i;bestDistance=d;}}
  return bestDistance<=22?bestIndex:null;
 }
 void _beginRouteDrag(Offset screen){
  if(!editingPoints||addingStop||pts.length<2)return;
  final point=mc.camera.screenOffsetToLatLng(screen);
  if(moveWholeRoute){routeDragKind=_RouteDragKind.whole;routeDragIndex=-1;routeDragT=0;}
  else{
   final vertex=_closestVertex(screen);
   if(vertex!=null){routeDragKind=_RouteDragKind.point;routeDragIndex=vertex;routeDragT=0;}
   else{final hit=_closestSegment(screen);if(hit==null||hit.distance>34)return;routeDragKind=_RouteDragKind.segment;routeDragIndex=hit.index;routeDragT=hit.t;}
  }
  routeDragAnchor=point;routeDragOriginal=List<LatLng>.of(pts);routeDragDistances=List<double>.filled(pts.length,0);
  for(var i=1;i<pts.length;i++)routeDragDistances[i]=routeDragDistances[i-1]+D(pts[i-1],pts[i]);
  routeDragCenterDistance=routeDragKind==_RouteDragKind.segment?routeDragDistances[routeDragIndex]+(routeDragDistances[routeDragIndex+1]-routeDragDistances[routeDragIndex])*routeDragT:(routeDragKind==_RouteDragKind.point?routeDragDistances[routeDragIndex]:0);
 }
 void _updateRouteDrag(Offset screen){
  final original=routeDragOriginal,anchor=routeDragAnchor;if(original==null||anchor==null||routeDragKind==_RouteDragKind.none)return;
  final current=mc.camera.screenOffsetToLatLng(screen),dLat=current.latitude-anchor.latitude,dLon=current.longitude-anchor.longitude;
  final total=routeDragDistances.isEmpty?0:routeDragDistances.last;
  final radius=(total*0.14).clamp(80.0,500.0).toDouble();
  final moved=List<LatLng>.generate(original.length,(i){
   if(routeDragKind==_RouteDragKind.point)return i==routeDragIndex?LatLng(original[i].latitude+dLat,original[i].longitude+dLon):original[i];
   if(routeDragKind==_RouteDragKind.whole)return LatLng(original[i].latitude+dLat,original[i].longitude+dLon);
   final x=((routeDragDistances[i]-routeDragCenterDistance).abs()/radius).clamp(0.0,1.0).toDouble(),weight=1-(x*x*(3-2*x));
   return LatLng(original[i].latitude+dLat*weight,original[i].longitude+dLon*weight);
  });
  setState((){pts..clear()..addAll(moved);distanceC.text=actualKm.toStringAsFixed(2);syncEnd();});
 }
 void _endRouteDrag(){routeDragKind=_RouteDragKind.none;routeDragOriginal=null;routeDragAnchor=null;routeDragDistances=const[];}

 @override void dispose(){timer?.cancel();for(final controller in _mapControllers){controller.dispose();}speedC.dispose();distanceC.dispose();super.dispose();}
 void add(LatLng p){if(!drawing||routeFinished)return;setState((){pts.add(p);undo.clear();if(smooth&&pts.length>2){final a=pts[pts.length-3],b=pts[pts.length-2],d=pts.last;pts[pts.length-2]=LatLng((a.latitude+b.latitude*2+d.latitude)/4,(a.longitude+b.longitude*2+d.longitude)/4);}distanceC.text=actualKm.toStringAsFixed(2);syncEnd();});}
 void freehandPoint(Offset local){if(!drawing||!freehandActive||activePointers!=1)return;final p=mc.camera.screenOffsetToLatLng(local);if(pts.isNotEmpty&&D(pts.last,p)<2)return;add(p);}
 void clearRoute(){setState((){pts.clear();stops.clear();undo.clear();distanceC.clear();routeFinished=false;drawing=false;editingPoints=false;syncEnd();});}
 void finishHere(){if(pts.length<2)return;setState((){routeFinished=true;drawing=false;editingPoints=false;freehandActive=false;syncEnd();});}
 void closeAndFinish(){if(pts.length<3)return;setState((){if(D(pts.last,pts.first)>0.5)pts.add(pts.first);distanceC.text=actualKm.toStringAsFixed(2);routeFinished=true;drawing=false;freehandActive=false;syncEnd();});}
 void back(){if(pts.isEmpty)return;setState((){undo.add(pts.removeLast());stops.removeWhere((s)=>s.index>=pts.length);distanceC.text=actualKm.toStringAsFixed(2);});}
 void forward(){if(undo.isEmpty)return;setState((){pts.add(undo.removeLast());distanceC.text=actualKm.toStringAsFixed(2);});}
 Future<void> locate()async{
  if(!await Geolocator.isLocationServiceEnabled()){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Telefon konum servisini açın.')));return;}
  var permission=await Geolocator.checkPermission();
  if(permission==LocationPermission.denied)permission=await Geolocator.requestPermission();
  if(permission==LocationPermission.denied||permission==LocationPermission.deniedForever){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Konum izni gerekli. Android ayarlarında Kesin konum iznini açın.')));return;}
  try{
   final accuracyStatus=await Geolocator.getLocationAccuracy();
   var best=await Geolocator.getCurrentPosition(locationSettings:const LocationSettings(accuracy:LocationAccuracy.bestForNavigation,distanceFilter:0,timeLimit:Duration(seconds:20)));
   if(best.accuracy>15){
    final improved=Completer<void>();
    final subscription=Geolocator.getPositionStream(locationSettings:const LocationSettings(accuracy:LocationAccuracy.bestForNavigation,distanceFilter:0)).listen((fix){
     if(fix.accuracy<best.accuracy)best=fix;
     if(best.accuracy<=10&&!improved.isCompleted)improved.complete();
    },onError:(_){if(!improved.isCompleted)improved.complete();});
    await Future.any([improved.future,Future<void>.delayed(const Duration(seconds:7))]);
    await subscription.cancel();
   }
   if(!mounted)return;
   setState(()=>me=LatLng(best.latitude,best.longitude));
   mc.move(me!,best.accuracy<=15?18:17);
   final note=accuracyStatus==LocationAccuracyStatus.reduced||best.accuracy>30
    ?'Konum yaklaşık ±${best.accuracy.toStringAsFixed(0)} m doğrulukta. Kesin konum iznini açıp açık alanda yeniden deneyin.'
    :'Konum doğruluğu yaklaşık ±${best.accuracy.toStringAsFixed(0)} m.';
   ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(note)));
  }catch(_){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Kesin konum alınamadı. GPS açık ve Kesin konum izni etkin olmalı.')));}
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
 Future<void> generateAutomaticStops() async {
  if(pts.length<2)return;
  final movementSeconds=estimatedMove.inSeconds;
  if(manualSpeed<=0||movementSeconds<12*60){
   if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Otomatik durak için rota en az 12 dakikalık hareket süresine sahip olmalı.')));
   return;
  }
  final original=List<LatLng>.of(pts);
  final cumulative=List<double>.filled(original.length,0);
  for(var i=1;i<original.length;i++)cumulative[i]=cumulative[i-1]+D(original[i-1],original[i]);
  final pathMeters=cumulative.last;
  if(pathMeters<100){
   if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Durak oluşturmak için rota biraz daha uzun olmalı.')));
   return;
  }
  final random=math.Random();
  final count=(movementSeconds/(20*60)).ceil().clamp(1,10).toInt();
  final sectionSeconds=movementSeconds/(count+1);
  final occupiedMeters=<double>[
   for(final stop in stops)cumulative[stop.index.clamp(0,original.length-1).toInt()],
  ];
  final candidates=<MapEntry<double,int>>[];
  for(var i=0;i<count;i++){
   final jitter=(random.nextDouble()-0.5)*sectionSeconds*0.28;
   final targetSeconds=(sectionSeconds*(i+1)+jitter).clamp(300.0,(movementSeconds-300).toDouble()).toDouble();
   final targetMeters=pathMeters*targetSeconds/movementSeconds;
   if(occupiedMeters.any((meters)=>(meters-targetMeters).abs()<250))continue;
   final roll=random.nextInt(100);
   final waitSeconds=roll<62?5+random.nextInt(26):roll<94?60+random.nextInt(121):300+random.nextInt(301);
   candidates.add(MapEntry(targetMeters,waitSeconds));
   occupiedMeters.add(targetMeters);
  }
  candidates.sort((a,b)=>a.key.compareTo(b.key));
  var added=0,insertedBefore=0;
  setState((){
   for(final candidate in candidates){
    var segmentIndex=0;
    while(segmentIndex<original.length-2&&candidate.key>cumulative[segmentIndex+1])segmentIndex++;
    final span=cumulative[segmentIndex+1]-cumulative[segmentIndex];
    final ratio=span<=0?0.0:((candidate.key-cumulative[segmentIndex])/span).clamp(0.0,1.0).toDouble();
    var stopIndex=segmentIndex+insertedBefore;
    if(ratio>=0.985)stopIndex++;
    else if(ratio>0.015){
     final a=original[segmentIndex],b=original[segmentIndex+1];
     final point=LatLng(a.latitude+(b.latitude-a.latitude)*ratio,a.longitude+(b.longitude-a.longitude)*ratio);
     stopIndex=segmentIndex+1+insertedBefore;
     pts.insert(stopIndex,point);
     for(var i=0;i<stops.length;i++){if(stops[i].index>=stopIndex)stops[i]=Stop(stops[i].index+1,stops[i].sec);}
     insertedBefore++;
    }
    stops.add(Stop(stopIndex,candidate.value));
    added++;
   }
   stops.sort((a,b)=>a.index.compareTo(b.index));
   syncEnd();
  });
  if(mounted){
   final message=added==0?'Bu rotadaki mevcut duraklara yakın yeni bir konum bulunamadı.':'$added otomatik durak eklendi. Sürelerini Duraklar bölümünden değiştirebilirsiniz.';
   ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(message)));
  }
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
 Future<void> shareType(String type)async{try{final p=await writeExport(type);await SharePlus.instance.share(ShareParams(files:[XFile(p)]));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}}
 Future<void> shareZip()async{try{final types=['gpx-track','gpx-route','kml','geojson','csv','json','txt','bin','rotasim'];final files=<String>[];for(final t in types)files.add(await writeExport(t));final dir=await getTemporaryDirectory();final stamp=DateFormat('yyyy-MM-dd HHmmss').format(end);final zip='${dir.path}/$stamp.zip';final ar=Archive();for(final p in files){final f=File(p);final data=await f.readAsBytes();ar.addFile(ArchiveFile(p.split('/').last,data.length,data));}await File(zip).writeAsBytes(ZipEncoder().encode(ar));await SharePlus.instance.share(ShareParams(files:[XFile(zip)]));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}}
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
  final editStride=pts.length>24?(pts.length+23)~/24:1;
  Widget logo()=>RichText(text:const TextSpan(style:TextStyle(fontSize:24,fontWeight:FontWeight.w800),children:[TextSpan(text:'Rota',style:TextStyle(color:Colors.white)),TextSpan(text:'Sim',style:TextStyle(color:purple))]));
  Widget stepper()=>Padding(padding:const EdgeInsets.fromLTRB(16,8,16,12),child:Row(children:List.generate(4,(i)=>Expanded(child:Column(children:[
   Row(children:[if(i>0)Expanded(child:Container(height:2,color:i<=flowStep?purple:Colors.white24)),CircleAvatar(radius:11,backgroundColor:i<=flowStep?purple:Colors.white24,child:i<flowStep?const Icon(Icons.check,size:13):Text('${i+1}',style:const TextStyle(fontSize:10))),if(i<3)Expanded(child:Container(height:2,color:i<flowStep?purple:Colors.white24))]),
   const SizedBox(height:5),Text(['Rota Çiz','Bilgiler','Önizleme','Paylaş'][i],style:TextStyle(fontSize:9,color:i==flowStep?Colors.white:Colors.white54)),
  ])))));
  Widget navButton(String text,VoidCallback? tap,{bool primary=true,IconData? icon})=>Expanded(child:SizedBox(height:50,child:primary?FilledButton.icon(onPressed:tap,style:FilledButton.styleFrom(backgroundColor:purple),icon:Icon(icon??Icons.arrow_forward),label:Text(text)):OutlinedButton.icon(onPressed:tap,icon:Icon(icon??Icons.arrow_back),label:Text(text))));
  Widget topBar({String? title,bool backBtn=false})=>SafeArea(bottom:false,child:Container(height:58,padding:const EdgeInsets.symmetric(horizontal:10),decoration:BoxDecoration(color:bg.withValues(alpha:.93)),child:Row(children:[
   if(backBtn)IconButton(tooltip:'Geri',onPressed:()=>goToStep(flowStep>0?flowStep-1:0),icon:const Icon(Icons.arrow_back)),
   if(title!=null)Text(title,style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold))else logo(),
   const Spacer(),
   if(title==null)IconButton(tooltip:'Rota dosyası içe aktar',onPressed:importTrack,icon:const Icon(Icons.file_open_outlined)),
   TextButton.icon(onPressed:()=>setState((){mapMode=mapMode==0?1:0;mapError=false;mapRetry++;}),icon:Icon(mapMode==0?Icons.satellite_alt_outlined:Icons.map_outlined),label:Text(mapMode==0?'Uydu':'Harita')),
   IconButton(tooltip:'Kayıtlı Rotalar',onPressed:saved,icon:const Icon(Icons.bookmarks_outlined)),
  ])));
  Widget metric(String value,String label)=>Column(mainAxisAlignment:MainAxisAlignment.center,children:[Text(value,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:14),maxLines:1,overflow:TextOverflow.ellipsis),const SizedBox(height:2),Text(label,style:const TextStyle(fontSize:8,color:Colors.white54),maxLines:1,overflow:TextOverflow.ellipsis)]);
  Widget summary()=>Container(padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:card,borderRadius:BorderRadius.circular(12)),child:GridView.count(
   crossAxisCount:3,shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),mainAxisSpacing:4,crossAxisSpacing:4,childAspectRatio:2.15,
   children:[metric('${effectiveKm.toStringAsFixed(2)} km','MESAFE'),metric('${manualSpeed.toStringAsFixed(1)} km/sa','ORT. HIZ'),metric(durationText(estimatedMove),'HAREKET'),metric(durationText(Duration(seconds:stopSec)),'BEKLEME'),metric(durationText(estimatedTotal),'TOPLAM'),metric('${stops.length}','DURAK')],
  ));
  Widget mapWidget()=>Listener(
   behavior:HitTestBehavior.opaque,
   onPointerDown:(e){
    activePointers++;
    if(activePointers==1&&drawing){freehandActive=true;freehandPoint(e.localPosition);}
    else if(activePointers==1&&editingPoints&&flowStep==0){freehandActive=false;_beginRouteDrag(e.localPosition);}
    else{freehandActive=false;if(activePointers>1)_endRouteDrag();}
   },
   onPointerMove:(e){if(activePointers!=1)return;if(routeDragKind!=_RouteDragKind.none){_updateRouteDrag(e.localPosition);}else{freehandPoint(e.localPosition);}},
   onPointerUp:(_){activePointers=(activePointers-1).clamp(0,10);freehandActive=false;if(activePointers==0)_endRouteDrag();},
   onPointerCancel:(_){activePointers=(activePointers-1).clamp(0,10);freehandActive=false;_endRouteDrag();},
  child:KeyedSubtree(key:mapGestureKeys[flowStep],child:FlutterMap(
    key:ValueKey('rotasim-map-$flowStep-$mapRetry'),
    mapController:mc,
    options:MapOptions(
     initialCenter:pts.isNotEmpty?pts[pts.length~/2]:(me??const LatLng(39.93,32.86)),
     initialZoom:pts.isNotEmpty?14:(me!=null?16:12),
     backgroundColor:mapBg,
     cameraConstraint:CameraConstraint.contain(bounds:LatLngBounds(const LatLng(-85.05112878,-180),const LatLng(85.05112878,180))),
     interactionOptions:InteractionOptions(flags:(drawing||editingPoints)&&flowStep==0?(InteractiveFlag.pinchMove|InteractiveFlag.pinchZoom):InteractiveFlag.all,enableMultiFingerGestureRace:true),
     onMapReady:fitRoute,
     onTap:(position,point){if(addingStop)unawaited(selectStopAt(point));},
    ),
    children:[
     if(mapMode==0)const MapLibreLayer(
      initStyle:'https://tiles.openfreemap.org/styles/liberty',
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
      if(pts.isNotEmpty&&!editingPoints)Marker(point:pts.first,width:36,height:36,child:const Icon(Icons.circle,color:Colors.greenAccent,size:28)),
      if(pts.length>1&&!editingPoints)Marker(point:pts.last,width:36,height:36,child:const Icon(Icons.location_on,color:Colors.redAccent,size:34)),
      for(final st in stops)if(st.index>=0&&st.index<pts.length)Marker(point:pts[st.index],width:34,height:34,child:const Icon(Icons.circle,color:Colors.orangeAccent,size:24)),
      if(editingPoints&&flowStep==0)for(var i=0;i<pts.length;i+=editStride)Marker(point:pts[i],width:26,height:26,child:Center(child:Container(width:14,height:14,decoration:BoxDecoration(color:i==0?Colors.greenAccent:i==pts.length-1?Colors.redAccent:purple,shape:BoxShape.circle,border:Border.all(color:Colors.white,width:2),boxShadow:const [BoxShadow(color:Colors.black54,blurRadius:4)])))),
      if(editingPoints&&flowStep==0&&(pts.length-1)%editStride!=0)Marker(point:pts.last,width:26,height:26,child:Center(child:Container(width:14,height:14,decoration:BoxDecoration(color:Colors.redAccent,shape:BoxShape.circle,border:Border.all(color:Colors.white,width:2),boxShadow:const [BoxShadow(color:Colors.black54,blurRadius:4)])))),
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
     if(editingPoints&&!mapError)Positioned(left:64,right:60,top:0,child:SafeArea(child:Container(margin:const EdgeInsets.only(top:66),padding:const EdgeInsets.symmetric(horizontal:10,vertical:8),decoration:BoxDecoration(color:bg.withValues(alpha:.92),borderRadius:BorderRadius.circular(12)),child:Text(moveWholeRoute?'Haritanın boş bir yerinden sürükleyerek rotanın tamamını taşıyın.':'Mor çizgiye dokunup sürükleyerek o bölümü düzenleyin. Harita için iki parmak kullanın.',textAlign:TextAlign.center,style:const TextStyle(fontSize:12))))),
     if(!drawing&&!addingStop)Positioned(left:10,top:0,child:SafeArea(child:Padding(padding:const EdgeInsets.only(top:64),child:DecoratedBox(decoration:BoxDecoration(color:bg.withValues(alpha:.58),borderRadius:BorderRadius.circular(6)),child:Padding(padding:const EdgeInsets.symmetric(horizontal:6,vertical:3),child:Text(mapMode==0?'© OpenMapTiles • © OpenStreetMap contributors':'© Esri World Imagery',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:9,color:Colors.white70))))))),
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
      if(pts.isNotEmpty&&!addingStop)Container(margin:const EdgeInsets.only(bottom:8),padding:const EdgeInsets.symmetric(horizontal:8,vertical:4),decoration:BoxDecoration(color:bg.withValues(alpha:.93),borderRadius:BorderRadius.circular(12)),child:Column(mainAxisSize:MainAxisSize.min,children:[Row(children:[const Icon(Icons.alt_route,color:purple),const SizedBox(width:6),Text('${actualKm.toStringAsFixed(2)} km'),const Spacer(),if(!drawing)IconButton(tooltip:editingPoints?'Düzenlemeyi bitir':'Rotayı düzenle',onPressed:()=>setState(()=>editingPoints=!editingPoints),icon:Icon(editingPoints?Icons.done:Icons.edit_location_alt_outlined)),if(!drawing)TextButton(onPressed:()=>setState((){drawing=true;editingPoints=false;routeFinished=false;}),child:Text(routeFinished?'ÇİZİMLE DÜZENLE':'DEVAM ET'))]),if(editingPoints)Row(children:[Expanded(child:ChoiceChip(label:const Text('BÖLÜMÜ DÜZENLE',style:TextStyle(fontSize:10)),selected:!moveWholeRoute,onSelected:(_)=>setState(()=>moveWholeRoute=false))),const SizedBox(width:8),Expanded(child:ChoiceChip(label:const Text('TÜM ROTAYI TAŞI',style:TextStyle(fontSize:10)),selected:moveWholeRoute,onSelected:(_)=>setState(()=>moveWholeRoute=true)))])])),
      if(addingStop)Container(margin:const EdgeInsets.only(bottom:8),padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),decoration:BoxDecoration(color:bg.withValues(alpha:.91),borderRadius:BorderRadius.circular(12)),child:const Text('Durak yerini seçin',textAlign:TextAlign.center)),
      SizedBox(width:double.infinity,height:54,child:FilledButton(
       onPressed:addingStop?()=>setState(()=>addingStop=false):pts.length>=2?(){finishHere();setState(()=>flowStep=1);}:()=>setState((){drawing=true;editingPoints=false;routeFinished=false;}),
       style:FilledButton.styleFrom(backgroundColor:purple),
       child:Text(addingStop?'VAZGEÇ':pts.length>=2?(drawing?'BİTİR VE DEVAM ET':'SONRAKİ  →'):(pts.isEmpty?'ROTA ÇİZMEYE BAŞLA':'ÇİZİME DEVAM ET'),style:const TextStyle(fontWeight:FontWeight.bold,letterSpacing:.3)),
      )),
     ])))),
    ])),
   );
  }
  if(flowStep==1){
   return Scaffold(backgroundColor:bg,body:SafeArea(child:Column(children:[
    topBar(title:'Rota Bilgileri',backBtn:true),stepper(),
    Expanded(child:ListView(padding:const EdgeInsets.symmetric(horizontal:14),children:[
     Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:card,borderRadius:BorderRadius.circular(10)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${actualKm.toStringAsFixed(2)} km\nHaritadan ölçülen mesafe',style:const TextStyle(fontSize:16,fontWeight:FontWeight.bold)),const SizedBox(height:8),Row(children:[Text('${stops.length} durak • ${durationText(Duration(seconds:stopSec))}'),const Spacer(),OutlinedButton.icon(onPressed:pts.length<2?null:addStopMode,icon:const Icon(Icons.add),label:const Text('DURAK EKLE'))])])),const SizedBox(height:10),
     _section('BAŞLANGIÇ',[ListTile(title:const Text('Başlangıç tarihi / saati'),subtitle:Text(DateFormat('dd.MM.yyyy • HH:mm:ss').format(start)),trailing:const Icon(Icons.calendar_month),onTap:()=>pick(true))]),const SizedBox(height:8),
     _section('MESAFE',[TextField(controller:distanceC,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(suffixText:'km',hintText:'Haritadan ölçülen mesafe'),onChanged:(_)=>setState(syncEnd))]),const SizedBox(height:8),
     _section('ORTALAMA HIZ',[TextField(controller:speedC,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(suffixText:'km/sa'),onChanged:(_)=>setState(syncEnd))]),const SizedBox(height:8),
     _section('SÜRELER',[ListTile(title:const Text('Tahmini hareket süresi'),subtitle:Text(durationText(estimatedMove))),ListTile(title:const Text('Toplam bekleme'),subtitle:Text(durationText(Duration(seconds:stopSec)))),ListTile(title:const Text('Toplam rota süresi'),subtitle:Text(durationText(estimatedTotal)))]),const SizedBox(height:8),
     _section('DURAKLAR',[Row(children:[Text('${stops.length} durak • ${durationText(Duration(seconds:stopSec))}'),const Spacer(),OutlinedButton.icon(onPressed:pts.length<2?null:addStopMode,icon:const Icon(Icons.add),label:const Text('Haritadan ekle'))]),SizedBox(width:double.infinity,child:OutlinedButton.icon(onPressed:pts.length<2?null:generateAutomaticStops,icon:const Icon(Icons.auto_awesome),label:const Text('Otomatik durak ekle'))),const Padding(padding:EdgeInsets.only(bottom:4),child:Text('Hareket süresine göre rota üzerine dağılır; saniyelik ve daha uzun molalar karışık olur. Mevcut duraklar korunur.',style:TextStyle(fontSize:11,color:Colors.white60))),for(var i=0;i<stops.length;i++)ListTile(title:Text('Durak ${i+1}'),subtitle:Text('Bekleme: ${durationText(Duration(seconds:stops[i].sec))}'),trailing:IconButton(tooltip:'Bekleme süresini düzenle',onPressed:()=>stopAt(stops[i].index),icon:const Icon(Icons.edit)))]),const SizedBox(height:8),
     _section('TAHMİNİ BİTİŞ',[SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Bitiş zamanını otomatik hesapla'),value:autoEnd,onChanged:(v)=>setState((){autoEnd=v;if(v)syncEnd();})),ListTile(title:Text(autoEnd?'Tahmini bitiş':'Elle seçilen bitiş'),subtitle:Text(DateFormat('dd.MM.yyyy • HH:mm:ss').format(autoEnd?estimatedEnd:end)),trailing:IconButton(onPressed:autoEnd?null:()=>pick(false),icon:const Icon(Icons.edit))) ,Text('Başlangıç + hareket + bekleme = bitiş',style:TextStyle(color:Colors.white.withValues(alpha:.62),fontSize:12))]),const SizedBox(height:20),
    ])),
    Padding(padding:const EdgeInsets.all(14),child:Row(children:[navButton('GERİ',()=>goToStep(0),primary:false),const SizedBox(width:10),navButton('SONRAKİ',nextToPreview)])),
   ])));
  }
  if(flowStep==2){
   return Scaffold(backgroundColor:bg,body:SafeArea(child:Column(children:[
    topBar(title:'Rotayı Önizle',backBtn:true),stepper(),
    Expanded(child:LayoutBuilder(builder:(context,box){final mapHeight=(box.maxHeight*.36).clamp(160.0,340.0).toDouble();return Padding(padding:const EdgeInsets.fromLTRB(14,0,14,8),child:Column(children:[
     SizedBox(width:double.infinity,height:mapHeight,child:ClipRRect(borderRadius:BorderRadius.circular(14),child:Stack(fit:StackFit.expand,children:[mapWidget(),if(mapError)Align(alignment:Alignment.bottomCenter,child:Container(margin:const EdgeInsets.all(8),padding:const EdgeInsets.symmetric(horizontal:10,vertical:4),decoration:BoxDecoration(color:bg.withValues(alpha:.94),borderRadius:BorderRadius.circular(10)),child:Row(mainAxisSize:MainAxisSize.min,children:[const Flexible(child:Text('Harita yüklenemedi',maxLines:1,overflow:TextOverflow.ellipsis)),TextButton(onPressed:retryMap,child:const Text('YENİDEN DENE'))])))]))),const SizedBox(height:8),summary(),const SizedBox(height:8),
     Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:9),decoration:BoxDecoration(color:card,borderRadius:BorderRadius.circular(12)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('BAŞLANGIÇ',style:TextStyle(fontSize:9,color:Colors.white54)),Text(DateFormat('dd.MM.yyyy • HH:mm:ss').format(start),style:const TextStyle(fontSize:12,fontWeight:FontWeight.w600))])),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('BİTİŞ',style:TextStyle(fontSize:9,color:Colors.white54)),Text(DateFormat('dd.MM.yyyy • HH:mm:ss').format(autoEnd?estimatedEnd:end),style:const TextStyle(fontSize:12,fontWeight:FontWeight.w600))]))])),const SizedBox(height:8),
     SizedBox(width:double.infinity,height:46,child:FilledButton.icon(onPressed:animate,style:FilledButton.styleFrom(backgroundColor:purple),icon:const Icon(Icons.play_arrow),label:const Text('ROTAYI ÖNİZLE'))),
    ]));})),
    Padding(padding:const EdgeInsets.fromLTRB(14,4,14,14),child:Row(children:[navButton('DÜZENLE',()=>goToStep(1),primary:false,icon:Icons.arrow_back),const SizedBox(width:10),navButton('DEVAM ET',()=>goToStep(3))])),
   ])));
  }
  return Scaffold(backgroundColor:bg,body:SafeArea(child:Column(children:[
   topBar(title:'Kaydet / Paylaş',backBtn:true),stepper(),
   Expanded(child:LayoutBuilder(builder:(context,box){final mapHeight=(box.maxHeight*.25).clamp(130.0,210.0).toDouble();return Padding(padding:const EdgeInsets.fromLTRB(14,0,14,10),child:Column(children:[
    SizedBox(width:double.infinity,height:mapHeight,child:ClipRRect(borderRadius:BorderRadius.circular(14),child:Stack(fit:StackFit.expand,children:[mapWidget(),if(mapError)Align(alignment:Alignment.bottomCenter,child:Container(margin:const EdgeInsets.all(8),padding:const EdgeInsets.symmetric(horizontal:10,vertical:4),decoration:BoxDecoration(color:bg.withValues(alpha:.94),borderRadius:BorderRadius.circular(10)),child:Row(mainAxisSize:MainAxisSize.min,children:[const Flexible(child:Text('Harita yüklenemedi',maxLines:1,overflow:TextOverflow.ellipsis)),TextButton(onPressed:retryMap,child:const Text('YENİDEN DENE'))])))]))),
    Expanded(child:ListView(padding:const EdgeInsets.only(top:10,bottom:10),children:[
     summary(),const SizedBox(height:10),
     Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:card,borderRadius:BorderRadius.circular(12)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(routeLabel,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:16)),const SizedBox(height:8),
      Text('Başlangıç: ${DateFormat('HH:mm:ss').format(start)}'),Text('Bitiş: ${DateFormat('HH:mm:ss').format(autoEnd?estimatedEnd:end)}'),Text('Mesafe: ${effectiveKm.toStringAsFixed(2)} km'),Text('Ortalama hız: ${manualSpeed.toStringAsFixed(1)} km/sa'),Text('Hareket: ${durationText(estimatedMove)}'),Text('Durak sayısı: ${stops.length}'),Text('Bekleme: ${durationText(Duration(seconds:stopSec))}'),Text('Toplam süre: ${durationText(estimatedTotal)}'),
     ])),Center(child:TextButton(onPressed:(){clearRoute();setState(()=>flowStep=0);},child:const Text('Yeni Rota Oluştur'))),
    ])),
    SizedBox(width:double.infinity,height:50,child:FilledButton.icon(onPressed:save,style:FilledButton.styleFrom(backgroundColor:purple),icon:const Icon(Icons.save_outlined),label:const Text('ROTAYI KAYDET'))),const SizedBox(height:8),
    SizedBox(width:double.infinity,height:50,child:FilledButton.icon(onPressed:()=>shareType('gpx-track'),style:FilledButton.styleFrom(backgroundColor:const Color(0xFF5530A8)),icon:const Icon(Icons.share),label:const Text('GPX TRACK PAYLAŞ'))),
   ]));})),
  ])));
 }
 Widget _section(String title,List<Widget> children)=>Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:const Color(0xFF141A23),borderRadius:BorderRadius.circular(10),border:Border.all(color:Colors.white10)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(fontSize:12,fontWeight:FontWeight.bold,color:Colors.white70)),const SizedBox(height:6),...children]));
}
