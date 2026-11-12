/// Configuracion de la app. La URL del backend se fija al compilar:
///   flutter run --dart-define=API_URL=https://fashionstore-api.onrender.com/api/v1
/// Por defecto apunta al backend local visto desde el emulador de Android (10.0.2.2).
class AppConfig {
  static const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://10.0.2.2:8000/api/v1');

  /// Tiempo maximo de espera de una peticion.
  static const requestTimeout = Duration(seconds: 20);
}
