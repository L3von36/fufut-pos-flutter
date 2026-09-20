import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/cart.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'cart_sheet.dart';

/// The till — a port of the web POS `MenuView.vue`.
///
/// Structure, top to bottom: table context bar (when a table is claimed),
/// category chip row (emoji + count pills), search bar with a grid/list
/// density toggle, course chips (dine-in), then the photo grid. The check
/// floats as a teal pill on phones and docks as a 340px right column on
/// wide landscape screens — the web's two cart layouts.
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
  String _course = 'main';
  bool _listMode = false; // density toggle, persisted like the web
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _restoreDensity();
  }

  Future<void> _restoreDensity() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _listMode =
          (prefs.getString('fufut.pos.menuDensity') == 'list'));
    }
  }

  Future<void> _toggleDensity() async {
    setState(() => _listMode = !_listMode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'fufut.pos.menuDensity', _listMode ? 'list' : 'grid');
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
      setState(() => _loading = false);
      showError(context, e);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showError(context, e);
    }
  }

  List<String> get _categories {
    final cats = _menu.map((m) => m.category).toSet().toList()..sort();
    return ['All', ...cats];
  }

  int _countFor(String category) => category == 'All'
      ? _menu.length
      : _menu.where((m) => m.category == category).length;

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

  // ── Category → emoji, the web's catEmoji map ───────────────────────────────

  static const _catEmoji = <String, String>{
    'breakfast': '🍳',
    'ቁርስ': '🍳',
    'salad': '🥗',
    'salad bowl': '🥗',
    'ethiopian dish': '🫕',
    'half bitt': '🍱',
    'pasta': '🍝',
    'sandwich': '🥪',
    'burger': '🍔',
    'pizza': '🍕',
    'break time': '🍟',
    'hot drink': '☕',
    'hot drinks': '☕',
    'seasonal juice': '🧃',
    'soft drink': '🥤',
    'extra': '➕',
  };

  static String _emojiFor(String category) {
    final key = category.toLowerCase().trim();
    for (final entry in _catEmoji.entries) {
      if (key.contains(entry.key)) return entry.value;
    }
    return '🍽️';
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartState>();
    final size = MediaQuery.sizeOf(context);
    // The web docks the check at (min-width:1024px) + landscape.
    final docked = size.width >= 1024 && size.width > size.height;
    final pal = Pal.of(context);

    final menuColumn = _buildMenuColumn(cart, pal);

    if (docked) {
      return Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: menuColumn),
            const SizedBox(width: 14),
            Container(
              width: 340,
              margin: const EdgeInsets.fromLTRB(0, 12, 12, 12),
              child: const CartPanel(docked: true),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: menuColumn,
      // Floating teal cart pill, center-bottom above the nav bar.
      bottomSheet:
          cart.isEmpty ? null : CartPill(onOpenCart: () => _openCart(context)),
    );
  }

  Widget _buildMenuColumn(CartState cart, Pal pal) {
    return Column(
      children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 110),
                    children: [
                      if (_offline)
                        _OfflineBanner(onRetry: _load),
                      if (cart.orderType == 'dine-in' &&
                          cart.tableNum.isNotEmpty) ...[
                        TableContextBar(
                          tableNum: cart.tableNum,
                          onMakeTakeaway: () => cart.setOrderType('takeaway'),
                        ),
                        const SizedBox(height: 10),
                      ],
                      _buildCategoryChips(pal),
                      const SizedBox(height: 8),
                      _buildSearchBar(pal),
                      if (cart.orderType == 'dine-in') ...[
                        const SizedBox(height: 8),
                        _buildCourseChips(pal),
                      ],
                      const SizedBox(height: 12),
                      if (_filtered.isEmpty)
                        const EmptyState(
                            icon: Icons.restaurant_menu,
                            title: 'No dishes match',
                            hint: 'Try another category or clear the search.')
                      else if (_listMode)
                        ..._filtered.map(_buildListRow)
                      else
                        _buildGrid(pal),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  // ── Category chips ──────────────────────────────────────────────────────────

  Widget _buildCategoryChips(Pal pal) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        // Hidden-scrollbar look: the web just hides overflow; a thin
        // padding does the same job visually.
        children: [
          for (final c in _categories)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _CatChip(
                emoji: c == 'All' ? '📋' : _emojiFor(c),
                label: c,
                count: _countFor(c),
                active: _category == c,
                onTap: () => setState(() => _category = c),
              ),
            ),
        ],
      ),
    );
  }

  // ── Search + density ────────────────────────────────────────────────────────

  Widget _buildSearchBar(Pal pal) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
      decoration: BoxDecoration(
        color: pal.surface,
        border: Border.all(color: pal.border, width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 18, color: pal.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(fontFamily: kFontBody, fontSize: 11.3, color: pal.heading),
              decoration: const InputDecoration(
                hintText: 'Search menu items...',
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (_query.isNotEmpty)
            IconButton(
              icon: Icon(Icons.close, size: 16, color: pal.muted),
              onPressed: () {
                _search.clear();
                setState(() => _query = '');
              },
            ),
          IconButton(
            tooltip: _listMode ? 'Photo grid' : 'Compact list',
            onPressed: _toggleDensity,
            icon: Icon(
              _listMode ? Icons.grid_view_outlined : Icons.view_list_outlined,
              size: 18,
              color: pal.muted,
            ),
          ),
        ],
      ),
    );
  }

  // ── Course chips (dine-in) ──────────────────────────────────────────────────

  Widget _buildCourseChips(Pal pal) {
    Widget chip(String value, String label) {
      final active = _course == value;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: InkWell(
          onTap: () => setState(() => _course = value),
          borderRadius: BorderRadius.circular(99),
          child: Container(
            constraints: const BoxConstraints(minHeight: 32, minWidth: 72),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: active ? pal.primary : pal.surface,
              borderRadius: BorderRadius.circular(99),
              border: Border.all(
                  color: active ? pal.primary : pal.border, width: 1.5),
            ),
            child: Text(label,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 10.0,
                    fontWeight: FontWeight.w500,
                    color: active ? Colors.white : pal.body)),
          ),
        ),
      );
    }

    return Row(
      children: [
        Text('COURSE',
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 8.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
                color: pal.muted)),
        const SizedBox(width: 10),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              chip('starters', 'Starters'),
              chip('main', 'Main'),
              chip('dessert', 'Dessert'),
            ]),
          ),
        ),
      ],
    );
  }

  // ── Product grid / list ─────────────────────────────────────────────────────

  Widget _buildGrid(Pal pal) {
    return LayoutBuilder(builder: (context, box) {
      // The web grid: auto-fill minmax(190px,1fr), but ≤600px viewports force
      // 3 columns (2 under 360px) and drop into the overlay card style.
      const gap = 10.0;
      final w = box.maxWidth;
      final int cols;
      final bool overlay;
      if (w <= 380) {
        cols = 2;
        overlay = true;
      } else if (w <= 600) {
        cols = 3;
        overlay = true;
      } else {
        cols = (w / 200).floor().clamp(2, 8);
        overlay = false;
      }
      final gapCount = cols + 1;
      final tileW = (w - gap * gapCount - 0) / cols;
      // Photo 16:10 plus a compact info block; overlay tiles are photo-only.
      final aspect = overlay
          ? 1.05
          : tileW / (tileW * 0.625 + 64);
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: gap,
          crossAxisSpacing: gap,
          childAspectRatio: aspect,
        ),
        itemCount: _filtered.length,
        itemBuilder: (context, i) => _ProductCard(
          item: _filtered[i],
          app: context.read<AppState>(),
          overlay: overlay,
          onAdd: () => _add(_filtered[i], 1),
          onLongPress: () => _openQtySheet(_filtered[i]),
        ),
      );
    });
  }

  /// Compact list rows — the web's list density: no photo, one line.
  Widget _buildListRow(MenuItem item) {
    final pal = Pal.of(context);
    final cart = context.watch<CartState>();
    final inCart = cart.qtyForItem(item.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: item.available ? () => _add(item, 1) : null,
        onLongPress: item.available ? () => _openQtySheet(item) : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: inCart > 0 ? pal.primary : pal.border,
                width: inCart > 0 ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: T.cardName.copyWith(fontSize: 11.3, color: pal.heading)),
              ),
              if (inCart > 0) ...[
                const SizedBox(width: 8),
                _CountBadge(count: inCart),
                const SizedBox(width: 8),
              ],
              Text(money(item.price),
                  style: T.price.copyWith(fontSize: 11.3, color: pal.primary)),
              const SizedBox(width: 10),
              _AddButton(onTap: item.available ? () => _add(item, 1) : null),
            ],
          ),
        ),
      ),
    );
  }

  // ── Add / qty flows ─────────────────────────────────────────────────────────

  void _add(MenuItem item, int qty) {
    final cart = context.read<CartState>();
    if (item.modifiers.isNotEmpty) {
      _showModifierSheet(context, item, qty);
      return;
    }
    cart.addItem(item, qty: qty, course: _course);
    HapticFeedback.selectionClick();
  }

  /// Press-and-hold → "How many?" sheet with the web's QUANTITIES grid.
  void _openQtySheet(MenuItem item) {
    final pal = Pal.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: pal.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHandle(),
              Text('How many?',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 13.4,
                      fontWeight: FontWeight.w600,
                      color: pal.heading)),
              const SizedBox(height: 4),
              Text(item.name,
                  style: TextStyle(fontFamily: kFontBody, fontSize: 10.5, color: pal.muted)),
              const SizedBox(height: 14),
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.6,
                children: [
                  for (final n in const [2, 3, 4, 5, 6, 8, 10, 12])
                    OutlinedButton(
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        _add(item, n);
                      },
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: pal.border, width: 1.5),
                        foregroundColor: pal.heading,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text('$n', style: T.price.copyWith(fontSize: 13.4)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openCart(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      constraints: BoxConstraints(
          maxWidth: 500, maxHeight: MediaQuery.sizeOf(context).height * 0.75),
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<CartState>(),
        child: const CartPanel(),
      ),
    );
  }

  // ── Modifiers ───────────────────────────────────────────────────────────────

  void _showModifierSheet(BuildContext context, MenuItem item, int qty) {
    final cart = context.read<CartState>();
    final selected = <int>{};
    final pal = Pal.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: pal.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetHandle(),
                Text(item.name,
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 13.4,
                        fontWeight: FontWeight.w700,
                        color: pal.heading)),
                const SizedBox(height: 4),
                Text('Choose options',
                    style: TextStyle(
                        fontFamily: kFontBody, fontSize: 10.5, color: pal.muted)),
                const SizedBox(height: 12),
                for (var i = 0; i < item.modifiers.length; i++)
                  InkWell(
                    onTap: () => setSheet(() {
                      selected.contains(i)
                          ? selected.remove(i)
                          : selected.add(i);
                    }),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: selected.contains(i)
                                  ? pal.primary
                                  : Colors.transparent,
                              border: Border.all(
                                  color: selected.contains(i)
                                      ? pal.primary
                                      : pal.borderStrong,
                                  width: 1.5),
                            ),
                            child: selected.contains(i)
                                ? const Icon(Icons.check,
                                    size: 13, color: Colors.white)
                                : null,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(item.modifiers[i].name,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 11.3,
                                    color: pal.body)),
                          ),
                          if (item.modifiers[i].priceDelta > 0)
                            Text('+${money(item.modifiers[i].priceDelta)}',
                                style: T.mono.copyWith(
                                    fontSize: 10.5, color: pal.muted)),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () {
                    cart.addItem(item,
                        qty: qty,
                        course: _course,
                        selected: selected
                            .map((i) => item.modifiers[i])
                            .toList());
                    HapticFeedback.selectionClick();
                    Navigator.of(sheetCtx).pop();
                  },
                  child: Text(qty > 1 ? 'Add $qty to order' : 'Add to order'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Offline banner — the web's warning strip under the topbar.
// ─────────────────────────────────────────────────────────────────────────────

class _OfflineBanner extends StatelessWidget {
  final VoidCallback onRetry;
  const _OfflineBanner({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: pal.warningBg,
        border: Border.all(color: pal.warningBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off, size: 15, color: pal.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Offline — the kitchen will not see orders until the '
              'connection returns.',
              style: TextStyle(fontFamily: kFontBody, fontSize: 10.0, color: pal.warning),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(44, 32)),
            child: Text('Retry',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 10.0,
                    fontWeight: FontWeight.w600,
                    color: pal.warning)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Category chip — pill, emoji + label + count.
// ─────────────────────────────────────────────────────────────────────────────

class _CatChip extends StatelessWidget {
  final String emoji;
  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;

  const _CatChip({
    required this.emoji,
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 84),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? pal.primary : pal.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
              color: active ? pal.primary : pal.border, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 10.0,
                      fontWeight: FontWeight.w500,
                      color: active ? Colors.white : pal.body)),
            ),
            const SizedBox(width: 6),
            Container(
              constraints: const BoxConstraints(minWidth: 18),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active
                    ? Colors.white.withValues(alpha: 0.2)
                    : pal.sunken,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text('$count',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 9.2,
                      fontWeight: FontWeight.w600,
                      color: active ? Colors.white : pal.muted)),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Product card — photo 16:10, name/price block, + button, in-cart ring.
// ─────────────────────────────────────────────────────────────────────────────

class _ProductCard extends StatelessWidget {
  final MenuItem item;
  final AppState app;
  final bool overlay;
  final VoidCallback onAdd;
  final VoidCallback onLongPress;

  const _ProductCard({
    required this.item,
    required this.app,
    required this.overlay,
    required this.onAdd,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final cart = context.watch<CartState>();
    final disabled = !item.available;
    final inCart = cart.qtyForItem(item.id);

    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: InkWell(
        onTap: disabled ? null : onAdd,
        onLongPress: disabled ? null : onLongPress,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: inCart > 0 ? pal.primary : pal.border,
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                  color: const Color(0xFF073735).withValues(alpha: 0.04),
                  offset: const Offset(0, 1),
                  blurRadius: 2),
            ],
          ),
          child: overlay
              ? _overlayBody(pal, inCart, disabled)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _image(pal, inCart, withAddButton: true)),
                    _infoBlock(pal),
                  ],
                ),
        ),
      ),
    );
  }

  /// Narrow-tile style: the name/price sit on a dark gradient over the
  /// photo, no add button (a tap adds) — the web's ≤175px container mode.
  Widget _overlayBody(Pal pal, int inCart, bool disabled) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _photo(pal),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 26, 8, 7),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xE6000000), Color(0x80000000), Colors.transparent],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 9.9,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        color: Colors.white)),
                Text(money(item.price),
                    style: T.price.copyWith(fontSize: 9.9, color: Colors.white)),
              ],
            ),
          ),
        ),
        if (inCart > 0)
          Positioned(top: 6, right: 6, child: _CountBadge(count: inCart, size: 24)),
        if (disabled)
          Container(
            color: Colors.black.withValues(alpha: 0.45),
            alignment: Alignment.center,
            child: const Text('UNAVAILABLE',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6)),
          ),
      ],
    );
  }

  /// Wide-tile info block: name left, price right, category tag below.
  Widget _infoBlock(Pal pal) {
    final tag = item.category.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 7, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: T.cardName.copyWith(color: pal.heading)),
              ),
              const SizedBox(width: 6),
              Text(money(item.price),
                  style: T.price.copyWith(color: pal.primary)),
            ],
          ),
          if (item.description.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(item.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.desc.copyWith(color: pal.muted)),
          ],
          if (tag.isNotEmpty) ...[
            const SizedBox(height: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: pal.sunken,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(tag.toUpperCase(),
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 7.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                      color: pal.muted)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _image(Pal pal, int inCart, {bool withAddButton = false}) {
    final disabled = !item.available;
    return Stack(
      fit: StackFit.expand,
      children: [
        _photo(pal),
        if (inCart > 0)
          Positioned(top: 8, right: 8, child: _CountBadge(count: inCart)),
        if (disabled)
          Container(
            color: Colors.black.withValues(alpha: 0.45),
            alignment: Alignment.center,
            child: const Text('UNAVAILABLE',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6)),
          ),
        if (withAddButton && !disabled)
          // 44px circular add button — always visible (touch devices).
          Positioned(bottom: 8, right: 8, child: _AddButton(onTap: onAdd)),
      ],
    );
  }

  Widget _photo(Pal pal) {
    final url = item.imageUrl(app.baseUrl);
    return Container(
      color: pal.sunken,
      child: url != null
          ? Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _placeholder(pal),
            )
          : _placeholder(pal),
    );
  }

  /// Deterministic photo placeholder, same idea as the web's fallback:
  /// a stable food photo per item name.
  Widget _placeholder(Pal pal) {
    final photos = MenuPhotos.list;
    final idx = (item.name.hashCode.abs()) % photos.length;
    return Image.asset(photos[idx], fit: BoxFit.cover);
  }
}

