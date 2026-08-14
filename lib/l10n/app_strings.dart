import 'package:flutter/widgets.dart';

import '../services/safe_xlsx_write.dart';
import 'locale_controller.dart';

/// Lightweight EN/RU string table (section 11): English is the default,
/// Russian is a Settings toggle -- not tied to the device locale.
///
/// Proper nouns that must match the actual xlsx file/sheet names the user
/// will see when they open the workbook in Excel -- "Mileage Report",
/// "Timesheet", "Driving Details", "GST", and the app name "ExpenseFlow" --
/// are deliberately left untranslated in both languages, so the in-app
/// screen names always match what's printed in the spreadsheet.
const Map<String, Map<String, String>> _strings = {
  'common.save': {'en': 'Save', 'ru': 'Сохранить'},
  'common.ok': {'en': 'OK', 'ru': 'ОК'},
  'common.edit': {'en': 'Edit', 'ru': 'Редактировать'},

  // Save-progress phases (a period-file save commonly takes several
  // seconds, dominated by the xlsx library's own decode/encode cost --
  // shown so it doesn't read as a freeze).
  'save.phaseReading': {'en': 'Reading file…', 'ru': 'Чтение файла…'},
  'save.phaseWriting': {'en': 'Writing…', 'ru': 'Запись…'},
  'save.phaseVerifying': {'en': 'Verifying…', 'ru': 'Проверка…'},

  'home.currentPeriod': {'en': 'Current period', 'ru': 'Текущий период'},
  'home.due': {'en': 'Due:', 'ru': 'Срок сдачи:'},
  'home.weekendDue': {'en': 'Weekend due:', 'ru': 'Срок (выходные):'},
  'home.addReceipt': {'en': 'Add receipt', 'ru': 'Добавить чек'},
  'home.drivingDetails': {'en': 'Driving Details', 'ru': 'Driving Details'},
  'home.timesheet': {'en': 'Timesheet', 'ru': 'Timesheet'},
  'home.shareSave': {'en': 'Share / Save', 'ru': 'Поделиться / Сохранить'},
  'home.pastPeriods': {'en': 'Past periods', 'ru': 'Прошлые периоды'},
  'home.settings': {'en': 'Settings', 'ru': 'Настройки'},
  'home.lowPeriodsReminder': {
    'en': 'Only a few payroll periods left in the schedule. Add more soon in Settings.',
    'ru': 'Осталось мало периодов в расписании. Скоро добавьте новые в Настройках.',
  },
  'home.errorPrefix': {'en': 'Error:', 'ru': 'Ошибка:'},

  'addPeriod.titleEdit': {'en': 'Edit period', 'ru': 'Изменить период'},
  'addPeriod.titleAdd': {'en': 'Add period', 'ru': 'Добавить период'},
  'addPeriod.blockingBanner': {
    'en': "Today's date is past the last known payroll period. Add the next period to continue.",
    'ru': 'Сегодняшняя дата выходит за пределы последнего известного периода. Добавьте следующий период, чтобы продолжить.',
  },
  'addPeriod.periodStart': {'en': 'Period start', 'ru': 'Начало периода'},
  'addPeriod.periodEnd': {'en': 'Period end', 'ru': 'Конец периода'},
  'addPeriod.dueDate': {'en': 'Due date', 'ru': 'Дата сдачи'},
  'addPeriod.dueTime': {'en': 'Due time', 'ru': 'Время сдачи'},
  'addPeriod.weekendToggle': {
    'en': 'Separate due date for working weekends',
    'ru': 'Отдельный срок для рабочих выходных',
  },
  'addPeriod.weekendDueDate': {'en': 'Weekend due date', 'ru': 'Дата сдачи (выходные)'},
  'addPeriod.weekendDueTime': {'en': 'Weekend due time', 'ru': 'Время сдачи (выходные)'},
  'addPeriod.statHolidays': {'en': 'STAT holidays', 'ru': 'STAT-праздники'},
  'addPeriod.name': {'en': 'Name', 'ru': 'Название'},
  'addPeriod.pickDate': {'en': 'Pick date', 'ru': 'Выбрать дату'},
  'addPeriod.errorEndBeforeStart': {
    'en': 'End date must be after start date.',
    'ru': 'Дата окончания должна быть позже даты начала.',
  },
  'addPeriod.errorDueOutOfRange': {
    'en': 'Due date must fall within the period.',
    'ru': 'Дата сдачи должна быть в пределах периода.',
  },
  'addPeriod.errorStatIncomplete': {
    'en': 'Each STAT holiday needs a name and a date.',
    'ru': 'У каждого STAT-праздника должны быть название и дата.',
  },
  'addPeriod.errorStatOutOfRange': {
    'en': 'STAT holiday "{name}" must fall within the period.',
    'ru': 'STAT-праздник «{name}» должен попадать в период.',
  },

  'addReceipt.title': {'en': 'Add receipt', 'ru': 'Добавить чек'},
  'addReceipt.camera': {'en': 'Camera', 'ru': 'Камера'},
  'addReceipt.gallery': {'en': 'Photo from gallery', 'ru': 'Фото из галереи'},
  'addReceipt.manual': {'en': 'Enter manually', 'ru': 'Ввести вручную'},
  'addReceipt.date': {'en': 'Date', 'ru': 'Дата'},
  'addReceipt.subtotal': {'en': 'Subtotal', 'ru': 'Сумма без налога'},
  'addReceipt.gst': {'en': 'GST', 'ru': 'GST'},
  'addReceipt.description': {'en': 'Description', 'ru': 'Описание'},
  'addReceipt.gstWarning': {
    'en': 'GST looks unusually far from 5% of Subtotal -- double check it.',
    'ru': 'GST заметно отличается от 5% суммы — проверьте значение.',
  },
  'addReceipt.noRoomTitle': {'en': 'No room left', 'ru': 'Нет свободных строк'},
  'addReceipt.noRoomContent': {
    'en': "This period's Mileage Report is full. Please add the remaining receipts directly in Excel.",
    'ru': 'Mileage Report для этого периода заполнен. Добавьте оставшиеся чеки прямо в Excel.',
  },
  'addReceipt.ocrError': {'en': 'Could not read the photo: {error}', 'ru': 'Не удалось распознать фото: {error}'},
  'addReceipt.saveError': {'en': 'Could not save: {error}', 'ru': 'Не удалось сохранить: {error}'},

  'drivingDetails.title': {'en': 'Driving Details', 'ru': 'Driving Details'},
  'drivingDetails.trip': {'en': 'Trip', 'ru': 'Маршрут'},
  'drivingDetails.km': {'en': 'KM', 'ru': 'Км'},
  'drivingDetails.invalidKm': {'en': 'Enter a valid KM value.', 'ru': 'Введите корректное значение км.'},
  'drivingDetails.noRoomContent': {
    'en': 'Driving Details is full for this period. Please add further trips directly in Excel.',
    'ru': 'Driving Details заполнен для этого периода. Добавьте новые поездки прямо в Excel.',
  },
  'drivingDetails.saveError': {'en': 'Could not save: {error}', 'ru': 'Не удалось сохранить: {error}'},

  'timesheet.title': {'en': 'Timesheet', 'ru': 'Timesheet'},
  'timesheet.totalHrs': {'en': 'Total Hrs.', 'ru': 'Итого часов'},
  'timesheet.statHoliday': {'en': 'STAT holiday', 'ru': 'STAT-праздник'},
  'timesheet.weekend': {'en': 'Weekend', 'ru': 'Выходной'},
  'timesheet.startTime': {'en': 'Start Time', 'ru': 'Начало смены'},
  'timesheet.lunchBreak': {'en': 'Lunch Break', 'ru': 'Обеденный перерыв'},
  'timesheet.coffeeBreak': {'en': 'Coffee Break', 'ru': 'Кофе-брейк'},
  'timesheet.finishTime': {'en': 'Finish Time', 'ru': 'Конец смены'},
  'timesheet.hours': {'en': 'Hours', 'ru': 'Часы'},

  'settings.title': {'en': 'Settings', 'ru': 'Настройки'},
  'settings.language': {'en': 'Language', 'ru': 'Язык'},
  'settings.english': {'en': 'English', 'ru': 'English'},
  'settings.russian': {'en': 'Русский', 'ru': 'Русский'},
  'settings.employeeName': {'en': 'Employee name', 'ru': 'Имя сотрудника'},
  'settings.firstName': {'en': 'First name', 'ru': 'Имя'},
  'settings.lastName': {'en': 'Last name', 'ru': 'Фамилия'},
  'settings.phone': {'en': 'Phone', 'ru': 'Телефон'},
  'settings.retentionTitle': {'en': 'Keep previous Excel files', 'ru': 'Хранение предыдущих Excel-файлов'},
  'settings.retentionNever': {'en': 'Never keep', 'ru': 'Никогда не хранить'},
  'settings.retentionOneMonth': {'en': 'Keep last month', 'ru': 'Хранить последний месяц'},
  'settings.retentionThreeMonths': {'en': 'Keep last 3 months', 'ru': 'Хранить 3 месяца'},
  'settings.retentionSixMonths': {'en': 'Keep last 6 months', 'ru': 'Хранить 6 месяцев'},
  'settings.retentionOneYear': {'en': 'Keep last year', 'ru': 'Хранить последний год'},
  'settings.saved': {'en': 'Settings saved', 'ru': 'Настройки сохранены'},
  'settings.addNextPeriod': {'en': 'Add next payroll period', 'ru': 'Добавить следующий период'},

  'shareSave.title': {'en': 'Share / Save', 'ru': 'Поделиться / Сохранить'},
  'shareSave.mileageReport': {'en': 'Mileage Report', 'ru': 'Mileage Report'},
  'shareSave.timesheet': {'en': 'Timesheet', 'ru': 'Timesheet'},
  'shareSave.bothFiles': {'en': 'Both files', 'ru': 'Оба файла'},
  'shareSave.share': {'en': 'Share', 'ru': 'Поделиться'},
  'shareSave.saveToDevice': {'en': 'Save to device', 'ru': 'Сохранить на устройство'},
  'shareSave.saved': {'en': 'Saved', 'ru': 'Сохранено'},
  'shareSave.shareError': {'en': 'Could not share: {error}', 'ru': 'Не удалось поделиться: {error}'},
  'shareSave.saveError': {'en': 'Could not save: {error}', 'ru': 'Не удалось сохранить: {error}'},

  'archive.title': {'en': 'Past periods', 'ru': 'Прошлые периоды'},
  'archive.empty': {
    'en': 'No past periods on this device yet.',
    'ru': 'На этом устройстве пока нет прошлых периодов.',
  },
};

/// Looks up [key] in the current language (from the nearest [AppLocale]),
/// falling back to English, then to the key itself if truly missing.
/// Pass [params] to substitute `{name}`-style placeholders.
String t(BuildContext context, String key, [Map<String, String>? params]) {
  final languageCode = AppLocale.of(context).languageCode;
  final entry = _strings[key];
  var value = entry?[languageCode] ?? entry?['en'] ?? key;
  if (params != null) {
    for (final e in params.entries) {
      value = value.replaceAll('{${e.key}}', e.value);
    }
  }
  return value;
}

/// Localized label for the current phase of a period-file save (see
/// [SaveXlsxPhase]); null shows nothing (used before a save has started).
String? saveXlsxPhaseLabel(BuildContext context, SaveXlsxPhase? phase) {
  return switch (phase) {
    null => null,
    SaveXlsxPhase.reading => t(context, 'save.phaseReading'),
    SaveXlsxPhase.writing => t(context, 'save.phaseWriting'),
    SaveXlsxPhase.verifying => t(context, 'save.phaseVerifying'),
  };
}
