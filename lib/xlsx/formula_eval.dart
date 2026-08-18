/// A small, pure evaluator for the handful of formula shapes the Mileage
/// Report template actually uses (`SUM(range)`, `SUM(a*b)`, chains of
/// `+cell+cell...`) -- kept independent of any XML/archive plumbing so the
/// formula grammar has its own focused tests. See `raw_style_patch.dart`
/// (defect #5) for why a computed value gets cached at all: Excel's
/// Protected View never runs a calculation engine, so a formula cell with
/// no cached `<v>` renders as blank there even though `fullCalcOnLoad`
/// guarantees a correct live recalculation once editing is enabled.
///
/// [evaluateFormula] never throws. Any parse failure, unresolvable cell
/// reference, or construct outside the grammar below returns `null` --
/// the caller's contract is "leave this formula cell with no cached value,
/// exactly as before," never a crash that could block a real save.
///
/// Grammar (deliberately a little more general than the 12 shapes observed
/// in the real templates -- supporting `-`, `/`, and bare numeric literals
/// costs nothing and makes this robust to minor future template edits):
///   expr    := term (('+' | '-') term)*
///   term    := factor (('*' | '/') factor)*
///   factor  := NUMBER | CELLREF | 'SUM(' (RANGE | expr) ')' | '(' expr ')'
///   CELLREF := '$'? [A-Za-z]+ '$'? [0-9]+
///   RANGE   := CELLREF ':' CELLREF
library;

double? evaluateFormula(String formula, double? Function(String cellRef) resolveCell) {
  try {
    final tokens = _tokenize(formula.trim());
    if (tokens.isEmpty) return null;
    final parser = _FormulaParser(tokens, resolveCell);
    final result = parser.parseExpr();
    if (result == null) return null;
    if (parser.pos != tokens.length) return null;
    if (!result.isFinite) return null;
    return result;
  } catch (_) {
    return null;
  }
}

class _Token {
  final String type; // 'num' | 'ident' | 'sym'
  final String text;
  const _Token(this.type, this.text);
}

final _digitOrDot = RegExp(r'[0-9.]');
final _identStart = RegExp(r'[A-Za-z$]');
final _identBody = RegExp(r'[A-Za-z0-9$]');
final _cellRefPattern = RegExp(r'^\$?[A-Za-z]+\$?[0-9]+$');

List<_Token> _tokenize(String s) {
  final tokens = <_Token>[];
  var i = 0;
  while (i < s.length) {
    final ch = s[i];
    if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
      i++;
      continue;
    }
    if (_digitOrDot.hasMatch(ch)) {
      var j = i + 1;
      while (j < s.length && _digitOrDot.hasMatch(s[j])) {
        j++;
      }
      tokens.add(_Token('num', s.substring(i, j)));
      i = j;
      continue;
    }
    if (_identStart.hasMatch(ch)) {
      var j = i + 1;
      while (j < s.length && _identBody.hasMatch(s[j])) {
        j++;
      }
      tokens.add(_Token('ident', s.substring(i, j)));
      i = j;
      continue;
    }
    if ('()+-*/:,'.contains(ch)) {
      tokens.add(_Token('sym', ch));
      i++;
      continue;
    }
    throw FormatException('unexpected character in formula: $ch');
  }
  return tokens;
}

bool _isCellRef(String text) => _cellRefPattern.hasMatch(text);

String _normalizeCellRef(String text) => text.replaceAll(r'$', '').toUpperCase();

class _CellAddress {
  final int col;
  final int row;
  const _CellAddress(this.col, this.row);
}

int _columnLettersToNum(String letters) {
  var n = 0;
  for (final ch in letters.codeUnits) {
    n = n * 26 + (ch - 64);
  }
  return n;
}

