import 'package:flutter/material.dart';

class LocaleProvider extends ChangeNotifier {
  LocaleProvider(String languageCode) : _locale = Locale(languageCode);

  Locale _locale;
  Locale get locale => _locale;

  void setLanguage(String languageCode) {
    if (_locale.languageCode == languageCode) return;
    _locale = Locale(languageCode);
    notifyListeners();
  }
}
