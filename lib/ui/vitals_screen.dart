import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/vitals.dart';

/// Host surface the vitals screen reads and writes. Main wires the real
/// controller by adding `implements VitalsHost` plus the two recording
/// methods below, validated through [addVital] and persisted in the vault,
/// plus the DOB getter (new: `DateTime? get activeDateOfBirth =>
/// profile?.dateOfBirth;` — required, the screen does not compile its host
/// contract without it):
///
/// ```dart
/// Future<void> recordVital(
///   VitalKind kind,
///   double value, {
///   double? diastolic,
///   String? unit,
///   DateTime? measuredAt,
///   String note = '',
/// });
/// Future<void> deleteVital(String id);
/// ```
abstract class VitalsHost implements Listenable {
  List<VitalEntry> get vitals;
  String? get activeProfileId;

  /// Active profile date of birth, or null when unknown. The screen clamps
  /// manual entry to calendar days on/after it; the controller enforces the
  /// same rule for every write path.
  DateTime? get activeDateOfBirth;
  bool get busy;

  Future<void> recordVital(
    VitalKind kind,
    double value, {
    double? diastolic,
    String? unit,
    DateTime? measuredAt,
    String note = '',
  });

  Future<void> deleteVital(String id);
}

const _kindUnits = <VitalKind, List<String>>{
  VitalKind.spo2: ['%'],
  VitalKind.bloodPressure: ['mmHg'],
  VitalKind.temperature: ['°C', '°F'],
  VitalKind.pulse: ['bpm'],
  VitalKind.height: ['cm'],
  VitalKind.weight: ['kg'],
};

const _kindIcons = <VitalKind, IconData>{
  VitalKind.spo2: Icons.air,
  VitalKind.bloodPressure: Icons.favorite_outline,
  VitalKind.temperature: Icons.thermostat,
  VitalKind.pulse: Icons.show_chart,
  VitalKind.height: Icons.height,
  VitalKind.weight: Icons.monitor_weight_outlined,
};

/// Per-profile key-metric tracking: latest values, local trend plots, and a
/// manual entry form. Everything shown is a recorded reading with its own
/// date — nothing is interpolated, averaged, or diagnosed. Manual entries
/// are user-reported and unverified.
class VitalsScreen extends StatefulWidget {
  const VitalsScreen({super.key, required this.host});

  final VitalsHost host;

  @override
  State<VitalsScreen> createState() => _VitalsScreenState();
}

class _VitalsScreenState extends State<VitalsScreen> {
  VitalKind _kind = VitalKind.spo2;

  /// Day window for chart and list. Null means all history.
  int? _windowDays;

  final _value = TextEditingController();
  final _diastolic = TextEditingController();
  final _note = TextEditingController();
  String _unit = '%';
  DateTime _when = DateTime.now();
  String? _error;
  bool _saving = false;
  late final String? _ownerProfileId;

  @override
  void initState() {
    super.initState();
    _ownerProfileId = widget.host.activeProfileId;
  }

  bool get _scopeMatches =>
      _ownerProfileId != null && _host.activeProfileId == _ownerProfileId;

  @override
  void dispose() {
    _value.dispose();
    _diastolic.dispose();
    _note.dispose();
    super.dispose();
  }

  VitalsHost get _host => widget.host;

  List<VitalEntry> get _owned =>
      vitalsFor(_host.vitals, _ownerProfileId ?? '', kind: _kind);

  List<VitalEntry> get _windowed {
    final days = _windowDays;
    if (days == null) return _owned;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    return _owned.where((e) => !e.measuredAt.isBefore(cutoff)).toList();
  }

  void _selectKind(VitalKind kind) {
    if (!_scopeMatches || kind == _kind) return;
    setState(() {
      _kind = kind;
      _unit = _kindUnits[kind]!.first;
      _error = null;
    });
  }

  /// Calendar-day floor for manual entry: the DOB day when known (a reading
  /// later the same day is fine), else 1900. The controller enforces the
  /// same rule for every write path.
  DateTime get _earliestDay {
    final dob = _host.activeDateOfBirth;
    if (dob == null) return DateTime(1900);
    return DateTime(dob.year, dob.month, dob.day);
  }

