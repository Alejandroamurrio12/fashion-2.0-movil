import 'package:flutter/material.dart';

/// Foto de producto y colores compartidos por la tienda del cliente y el catalogo del punto de venta.
const _palette = [
  Color(0xFF7A2E5C), Color(0xFF2E5C7A), Color(0xFF2E7A5C), Color(0xFF7A5C2E),
  Color(0xFF5C2E7A), Color(0xFF7A2E2E), Color(0xFF2E6B7A), Color(0xFF4A5560),
];

Color tintOf(int id) => _palette[id % _palette.length];

String initialsOf(String name) =>
    name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2).map((w) => w[0].toUpperCase()).join();

Color colorOf(String? hex) {
  if (hex == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return const Color(0xFF9AA2B1);
  return Color(int.parse('FF${hex.substring(1)}', radix: 16));
}

/// Foto del producto o, si no tiene, un degradado con sus iniciales.
class ProductPhoto extends StatelessWidget {
  const ProductPhoto({super.key, required this.id, required this.name, this.url, this.fontSize = 34});

  final int id;
  final String name;
  final String? url;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final tint = tintOf(id);
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(tint, Colors.white, 0.78)!, Color.lerp(tint, Colors.white, 0.45)!],
        ),
      ),
      child: Center(
        child: Text(initialsOf(name),
            style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, color: Color.lerp(tint, Colors.black, 0.2)!.withValues(alpha: 0.6))),
      ),
    );
    if (url == null) return placeholder;
    return Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder);
  }
}

