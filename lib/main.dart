import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';

const platform = MethodChannel('esp32.network/bind');

Future<void> bindToEsp32Network() async {
  try {
    await platform.invokeMethod('bindToESP32');
  } on PlatformException catch (e) {
    print("Failed to bind to network: ${e.message}");
  }
}



void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final Location _locationService = Location();
  final MapController _mapController = MapController();
  final TextEditingController _locationController = TextEditingController();

  bool _isLoading = true;
  bool _isNavigating = false;
  LatLng? _currentLocation;
  LatLng? _destination;
  List<LatLng> _route = [];
  double _distanceLeft = 0.0;
  double _currentHeading = 0.0;
  bool _hasAlerted = false; // NEW


  @override
  void initState() {
    super.initState();
    _initializeLocation();
  }

  static const platform = MethodChannel('esp32.network/bind');

  Future<void> sendCommand(String cmd) async {
    try {
      await platform.invokeMethod('sendRequestToESP32', {'cmd': cmd});
    } catch (e) {
      print("Failed to send command: $e");
    }
  }

  void _showProximityAlert() async {
    print("executing");
    await sendCommand("ON"); // ✅ Await this to ensure it's executed

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Almost there!'),

        content: Text('You are within 500 meters of your destination.'),
        actions: [
          TextButton(
            onPressed: () async {
              await sendCommand("OFF"); // ✅ Also await this
              Navigator.of(context).pop();
            },
            child: Text('OK'),
          ),
        ],
      ),
    );
  }



  Future<void> _initializeLocation() async {
    if (!await _checkAndRequestPermissions()) return;

    _locationService.onLocationChanged.listen((LocationData locationData) {
      if (locationData.latitude != null && locationData.longitude != null) {
        setState(() {
          _currentLocation =
              LatLng(locationData.latitude!, locationData.longitude!);
          _isLoading = false;
          _currentHeading = locationData.heading ?? 0.0;
        });

        if (_isNavigating && _destination != null) {
          _updateDistance();

          if (_isNavigating) {
            _mapController.rotate(_currentHeading);
          } else {
            _mapController.rotate(0); // Reset rotation if not navigating
          }
          _mapController.move(_currentLocation!, _mapController.camera.zoom);

        }
      }
    });
  }

  /// Check and request permissions
  Future<bool> _checkAndRequestPermissions() async {
    bool serviceEnabled = await _locationService.serviceEnabled();
    if (!serviceEnabled) {
      serviceEnabled = await _locationService.requestService();
      if (!serviceEnabled) return false;
    }
    PermissionStatus permissionGranted = await _locationService.hasPermission();
    if (permissionGranted == PermissionStatus.denied) {
      permissionGranted = await _locationService.requestPermission();
      if (permissionGranted != PermissionStatus.granted) return false;
    }
    return true;
  }

  /// Fetch coordinates for entered location
  Future<void> _fetchCoordinates(String location) async {
    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=$location&format=json&limit=1');
    final response = await http.get(url);

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data.isNotEmpty) {
        final lat = double.parse(data[0]['lat']);
        final lon = double.parse(data[0]['lon']);
        setState(() {
          _destination = LatLng(lat, lon);
        });

        await _fetchRoute();
      } else {
        _showError('Location not found. Please try another search.');
      }
    } else {
      _showError('Failed to fetch location. Try again later.');
    }
  }

  /// Fetch route from OSRM
  Future<void> _fetchRoute() async {
    if (_currentLocation == null || _destination == null) return;

    final url = Uri.parse('http://router.project-osrm.org/route/v1/driving/'
        '${_currentLocation!.longitude},${_currentLocation!.latitude};'
        '${_destination!.longitude},${_destination!.latitude}?overview=full&geometries=polyline');

    final response = await http.get(url);

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final geometry = data['routes'][0]['geometry'];
      final distanceInMeters = data['routes'][0]['distance'];

      final routePolyline = _decodePolyline(geometry);
      setState(() {
        _route = routePolyline.map((point) => LatLng(point[0], point[1])).toList();
        _distanceLeft = distanceInMeters / 1000;
      });

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Route Distance'),
          content: Text('The route is ${_distanceLeft.toStringAsFixed(2)} km long.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('OK'),
            ),
          ],
        ),
      );
    } else {
      _showError('Failed to fetch route. Try again later.');
    }
  }

  /// Decode polyline
  List<List<double>> _decodePolyline(String polyline) {
    const factor = 1e5;
    List<List<double>> points = [];
    int index = 0;
    int len = polyline.length;
    int lat = 0;
    int lon = 0;

    while (index < len) {
      int shift = 0;
      int result = 0;
      int byte;
      do {
        byte = polyline.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      int dlat = (result & 1) != 0 ? ~(result >> 1) : result >> 1;
      lat += dlat;
      shift = 0;
      result = 0;

      do {
        byte = polyline.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);

      int dlng = (result & 1) != 0 ? ~(result >> 1) : result >> 1;
      lon += dlng;
      points.add([lat / factor, lon / factor]);
    }
    return points;
  }

  void _updateDistance() {
    if (_currentLocation != null && _destination != null) {
      final distance = Distance();
      final meters = distance(_currentLocation!, _destination!);
      setState(() {
        _distanceLeft = meters / 1000;
      });

      if (meters <= 5000 && !_hasAlerted) {
        _hasAlerted = true;
        _showProximityAlert();
      }
    }
  }


  /// Show error
  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Start navigation
  void _startNavigation() {
    setState(() {
      _isNavigating = true;
    });
  }

  void _cancelNavigation() {
    _mapController.rotate(0); // Reset map rotation when navigation ends
    setState(() {
      _isNavigating = false;
      _destination = null;
      _route.clear();
      _locationController.clear();
      _hasAlerted = false; // <-- ADD THIS LINE
    });
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Column(
            children: [
              const SizedBox(height: 50),
              // Top search bar
              if (!_isNavigating)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 6,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Icon(Icons.search, color: Colors.grey),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _locationController,
                            decoration: const InputDecoration(
                              hintText: 'Search for a location...',
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.send),
                          onPressed: () {
                            final location = _locationController.text.trim();
                            if (location.isNotEmpty) _fetchCoordinates(location);
                          },
                        )
                      ],
                    ),
                  ),
                ),
              if (_isNavigating)
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Text(
                    'Distance left: ${_distanceLeft.toStringAsFixed(2)} km',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              Expanded(
                child: _isLoading || _currentLocation == null
                    ? const Center(child: CircularProgressIndicator())
                    : FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _currentLocation!,
                    initialZoom: 15,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                      "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
                      subdomains: ['a', 'b', 'c'],
                    ),
                    CurrentLocationLayer(
                      alignPositionOnUpdate: AlignOnUpdate.always,
                      alignDirectionOnUpdate: AlignOnUpdate.always,
                      style: const LocationMarkerStyle(
                        marker: DefaultLocationMarker(
                          child: Icon(Icons.navigation, color: Colors.white),
                        ),
                        markerSize: Size(40, 40),
                        markerDirection: MarkerDirection.heading,
                      ),
                    ),
                    if (_destination != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _destination!,
                            width: 50,
                            height: 50,
                            child: Transform.rotate(
                              angle: 0.0, // Keeps pin upright regardless of map rotation
                              child: const Icon(Icons.location_pin, color: Colors.red, size: 40),
                            ),

                          ),
                        ],
                      ),
                    if (_currentLocation != null &&
                        _destination != null &&
                        _route.isNotEmpty)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: _route,
                            strokeWidth: 4.0,
                            color: Colors.red,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),

          // Floating center icon


          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(36),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Search button
                  _buildActionButton(Icons.location_on, () {
                    _showError("Pick on map not implemented");
                  },false),
                  // Center “Start/Cancel” button (bigger)
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: Colors.green,
                    child: IconButton(
                      icon: Icon(
                        _isNavigating ? Icons.close : Icons.play_arrow,
                        color: Colors.white,
                        size: 28,
                      ),
                      onPressed: _isNavigating ? _cancelNavigation : _startNavigation,
                    ),
                  ),
                  // Settings button
                  _buildActionButton(Icons.settings, () {
                    _showError("Settings not implemented");
                  },false),
                ],
              ),
            ),
          ),

        ],
      ),
    );
  }

  bool isSearchSelected = false;
  bool isSettingsSelected = false;

  // Update your _buildActionButton to conditionally change colors
  Widget _buildActionButton(IconData icon, VoidCallback onPressed, bool isSelected) {
    return CircleAvatar(
      radius: 24,
      backgroundColor: isSelected ? Colors.green : Colors.grey[300], // Change based on selection
      child: IconButton(
        icon: Icon(icon, color: isSelected ? Colors.white : Colors.black, size: 24),
        onPressed: onPressed,
      ),
    );
  }

}
