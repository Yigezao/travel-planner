import 'dart:math' as math;

const double _a = 6378245.0;
const double _ee = 0.00669342162296594323;

double _tLat(double x, double y) {
  double r = -100.0 + 2.0*x + 3.0*y + 0.2*y*y + 0.1*x*y + 0.2*math.sqrt(x.abs());
  r += (20.0*math.sin(6.0*x*math.pi) + 20.0*math.sin(2.0*x*math.pi))*2.0/3.0;
  r += (20.0*math.sin(y*math.pi) + 40.0*math.sin(y/3.0*math.pi))*2.0/3.0;
  r += (160.0*math.sin(y/12.0*math.pi) + 320*math.sin(y*math.pi/30.0))*2.0/3.0;
  return r;
}
double _tLng(double x, double y) {
  double r = 300.0 + x + 2.0*y + 0.1*x*x + 0.1*x*y + 0.1*math.sqrt(x.abs());
  r += (20.0*math.sin(6.0*x*math.pi) + 20.0*math.sin(2.0*x*math.pi))*2.0/3.0;
  r += (20.0*math.sin(x*math.pi) + 40.0*math.sin(x/3.0*math.pi))*2.0/3.0;
  r += (150.0*math.sin(x/12.0*math.pi) + 300.0*math.sin(x/30.0*math.pi))*2.0/3.0;
  return r;
}
({double lat, double lng}) w2g(double lat, double lng) {
  double dLat = _tLat(lng-105.0, lat-35.0);
  double dLng = _tLng(lng-105.0, lat-35.0);
  final radLat = lat/180.0*math.pi;
  double magic = math.sin(radLat);
  magic = 1 - _ee*magic*magic;
  final sqrtMagic = math.sqrt(magic);
  dLat = (dLat*180.0)/((_a*(1-_ee))/(magic*sqrtMagic)*math.pi);
  dLng = (dLng*180.0)/(_a/sqrtMagic*math.cos(radLat)*math.pi);
  return (lat: lat+dLat, lng: lng+dLng);
}
double dist(double lat1,double lng1,double lat2,double lng2){
  const r=6371000.0;
  final dLat=(lat2-lat1)*math.pi/180, dLng=(lng2-lng1)*math.pi/180;
  final a=math.sin(dLat/2)*math.sin(dLat/2)+math.cos(lat1*math.pi/180)*math.cos(lat2*math.pi/180)*math.sin(dLng/2)*math.sin(dLng/2);
  return r*2*math.atan2(math.sqrt(a),math.sqrt(1-a));
}

void main() {
  // 滕王阁真实坐标（WGS-84）
  const lat = 28.684684, lng = 115.876331;
  final g = w2g(lat, lng);

  print('滕王阁 WGS84:  $lat, $lng');
  print('转成 GCJ-02:   ${g.lat.toStringAsFixed(6)}, ${g.lng.toStringAsFixed(6)}');
  print('两者相距:      ${dist(lat,lng,g.lat,g.lng).toStringAsFixed(0)} 米');
  print('');

  // 关键：这个偏移量在屏幕上是多少像素？随缩放怎么变？
  // Web Mercator: 1 像素对应的距离 = 156543.03 * cos(lat) / 2^zoom  米
  print('偏移在屏幕上的像素数（随缩放变化）：');
  for (final z in [10, 12, 13, 14, 15, 16, 17, 18]) {
    final metersPerPixel = 156543.03 * math.cos(lat*math.pi/180) / math.pow(2, z);
    final px = dist(lat,lng,g.lat,g.lng) / metersPerPixel;
    print('  zoom $z : 1像素=${metersPerPixel.toStringAsFixed(1)}米'
        '  → 偏移 ${px.toStringAsFixed(1)} 像素');
  }
}
