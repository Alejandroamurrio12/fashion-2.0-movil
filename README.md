# FashionStore – App móvil (Flutter, Android)

App para el personal y los clientes de cada empresa: venta en tienda con y sin conexión, reservas, cambios y sincronización. Usa la misma API que la PWA (`../fashion-2.0-backend`). Plan: `../documentacion/PLAN_MOVIL.md`.

## Puesta en marcha

```powershell
flutter pub get
# backend publicado en Render (por defecto): https://fashionstore-api-xcrn.onrender.com
flutter run
# backend local desde el emulador (10.0.2.2 = la PC vista desde el emulador)
flutter run --dart-define=API_URL=http://10.0.2.2:8000/api/v1
# APK para instalar en el telefono (usa Render)
flutter build apk --release
```

Para compilar el APK hay que aceptar antes las licencias de Android: `flutter doctor --android-licenses`.

En producción solo se permite HTTPS; HTTP queda habilitado únicamente para `10.0.2.2` y `localhost` (`android/app/src/main/res/xml/network_security_config.xml`).

## Tienda del cliente

El rol Cliente entra directo a la tienda (`lib/store/`): catálogo en cuadrícula con precio, etiquetas Nuevo/Agotado, búsqueda, categorías, orden y filtro de stock; detalle con color, talla y disponibilidad por sucursal; carrito que se confirma como reserva en la sucursal elegida (`POST /reservations`).

## Pruebas

```powershell
flutter test                       # unitarias y de pantallas (backend simulado)
# contra el backend real (base de pruebas levantada en el puerto 8000)
flutter test test_api/backend_smoke_test.dart --dart-define=API_URL=http://127.0.0.1:8000/api/v1
```

## Estructura

```
lib/
  core/      configuración, error normalizado, cliente HTTP con renovación, almacenamiento seguro, conexión
  auth/      modelos de /auth/me y sesión
  branch/    sucursal de trabajo (/branches/mine)
  offline/   SQLite (catálogo offline, cola de operaciones), dueño de la base, arranque offline
  sales/     punto de venta con y sin conexión, buscadores, comprobante
  ui/        login, inicio y menú por permisos y plan
```

## Sin conexión

- Al entrar, si el rol tiene `sync.run` y el plan `offline`, se descarga `GET /offline/catalog` a SQLite; se puede actualizar desde el inicio. Se marca desactualizado al superar `max_age_hours`.
- La base pertenece a un usuario de una empresa: si entra otro, se vacía (RN-22). Al cerrar sesión se borra, avisando si quedan operaciones sin sincronizar.
- Venta sin conexión: solo efectivo (RN-06), con el precio cobrado (RN-13); queda en la cola con UUID y `local_seq` y comprobante provisional `PROV-…`; el stock local se descuenta.

## Sincronización

- `SyncService` envía la cola en orden de `local_seq`, en lotes de hasta 100; cada operación queda con su resultado (CONFIRMED con código, REJECTED con motivo, IN_CONFLICT). Un fallo temporal se reintenta a los 5 s, 10 s, 20 s… hasta 5 min, sin adelantar operaciones posteriores.
- Reenviar es seguro: el servidor reconoce el UUID y devuelve el mismo resultado sin duplicar.
- Los conflictos se consultan con `/sync/operations/status`: cuando el encargado decide, la operación pasa a confirmada o cancelada.
- Conflictos (CU63): el encargado o el administrador los resuelve desde la app con las decisiones que permite el backend.

## Sesión

- Tokens y usuario en el almacenamiento seguro de Android; la contraseña nunca se guarda.
- Al abrir, la sesión se valida con `/auth/me`; sin conexión se conserva la guardada.
- Ante un `401` se renueva el token una sola vez (aunque fallen varias peticiones a la vez) y se reintenta. Empresa suspendida o usuario inactivo cierran la sesión con el motivo.
- El administrador de plataforma usa la aplicación web.
- Al cerrar sesión se borran los datos locales; si la sesión vence, no (se conservan las operaciones pendientes).

## Avance

| Fase | Contenido | Estado |
|---|---|---|
| M0 | Proyecto Android, configuración, cliente HTTP y errores, almacenamiento seguro, permisos de red | listo |
| M1 | Login, renovación, cierre por suspensión, sucursal de trabajo, inicio con plan y menú por permisos | listo |
| M2 | SQLite, catálogo offline y su antigüedad, dueño de la base (RN-22), sucursales sin conexión | listo |
| M3 | Punto de venta con y sin conexión, efectivo con cambio, tarjeta/QR/transferencia con referencia, comprobante (provisional sin conexión) | listo |
| M4 | Sincronización (FIFO, lotes de 100, reintento exponencial, idempotencia, al volver la red/al abrir/cada 30 s/a mano), pantalla de operaciones, resolución de conflictos (encargado y administrador) | listo (52 pruebas + 3 contra el backend real, incluida la venta simultánea de la última unidad en dos teléfonos) |
