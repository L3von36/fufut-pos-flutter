/// Role registry — the Flutter half of the web POS role matrix.
///
/// Source of truth on the server is `fufut-api/src/auth.js` (ROLE_ACCESS);
/// the web POS mirrors it in `pos/src/api/index.js` (ROLE_PERMISSIONS +
/// ROLE_DEFAULT_VIEW). This file is the same mapping narrowed to the screens
/// this app can render: every entry here is backed by a server grant, so a
/// nav item can never open onto a screen whose first request 403s.
///
/// What changed: the shell used to show every role the same four tabs. Now
/// each role signs in to its own home screen — the manager to the dashboard,
/// the chef to the kitchen board, the waiter to the floor, the cashier to the
/// till, the driver to the run list, the cleaner to the waste log, the
/// accountant to the reports — exactly like pos.fufutcoffee.com.
library;

import 'package:flutter/material.dart';

/// Every screen the Flutter app can navigate to.
enum NavKey {
  dashboard,
  kitchen, // also the barista board in drinks mode
  barista,
  tables,
  menuView,
  orders,
  openChecks,
  cashdrawer,
  delivery,
  waste,
  reports,
  settings,
}

/// One destination in the sidebar / drawer / bottom bar.
class NavEntry {
  final NavKey key;
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String section;

  const NavEntry(this.key, this.icon, this.activeIcon, this.label,
      {this.section = ''});
}

/// The full catalogue, ordered per the web sidebar's section grouping
/// (Overview → Sales → Operations → Finance → Stock → System).
const List<NavEntry> kAllNavEntries = [
  NavEntry(NavKey.dashboard, Icons.dashboard_outlined, Icons.dashboard,
      'Dashboard', section: 'Overview'),
  NavEntry(NavKey.tables, Icons.grid_view_outlined, Icons.grid_view, 'Tables',
      section: 'Operations'),
  NavEntry(NavKey.menuView, Icons.menu_book_outlined, Icons.menu_book,
      'Menu View', section: 'Sales'),
  NavEntry(NavKey.orders, Icons.shopping_cart_outlined, Icons.shopping_cart,
      'Orders', section: 'Sales'),
  NavEntry(NavKey.openChecks, Icons.credit_card_outlined, Icons.credit_card,
      'Open Checks', section: 'Sales'),
  NavEntry(NavKey.kitchen, Icons.restaurant_outlined, Icons.restaurant,
      'Kitchen', section: 'Operations'),
  NavEntry(NavKey.barista, Icons.local_cafe_outlined, Icons.local_cafe,
      'Barista', section: 'Operations'),
  NavEntry(NavKey.delivery, Icons.local_shipping_outlined,
      Icons.local_shipping, 'Delivery', section: 'Operations'),
  NavEntry(NavKey.cashdrawer, Icons.payments_outlined, Icons.payments,
      'Cash Drawer', section: 'Finance'),
  NavEntry(NavKey.reports, Icons.description_outlined, Icons.description,
      'Reports', section: 'Finance'),
  NavEntry(NavKey.waste, Icons.delete_outline, Icons.delete, 'Waste Log',
      section: 'Stock'),
  NavEntry(NavKey.settings, Icons.settings_outlined, Icons.settings,
      'Settings', section: 'System'),
];

NavEntry _entry(NavKey key) =>
    kAllNavEntries.firstWhere((e) => e.key == key);

