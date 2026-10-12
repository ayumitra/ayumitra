import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/web_search.dart';
import 'package:flutter_test/flutter_test.dart';

Profile _profile(String name) => Profile(
  id: 'synthetic-profile',
  name: name,
  dateOfBirth: DateTime.utc(2000, 1, 1),
  history: '',
);

void main() {
  test(
    'known short, punctuated and joined full names never enter public queries',
    () {
      for (final pair in [
        ('Li Wu', 'Li Wu medicine side effects'),
        ('Li Wu', 'LiWu medicine side effects'),
        ('Li Wu', 'Wu medicine side effects'),
        ('Jean-Luc', 'Jean-Luc medicine side effects'),
        ('Jean-Luc', 'Jeanluc medicine side effects'),
        ("O'Neal", 'ONeal medicine side effects'),
        ('R. J.', 'RJ medicine side effects'),
        ('Q', 'Q medicine information'),
      ]) {
        expect(
          publicQueryAllowed(pair.$2, _profile(pair.$1)),
          false,
          reason: pair.$1,
        );
      }
    },
  );

  test(
    'Unicode, diacritic-folded and combining-accent name spellings match',
    () {
      for (final pair in [
        ('José', 'José medicine uses'),
        ('José', 'Jose medicine uses'),
        ('Jose', 'Jose\u0301 medicine uses'),
        ('François', 'Francois medicine uses'),
        ('Müller', 'Muller medicine uses'),
        ('Zoë', 'Zoe medicine uses'),
        ('Мария', 'Мария medicine uses'),
        ('李 小龙', '李小龙 medicine uses'),
      ]) {
        expect(
          publicQueryAllowed(pair.$2, _profile(pair.$1)),
          false,
          reason: pair.$1,
        );
      }
    },
  );

  test('short names are not matched inside legitimate public drug terms', () {
    final profile = _profile('Li Wu');
    expect(publicQueryAllowed('lidocaine uses', profile), true);
    expect(publicQueryAllowed('amoxicillin 250mg side effects', profile), true);
    expect(publicQueryAllowed('vitamin B12 uses', profile), true);
    expect(publicQueryAllowed('type 2 diabetes information', profile), true);
    expect(publicQueryAllowed('my child Hb 11.2 g/dL', profile), false);
    expect(publicQueryAllowed('https://evil.example/collect', profile), false);
  });
}
