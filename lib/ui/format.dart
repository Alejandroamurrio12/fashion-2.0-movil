import 'package:intl/intl.dart';

final _money = NumberFormat('#,##0.00', 'es_BO');
final _dateTime = DateFormat('dd/MM/yyyy HH:mm', 'es_BO');
final _date = DateFormat('dd/MM/yyyy', 'es_BO');

/// Importe en bolivianos: "Bs 1.200,50".
String money(num? value) => value == null ? '—' : 'Bs ${_money.format(value)}';

String dateTime(String? iso) => iso == null ? '—' : _dateTime.format(DateTime.parse(iso).toLocal());

String date(String? iso) => iso == null ? '—' : _date.format(DateTime.parse(iso).toLocal());

double round2(num v) => (v * 100).roundToDouble() / 100;