/// Which screens each role sees — the web ROLE_PERMISSIONS lists, intersected
/// with what the app renders. Order matters twice over: it is the nav order,
/// and the first three non-Settings entries ride the phone's bottom bar — so
/// each list leads with the role's home screen and keeps sections contiguous.
const Map<String, List<NavKey>> kRolePermissions = {
  'manager': [
    NavKey.dashboard,
    // Operations
    NavKey.tables,
    NavKey.delivery,
    NavKey.kitchen,
    NavKey.barista,
    // Sales
    NavKey.menuView,
    NavKey.orders,
    NavKey.openChecks,
    // Finance
    NavKey.cashdrawer,
    NavKey.reports,
    // Stock
    NavKey.waste,
  ],
  // The kitchen board is home; orders gives whole-ticket context, waste and
  // reports are the chef's own stock + cost duties.
  'head-chef': [
    NavKey.kitchen,
    NavKey.orders,
    NavKey.dashboard,
    NavKey.waste,
    NavKey.reports,
  ],
  // Cooks from the recipes, does not own the counts — so no waste entry here.
  'assistant-chef': [
    NavKey.kitchen,
    NavKey.orders,
    NavKey.dashboard,
  ],
  // The drinks station: its own board first, then whole tickets and the bin.
  'barista': [
    NavKey.barista,
    NavKey.orders,
    NavKey.waste,
  ],
  // The floor: tables is home, menu view takes orders, open checks is money
  // owed. No delivery — the web grant does not carry it either.
  'head-waiter': [
    NavKey.tables,
    NavKey.menuView,
    NavKey.orders,
    NavKey.openChecks,
    NavKey.dashboard,
  ],
  // The till: drawer home, menu view for walk-in sales, checks to settle.
  // Reports stay with the accountant's screen; the drawer home already shows
  // the cashier their day.
  'cashier': [
    NavKey.cashdrawer,
    NavKey.menuView,
    NavKey.orders,
    NavKey.openChecks,
    NavKey.tables,
    NavKey.dashboard,
  ],
  'delivery-staff': [
    NavKey.delivery,
    NavKey.dashboard,
  ],
  'cleaner': [
    NavKey.waste,
    NavKey.dashboard,
  ],
  // Reads the financial picture, changes almost none of it.
  'accountant': [
    NavKey.reports,
    NavKey.dashboard,
  ],
};

/// The screen a role lands on at sign-in — the web ROLE_DEFAULT_VIEW.
const Map<String, NavKey> kRoleDefaultView = {
  'manager': NavKey.dashboard,
  'head-chef': NavKey.kitchen,
  'assistant-chef': NavKey.kitchen,
  'barista': NavKey.barista,
  'head-waiter': NavKey.tables,
  'cashier': NavKey.cashdrawer,
  'delivery-staff': NavKey.delivery,
  'cleaner': NavKey.waste,
  'accountant': NavKey.reports,
};

/// Fallback for a role this app does not know (or a stale cached identity):
/// the till, which is what the app shipped with.
const List<NavKey> kFallbackPermissions = [
  NavKey.menuView,
  NavKey.orders,
  NavKey.openChecks,
];

/// "head-chef" → "Head Chef" for display.
String roleTitle(String role) {
  if (role.isEmpty) return '';
  return role
      .split(RegExp(r'[\s_-]+'))
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
      .join(' ');
}

/// Nav entries for [roleKey], Settings always last. Unknown roles fall back
/// to the original cashier layout so nobody lands on an empty shell.
List<NavEntry> navForRole(String? roleKey) {
  final keys =
      kRolePermissions[roleKey] ?? kFallbackPermissions;
  return [...keys.map(_entry), _entry(NavKey.settings)];
}

/// The first screen for [roleKey]. Unknown roles start on the till.
NavKey defaultViewFor(String? roleKey) =>
    kRoleDefaultView[roleKey] ?? NavKey.menuView;

/// Titles for the topbar.
String titleFor(NavKey key) {
  switch (key) {
    case NavKey.dashboard:
      return 'Dashboard';
    case NavKey.kitchen:
      return 'Kitchen Display';
    case NavKey.barista:
      return 'Barista Display';
    case NavKey.tables:
      return 'Floor Plan';
    case NavKey.menuView:
      return 'Menu View';
    case NavKey.orders:
      return 'Orders';
    case NavKey.openChecks:
      return 'Open Checks';
    case NavKey.cashdrawer:
      return 'Cash Drawer';
    case NavKey.delivery:
      return 'Delivery';
    case NavKey.waste:
      return 'Waste Log';
    case NavKey.reports:
      return 'Reports';
    case NavKey.settings:
      return 'Settings';
  }
}

/// What counts as a drink, shared with the barista board — the web POS
/// `lib/drinks.js` DRINK_WORDS regex, verbatim. A line belongs to the bar
/// when its category — or, for rows written before categories were stamped,
/// its name — reads as a drink.
final RegExp kDrinkWords = RegExp(
    r'drink|coffee|beverage|juice|water|soda|\bbar\b|\btea\b|latte|espresso|cappuccino|macchiato|americano|mocha|smoothie|shake|lemonade',
    caseSensitive: false);

bool nameIsDrink(String category, String name) =>
    kDrinkWords.hasMatch(category) || kDrinkWords.hasMatch(name);
