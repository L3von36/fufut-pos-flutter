#!/usr/bin/env python3
"""RBAC live probe: sign in as every role on the production POS API and
assert the server-side role matrix refuses forbidden reads/writes (403)
while allowing the role's own endpoints (200/2xx).

Usage: python3 rbac_probe.py
"""
import json
import urllib.request
import urllib.error

BASE = 'https://pos.fufutcoffee.com'
PASSWORD = 'selam@336'

# Per role: account + endpoints expected ALLOWED (2xx) and FORBIDDEN (403).
# Expectations mirror lib/state/roles.dart kRolePermissions (v1.1.9+20),
# which mirrors the web POS matrix and the fufut-api ROLE_ACCESS.
ROLES = {
    'manager (amanuel)': {
        'email': 'amanuel@fufut.coffee',
        'allowed': ['orders', 'tables', 'menu', 'suppliers', 'purchases',
                    'inventory', 'expenses', 'staff', 'reports', 'reservations',
                    'waste'],
        'forbidden': [],
    },
    'head-waiter (yonas)': {
        'email': 'yonas@fufut.coffee',
        'allowed': ['orders', 'tables', 'menu', 'reservations'],
        'forbidden': ['suppliers', 'purchases', 'staff', 'expenses',
                      'reports', 'stock-movements', 'pnl'],
    },
    'cashier (bethel)': {
        'email': 'bethel@fufut.coffee',
        'allowed': ['orders', 'menu', 'reservations', 'reports/dashboard'],
        'forbidden': ['suppliers', 'purchases', 'staff', 'expenses',
                      'reports/financial', 'reports/accountant',
                      'reports/staff-performance', 'reports/top-items',
                      'reports/hourly-heatmap', 'reports/ingredient/RM1',
                      'stock-movements', 'pnl', 'revenue'],
    },
    'barista': {
        'email': 'barista@fufut.coffee',
        'allowed': ['orders', 'menu'],
        # 'tables' is a documented server grant (ticket context for the bar),
        # not a leak — the barista nav has no Tables screen on any client.
        'forbidden': ['suppliers', 'purchases', 'staff', 'expenses',
                      'reports', 'stock-movements'],
    },
    'head-chef (selam)': {
        'email': 'selam@fufut.coffee',
        'allowed': ['orders', 'menu', 'inventory', 'waste'],
        'forbidden': ['suppliers', 'purchases', 'staff', 'expenses',
                      'reports', 'stock-movements', 'pnl', 'reservations'],
    },
    'delivery (gebremedhin)': {
        'email': 'gebremedhin@fufut.coffee',
        'allowed': ['orders'],
        'forbidden': ['suppliers', 'purchases', 'staff', 'expenses',
                      'reports', 'tables', 'menu-mgmt'],
    },
    'cleaner (asnegash)': {
        'email': 'asnegash@fufut.coffee',
        'allowed': [],
        'forbidden': ['suppliers', 'purchases', 'staff', 'expenses',
                      'reports', 'orders', 'reservations', 'menu-mgmt'],
    },
    # 2026-09-23: owner supplied the last two passwords; walk them live.
    'assistant-chef (tigist)': {
        'email': 'tigist@fufut.coffee',
        # auth.js ROLE_ACCESS read: orders tables inventory recipes units
        # alerts tasks — mirrors roles.dart (7 nav items, no waste: the head
        # chef owns the bin).
        'allowed': ['orders', 'tables', 'inventory', 'recipes', 'alerts'],
        'forbidden': ['suppliers', 'purchases', 'staff', 'expenses',
                      'reports/financial', 'stock-movements', 'pnl', 'waste',
                      'reservations', 'cashdrawer', 'audit'],
    },
    'accountant (novel)': {
        'email': 'novel@fufut.coffee',
        # auth.js ROLE_ACCESS: full financial read incl. every /api/reports/*
        # subpath + staff/payroll context; write = expenses ONLY. No tables,
        # no waste, no reservations.
        'allowed': ['reports/financial', 'reports/accountant',
                    'reports/staff-performance', 'reports/top-items',
                    'reports/hourly-heatmap', 'orders', 'payments', 'expenses',
                    'purchases', 'suppliers', 'staff', 'inventory',
                    'cashdrawer', 'audit'],
        'forbidden': ['waste', 'tables', 'reservations', 'stock-movements',
                      'pnl', 'role-scopes'],
    },
}

