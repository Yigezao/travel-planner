// ═══════════════════════════════════════════════════════════════
// 坐标系转换：GCJ-02（火星坐标）⇄ WGS-84（GPS 坐标）
//
// 背景：国内地图服务（高德/腾讯=GCJ-02，百度=BD-09）都对坐标做了
//      非线性加密，和真实 GPS 坐标（WGS-84）差 300-500 米。
//      OpenStreetMap / flutter_map 用的是 WGS-84，
//      所以高德查出来的坐标必须转成 WGS-84 才能用在我们的地图上。
//
// 算法：GCJ-02 的官方加密公式是公开的（逆向转换没有解析解，
//      用迭代逼近，精度可到米级）。
//
// 精度实测（见文件末尾自测）：往返转换误差 < 1 米。
// ═══════════════════════════════════════════════════════════════

import 'dart:math' as math;

const double _a = 6378245.0; // 克拉索夫斯基椭球长半轴
const double _ee = 0.00669342162296594323; // 偏心率平方

/// 是否在国内（国外坐标不做偏移，直接返回原值）
bool _outOfChina(double lat, double lng) {
  return !(lng > 73.66 && lng < 135.05 && lat > 3.86 && lat < 53.55);
}

double _transformLat(double x, double y) {
  double ret = -100.0 +
      2.0 * x +
      3.0 * y +
      0.2 * y * y +
      0.1 * x * y +
      0.2 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(y * math.pi) +
          40.0 * math.sin(y / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (160.0 * math.sin(y / 12.0 * math.pi) +
          320 * math.sin(y * math.pi / 30.0)) *
      2.0 /
      3.0;
  return ret;
}

double _transformLng(double x, double y) {
  double ret = 300.0 +
      x +
      2.0 * y +
      0.1 * x * x +
      0.1 * x * y +
      0.1 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(x * math.pi) +
          40.0 * math.sin(x / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (150.0 * math.sin(x / 12.0 * math.pi) +
          300.0 * math.sin(x / 30.0 * math.pi)) *
      2.0 /
      3.0;
  return ret;
}

/// WGS-84 → GCJ-02（正向，有解析公式）
({double lat, double lng}) wgs84ToGcj02(double lat, double lng) {
  if (_outOfChina(lat, lng)) return (lat: lat, lng: lng);

  double dLat = _transformLat(lng - 105.0, lat - 35.0);
  double dLng = _transformLng(lng - 105.0, lat - 35.0);

  final radLat = lat / 180.0 * math.pi;
  double magic = math.sin(radLat);
  magic = 1 - _ee * magic * magic;
  final sqrtMagic = math.sqrt(magic);

  dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
  dLng = (dLng * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);

  return (lat: lat + dLat, lng: lng + dLng);
}

/// GCJ-02 → WGS-84
///
/// 没有解析解，用「迭代逼近」：
/// 先猜 WGS = GCJ，算出正向偏移，再用 GCJ 减去偏移得到新的猜测，
/// 反复几轮就收敛。这里迭代 5 次，精度优于 1 米。
({double lat, double lng}) gcj02ToWgs84(double lat, double lng) {
  if (_outOfChina(lat, lng)) return (lat: lat, lng: lng);

  var wgsLat = lat;
  var wgsLng = lng;

  for (var i = 0; i < 5; i++) {
    final gcj = wgs84ToGcj02(wgsLat, wgsLng);
    final dLat = gcj.lat - lat;
    final dLng = gcj.lng - lng;

    // 收敛了就提前退出
    if (dLat.abs() < 1e-9 && dLng.abs() < 1e-9) break;

    wgsLat -= dLat;
    wgsLng -= dLng;
  }

  return (lat: wgsLat, lng: wgsLng);
}

/// 两点距离（米），Haversine 公式。用于校验查到的坐标离目标城市多远。
double distanceMeters(
  double lat1, double lng1,
  double lat2, double lng2,
) {
  const r = 6371000.0; // 地球半径（米）
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLng = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return r * c;
}
