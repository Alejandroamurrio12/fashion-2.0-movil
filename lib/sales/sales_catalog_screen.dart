import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../branch/branch_service.dart';
import '../core/api_error.dart';
import '../core/connectivity_service.dart';
import '../offline/catalog_store.dart';
import '../offline/offline_bootstrap.dart';
import '../ui/format.dart';
import '../ui/product_photo.dart';
import 'pickers.dart';
import 'sale_cart.dart';

/// Catalogo visual del punto de venta (cajero, encargado, administrador).
///
/// Lee el catalogo descargado en el telefono (CU59), asi funciona con y sin internet; el stock es
/// el de la sucursal de trabajo y ya descuenta lo vendido sin conexion. Con internet se actualiza
/// al abrir. "Comprar" agrega la prenda al carrito y lleva al cobro.
class SalesCatalogScreen extends StatefulWidget {
  const SalesCatalogScreen({super.key});

  @override
  State<SalesCatalogScreen> createState() => _SalesCatalogScreenState();
}

class _SalesCatalogScreenState extends State<SalesCatalogScreen> {
  List<LocalProduct> _products = [];
  Map<int, int> _stock = {};
  bool _loading = true;
  String? _error;
  String _search = '';
  String? _category;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(refresh: true));
  }

  Future<void> _load({bool refresh = false}) async {
    final catalog = context.read<CatalogStore>();
    final online = context.read<ConnectivityService>().online;
    final canDownload = context.read<OfflineBootstrap>().canOperateOffline;
    setState(() {
      _loading = true;
      _error = null;
    });
    // con internet se trae el stock vigente; sin internet se usa la copia del telefono
    if (refresh && online && canDownload) {
      try {
        await catalog.download();
      } on ApiError catch (e) {
        if (catalog.info == null) _error = e.message;
      }
    }
    await _readLocal();
  }

  Future<void> _readLocal() async {
    final catalog = context.read<CatalogStore>();
    final branch = context.read<BranchService>().selected;
    final products = await catalog.products();
    final stock = branch == null ? <int, int>{} : await catalog.stockOf(branch.id);
    if (!mounted) return;
    setState(() {
      _products = products;
      _stock = stock;
      _loading = false;
    });
  }

  int _availableOf(LocalProduct p) => p.variants.fold(0, (n, v) => n + (_stock[v.variantId] ?? 0));

  List<LocalProduct> get _visible {
    final term = _search.trim().toLowerCase();
    return _products
        .where((p) =>
            (_category == null || p.category == _category) &&
            (term.isEmpty || '${p.name} ${p.code} ${p.brand ?? ''} ${p.variants.map((v) => v.sku).join(' ')}'.toLowerCase().contains(term)))
        .toList();
  }

  Future<void> _open(LocalProduct p) async {
    final goToCart = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SalesProductScreen(product: p, stock: _stock)),
    );
    if (!mounted) return;
    if (goToCart == true) {
      await Navigator.of(context).pushNamed('/pos');
      if (mounted) await _readLocal(); // stock local actualizado tras una venta sin conexion
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<SaleCart>();
    final online = context.watch<ConnectivityService>().online;
    final branch = context.watch<BranchService>().selected;
    final catalog = context.watch<CatalogStore>();
    final scheme = Theme.of(context).colorScheme;
    final categories = [...{for (final p in _products) p.category}]..sort();
    final visible = _visible;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Catálogo'),
        actions: [
          IconButton(
            key: const Key('sale-cart'),
            tooltip: 'Carrito',
            onPressed: () => Navigator.of(context).pushNamed('/pos').then((_) => _readLocal()),
            icon: Badge(
              isLabelVisible: cart.count > 0,
              label: Text('${cart.count}', key: const Key('sale-cart-count')),
              child: const Icon(Icons.shopping_cart_outlined),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : branch == null
              ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Elija una sucursal de trabajo en el inicio.')))
              : _products.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error ?? (online ? 'No hay productos en el catálogo.' : 'Sin conexión y sin catálogo descargado en este teléfono.'),
                          key: const Key('catalog-empty'),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () => _load(refresh: true),
                      child: CustomScrollView(slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Container(
                                key: const Key('catalog-status'),
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: online ? scheme.secondaryContainer : scheme.tertiaryContainer,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(online
                                    ? 'Sucursal ${branch.name} · stock actualizado'
                                    : 'Sin conexión · Sucursal ${branch.name}: stock del teléfono${catalog.stale ? ' (desactualizado)' : ''}. Se cobra solo al contado.'),
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                key: const Key('catalog-search'),
                                decoration: const InputDecoration(
                                  hintText: '¿Qué estás buscando?',
                                  prefixIcon: Icon(Icons.search),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(28))),
                                  isDense: true,
                                ),
                                onChanged: (v) => setState(() => _search = v),
                              ),
                            ]),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: 52,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              children: [
                                ChoiceChip(label: const Text('Todo'), selected: _category == null, onSelected: (_) => setState(() => _category = null)),
                                for (final c in categories) ...[
                                  const SizedBox(width: 8),
                                  ChoiceChip(label: Text(c), selected: _category == c, onSelected: (_) => setState(() => _category = c)),
                                ],
                              ],
                            ),
                          ),
                        ),
                        if (visible.isEmpty)
                          const SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('No hay prendas que coincidan.')))
                        else
                          SliverPadding(
                            padding: const EdgeInsets.all(12),
                            sliver: SliverGrid.builder(
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                                childAspectRatio: 0.6,
                              ),
                              itemCount: visible.length,
                              itemBuilder: (_, i) => _Card(product: visible[i], available: _availableOf(visible[i]), onTap: () => _open(visible[i])),
                            ),
                          ),
                      ]),
                    ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.product, required this.available, required this.onTap});

  final LocalProduct product;
  final int available;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = product;
    final theme = Theme.of(context);
    return Card(
      key: Key('catalog-product-${p.id}'),
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
                child: Wrap(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: available > 0 ? const Color(0xFF2F8F83) : const Color(0xFF4A5560),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(available > 0 ? '$available disp.' : 'Agotado',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
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
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Detalle de la prenda: talla, color, disponibilidad en la sucursal, cantidad y "Comprar".
/// Devuelve true si hay que ir al carrito.
class SalesProductScreen extends StatefulWidget {
  const SalesProductScreen({super.key, required this.product, required this.stock});

  final LocalProduct product;
  final Map<int, int> stock;

  @override
  State<SalesProductScreen> createState() => _SalesProductScreenState();
}

class _SalesProductScreenState extends State<SalesProductScreen> {
  String? _color;
  String? _size;
  int _qty = 1;
  String? _warning;

  @override
  void initState() {
    super.initState();
    final colors = widget.product.colors;
    if (colors.length == 1) _color = colors.first;
  }

  LocalVariant? get _variant =>
      widget.product.variants.where((v) => v.color == _color && v.size == _size).firstOrNull;

  int _avail(LocalVariant v) => widget.stock[v.variantId] ?? 0;

  bool _sizeAvailable(String size) =>
      widget.product.variants.any((v) => v.size == size && (_color == null || v.color == _color) && _avail(v) > 0);

  int get _inCart {
    final v = _variant;
    if (v == null) return 0;
    return context.read<SaleCart>().lines.where((l) => l.item.variantId == v.variantId).fold(0, (n, l) => n + l.quantity);
  }

  void _buy() {
    final v = _variant;
    if (_color == null || _size == null || v == null) {
      setState(() => _warning = _size == null ? 'Por favor seleccione su talla' : 'Por favor seleccione el color');
      return;
    }
    final available = _avail(v);
    if (_qty + _inCart > available) {
      setState(() => _warning = 'Solo hay $available disponibles en esta sucursal.');
      return;
    }
    context.read<SaleCart>().add(
          PickedItem(variantId: v.variantId, label: v.label, sku: v.sku, price: v.price, available: available),
          _qty,
        );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final v = _variant;
    final theme = Theme.of(context);
    final teal = const Color(0xFF2F8F83);
    final available = v == null ? p.variants.fold(0, (n, x) => n + _avail(x)) : _avail(v);

    return Scaffold(
      appBar: AppBar(title: Text(p.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_warning != null)
            Container(
              key: const Key('product-warning'),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFFFFF4DC), borderRadius: BorderRadius.circular(6)),
              child: Row(children: [
                const Icon(Icons.warning_amber, color: Color(0xFFB26A00)),
                const SizedBox(width: 8),
                Expanded(child: Text(_warning!, style: const TextStyle(color: Color(0xFF6B4200)))),
              ]),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(aspectRatio: 1, child: ProductPhoto(id: p.id, name: p.name, url: p.imageUrl, fontSize: 64)),
          ),
          const SizedBox(height: 16),
          Text(p.name, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(spacing: 12, children: [
            Text(available > 0 ? 'DISPONIBLE' : 'AGOTADO',
                key: const Key('product-availability'),
                style: TextStyle(fontWeight: FontWeight.w700, color: available > 0 ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.error)),
            Text('SKU ${v?.sku ?? p.code}', style: theme.textTheme.bodyMedium),
          ]),
          const SizedBox(height: 12),
          Text.rich(TextSpan(children: [
            const TextSpan(text: 'Precio  '),
            TextSpan(
              text: money(v?.price ?? p.minPrice),
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: teal),
            ),
          ]), key: const Key('product-price')),
          if (p.colors.length > 1) ...[
            const SizedBox(height: 16),
            Text('Color${_color == null ? '' : ': $_color'}', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Wrap(spacing: 8, children: [
              for (final c in p.colors)
                InkWell(
                  key: Key('product-color-$c'),
                  onTap: () => setState(() {
                    _color = c;
                    _warning = null;
                  }),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: colorOf(p.hexByColor[c]),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _color == c ? theme.colorScheme.primary : theme.dividerColor, width: _color == c ? 3 : 1),
                    ),
                  ),
                ),
            ]),
          ],
          const SizedBox(height: 16),
          Text('Talla', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final s in p.sizes)
              InkWell(
                key: Key('product-size-$s'),
                onTap: () => setState(() {
                  _size = s;
                  _qty = 1;
                  _warning = null;
                }),
                child: Container(
                  width: 50,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _size == s ? teal : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(s,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _size == s ? Colors.white : (_sizeAvailable(s) ? null : theme.disabledColor),
                        decoration: _sizeAvailable(s) || _size == s ? null : TextDecoration.lineThrough,
                      )),
                ),
              ),
          ]),
          if (v != null) ...[
            const SizedBox(height: 8),
            Text('${_avail(v)} disponibles en esta sucursal', key: const Key('product-stock')),
          ],
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: FilledButton(
                key: const Key('buy'),
                style: FilledButton.styleFrom(
                  backgroundColor: teal,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                ),
                onPressed: available > 0 ? _buy : null,
                child: const Text('COMPRAR', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 12),
            const Text('Cantidad', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Container(
              width: 44,
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(border: Border.all(color: theme.dividerColor)),
              child: Text('$_qty', key: const Key('product-qty')),
            ),
            Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 34,
                height: 25,
                child: IconButton.filled(
                  key: const Key('qty-up'),
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  style: IconButton.styleFrom(backgroundColor: const Color(0xFF5F6878), shape: const RoundedRectangleBorder()),
                  onPressed: () => setState(() => _qty++),
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
              ),
              SizedBox(
                width: 34,
                height: 25,
                child: IconButton.filled(
                  key: const Key('qty-down'),
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  style: IconButton.styleFrom(backgroundColor: const Color(0xFF5F6878), shape: const RoundedRectangleBorder()),
                  onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
              ),
            ]),
          ]),
          const SizedBox(height: 20),
          const Divider(),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.payments_outlined, size: 32),
            title: Text('PAGO AL CONTADO, TARJETA, QR O TRANSFERENCIA'),
            subtitle: Text('Sin internet solo se acepta efectivo: la venta se guarda en el teléfono y se sincroniza al volver la conexión.'),
          ),
        ],
      ),
    );
  }
}
