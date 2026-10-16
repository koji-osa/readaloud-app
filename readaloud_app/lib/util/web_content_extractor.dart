// Web HTML -> reading text extraction: frozen S1 + N2 (RA-WEB-IMP01).
//
// This is a faithful port of the frozen RA-WEB prototypes; it is NOT a place for
// tuning. Any behaviour change needs a new research card. Where the N2 prose and
// the prototype differ, the hash-pinned prototype behaviour is authoritative.
//
//   S1  = light.dart            SHA-256 1faa3ee04e19b143b37344d5ee44542b79657437f3849c7bf30b8f3c9711715f
//   N2  = N2_SPEC_v1.md         SHA-256 03797acd743c26b997a7a2200f087cb329d30549b2995810447c85a5223156c2
//         (n2.dart prototype)   SHA-256 b51e7c76d444cac7c752ce6be4ad2490955968ca05fadbc9414f3871b327dda1
//
// Contract in one paragraph:
//  * S1: root = first <article>, else first <main>, else <body>; walk it with a
//    fixed drop set (script/style/nav/header/footer/aside/form/... and hidden
//    subtrees), keep block boundaries and h1..h6 as "# " lines, clean whitespace.
//  * N2-A (root repair): the root may only be replaced when nonLink(r0) < 40,
//    where r0 is the S1 root. That includes an r0 that holds only link text or a
//    handful of characters. Candidates in order: an <article> (other than r0)
//    containing the validated title h1 with nonLink >= 40, the first <main>,
//    <body>. An <article> is never chosen by size or position alone.
//  * N2-B (title repair): a unique <h1> that equals og:title / <title> (exact, or
//    exact to the strictly longest segment) is re-inserted once as "# <h1 text>"
//    at the top when S1 lost it. Metadata text itself is never inserted.
//
// Pure function of the HTML: no network, no state, no DB/UI/player dependency.
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// Result of [extractWebContent]. [text] is the reading text; the other fields
/// are diagnostics only (never used by the algorithm).
class WebContentExtraction {
  const WebContentExtraction({
    required this.text,
    required this.rootAction,
    required this.titleAction,
    this.titleRule = '',
    this.r0Tag,
    this.r0NonLink,
  });

  final String text;

  /// identity | article_T | main | body | rejected_all | no_root
  final String rootAction;

  /// insert | none:no_match | none:ambiguous | none:outside_root |
  /// none:present | none:empty_body
  final String titleAction;

  /// M1 | M2 | '' (rule that validated the title heading)
  final String titleRule;

  final String? r0Tag;
  final int? r0NonLink;
}

/// Extracts the reading text from an HTML string (S1 + N2).
WebContentExtraction extractWebContent(String html) =>
    extractWebContentFromDocument(html_parser.parse(html));

/// Same as [extractWebContent] for an already parsed [Document]. The document is
/// not modified.
WebContentExtraction extractWebContentFromDocument(Document d) {
  final r0 = _s1DefaultRoot(d);
  if (r0 == null) {
    return const WebContentExtraction(
        text: '', rootAction: 'no_root', titleAction: 'none:no_match');
  }
  final th = _titleHeadings(d);
  final r0NonLink = _nonLink(r0);

  // ---- N2-A: root repair (only when r0 has (almost) no text of its own) ----
  var root = r0;
  var rootAction = 'identity';
  if (r0NonLink < _nearEmpty) {
    Element? pick;
    var act = 'rejected_all';
    for (final a in d.querySelectorAll('article')) {
      if (!identical(a, r0) &&
          th.hs.any((h) => _within(a, h)) &&
          _nonLink(a) >= _nearEmpty) {
        pick = a;
        act = 'article_T';
        break;
      }
    }
    if (pick == null) {
      final m = d.querySelector('main');
      if (m != null && !identical(m, r0) && _nonLink(m) >= _nearEmpty) {
        pick = m;
        act = 'main';
      }
    }
    if (pick == null) {
      final b = d.querySelector('body');
      if (b != null && !identical(b, r0) && _nonLink(b) >= _nearEmpty) {
        pick = b;
        act = 'body';
      }
    }
    if (pick != null) root = pick;
    rootAction = act;
  }

  // ---- S1 walk of the final root ----
  var w = _s1WalkClean(root);

  // ---- N2-B: title repair ----
  var titleAction = 'none:${th.why.isEmpty ? 'x' : th.why}';
  if (th.why.isEmpty && _ns(w) < _nearEmpty) {
    titleAction = 'none:empty_body';
  } else if (th.why.isEmpty) {
    final inRoot = th.hs.where((h) => _within(root, h)).toList();
    if (inRoot.isEmpty) {
      titleAction = 'none:outside_root';
    } else {
      final tt = _headingText(inRoot.first);
      final tk = _tn(tt);
      final lines = w
          .split('\n')
          .map((x) => x.trim())
          .where((x) => x.isNotEmpty)
          .toList();
      String bare(String x) => x.startsWith('# ') ? x.substring(2) : x;
      final present = lines.any((x) => x.startsWith('# ') && _tn(bare(x)) == tk) ||
          lines.take(_dupWindow).any((x) {
            final k = _tn(bare(x));
            return k.contains(tk) && k.runes.length <= 2 * tk.runes.length;
          });
      if (present) {
        titleAction = 'none:present';
      } else {
        w = _s1Clean('# $tt\n\n$w');
        titleAction = 'insert';
      }
    }
  }

  return WebContentExtraction(
    text: w,
    rootAction: rootAction,
    titleAction: titleAction,
    titleRule: th.rule,
    r0Tag: r0.localName,
    r0NonLink: r0NonLink,
  );
}

