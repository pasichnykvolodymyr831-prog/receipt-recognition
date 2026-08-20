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
  'common.cancel': {'en': 'Cancel', 'ru': 'Отмена'},
  'common.confirm': {'en': 'Confirm', 'ru': 'Подтвердить'},

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
  'home.receiptList': {'en': 'Receipts', 'ru': 'Чеки'},
  'home.drivingDetails': {'en': 'Driving Details', 'ru': 'Driving Details'},
  'home.tripList': {'en': 'Trips', 'ru': 'Поездки'},
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
  'addPeriod.saveError': {'en': 'Could not save: {error}', 'ru': 'Не удалось сохранить: {error}'},
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
  'addPeriod.errorStatDuplicate': {
    'en': 'Two STAT holidays have the same date -- check for a typo.',
    'ru': 'Два STAT-праздника указаны на одну и ту же дату — проверьте, нет ли опечатки.',
  },
  'addPeriod.errorLength': {
    'en': 'Period length looks off (must be 7-40 days) -- check the dates.',
    'ru': 'Длина периода выглядит неправильной (должна быть 7–40 дней) — проверьте даты.',
  },
  'addPeriod.errorOverlap': {
    'en': 'This period overlaps an existing one -- check the dates.',
    'ru': 'Этот период пересекается с уже существующим — проверьте даты.',
  },
  'addPeriod.kmRate': {'en': r'Rate ($/km)', 'ru': r'Ставка ($/км)'},
  'addPeriod.kmRateLabel': {'en': 'Rate (optional)', 'ru': 'Ставка (необязательно)'},
  'addPeriod.kmRateHint': {
    'en': 'Leave blank to use the Settings default',
    'ru': 'Оставьте пустым, чтобы использовать умолчание из Настроек',
  },
  'addPeriod.errorKmRate': {
    'en': 'Rate must be greater than zero, or left blank.',
    'ru': 'Ставка должна быть больше нуля либо оставлена пустой.',
  },
  // Пакет 5 of whimsical-booping-salamander.md: a "9-23" period's own rate
  // is never used for Mileage (MileageCycle.kmRate reads only the opening
  // "24-8" half) -- the field is disabled, not hidden, with this caption.
  'addPeriod.kmRateNotUsedForThisPeriod': {
    'en': "This period's own rate isn't used -- the Mileage cycle uses the opening period's rate.",
    'ru': 'Ставка этого периода не используется — Mileage-цикл берёт ставку открывающего периода.',
  },
  // Shown for a "24-8" period whose cycle's Mileage file already exists --
  // its G1 is filled and permanently authoritative, so editing the rate
  // here only takes effect for the NEXT cycle, never this already-started
  // file (section 6.2's retroactive-rate-change path was removed).
  'addPeriod.kmRateAppliesNextCycle': {
    'en': "This cycle's Mileage file already exists -- a rate change here applies starting with the next cycle.",
    'ru': 'Mileage-файл этого цикла уже существует — изменение ставки здесь вступит в силу со следующего цикла.',
  },

  'addReceipt.title': {'en': 'Add receipt', 'ru': 'Добавить чек'},
  'addReceipt.editTitle': {'en': 'Edit receipt', 'ru': 'Редактировать чек'},
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
  'addReceipt.dateRequired': {'en': 'Date is required.', 'ru': 'Укажите дату.'},
  'addReceipt.subtotalRequired': {'en': 'Subtotal is required.', 'ru': 'Укажите сумму без налога.'},
  'addReceipt.gstRequired': {'en': 'GST is required.', 'ru': 'Укажите GST.'},
  'addReceipt.noRoomContent': {
    'en': "This period's Mileage Report is full. Please add the remaining receipts directly in Excel.",
    'ru': 'Mileage Report для этого периода заполнен. Добавьте оставшиеся чеки прямо в Excel.',
  },
  'addReceipt.ocrError': {'en': 'Could not read the photo: {error}', 'ru': 'Не удалось распознать фото: {error}'},
  'addReceipt.saveError': {'en': 'Could not save: {error}', 'ru': 'Не удалось сохранить: {error}'},

  'drivingDetails.title': {'en': 'Driving Details', 'ru': 'Driving Details'},
  'drivingDetails.editTitle': {'en': 'Edit trip', 'ru': 'Редактировать поездку'},
  'drivingDetails.trip': {'en': 'Trip', 'ru': 'Маршрут'},
  'drivingDetails.km': {'en': 'KM', 'ru': 'Км'},
  'drivingDetails.invalidKm': {'en': 'Enter a valid KM value.', 'ru': 'Введите корректное значение км.'},
  'drivingDetails.tripRequired': {'en': 'Trip is required.', 'ru': 'Укажите маршрут.'},
  'drivingDetails.kmMustBePositive': {
    'en': 'KM must be greater than zero.',
    'ru': 'Километраж должен быть больше нуля.',
  },
  'drivingDetails.noRoomContent': {
    'en': 'Driving Details is full for this period. Please add further trips directly in Excel.',
    'ru': 'Driving Details заполнен для этого периода. Добавьте новые поездки прямо в Excel.',
  },
  'drivingDetails.saveError': {'en': 'Could not save: {error}', 'ru': 'Не удалось сохранить: {error}'},

  'timesheet.title': {'en': 'Timesheet', 'ru': 'Timesheet'},
  'timesheet.saveError': {'en': 'Could not save: {error}', 'ru': 'Не удалось сохранить: {error}'},
  'timesheet.totalHrs': {'en': 'Total Hrs.', 'ru': 'Итого часов'},
  'timesheet.statHoliday': {'en': 'STAT holiday', 'ru': 'STAT-праздник'},
  'timesheet.weekend': {'en': 'Weekend', 'ru': 'Выходной'},
  'timesheet.startTime': {'en': 'Start Time', 'ru': 'Начало смены'},
  'timesheet.lunchBreak': {'en': 'Lunch Break', 'ru': 'Обеденный перерыв'},
  'timesheet.coffeeBreak': {'en': 'Coffee Break', 'ru': 'Кофе-брейк'},
  'timesheet.finishTime': {'en': 'Finish Time', 'ru': 'Конец смены'},
  'timesheet.hours': {'en': 'Hours', 'ru': 'Часы'},
  'timesheet.clearDay': {'en': 'Clear day', 'ru': 'Очистить день'},
  'timesheet.errorNonPositiveHours': {
    'en': 'Hours worked can\'t be zero or negative -- check Start, Finish, and the breaks.',
    'ru': 'Часы за день не могут быть нулевыми или отрицательными — проверьте начало, конец смены и перерывы.',
  },
  'timesheet.errorMidnightCrossing': {
    'en': 'A shift crossing midnight isn\'t supported in one row. Split it into two entries: one ending before midnight, one starting after.',
    'ru': 'Смена через полночь не поддерживается одной строкой. Разбейте её на две записи: одна до полуночи, другая после.',
  },

  'settings.title': {'en': 'Settings', 'ru': 'Настройки'},
  'settings.language': {'en': 'Language', 'ru': 'Язык'},
  'settings.english': {'en': 'English', 'ru': 'English'},
  'settings.russian': {'en': 'Русский', 'ru': 'Русский'},
  'settings.employeeName': {'en': 'Employee name', 'ru': 'Имя сотрудника'},
  'settings.firstName': {'en': 'First name', 'ru': 'Имя'},
  'settings.lastName': {'en': 'Last name', 'ru': 'Фамилия'},
  'settings.phone': {'en': 'Phone', 'ru': 'Телефон'},
  'settings.kmRateTitle': {'en': r'Rate ($/km)', 'ru': r'Ставка ($/км)'},
  'settings.kmRateLabel': {'en': 'Rate', 'ru': 'Ставка'},
  'settings.kmRateRequired': {'en': 'Rate is required.', 'ru': 'Укажите ставку.'},
  'settings.kmRateMustBePositive': {
    'en': 'Rate must be greater than zero.',
    'ru': 'Ставка должна быть больше нуля.',
  },
  // Пакет 5 of whimsical-booping-salamander.md: a changed Settings default
  // rate is never written into an already-created Mileage cycle file (its
  // G1 is permanently authoritative once filled) -- only a not-yet-created
  // cycle picks it up, at creation time.
  'settings.kmRateAppliesNextCycle': {
    'en': ' The new rate applies starting with the next Mileage cycle -- an already-started file is never changed retroactively.',
    'ru': ' Новая ставка вступит в силу со следующего Mileage-цикла — уже начатый файл задним числом не меняется.',
  },
  'settings.retentionTitle': {'en': 'Keep previous Excel files', 'ru': 'Хранение предыдущих Excel-файлов'},
  'settings.retentionNever': {'en': 'Never keep', 'ru': 'Никогда не хранить'},
  'settings.retentionOneMonth': {'en': 'Keep last month', 'ru': 'Хранить последний месяц'},
  'settings.retentionThreeMonths': {'en': 'Keep last 3 months', 'ru': 'Хранить 3 месяца'},
  'settings.retentionSixMonths': {'en': 'Keep last 6 months', 'ru': 'Хранить 6 месяцев'},
  'settings.retentionOneYear': {'en': 'Keep last year', 'ru': 'Хранить последний год'},
  'settings.retentionConfirmTitle': {'en': 'Change retention?', 'ru': 'Изменить хранение?'},
  'settings.retentionConfirmCount': {
    'en': 'This will delete the files of {count} past period(s) that fall outside the new window.',
    'ru': 'Это удалит файлы {count} прошлых периодов, не попадающих в новое окно хранения.',
  },
  'settings.retentionConfirmAll': {
    'en': 'This will delete the files of every past period -- the archive will be fully cleared.',
    'ru': 'Это удалит файлы всех прошлых периодов -- архив будет полностью очищен.',
  },
  'settings.saved': {'en': 'Settings saved', 'ru': 'Настройки сохранены'},
  'settings.saveError': {'en': 'Could not save: {error}', 'ru': 'Не удалось сохранить: {error}'},
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

  // Shared between add_receipt_screen.dart and driving_details_screen.dart
  // (Пакет 38, audit 2026-08-18): both hit the identical "row 8-27 range is
  // full" condition on the same underlying Mileage Report file, previously
  // driving_details_screen.dart borrowed 'addReceipt.noRoomTitle' for this
  // dialog's title while using its own key for the body -- a neutral
  // shared key for the (identical) title is more honest than that mix.
  'mileageReport.noRoomTitle': {'en': 'No room left', 'ru': 'Нет свободных строк'},

  'archive.title': {'en': 'Past periods', 'ru': 'Прошлые периоды'},
  'archive.empty': {
    'en': 'No past periods on this device yet.',
    'ru': 'На этом устройстве пока нет прошлых периодов.',
  },

  // Shared between period_archive_screen.dart's PeriodDetailScreen and
  // share_save_screen.dart -- both need the exact same explanation for the
  // exact same situation (Пакет 10, code-review 2026-08-19: previously two
  // separately-maintained keys with byte-identical text, a drift risk).
  'period.filesUnavailableMessage': {
    'en': "This period's Excel files are no longer on this device, per your "
        'file retention setting in Settings.',
    'ru': 'Excel-файлов этого периода больше нет на устройстве -- согласно '
        'настройке хранения файлов в Настройках.',
  },
  'periodActions.filesUnavailable': {
    'en': 'Files not available for this period',
    'ru': 'Файлы этого периода недоступны',
  },

  // Accounting accepts Mileage Report only every 4 weeks, as one file
  // covering two consecutive periods (a "Mileage cycle") -- distinct from
  // period.filesUnavailableMessage above, which is about retention having
  // deleted files that DID exist; this is about the cycle simply not being
  // complete yet (no such file could exist), so the two must never be
  // conflated into one message (whimsical-booping-salamander.md, Пакет 3).
  'mileageCycle.notReadyMessage': {
    'en': 'This period is not yet paired with its Mileage cycle partner. '
        'Add the next payroll period to enable Mileage Report entry here.',
    'ru': 'Этот период ещё не объединён в пару со своим партнёром по Mileage-циклу. '
        'Добавьте следующий период, чтобы включить ввод в Mileage Report здесь.',
  },

  'receiptList.title': {'en': 'Receipts', 'ru': 'Чеки'},
  'receiptList.empty': {'en': 'No receipts yet.', 'ru': 'Чеков пока нет.'},
  'receiptList.noDescription': {'en': '(no description)', 'ru': '(без описания)'},

  'tripList.title': {'en': 'Trips', 'ru': 'Поездки'},
  'tripList.empty': {'en': 'No trips yet.', 'ru': 'Поездок пока нет.'},

  // NotificationService has no BuildContext to read AppLocale from -- it
  // calls [tForLanguage] directly with the Settings language instead
  // (whimsical-booping-salamander.md, Пакет 6). The body text splits on
  // whether the reminder's period is a "24-8" cycle-opening half (Mileage
  // Report isn't due yet for it specifically -- accounting only accepts it
  // every 4 weeks, see MileageCycle) or a "9-23" closing half (its own due
  // date IS the whole cycle's due, MileageCycle.due reads secondHalf.due).
  'notification.dueReminderTimesheetOnly': {
    'en': 'Timesheet is due soon.',
    'ru': 'Скоро срок сдачи Timesheet.',
  },
  'notification.dueReminderBoth': {
    'en': 'Mileage Report and Timesheet are due soon.',
    'ru': 'Скоро срок сдачи Mileage Report и Timesheet.',
  },
};

/// Looks up [key] in [languageCode], falling back to English, then to the
/// key itself if truly missing. The context-free half of [t] -- for the
/// rare caller (like [NotificationService]) that can't reach a
/// [BuildContext]/[AppLocale] at all.
String tForLanguage(String languageCode, String key, [Map<String, String>? params]) {
  final entry = _strings[key];
  var value = entry?[languageCode] ?? entry?['en'] ?? key;
  if (params != null) {
    for (final e in params.entries) {
      value = value.replaceAll('{${e.key}}', e.value);
    }
  }
  return value;
}

/// Looks up [key] in the current language (from the nearest [AppLocale]),
/// falling back to English, then to the key itself if truly missing.
/// Pass [params] to substitute `{name}`-style placeholders.
String t(BuildContext context, String key, [Map<String, String>? params]) {
  return tForLanguage(AppLocale.of(context).languageCode, key, params);
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
