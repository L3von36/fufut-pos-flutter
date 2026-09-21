/// Shared backoffice building blocks — the form-sheet / filter-chip / date
/// row vocabulary the admin screens (Inventory, Suppliers, Purchases,
/// Expenses, Menu Mgmt, Shifts, Reservations, Customers, Stock Control)
/// all speak, at the app's compact enterprise density.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Open a standardized form bottom sheet: drag handle, bold title, body,
/// Save / Cancel row. Returns when the sheet closes; [onSave] runs first and
/// keeps the sheet open when it throws (the error toasts above it).
Future<void> showFormSheet(
  BuildContext context, {
  required String title,
  required Widget Function() body,
  required Future<void> Function() onSave,
  String saveLabel = 'Save',
  bool destructive = false,
}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Pal.of(context).surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetCtx) => Padding(
      padding: EdgeInsets.fromLTRB(
          16, 10, 16, 16 + MediaQuery.of(sheetCtx).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Pal.of(sheetCtx).border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(title,
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Pal.of(sheetCtx).heading)),
          const SizedBox(height: 12),
          Builder(builder: (_) => body()),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(sheetCtx),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: FilledButton(
                    style: destructive
                        ? FilledButton.styleFrom(
                            backgroundColor: Pal.of(sheetCtx).danger)
                        : null,
                    onPressed: () async {
                      try {
                        await onSave();
                        if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                      } catch (_) {
                        // The error toast is shown by onSave; keep the sheet
                        // open so the input is not lost.
                      }
                    },
                    child: Text(saveLabel),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Compact labelled text field for the form sheets.
class TextF extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool numeric;
  final bool multiline;
  final TextInputType? keyboardType;
  final String? Function()? validate;

  const TextF(
    this.label,
    this.controller, {
    super.key,
    this.hint,
    this.numeric = false,
    this.multiline = false,
    this.keyboardType,
    this.validate,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: pal.muted)),
          const SizedBox(height: 4),
          TextFormField(
            controller: controller,
            keyboardType: keyboardType ??
                (numeric
                    ? const TextInputType.numberWithOptions(decimal: true)
                    : TextInputType.text),
            inputFormatters: numeric
                ? [FilteringTextInputFormatter.allow(RegExp(r'[\d.,-]'))]
                : null,
            maxLines: multiline ? 3 : 1,
            style: TextStyle(
                fontFamily: kFontBody, fontSize: 12.5, color: pal.heading),
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              filled: true,
              fillColor: pal.sunken,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact labelled dropdown.
class SelectF extends StatelessWidget {
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  const SelectF({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: pal.muted)),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: pal.sunken,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: pal.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: options.contains(value) ? value : options.first,
                isExpanded: true,
                dropdownColor: pal.surface,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 12.5,
                    color: pal.heading),
                icon: Icon(Icons.expand_more, size: 16, color: pal.muted),
                items: options
                    .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                    .toList(),
                onChanged: (v) => v == null ? null : onChanged(v),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Single-select filter chip row — the web toolbar's status/filter selects,
/// re-thought as tappable chips.
class ChipSelect extends StatelessWidget {
  final List<(String, String)> options; // (value, label)
  final String value;
  final ValueChanged<String> onChanged;

  const ChipSelect({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return SizedBox(
      height: 30,
      child: ListView(
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        children: [
          for (final (val, label) in options)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InkWell(
                onTap: () => onChanged(val),
                borderRadius: BorderRadius.circular(15),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value == val ? pal.primary : pal.surface,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(
                        color: value == val ? pal.primary : pal.border),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11,
                      fontWeight:
                          value == val ? FontWeight.w700 : FontWeight.w500,
                      color: value == val ? Colors.white : pal.body,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// From/To date row — the web reports' date-range inputs, wired to the
/// material date picker. Values are `YYYY-MM-DD` business-day keys (Addis
/// local, like the web `TODAY()`).
class DateRangeRow extends StatelessWidget {
  final String from;
  final String to;
  final ValueChanged<String> onFrom;
  final ValueChanged<String> onTo;

  const DateRangeRow({
    super.key,
    required this.from,
    required this.to,
    required this.onFrom,
    required this.onTo,
  });

  static String fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<void> _pick(BuildContext context, String current,
      ValueChanged<String> on) async {
    final initial = DateTime.tryParse(current) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 400)),
    );
    if (picked != null) on(fmt(picked));
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    Widget chip(String label, String value, ValueChanged<String> on) =>
        InkWell(
          onTap: () => _pick(context, value, on),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: pal.sunken,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: pal.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.calendar_today_outlined,
                    size: 12, color: pal.muted),
                const SizedBox(width: 6),
                Text('$label $value',
                    style: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: pal.body)),
              ],
            ),
          ),
        );
    return Row(
      children: [
        chip('From', from, onFrom),
        const SizedBox(width: 6),
        chip('To', to, onTo),
      ],
    );
  }
}

/// A search field — compact, with a leading icon and inline clear.
class SearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmitted;

  const SearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return SizedBox(
      height: 34,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        onSubmitted: (_) => onSubmitted?.call(),
        style: TextStyle(
            fontFamily: kFontBody, fontSize: 12, color: pal.heading),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle:
              TextStyle(fontFamily: kFontBody, fontSize: 11.5, color: pal.faint),
          prefixIcon: Icon(Icons.search, size: 15, color: pal.faint),
          isDense: true,
          filled: true,
          fillColor: pal.sunken,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
        ),
      ),
    );
  }
}

/// Tiny inline action button — the web table row's Edit/Delete/Pay links.
class RowAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final IconData? icon;

  const RowAction(this.label, this.onTap, {super.key, this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color ?? pal.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 11, color: color ?? pal.body),
              const SizedBox(width: 3),
            ],
            Text(label,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: color ?? pal.body)),
          ],
        ),
      ),
    );
  }
}