// ---------------------------------------------------------------------------
// N2 constants (declared in the frozen spec, never tuned)
// ---------------------------------------------------------------------------
const int _nearEmpty = 40; // non-link, non-whitespace chars
const int _minT = 4; // runes of a normalized title heading
const int _dupWindow = 10; // non-empty lines

// ---------------------------------------------------------------------------
// S1 (frozen)
// ---------------------------------------------------------------------------
const _s1Drop = {
  'script', 'style', 'noscript', 'template', 'svg', 'iframe', 'canvas', 'form',
  'button', 'select', 'input', 'textarea', 'nav', 'header', 'footer', 'aside',
  'dialog', 'video', 'audio', 'picture', 'head',
};
const _block = {
  'p', 'div', 'section', 'article', 'main', 'ul', 'ol', 'li', 'dl', 'dt', 'dd',
  'blockquote', 'pre', 'table', 'tr', 'figure', 'figcaption', 'br', 'hr',
  'details', 'summary', 'address', 'caption',
};
const _heading = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};

bool _hidden(Element e) {
  final a = e.attributes;
  if (a.containsKey('hidden') || a['aria-hidden'] == 'true') return true;
  final st = (a['style'] ?? '').replaceAll(' ', '').toLowerCase();
  return st.contains('display:none');
}

void _walk(Node n, StringBuffer b, bool inPre) {
  if (n is Text) {
    b.write(inPre ? n.text : n.text.replaceAll(RegExp(r'[\s ]+'), ' '));
    return;
  }
  if (n is! Element) return;
  final t = n.localName ?? '';
  if (_s1Drop.contains(t) || _hidden(n)) return;
  if (_heading.contains(t)) {
    b.write('\n\n# ');
    for (final c in n.nodes) {
      _walk(c, b, false);
    }
    b.write('\n\n');
    return;
  }
  if (t == 'li') {
    b.write('\n- ');
  } else if (t == 'td' || t == 'th') {
    b.write(' ');
  } else if (_block.contains(t)) {
    b.write('\n');
  }
  for (final c in n.nodes) {
    _walk(c, b, inPre || t == 'pre');
  }
  if (_block.contains(t) && t != 'li') b.write('\n');
}