WRITE_PROBES = [  # forbidden writes, sampled per run
    ('POST', 'suppliers', {'name': 'RBAC-PROBE'}),
    ('POST', 'purchases', {'supplier': 'RBAC-PROBE'}),
    ('POST', 'expenses', {'amount': 1, 'category': 'RBAC-PROBE'}),
]


def request(method, path, cookie=None, payload=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header('Content-Type', 'application/json')
    req.add_header('Origin', BASE)
    req.add_header('User-Agent', 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36')
    if cookie:
        req.add_header('Cookie', cookie)
    data = json.dumps(payload).encode() if payload is not None else None
    try:
        with urllib.request.urlopen(req, data=data, timeout=30) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:  # noqa
        return 0, str(e).encode()


def main():
    total_pass = total_fail = 0
    failures = []
    for label, cfg in ROLES.items():
        code, body = request('POST', '/api/auth/login',
                             payload={'email': cfg['email'],
                                      'password': PASSWORD})
        if code != 200:
            print(f"[{label}] LOGIN FAILED {code}: {body[:80]!r}")
            total_fail += 1
            failures.append((label, 'login', code))
            continue
        # session cookie from Set-Cookie
        # (urlopen raises for 4xx; re-issue with a no-redirect opener)
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k):
                return None
        opener = urllib.request.build_opener(NoRedirect)
        req = urllib.request.Request(BASE + '/api/auth/login', method='POST',
                                     data=json.dumps({'email': cfg['email'],
                                                      'password': PASSWORD}).encode())
        req.add_header('Content-Type', 'application/json')
        req.add_header('Origin', BASE)
        req.add_header('User-Agent', 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36')
        try:
            resp = opener.open(req, timeout=30)
            setc = resp.headers.get('Set-Cookie', '')
        except urllib.error.HTTPError as e:
            setc = e.headers.get('Set-Cookie', '')
        cookie = setc.split(';')[0] if setc else None
        if not cookie:
            print(f"[{label}] no session cookie — aborting role")
            total_fail += 1
            continue
        role_tag = json.loads(body).get('user', {}).get('role', '?')

        print(f"\n== {label}  (server role: {role_tag}) ==")
        for ep in cfg['allowed']:
            code, _ = request('GET', f'/api/{ep}', cookie=cookie)
            ok = code in (200, 201)
            total_pass += ok
            total_fail += not ok
            if not ok:
                failures.append((label, f'GET {ep} allowed', code))
            print(f"  ALLOW GET /api/{ep:<16} -> {code} {'OK' if ok else '<-- UNEXPECTED'}")
        for ep in cfg['forbidden']:
            code, b = request('GET', f'/api/{ep}', cookie=cookie)
            ok = code == 403
            total_pass += ok
            total_fail += not ok
            if not ok:
                failures.append((label, f'GET {ep} forbidden', code))
            detail = ''
            if not ok:
                detail = ' ' + b[:120].decode(errors='replace')
            print(f"  DENY  GET /api/{ep:<16} -> {code} {'OK' if ok else '<-- LEAK'}{detail}")
        for method, ep, payload in WRITE_PROBES:
            if label.startswith('manager'):
                continue  # manager holds write:* — its allowed writes are not leaks
            if label.startswith('accountant') and ep == 'expenses':
                # accountant holds write:expenses — the probe would SUCCEED and
                # create a real expense row in production. Read probes above
                # already cover the role; skip rather than pollute the ledger.
                continue
            code, b = request(method, f'/api/{ep}', cookie=cookie, payload=payload)
            ok = code == 403
            total_pass += ok
            total_fail += not ok
            if not ok:
                failures.append((label, f'{method} {ep} forbidden', code))
            print(f"  DENY  {method} /api/{ep:<16} -> {code} {'OK' if ok else '<-- LEAK'}")

    print(f"\n===== TOTAL: {total_pass} pass / {total_fail} fail =====")
    for f in failures:
        print('  FAIL:', f)


if __name__ == '__main__':
    main()
