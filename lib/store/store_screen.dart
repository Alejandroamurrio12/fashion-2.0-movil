import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_service.dart';
import '../core/api_error.dart';
import '../ui/format.dart';
import '../ui/product_photo.dart';
import 'cart.dart';
import 'cart_screen.dart';
import 'store_models.dart';

enum SortMode { name, priceAsc, priceDesc, newest }

const _sortLabels = {
  SortMode.name: 'Nombre',
  SortMode.priceAsc: 'Menor precio',
  SortMode.priceDesc: 'Mayor precio',
  SortMode.newest: 'Más nuevos',
};

/// Tienda del cliente: catalogo con precios y disponibilidad; el carrito se confirma como reserva.
/// Es la pantalla inicial del rol Cliente.
class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key});

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  String? _error;
  bool _loading = true;
  String _search = '';
  int? _category;
  SortMode _sort = SortMode.name;
  bool _onlyAvailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await context.read<CartService>().load();
    } on ApiError catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() => _loading = false);
  }

  List<StoreProduct> _visible(StoreCatalog c) {
    final term = _search.trim().toLowerCase();
    final list = c.products
        .where((p) =>
            (term.isEmpty || '${p.name} ${p.brand ?? ''} ${p.category} ${p.code}'.toLowerCase().contains(term)) &&
            (_category == null || p.categoryId == _category) &&
            (!_onlyAvailable || p.available > 0))
        .toList();
    int Function(StoreProduct, StoreProduct) by = switch (_sort) {
      SortMode.name => (a, b) => a.name.compareTo(b.name),
      SortMode.priceAsc => (a, b) => a.minPrice.compareTo(b.minPrice),
      SortMode.priceDesc => (a, b) => b.minPrice.compareTo(a.minPrice),
      SortMode.newest => (a, b) => b.createdAt.compareTo(a.createdAt),
    };
    return list..sort(by);
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cerrar sesión'),
        content: const Text('Se vaciará el carrito de este teléfono.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(key: const Key('confirm-logout'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Cerrar sesión')),
        ],
      ),
    );
    if (ok == true && mounted) await context.read<AuthService>().logout();
  }

  void _openCart() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CartScreen()));

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartService>();
    final c = cart.catalog;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(c?.tenantName ?? context.read<AuthService>().me?.tenant?.legalName ?? 'Tienda'),
        actions: [
          IconButton(
            key: const Key('cart-button'),
            tooltip: 'Carrito',
            onPressed: _openCart,
            icon: Badge(
              isLabelVisible: cart.count > 0,
              label: Text('${cart.count}', key: const Key('cart-count')),
              child: const Icon(Icons.shopping_bag_outlined),
            ),
          ),
          IconButton(key: const Key('logout'), tooltip: 'Cerrar sesión', onPressed: _logout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: _loading && c == null
          ? const Center(child: CircularProgressIndicator())
          : c == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error ?? 'No se pudo cargar el catálogo.', textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _load, child: const Text('Reintentar')),
                    ]),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                          child: TextField(
                            key: const Key('store-search'),
                            decoration: const InputDecoration(
                              hintText: '¿Qué estás buscando?',
                              prefixIcon: Icon(Icons.search),
                              border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(28))),
                              isDense: true,
                            ),
                            onChanged: (v) => setState(() => _search = v),
                          ),
                        ),
                      ),
                      if (!c.canReserve)
                        SliverToBoxAdapter(
                          child: Card(
                            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                            color: scheme.secondaryContainer,
                            child: const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text('Puede ver el catálogo, pero su empresa no tiene habilitadas las reservas.'),
                            ),
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 52,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            children: [
                              ChoiceChip(
                                label: Text('Todas (${c.products.length})'),
                                selected: _category == null,
                                onSelected: (_) => setState(() => _category = null),
                              ),
                              for (final cat in c.categories) ...[
                                const SizedBox(width: 8),
                                ChoiceChip(
                                  key: Key('category-${cat.id}'),
                                  label: Text('${cat.name} (${cat.count})'),
                                  selected: _category == cat.id,
                                  onSelected: (_) => setState(() => _category = cat.id),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(children: [
                            FilterChip(
                              key: const Key('only-available'),
                              label: const Text('Con stock'),
                              selected: _onlyAvailable,
                              onSelected: (v) => setState(() => _onlyAvailable = v),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text('${_visible(c).length} artículos',
                                  overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant)),
                            ),
                            PopupMenuButton<SortMode>(
                              key: const Key('sort'),
                              initialValue: _sort,
                              tooltip: 'Ordenar por',
                              onSelected: (m) => setState(() => _sort = m),
                              itemBuilder: (_) => [for (final m in SortMode.values) PopupMenuItem(value: m, child: Text(_sortLabels[m]!))],
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.sort, size: 20),
                                const SizedBox(width: 4),
                                Text(_sortLabels[_sort]!),
                              ]),
                            ),
                          ]),
                        ),
                      ),
                      if (_visible(c).isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: Text('No hay prendas que coincidan.')),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.all(12),
                          sliver: SliverGrid.builder(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 0.58,
                            ),
                            itemCount: _visible(c).length,
                            itemBuilder: (_, i) => _ProductCard(product: _visible(c)[i], onTap: () => _openProduct(_visible(c)[i])),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }

  void _openProduct(StoreProduct p) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ChangeNotifierProvider.value(value: context.read<CartService>(), child: ProductSheet(product: p)),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product, required this.onTap});

  final StoreProduct product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = product;
    final theme = Theme.of(context);
    return Card(
      key: Key('product-${p.id}'),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              ProductPhoto(id: p.id, name: p.name, url: p.imageUrl),
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Wrap(spacing: 4, runSpacing: 4, children: [
                  if (p.isNew) const _Tag('Nuevo', Color(0xFF2F8F83)),
                  if (p.available == 0) const _Tag('Agotado', Color(0xFF4A5560)),
                ]),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.category, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              Text(p.name.toUpperCase(), maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text.rich(TextSpan(children: [
                if (p.minPrice != p.maxPrice) TextSpan(text: 'Desde ', style: theme.textTheme.labelSmall),
                TextSpan(text: money(p.minPrice), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ])),
              const SizedBox(height: 4),
              Row(children: [
                for (final color in p.colors.take(5))
                  Container(
                    width: 12,
                    height: 12,
                    margin: const EdgeInsets.only(right: 3),
                    decoration: BoxDecoration(color: colorOf(p.hexOf(color)), shape: BoxShape.circle, border: Border.all(color: theme.dividerColor)),
                  ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
      );
}

/// Detalle: color, talla, disponibilidad por sucursal, cantidad y "Agregar al carrito".
class ProductSheet extends StatefulWidget {
  const ProductSheet({super.key, required this.product});
  final StoreProduct product;

  @override
  State<ProductSheet> createState() => _ProductSheetState();
}

class _ProductSheetState extends State<ProductSheet> {
  late String _color;
  late String _size;
  int _qty = 1;
  String? _added;

  @override
  void initState() {
    super.initState();
    final first = widget.product.variants.where((v) => v.available > 0).firstOrNull ?? widget.product.variants.first;
    _color = first.color;
    _size = first.size;
  }

  StoreVariant? get _variant => widget.product.variants.where((v) => v.color == _color && v.size == _size).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final cart = context.watch<CartService>();
    final catalog = cart.catalog!;
    final v = _variant;
    final theme = Theme.of(context);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(height: 200, width: double.infinity, child: ProductPhoto(id: p.id, name: p.name, url: p.imageUrl, fontSize: 56)),
          ),
          const SizedBox(height: 12),
          Text('${p.category}${p.brand != null ? ' · ${p.brand}' : ''} · ${p.code}', style: theme.textTheme.labelMedium),
          Text(p.name, style: theme.textTheme.titleLarge),
          Text(money(v?.price ?? p.minPrice),
              key: const Key('sheet-price'),
              style: theme.textTheme.headlineSmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
          if (p.description != null) Text(p.description!, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          Text('Color: $_color', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final color in p.colors)
              InkWell(
                key: Key('color-$color'),
                onTap: () => setState(() {
                  _color = color;
                  if (_variant == null) _size = p.variants.firstWhere((x) => x.color == color).size;
                  _added = null;
                }),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: colorOf(p.hexOf(color)),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _color == color ? theme.colorScheme.primary : theme.dividerColor, width: _color == color ? 3 : 1),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 12),
          Text('Talla', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final size in p.sizes)
              ChoiceChip(
                key: Key('size-$size'),
                label: Text(size),
                selected: _size == size,
                onSelected: (_) => setState(() {
                  _size = size;
                  _qty = 1;
                  _added = null;
                }),
              ),
          ]),
          const SizedBox(height: 12),
          if (v == null)
            Text('No existe esa combinación', style: TextStyle(color: theme.colorScheme.error))
          else ...[
            Text(v.available > 0 ? '${v.available} disponibles' : 'Sin stock en esta combinación',
                key: const Key('sheet-stock'),
                style: TextStyle(fontWeight: FontWeight.w600, color: v.available > 0 ? Colors.green.shade700 : theme.colorScheme.error)),
            for (final e in v.availability.entries) Text('${catalog.branchName(e.key)}: ${e.value}', style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(children: [
              IconButton.outlined(onPressed: _qty > 1 ? () => setState(() => _qty--) : null, icon: const Icon(Icons.remove)),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('$_qty', key: const Key('sheet-qty'), style: theme.textTheme.titleMedium)),
              IconButton.outlined(onPressed: _qty < v.available ? () => setState(() => _qty++) : null, icon: const Icon(Icons.add)),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('add-to-cart'),
                  onPressed: v.available > 0 && catalog.canReserve
                      ? () {
                          cart.add(p, v, _qty);
                          setState(() => _added = '${p.name} · ${v.color} · ${v.size}');
                        }
                      : null,
                  icon: const Icon(Icons.add_shopping_cart),
                  label: const Text('Agregar'),
                ),
              ),
            ]),
          ],
          if (_added != null) ...[
            const SizedBox(height: 8),
            Text('Agregado: $_added', key: const Key('added'), style: TextStyle(color: Colors.green.shade700)),
          ],
        ]),
      ),
    );
  }
}