String _s1Clean(String s) => s
    .replaceAll(RegExp(r'[ \t]*\n[ \t]*'), '\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .replaceAll(RegExp(r' {2,}'), ' ')
    .trim();

String _s1WalkClean(Element target) {
  final b = StringBuffer();
  _walk(target, b, false);
  return _s1Clean(b.toString());
}

Element? _s1DefaultRoot(Document doc) =>
    doc.querySelector('article') ??
    doc.querySelector('main') ??
    doc.querySelector('body');

/// Text of a heading as S1 would emit it (children walked with S1 rules),
/// whitespace collapsed.
String _headingText(Element h) {
  final b = StringBuffer();
  for (final c in h.nodes) {
    _walk(c, b, false);
  }
  return b.toString().replaceAll(RegExp(r'[\s 　]+'), ' ').trim();
}

// ---------------------------------------------------------------------------
// N2 (frozen)
// ---------------------------------------------------------------------------
const _zone = {
  'nav', 'aside', 'footer', 'dialog', 'form', 'template', 'noscript', 'svg',
  'head', 'iframe', 'canvas', 'script', 'style',
};

// Whitespace for counting / normalization: \s + NBSP, U+3000, U+FEFF, U+2000-200A.
final _ws = RegExp(r'[\s 　﻿ - ]');

// Title-segment separators: dash with surrounding spaces, | ｜ • » « ：, or ": ".
// (Prototype behaviour is authoritative: the second branch tolerates no spaces.)
final _sep = RegExp(
    r'\s+[-–—―－]\s+|\s*[|｜•»«：]\s*|:\s+');

int _ns(String s) => s.replaceAll(_ws, '').length;

/// Non-whitespace chars of text nodes under [n], skipping S1-dropped / hidden
/// subtrees and text under <a>.
int _nonLink(Node n, [bool inA = false]) {
  if (n is Text) return inA ? 0 : _ns(n.text);
  if (n is! Element) return 0;
  final t = n.localName ?? '';
  if (_s1Drop.contains(t) || _hidden(n)) return 0;
  var c = 0;
  for (final k in n.nodes) {
    c += _nonLink(k, inA || t == 'a');
  }
  return c;
}

/// Title normalization: lowercase, fold full-width ASCII, delete whitespace and
/// punctuation/symbols.
String _tn(String s) {
  final o = StringBuffer();
  for (var r in s.toLowerCase().runes) {
    if (r >= 0xFF01 && r <= 0xFF5E) r -= 0xFEE0;
    if (r == 0x3000) continue;
    if ((r >= 0x21 && r <= 0x2F) ||
        (r >= 0x3A && r <= 0x40) ||
        (r >= 0x5B && r <= 0x60) ||
        (r >= 0x7B && r <= 0x7E) ||
        (r >= 0xA1 && r <= 0xBF) ||
        (r >= 0x2010 && r <= 0x2027) ||
        (r >= 0x2030 && r <= 0x205E) ||
        (r >= 0x3001 && r <= 0x3003) ||
        (r >= 0x3008 && r <= 0x3011) ||
        (r >= 0x3014 && r <= 0x301F) ||
        r == 0x30FB ||
        (r >= 0xFF5F && r <= 0xFF65)) {
      continue;
    }
    if (_ws.hasMatch(String.fromCharCode(r))) continue;
    o.writeCharCode(r);
  }
  return o.toString();
}

bool _inZone(Element h) {
  Element? p = h;
  while (p != null) {
    if (_zone.contains(p.localName) || _hidden(p)) return true;
    p = p.parent;
  }
  return false;
}

bool _within(Element root, Element e) {
  Node? p = e;
  while (p != null) {
    if (identical(p, root)) return true;
    p = p.parent;
  }
  return false;
}

/// Title headings (spec section 4): every <h1> validated against og:title /
/// <title>. Exactly one distinct normalized text => usable; else [why] is set.
({List<Element> hs, String why, String rule}) _titleHeadings(Document d) {
  final metas = <String>[];
  for (final v in [
    d.querySelector('meta[property="og:title"]')?.attributes['content'],
    d.querySelector('title')?.text,
  ]) {
    if (v != null && v.trim().isNotEmpty) metas.add(v.trim());
  }
  final site = _tn(
      d.querySelector('meta[property="og:site_name"]')?.attributes['content'] ??
          '');
  final hs = <Element>[];
  final texts = <String>{};
  var rule = '';
  for (final h in d.querySelectorAll('h1')) {
    final n = _tn(_headingText(h));
    if (n.runes.length < _minT || _inZone(h) || (site.isNotEmpty && n == site)) {
      continue;
    }
    var r = '';
    for (final m in metas) {
      if (_tn(m) == n) {
        r = 'M1';
        break;
      }
      final segs = m.split(_sep).map(_tn).where((x) => x.isNotEmpty).toList();
      if (segs.length >= 2) {
        final mx = segs.map((x) => x.runes.length).reduce((a, b) => a > b ? a : b);
        final top = segs.where((x) => x.runes.length == mx).toList();
        if (top.length == 1 && top.first == n) {
          r = 'M2';
          break;
        }
      }
    }
    if (r.isEmpty) continue;
    hs.add(h);
    texts.add(n);
    if (rule.isEmpty) rule = r;
  }
  if (texts.isEmpty) return (hs: <Element>[], why: 'no_match', rule: '');
  if (texts.length > 1) return (hs: <Element>[], why: 'ambiguous', rule: '');
  return (hs: hs, why: '', rule: rule);
}
