import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/cart.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'cart_sheet.dart';

/// The till: menu grid on the left/top, cart behind the bottom bar.
///
/// Same flow as the web POS MenuView — pick products, choose where the order
/// is going (dine-in / takeaway / delivery), then either fire the ticket to
/// the kitchen unpaid or charge it now.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  List<MenuItem> _menu = const [];
  bool _loading = true;
  bool _offline = false;
  String _category = 'All';
  String _query = '';
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    setState(() {
      _loading = true;
      _offline = false;
    });
    try {
      final menu = await app.api.menu();
      if (!mounted) return;
      setState(() {
        _menu = menu;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      setState(() {
        _loading = false;
        _offline = true;
      });
      showError(context, e);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _offline = true;
      });
      showError(context, e);
    }
  }

  List<String> get _categories {
    final cats = _menu.map((m) => m.category).toSet().toList()..sort();
    return ['All', ...cats];
  }

  List<MenuItem> get _filtered {
    final q = _query.trim().toLowerCase();
    return _menu.where((m) {
      if (_category != 'All' && m.category != _category) return false;
      if (q.isNotEmpty &&
          !m.name.toLowerCase().contains(q) &&
          !m.category.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Register'),
        actions: [
          if (_offline)
            TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.cloud_off, size: 18),
              label: const Text('Retry'),
            ),
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload menu',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // ── Search + categories ────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: TextField(
                    controller: _search,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'Search the menu…',
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                            ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final c in _categories)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(c),
                            selected: _category == c,
                            onSelected: (_) => setState(() => _category = c),
                          ),
                        ),
                    ],
                  ),
                ),
                // ── Product grid ───────────────────────────────────────────
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: GridView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 120),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 200,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 0.92,
                      ),
                      itemCount: _filtered.length,
                      itemBuilder: (context, i) =>
                          _ProductCard(item: _filtered[i]),
                    ),
                  ),
                ),
              ],
            ),
      // ── Cart bar ───────────────────────────────────────────────────────────
      bottomSheet: cart.isEmpty
          ? null
          : CartBar(onOpenCart: () => _openCart(context)),
    );
  }
}

class _ProductCard extends StatelessWidget {
  final MenuItem item;
  const _ProductCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final cart = context.read<CartState>();
    final disabled = !item.available;
    return Opacity(
      opacity: disabled ? 0.45 : 1,
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: disabled
              ? null
              : () {
                  if (item.modifiers.isNotEmpty) {
                    _showModifierSheet(context, item);
                  } else {
                    cart.addItem(item);
                    HapticFeedback.selectionClick();
                  }
                },
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Images are small and optional; a missing one is a
                        // teal tile with the first letter, not a red box.
                        Container(
                          color: const Color(0xFF0F7B78),
                          alignment: Alignment.center,
                          child: Text(
                            item.name.isNotEmpty ? item.name[0] : '?',
                            style: const TextStyle(
                                fontSize: 32,
                                color: Colors.white70,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (disabled)
                          Container(
                            color: Colors.black54,
                            alignment: Alignment.center,
                            child: const Text('Sold out',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600)),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  money(item.price),
                  style: const TextStyle(
                      color: Color(0xFF7FD1CE),
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showModifierSheet(BuildContext context, MenuItem item) {
    final cart = context.read<CartState>();
    final selected = <int>{};
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(item.name,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text('Choose options',
                    style: TextStyle(color: Colors.white54)),
                const SizedBox(height: 12),
                for (var i = 0; i < item.modifiers.length; i++)
                  CheckboxListTile(
                    value: selected.contains(i),
                    onChanged: (v) => setSheet(() {
                      v == true ? selected.add(i) : selected.remove(i);
                    }),
                    title: Text(item.modifiers[i].name),
                    subtitle: item.modifiers[i].priceDelta > 0
                        ? Text('+${money(item.modifiers[i].priceDelta)}',
                            style: const TextStyle(
                                color: Color(0xFF7FD1CE), fontSize: 12))
                        : null,
                    contentPadding: EdgeInsets.zero,
                  ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () {
                    cart.addItem(item,
                        selected: selected
                            .map((i) => item.modifiers[i])
                            .toList());
                    Navigator.of(sheetCtx).pop();
                  },
                  child: const Text('Add to cart'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The sticky bottom bar showing the running total.
class CartBar extends StatelessWidget {
  final VoidCallback onOpenCart;
  const CartBar({super.key, required this.onOpenCart});

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartState>();
    return SafeArea(
      top: false,
      child: Container(
        color: const Color(0xFF14201E),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            Badge(
              label: Text('${cart.itemCount}'),
              isLabelVisible: cart.itemCount > 0,
              child: const Icon(Icons.shopping_cart_outlined, size: 26),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${cart.itemCount} item${cart.itemCount == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 12, color: Colors.white54)),
                Text(money(cart.subtotal),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ],
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: onOpenCart,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Cart'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openCart(BuildContext context) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => ChangeNotifierProvider.value(
      value: context.read<CartState>(),
      child: const CartSheet(),
    ),
  );
}