/// Bundled placeholder photos (copied from the PWA's own /assets).
class MenuPhotos {
  static const list = [
    'assets/images/placeholder-1.jpg',
    'assets/images/placeholder-2.jpg',
    'assets/images/placeholder-3.jpg',
    'assets/images/placeholder-4.jpg',
    'assets/images/placeholder-5.jpg',
    'assets/images/placeholder-6.jpg',
    'assets/images/placeholder-7.jpg',
    'assets/images/placeholder-8.jpg',
    'assets/images/placeholder-9.jpg',
    'assets/images/placeholder-10.jpg',
    'assets/images/placeholder-11.jpg',
    'assets/images/placeholder-12.jpg',
    'assets/images/placeholder-13.jpg',
    'assets/images/placeholder-14.jpg',
    'assets/images/placeholder-15.jpg',
    'assets/images/placeholder-16.jpg',
    'assets/images/placeholder-17.jpg',
  ];
}

/// 28px primary circle with the in-cart quantity — the web's badge-pop.
class _CountBadge extends StatelessWidget {
  final int count;
  final double size;
  const _CountBadge({required this.count, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Pal.of(context).primary,
        boxShadow: [
          BoxShadow(
              color: Pal.of(context)
                  .primary
                  .withValues(alpha: 0.35),
              blurRadius: 8),
        ],
      ),
      child: Text('$count',
          style: const TextStyle(
              fontFamily: kFontBody,
              fontSize: 9.6,
              fontWeight: FontWeight.w700,
              color: Colors.white)),
    );
  }
}

/// 44px circular `+` button — primary disc, white plus.
class _AddButton extends StatelessWidget {
  final VoidCallback? onTap;
  const _AddButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Material(
      color: pal.primary,
      shape: const CircleBorder(),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: const SizedBox(
          width: 44,
          height: 44,
          child: Icon(Icons.add, size: 20, color: Colors.white),
        ),
      ),
    );
  }
}