String _numToColumnLetters(int col) {
  var n = col;
  var s = '';
  while (n > 0) {
    final rem = (n - 1) % 26;
    s = String.fromCharCode(65 + rem) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

_CellAddress? _parseCellAddress(String ref) {
  final normalized = _normalizeCellRef(ref);
  final m = RegExp(r'^([A-Z]+)([0-9]+)$').firstMatch(normalized);
  if (m == null) return null;
  return _CellAddress(_columnLettersToNum(m.group(1)!), int.parse(m.group(2)!));
}

class _FormulaParser {
  final List<_Token> tokens;
  final double? Function(String cellRef) resolveCell;
  int pos = 0;

  _FormulaParser(this.tokens, this.resolveCell);

  _Token? get _current => pos < tokens.length ? tokens[pos] : null;

  bool _atSym(String text) => _current != null && _current!.type == 'sym' && _current!.text == text;

  double? parseExpr() {
    var value = parseTerm();
    if (value == null) return null;
    while (_atSym('+') || _atSym('-')) {
      final op = _current!.text;
      pos++;
      final rhs = parseTerm();
      if (rhs == null) return null;
      value = op == '+' ? value! + rhs : value! - rhs;
    }
    return value;
  }

  double? parseTerm() {
    var value = parseUnary();
    if (value == null) return null;
    while (_atSym('*') || _atSym('/')) {
      final op = _current!.text;
      pos++;
      final rhs = parseUnary();
      if (rhs == null) return null;
      if (op == '/') {
        if (rhs == 0) return null;
        value = value! / rhs;
      } else {
        value = value! * rhs;
      }
    }
    return value;
  }

  // A leading unary +/- (e.g. Excel's legacy Lotus-1-2-3-style "+H8+G8+..."
  // convention, still common and accepted today) isn't a binary operator,
  // so it has to be handled before falling into parseFactor -- allowed
  // anywhere a factor is expected (top of an expr, inside SUM(...), inside
  // parens), not just at the very start of the formula.
  double? parseUnary() {
    if (_atSym('+') || _atSym('-')) {
      final negate = _current!.text == '-';
      pos++;
      final v = parseUnary();
      if (v == null) return null;
      return negate ? -v : v;
    }
    return parseFactor();
  }

  double? parseFactor() {
    final tok = _current;
    if (tok == null) return null;

    if (tok.type == 'num') {
      pos++;
      return double.tryParse(tok.text);
    }

    if (tok.type == 'sym' && tok.text == '(') {
      pos++;
      final v = parseExpr();
      if (v == null) return null;
      if (!_atSym(')')) return null;
      pos++;
      return v;
    }

    if (tok.type == 'ident') {
      if (tok.text.toUpperCase() == 'SUM' && pos + 1 < tokens.length && tokens[pos + 1].text == '(') {
        return _parseSumCall();
      }
      if (!_isCellRef(tok.text)) return null;
      pos++;
      return resolveCell(_normalizeCellRef(tok.text));
    }

    return null;
  }

  double? _parseSumCall() {
    pos += 2; // consume 'SUM' and '('
    final saved = pos;

    if (_current != null && _current!.type == 'ident' && _isCellRef(_current!.text)) {
      final startRef = _current!.text;
      final afterFirst = pos + 1;
      if (afterFirst < tokens.length && tokens[afterFirst].type == 'sym' && tokens[afterFirst].text == ':') {
        final afterColon = afterFirst + 1;
        if (afterColon < tokens.length &&
            tokens[afterColon].type == 'ident' &&
            _isCellRef(tokens[afterColon].text)) {
          final endRef = tokens[afterColon].text;
          final afterEnd = afterColon + 1;
          if (afterEnd < tokens.length && tokens[afterEnd].type == 'sym' && tokens[afterEnd].text == ')') {
            pos = afterEnd + 1;
            return _sumRange(startRef, endRef);
          }
        }
      }
    }

    pos = saved;
    final v = parseExpr();
    if (v == null) return null;
    if (!_atSym(')')) return null;
    pos++;
    return v;
  }

  double? _sumRange(String startRef, String endRef) {
    final start = _parseCellAddress(startRef);
    final end = _parseCellAddress(endRef);
    if (start == null || end == null) return null;
    var total = 0.0;
    for (var col = start.col; col <= end.col; col++) {
      for (var row = start.row; row <= end.row; row++) {
        final ref = '${_numToColumnLetters(col)}$row';
        final v = resolveCell(ref);
        if (v == null) return null;
        total += v;
      }
    }
    return total;
  }
}
