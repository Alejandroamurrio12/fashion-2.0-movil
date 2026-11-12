/// Configuracion de la app.
///
/// Por defecto usa el backend publicado en Render. Para el backend local desde el emulador:
///   flutter run --dart-define=API_URL=http://10.0.2.2:8000/api/v1
class AppConfig {
  static const productionApiUrl = 'https://fashionstore-api-xcrn.onrender.com/api/v1';

  static const apiUrl = String.fromEnvironment('API_URL', defaultValue: productionApiUrl);

  /// Tiempo maximo de espera de una peticion. El plan gratuito de Render apaga el servicio sin
  /// uso y la primera peticion puede tardar unos 50 s en despertarlo.
  static const requestTimeout = Duration(seconds: 70);
}
