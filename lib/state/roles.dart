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

/// Every screen the Flutter app can navigate to — the web POS's full nav
/// catalogue (NAV_ITEMS), one enum value per route.
enum NavKey {
  dashboard,
  alertsDash, // web /app/alerts — the SLA dashboard (the banner is its push twin)
  kitchen, // also the barista board in drinks mode
  barista,
  tables,
  tableHistory, // the floor's archive — per-table order history by day
  menuView,
  menuMgmt, // web /app/menu-mgmt — catalogue CRUD + dish-86 toggle
  orders,
  openChecks,
  pipeline, // web /app/pipeline — the order kanban
  reservations,
  delivery,
  cashdrawer,
  expenses,
  pnl, // web /app/pnl — profit & loss
  revenue, // web /app/revenue — revenue by day + method
  analytics, // web /app/analytics — the deep analytics panel
  reports,
  inventory,
  recipes,
  stockControl, // web /app/stock-control — the six stock intelligence tabs
  suppliers,
  purchases,
  waste,
  shifts, // web /app/shifts — the roster
  timeclock,
  myPay,
  myActivity,
  customers, // web /app/customers — route-only on the web; manager tool here
  audit, // web /app/audit — the admin audit trail
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
/// (Overview → Sales → Operations → Finance → Stock → HR → Analytics →
/// System).
const List<NavEntry> kAllNavEntries = [
  NavEntry(NavKey.dashboard, Icons.dashboard_outlined, Icons.dashboard,
      'Dashboard', section: 'Overview'),
  NavEntry(NavKey.alertsDash, Icons.notifications_outlined,
      Icons.notifications, 'SLA Alerts', section: 'Overview'),
  NavEntry(NavKey.orders, Icons.shopping_cart_outlined, Icons.shopping_cart,
      'Orders', section: 'Sales'),
  NavEntry(NavKey.openChecks, Icons.credit_card_outlined, Icons.credit_card,
      'Open Checks', section: 'Sales'),
  NavEntry(NavKey.menuMgmt, Icons.restaurant_menu_outlined,
      Icons.restaurant_menu, 'Menu', section: 'Sales'),
  NavEntry(NavKey.menuView, Icons.menu_book_outlined, Icons.menu_book,
      'Menu View', section: 'Sales'),
  NavEntry(NavKey.tables, Icons.grid_view_outlined, Icons.grid_view, 'Tables',
      section: 'Operations'),
  NavEntry(NavKey.tableHistory, Icons.history_rounded, Icons.history,
      'Table History', section: 'Operations'),
  NavEntry(NavKey.reservations, Icons.calendar_today_outlined,
      Icons.calendar_today, 'Reservations', section: 'Operations'),
  NavEntry(NavKey.delivery, Icons.local_shipping_outlined,
      Icons.local_shipping, 'Delivery', section: 'Operations'),
  NavEntry(NavKey.kitchen, Icons.restaurant_outlined, Icons.restaurant,
      'Kitchen', section: 'Operations'),
  NavEntry(NavKey.barista, Icons.local_cafe_outlined, Icons.local_cafe,
      'Barista', section: 'Operations'),
  NavEntry(NavKey.pipeline, Icons.account_tree_outlined, Icons.account_tree,
      'Pipeline', section: 'Operations'),
  NavEntry(NavKey.expenses, Icons.account_balance_wallet_outlined,
      Icons.account_balance_wallet, 'Expenses', section: 'Finance'),
  NavEntry(NavKey.pnl, Icons.bar_chart_outlined, Icons.bar_chart, 'P&L',
      section: 'Finance'),
  NavEntry(NavKey.cashdrawer, Icons.payments_outlined, Icons.payments,
      'Cash Drawer', section: 'Finance'),
  NavEntry(NavKey.revenue, Icons.trending_up_outlined, Icons.trending_up,
      'Revenue', section: 'Finance'),
  NavEntry(NavKey.inventory, Icons.inventory_2_outlined, Icons.inventory_2,
      'Inventory', section: 'Stock'),
  NavEntry(NavKey.recipes, Icons.menu_book_outlined, Icons.menu_book,
      'Recipes', section: 'Stock'),
  NavEntry(NavKey.stockControl, Icons.query_stats_outlined, Icons.query_stats,
      'Stock Control', section: 'Stock'),
  NavEntry(NavKey.suppliers, Icons.local_shipping_outlined,
      Icons.local_shipping, 'Suppliers', section: 'Stock'),
  NavEntry(NavKey.purchases, Icons.shopping_basket_outlined,
      Icons.shopping_basket, 'Purchases', section: 'Stock'),
  NavEntry(NavKey.waste, Icons.delete_outline, Icons.delete, 'Waste Log',
      section: 'Stock'),
  NavEntry(NavKey.shifts, Icons.badge_outlined, Icons.badge, 'Shifts',
      section: 'HR'),
  // HR — self-service, every role carries the web grants timeclock / my-pay /
  // my-activity, so the trio rides at the end of every list.
  NavEntry(NavKey.timeclock, Icons.schedule_outlined, Icons.schedule,
      'Time Clock', section: 'HR'),
  NavEntry(NavKey.myPay, Icons.request_quote_outlined, Icons.request_quote,
      'My Payslips', section: 'HR'),
  NavEntry(NavKey.myActivity, Icons.insights_outlined, Icons.insights,
      'My Activity', section: 'HR'),
  NavEntry(NavKey.reports, Icons.description_outlined, Icons.description,
      'Reports', section: 'Analytics'),
  NavEntry(NavKey.analytics, Icons.insights_outlined, Icons.insights,
      'Analytics', section: 'Analytics'),
  NavEntry(NavKey.customers, Icons.group_outlined, Icons.group, 'Customers',
      section: 'System'),
  NavEntry(NavKey.audit, Icons.receipt_long_outlined, Icons.receipt_long,
      'Audit Log', section: 'System'),
  NavEntry(NavKey.settings, Icons.settings_outlined, Icons.settings,
      'Settings', section: 'System'),
];

NavEntry _entry(NavKey key) =>
    kAllNavEntries.firstWhere((e) => e.key == key);

/// Which screens each role sees — the web ROLE_PERMISSIONS matrix verbatim
/// (pos/src/api/index.js), in nav order. Order matters twice over: it is the
/// sidebar order, and the first three non-Settings entries ride the phone's
/// bottom bar — so each list leads with the role's home screen.
const Map<String, List<NavKey>> kRolePermissions = {
  // Everything but the HR self-service trio, which rides below.
  'manager': [
    NavKey.dashboard,
    NavKey.alertsDash,
    // Sales
    NavKey.orders,
    NavKey.openChecks,
    NavKey.menuMgmt,
    NavKey.menuView,
    // Operations
    NavKey.tables,
    NavKey.tableHistory,
    NavKey.reservations,
    NavKey.delivery,
    NavKey.kitchen,
    NavKey.barista,
    NavKey.pipeline,
    // Finance
    NavKey.expenses,
    NavKey.pnl,
    NavKey.cashdrawer,
    NavKey.revenue,
    // Stock
    NavKey.inventory,
    NavKey.recipes,
    NavKey.stockControl,
    NavKey.suppliers,
    NavKey.purchases,
    NavKey.waste,
    NavKey.shifts,
    // Analytics + system
    NavKey.reports,
    NavKey.analytics,
    NavKey.audit,
    NavKey.customers,
  ],
  // The kitchen board is home; the chef owns the counts (inventory), the BOM
  // (recipes) and the bin (waste). Suppliers, purchases, stock-control and
  // reports were removed at the owner's direction — procurement, the stock
  // intelligence screens and business reporting are backoffice reading, and
  // the server matrix (fufut-api ROLE_ACCESS) refuses them to this role too.
  // The floor plan joined (owner's call, 2026-09): the kitchen sees the room
  // it cooks for — which tables are busy, who is waiting for the bill — and
  // turns a table when the party has gone. Read-shaped: the sheet hides the
  // order/seating writes for this role; the only action is Free Table.
  'head-chef': [
    NavKey.kitchen,
    NavKey.orders,
    NavKey.dashboard,
    NavKey.alertsDash,
    // Pipeline left (owner's call, 2026-09): for the kitchen it duplicated
    // the board ticket-for-ticket — the board IS the kitchen's pipeline. The
    // kanban stays a manager's overview (served/cancelled lanes, cancel).
    NavKey.tables,
    NavKey.inventory,
    NavKey.recipes,
    NavKey.waste,
    NavKey.menuMgmt, // availability toggle only — the screen gates the CRUD
  ],
  // Cooks from the recipes: stock visibility and the BOM. Writes no stock,
  // no waste — the head chef owns both. Floor visibility rides along with the
  // head chef's grant (read + Free Table; no ordering, no seating).
  'assistant-chef': [
    NavKey.kitchen,
    NavKey.orders,
    NavKey.dashboard,
    NavKey.alertsDash,
    // Pipeline left with the head chef (same owner call — the board covers it).
    NavKey.tables,
    NavKey.inventory,
    NavKey.recipes,
  ],
  // The drinks station: its own board first, then whole tickets, the bin and
  // the drink recipes (read-only, filtered to drinks by the screen).
  'barista': [
    NavKey.barista,
    NavKey.orders,
    NavKey.alertsDash,
    NavKey.waste,
    NavKey.recipes,
  ],
  // The floor: tables is home, menu view takes orders, open checks is money
  // owed, reservations is the book. No delivery — the web grant does not
  // carry it either.
  'head-waiter': [
    NavKey.tables,
    NavKey.tableHistory,
    NavKey.menuView,
    NavKey.orders,
    NavKey.openChecks,
    NavKey.dashboard,
    NavKey.alertsDash,
    NavKey.reservations,
  ],
  // The till: drawer home, menu view for walk-in sales, checks to settle, the
  // book. The floor plan left (owner's call, 2026-09) — running the tables is
  // the head-waiter's job, and the till's table work is answering the Bill
  // Requests card on the Dashboard and settling from Open Checks, not walking
  // the floor. Revenue, Analytics and Reports are manager and accountant
  // reading — the cashier's own numbers live on the Dashboard and the Cash
  // Drawer (whose tiles read /api/reports/dashboard, which the server still
  // allows this role).
  'cashier': [
    NavKey.cashdrawer,
    NavKey.menuView,
    NavKey.orders,
    NavKey.openChecks,
    NavKey.dashboard,
    NavKey.alertsDash,
    NavKey.reservations,
  ],
  'delivery-staff': [
    NavKey.delivery,
    NavKey.dashboard,
    NavKey.alertsDash,
  ],
  'cleaner': [
    NavKey.waste,
    NavKey.dashboard,
  ],
  // Reads the financial picture, writes only expenses — the accountant's
  // web grant exactly.
  'accountant': [
    NavKey.reports,
    NavKey.dashboard,
    NavKey.revenue,
    NavKey.pnl,
    NavKey.expenses,
    NavKey.analytics,
    NavKey.orders,
    NavKey.purchases,
    NavKey.suppliers,
  ],
};

/// The web grants `timeclock`, `my-pay` and `my-activity` to the manager
/// alone in the least-privilege pass — the HR section is the owner's, not the
/// staff's. Clocking in and out still works for any signed-in account (the
/// server's self-service routes), but the screens stay off the staff nav so
/// an employed team member never sees an HR tab at all.
const List<NavKey> kHrNavKeys = [
  NavKey.timeclock,
  NavKey.myPay,
  NavKey.myActivity,
];

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

// ── Action grants ────────────────────────────────────────────────────────────
// Navigation is half the matrix; the other half is who may press which button
// inside a shared screen. These mirror the web POS exactly:
//
//  * `checkout` — the settlement grant. "deliberately NOT in the head-waiter's
//    list" (pos/src/api/index.js): the floor takes orders and asks for the
//    bill, the till takes the money. OpenChecksView's Settle, TablesView's
//    checkout button and OrdersView's New Order all ride this gate.
//  * prep advancing — OrdersView shows "Start Prep" / "Ready" only to the
//    two chef roles (`auth.roleKey==='head-chef' || 'assistant-chef'`).
//    Everyone else — the waiter included — sees tickets move; they do not
//    move them. "Complete" (ready → fulfilled) is deliberately ungated on the
//    web: handing the guest their food is the floor's moment too.
//  * manager rides along everywhere by grant, except prep on the Orders
//    screen (the web keeps that chef-only; the manager's kitchen board is the
//    place to push tickets from).

const Set<String> kCheckoutRoles = {'manager', 'cashier'};
const Set<String> kPrepRoles = {'head-chef', 'assistant-chef'};

/// Who may mark an order SERVED. Owner's rule (2026-09): the kitchen hands
/// food over, the floor serves it — the chef says "picked up", the waiter
/// says "served", and never the other way round. The till joins the floor
/// set because takeaway hands over at the counter: the guest's last touch is
/// the till, and an order the till cannot mark served would never reach the
/// settle list (only served orders settle). The manager rides along.
const Set<String> kServeRoles = {'manager', 'head-waiter', 'cashier'};

/// May this role mark a fulfilled order served?
bool canMarkServed(String? roleKey) => kServeRoles.contains(roleKey ?? '');

/// Who opens a table's ticket. Starting a New Order / adding a round to a
/// seated party is floor work — the head-waiter's, with the manager riding
/// along. The till sells at the counter (Menu View), not off the floor plan;
/// the kitchen cooks what arrives; the driver and the cleaner never open a
/// ticket. Mirrors the server's request-bill rule (tables.js): the floor
/// leads and the manager.
const Set<String> kFloorOrderRoles = {'manager', 'head-waiter'};

/// May this role start a New Order / Add Round from the floor plan?
bool canTakeTableOrders(String? roleKey) =>
    kFloorOrderRoles.contains(roleKey ?? '');

/// Who may clear a party off a table. Freeing a table after the guests have
/// gone used to belong to the floor alone; the owner added the kitchen
/// (2026-09) because the pass sees the room empty first and a table left
/// 'occupied' ghosts the whole floor plan. Guarded server-side: the call
/// refuses while an open check on the table is still unpaid — the kitchen
/// can turn a table, it cannot erase a bill.
const Set<String> kFreeTableRoles = {
  'manager',
  'head-waiter',
  'head-chef',
  'assistant-chef',
};

/// May this role free a table (the sheet's Free Table action)?
bool canFreeTable(String? roleKey) => kFreeTableRoles.contains(roleKey ?? '');

/// May this role edit a table's party — quick-status chips, guests, notes,
/// Save Changes? The server grants `tables` writes to the head-waiter and
/// the manager (plus the cashier, whose tab no longer reaches the screen);
/// the kitchen's floor view is read-shaped, so the sheet hides the form.
const Set<String> kTableEditRoles = {'manager', 'head-waiter'};

/// May this role edit the party on a table (status chips, guests, notes)?
bool canEditTable(String? roleKey) => kTableEditRoles.contains(roleKey ?? '');

/// May this role settle bills / open the payment sheet? (the web `checkout`
/// grant — manager and cashier only).
bool canCheckout(String? roleKey) =>
    kCheckoutRoles.contains(roleKey ?? '');

/// May this role advance kitchen stages from the Orders screen? (Start Prep /
/// Mark Ready — chef work, chef roles only.)
bool canAdvancePrep(String? roleKey) => kPrepRoles.contains(roleKey ?? '');

/// "head-chef" → "Head Chef" for display.
String roleTitle(String role) {
  if (role.isEmpty) return '';
  return role
      .split(RegExp(r'[\s_-]+'))
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
      .join(' ');
}

/// Nav entries for [roleKey], Settings always last. The HR self-service trio
/// rides for the manager only — staff see their job's screens and nothing
/// else. Unknown roles fall back to the original cashier layout so nobody
/// lands on an empty shell.
List<NavEntry> navForRole(String? roleKey) {
  final keys =
      kRolePermissions[roleKey] ?? kFallbackPermissions;
  final hr = roleKey == 'manager' ? kHrNavKeys.map(_entry) : const Iterable<NavEntry>.empty();
  return [...keys.map(_entry), ...hr, _entry(NavKey.settings)];
}

/// The first screen for [roleKey]. Unknown roles start on the till.
NavKey defaultViewFor(String? roleKey) =>
    kRoleDefaultView[roleKey] ?? NavKey.menuView;

/// Titles for the topbar.
String titleFor(NavKey key) {
  switch (key) {
    case NavKey.dashboard:
      return 'Dashboard';
    case NavKey.alertsDash:
      return 'SLA Alerts';
    case NavKey.kitchen:
      return 'Kitchen Display';
    case NavKey.barista:
      return 'Barista Display';
    case NavKey.tables:
      return 'Floor Plan';
    case NavKey.tableHistory:
      return 'Table History';
    case NavKey.menuView:
      return 'Menu View';
    case NavKey.menuMgmt:
      return 'Menu Management';
    case NavKey.orders:
      return 'Orders';
    case NavKey.openChecks:
      return 'Open Checks';
    case NavKey.pipeline:
      return 'Pipeline';
    case NavKey.reservations:
      return 'Reservations';
    case NavKey.cashdrawer:
      return 'Cash Drawer';
    case NavKey.delivery:
      return 'Delivery';
    case NavKey.expenses:
      return 'Expenses';
    case NavKey.pnl:
      return 'Profit & Loss';
    case NavKey.revenue:
      return 'Revenue';
    case NavKey.analytics:
      return 'Analytics';
    case NavKey.reports:
      return 'Reports';
    case NavKey.inventory:
      return 'Inventory';
    case NavKey.recipes:
      return 'Recipes';
    case NavKey.stockControl:
      return 'Stock Control';
    case NavKey.suppliers:
      return 'Suppliers';
    case NavKey.purchases:
      return 'Purchases';
    case NavKey.waste:
      return 'Waste Log';
    case NavKey.shifts:
      return 'Shifts';
    case NavKey.timeclock:
      return 'Time Clock';
    case NavKey.myPay:
      return 'My Payslips';
    case NavKey.myActivity:
      return 'My Activity';
    case NavKey.customers:
      return 'Customers';
    case NavKey.audit:
      return 'Audit Log';
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