  bool _dayBefore(DateTime day, DateTime floor) =>
      day.year < floor.year ||
      (day.year == floor.year &&
          (day.month < floor.month ||
              (day.month == floor.month && day.day < floor.day)));

  Future<void> _pickDate() async {
    if (!_scopeMatches) return;
    final now = DateTime.now();
    var initial = _when;
    if (_dayBefore(
      DateTime(initial.year, initial.month, initial.day),
      _earliestDay,
    )) {
      initial = DateTime(
        _earliestDay.year,
        _earliestDay.month,
        _earliestDay.day,
        now.hour,
        now.minute,
      );
    }
    if (initial.isAfter(now)) initial = now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: _earliestDay,
      lastDate: now,
    );
    if (picked == null || !mounted || !_scopeMatches) return;
    setState(() {
      _when = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _when.hour,
        _when.minute,
      );
      _error = null;
    });
  }

  Future<void> _pickTime() async {
    if (!_scopeMatches) return;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_when),
    );
    if (picked == null || !mounted || !_scopeMatches) return;
    setState(() {
      _when = DateTime(
        _when.year,
        _when.month,
        _when.day,
        picked.hour,
        picked.minute,
      );
      _error = null;
    });
  }

  Future<void> _save() async {
    if (!_scopeMatches || _host.busy || _saving) return;
    final raw = _value.text.trim();
    final value = double.tryParse(raw);
    if (value == null) {
      setState(() => _error = 'Enter a numeric value.');
      return;
    }
    if (_dayBefore(
      DateTime(_when.year, _when.month, _when.day),
      _earliestDay,
    )) {
      setState(() => _error = 'Date cannot be before the date of birth.');
      return;
    }
    double? diastolic;
    if (_kind == VitalKind.bloodPressure) {
      diastolic = double.tryParse(_diastolic.text.trim());
      if (diastolic == null) {
        setState(() => _error = 'Enter diastolic as a number.');
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _host.recordVital(
        _kind,
        value,
        diastolic: diastolic,
        unit: _unit,
        measuredAt: _when,
        note: _note.text.trim(),
      );
      if (!mounted || !_scopeMatches) return;
      _value.clear();
      _diastolic.clear();
      _note.clear();
      setState(() => _error = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Reading saved.')));
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(VitalEntry entry) async {
    if (!_scopeMatches || entry.profileId != _ownerProfileId || _host.busy) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this reading?'),
        content: Text(
          '${_readingText(entry)} · ${_dateText(entry.measuredAt)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true &&
        mounted &&
        _scopeMatches &&
        entry.profileId == _ownerProfileId &&
        !_host.busy) {
      await _host.deleteVital(entry.id);
    }
  }

  String _readingText(VitalEntry entry) {
    if (entry.kind == VitalKind.bloodPressure) {
      String number(double? v) => v == null ? '–' : formatVitalValue(v);
      return '${number(entry.value)}/${number(entry.secondaryValue)} ${entry.unit}';
    }
    final glue = entry.unit == '%' ? '' : ' ';
    return '${formatVitalValue(entry.value)}$glue${entry.unit}';
  }

  String _dateText(DateTime at) =>
      '${DateFormat.yMMMd().format(at)} · ${DateFormat.Hm().format(at)}';

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _host,
    builder: (context, _) {
      final profileId = _host.activeProfileId;
      return Scaffold(
        appBar: AppBar(title: const Text('Key metrics')),
        body: profileId == null && _ownerProfileId == null
            ? const Center(child: Text('Open a profile to track metrics.'))
            : !_scopeMatches
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'You switched profiles. Go back and reopen Key metrics for the current profile. Your unfinished entry has not been saved.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                      children: [
                        const Text(
                          'Readings you add are user-reported and unverified. '
                          'Trends show recorded points only — nothing is '
                          'interpreted or diagnosed here.',
                          style: TextStyle(fontSize: 12, height: 1.5),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final kind in VitalKind.values)
                              ChoiceChip(
                                key: Key('vitals-kind-${kind.name}'),
                                avatar: Icon(_kindIcons[kind], size: 18),
                                label: Text(vitalKindLabel(kind)),
                                selected: _kind == kind,
                                onSelected: _host.busy
                                    ? null
                                    : (_) => _selectKind(kind),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _latestCard(),
                        const SizedBox(height: 8),
                        _windowRow(),
                        const SizedBox(height: 8),
                        _chartCard(),
                        const SizedBox(height: 12),
                        _formCard(),
                        const SizedBox(height: 12),
                        _historyList(),
                      ],
                    ),
                  ),
                ),
              ),
      );
    },
  );

  Widget _latestCard() {
    final latest = _windowed.isEmpty ? null : _windowed.first;
    return Card(
      child: ListTile(
        leading: Icon(_kindIcons[_kind], size: 32),
        title: Text(
          latest == null
              ? 'No ${vitalKindLabel(_kind).toLowerCase()} readings yet'
              : 'Latest ${_readingText(latest)}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: latest == null
            ? const Text('Add the first measurement below.')
            : Text(_dateText(latest.measuredAt)),
      ),
    );
  }

  Widget _windowRow() => Wrap(
    spacing: 8,
    children: [
      for (final entry in const [
        (7, '7 days'),
        (30, '30 days'),
        (90, '90 days'),
        (null, 'All'),
      ])
        ChoiceChip(
          key: Key('vitals-window-${entry.$1 ?? 'all'}'),
          label: Text(entry.$2),
          selected: _windowDays == entry.$1,
          onSelected: _host.busy
              ? null
              : (_) => setState(() => _windowDays = entry.$1),
        ),
    ],
  );

  Widget _chartCard() => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${vitalKindLabel(_kind)} trend',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 220,
            width: double.infinity,
            child: CustomPaint(
              key: const Key('vitals-chart'),
              painter: _TrendPainter(
                entries: _windowed,
                kind: _kind,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _formCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Add a measurement',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('vitals-value'),
            controller: _value,
            enabled: !_host.busy && !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: _kind == VitalKind.bloodPressure
                  ? 'Systolic'
                  : 'Value',
              suffixText: _unit,
            ),
          ),
          if (_kind == VitalKind.bloodPressure) ...[
            const SizedBox(height: 8),
            TextField(
              key: const Key('vitals-diastolic'),
              controller: _diastolic,
              enabled: !_host.busy && !_saving,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Diastolic'),
            ),
          ],
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: const Key('vitals-unit'),
            initialValue: _unit,
            decoration: const InputDecoration(labelText: 'Unit'),
            items: _kindUnits[_kind]!
                .map((unit) => DropdownMenuItem(value: unit, child: Text(unit)))
                .toList(),
            onChanged: _host.busy || _saving
                ? null
                : (next) {
                    if (next != null) setState(() => _unit = next);
                  },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('vitals-date'),
                  onPressed: _host.busy || _saving ? null : _pickDate,
                  icon: const Icon(Icons.calendar_today_outlined, size: 18),
                  label: Text(DateFormat.yMMMd().format(_when)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('vitals-time'),
                  onPressed: _host.busy || _saving ? null : _pickTime,
                  icon: const Icon(Icons.schedule_outlined, size: 18),
                  label: Text(DateFormat.Hm().format(_when)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('vitals-note'),
            controller: _note,
            enabled: !_host.busy && !_saving,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('vitals-save'),
              onPressed: _host.busy || _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              label: Text(_saving ? 'Saving…' : 'Save reading'),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _historyList() {
    if (_windowed.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recorded readings (${_windowed.length})',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        for (final entry in _windowed)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              title: Text(_readingText(entry)),
              subtitle: Text(_dateText(entry.measuredAt)),
              trailing: IconButton(
                key: Key('vitals-delete-${entry.id}'),
                tooltip: 'Delete reading',
                onPressed: _host.busy ? null : () => _delete(entry),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          ),
      ],
    );
  }
}

/// Local trend plot over recorded points only. One dot per measurement with
/// thin connectors between consecutive real readings — never smoothed,
/// extrapolated, or gap-filled. Blood pressure draws systolic and diastolic
/// as two series; temperature normalizes °F to °C for a single series.
class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.entries,
    required this.kind,
    required this.color,
  });

  final List<VitalEntry> entries;
  final VitalKind kind;
  final Color color;

  double _plotted(VitalEntry entry) {
    if (kind == VitalKind.temperature) {
      final unit = entry.unit.trim().toLowerCase();
      if (unit == '°f' || unit == 'f') {
        return (entry.value - 32) * 5 / 9;
      }
    }
    return entry.value;
  }

  double? _plottedSecond(VitalEntry entry) =>
      kind == VitalKind.bloodPressure ? entry.secondaryValue : null;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = EdgeInsets.fromLTRB(44, 12, 12, 24);
    final plot = Rect.fromLTWH(
      pad.left,
      pad.top,
      size.width - pad.horizontal,
      size.height - pad.vertical,
    );
    if (plot.width <= 0 || plot.height <= 0) return;
    final textStyle = TextStyle(
      color: color.withValues(alpha: 0.8),
      fontSize: 11,
    );

    void label(String text, Offset at) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: textStyle),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      painter.paint(canvas, at - Offset(0, painter.height / 2));
    }

    if (entries.isEmpty) {
      label('No readings in this window', plot.centerLeft);
      return;
    }
    // Chronological for the time axis; callers pass newest-first.
    final ordered = entries.reversed.toList();
    final values = <double>[
      for (final entry in ordered) _plotted(entry),
      for (final entry in ordered)
        if (_plottedSecond(entry) != null) _plottedSecond(entry)!,
    ];
    var min = values.reduce((a, b) => a < b ? a : b);
    var max = values.reduce((a, b) => a > b ? a : b);
    if (min == max) {
      min -= 1;
      max += 1;
    }
    final span = max - min;
    final first = ordered.first.measuredAt.millisecondsSinceEpoch.toDouble();
    final last = ordered.last.measuredAt.millisecondsSinceEpoch.toDouble();
    final timeSpan = (last - first) == 0 ? 1.0 : last - first;

    Offset point(DateTime at, double value) => Offset(
      plot.left + (at.millisecondsSinceEpoch - first) / timeSpan * plot.width,
      plot.bottom - (value - min) / span * plot.height,
    );

    final grid = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..strokeWidth = 1;
    for (final fraction in [0.0, 0.5, 1.0]) {
      final y = plot.top + fraction * plot.height;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    }
    label(_axisValue(max), Offset(0, plot.top));
    label(_axisValue(min), Offset(0, plot.bottom));
    label(
      DateFormat.MMMd().format(ordered.first.measuredAt),
      Offset(plot.left, plot.bottom + 6),
    );
    if (ordered.length > 1) {
      label(
        DateFormat.MMMd().format(ordered.last.measuredAt),
        Offset(plot.right - 30, plot.bottom + 6),
      );
    }

    void series(double? Function(VitalEntry) pick, Color paintColor) {
      final pts = [
        for (final entry in ordered)
          if (pick(entry) != null) point(entry.measuredAt, pick(entry)!),
      ];
      if (pts.isEmpty) return;
      if (pts.length > 1) {
        canvas.drawPoints(
          ui.PointMode.polygon,
          pts,
          Paint()
            ..color = paintColor.withValues(alpha: 0.5)
            ..strokeWidth = 1.5,
        );
      }
      canvas.drawPoints(
        ui.PointMode.points,
        pts,
        Paint()
          ..color = paintColor
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
    }

    series(_plotted, color);
    if (kind == VitalKind.bloodPressure) {
      series(_plottedSecond, Colors.orange);
    }
  }

  String _axisValue(double value) => formatVitalValue(value);

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.entries != entries || old.kind != kind || old.color != color;
}
