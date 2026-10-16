// RA-WEB-IMP01: acceptance tests for the frozen S1 + N2 web content extractor.
//
// Part 1 = the 30 hand-written synthetic fixtures frozen in RA-WEB-N2S (SR1-SR11,
// ST1-ST18 incl. ST5a/ST5b), ported 1:1 (same HTML, same expectations).
// Part 2 = S1 behaviour pins and IMP01-only additions (NOT part of the frozen 30).
// No third-party page content is used anywhere in this file.
import 'package:flutter_test/flutter_test.dart';
import 'package:readaloud_app/usecase/content/fetch_url_content_usecase.dart';
import 'package:readaloud_app/util/web_content_extractor.dart';

String para(String tag, int n) {
  const u = 'これは合成検証用の文章です。';
  final b = StringBuffer();
  while (b.length < n) {
    b.write(u);
  }
  // exactly n chars including the tag
  return '$tag${b.toString().substring(0, n - tag.length)}';
}

String p(String tag, int n) => '<p>${para(tag, n)}</p>';
String card(String tag, int n) =>
    '<article><a href="/x">${para(tag, n)}</a></article>';
String cardT(String tag, int n) => '<article><div>${para(tag, n)}</div></article>';

String page(String head, String body) =>
    '<!doctype html><html><head><meta charset="utf-8">$head</head><body>$body</body></html>';

const ogT =
    '<meta property="og:title" content="Alpha Report 2026 | Acme Daily"><title>Alpha Report 2026 | Acme Daily</title>';

int occurrences(String h, String n) {
  var c = 0, i = 0;
  while ((i = h.indexOf(n, i)) >= 0) {
    c++;
    i += n.length;
  }
  return c;
}

class Fx {
  Fx(
    this.name,
    this.html, {
    this.root,
    this.title,
    this.has = const [],
    this.hasNot = const [],
    this.startsWith,
    this.countOf,
    this.count,
  });

  final String name, html;
  final String? root, title, startsWith, countOf;
  final List<String> has, hasNot;
  final int? count;
}

final frozenFixtures = <Fx>[
  // ---------- Root Repair ----------
  Fx(
      'SR1 empty-first-article, title in body outside articles -> body',
      page(
          ogT,
          '<div><h1>Alpha Report 2026</h1></div><article></article>${card('CARD1_', 60)}${card('CARD2_', 70)}<div>${p('BODYA_', 600)}${p('BODYB_', 600)}</div>'),
      root: 'body',
      title: 'none:present',
      has: ['BODYA_', 'BODYB_']),
  Fx(
      'SR2 empty first, 208-char non-link card, then T-bearing article -> article_T (card never chosen)',
      page(ogT,
          '<article> </article>${cardT('CARD208_', 208)}<article><header><h1>Alpha Report 2026</h1></header>${p('REAL_', 1500)}</article>'),
      root: 'article_T',
      has: ['REAL_'],
      hasNot: ['CARD208_'],
      startsWith: '# Alpha Report 2026',
      title: 'insert'),
  Fx(
      'SR3 empty first, only 208/243-char cards (no T), body has T+text -> body',
      page(ogT,
          '<h1>Alpha Report 2026</h1><article></article>${cardT('CARD208_', 208)}${cardT('CARD243_', 243)}<div>${p('MAIN_', 900)}</div>'),
      root: 'body',
      has: ['MAIN_'],
      hasNot: [],
      title: 'none:present'),
  Fx(
      'SR4 empty first, no title heading, big later article -> never chosen by size (body tier)',
      page(ogT,
          '<article></article><article>${p('LATER_', 3000)}</article><div>${p('TAIL_', 100)}</div>'),
      root: 'body',
      has: ['LATER_', 'TAIL_'],
      title: 'none:no_match'),
  Fx(
      'SR5 plausible r0 (600 chars), title above article in page header -> identity, no change of root',
      page(ogT,
          '<div><h1>Alpha Report 2026</h1></div><article>${p('ART_', 600)}</article><div>${p('OUT_', 600)}</div>'),
      root: 'identity',
      has: ['ART_'],
      hasNot: ['OUT_'],
      title: 'none:outside_root'),
  Fx(
      'SR6 empty first article, non-empty main, T not in main -> main',
      page(ogT,
          '<article></article><main>${p('MAINLM_', 400)}</main><div>${p('OUTSIDE_', 400)}</div>'),
      root: 'main',
      has: ['MAINLM_'],
      hasNot: ['OUTSIDE_'],
      title: 'none:no_match'),
  Fx(
      'SR7 everything near-empty -> rejected_all, empty text, no crash',
      page(ogT, '<article></article><nav>${para('NAV_', 500)}</nav>'),
      root: 'rejected_all',
      title: 'none:no_match',
      hasNot: ['NAV_']),
  Fx(
      'SR8 link-only first article (60 chars all link) is near-empty -> triggers; body chosen',
      page(ogT,
          '<h1>Alpha Report 2026</h1>${card('LINKCARD_', 60)}<div>${p('TEXTB_', 500)}</div>'),
      root: 'body',
      has: ['TEXTB_']),
  Fx(
      'SR9 first article with 39 non-link chars triggers (boundary), 40 does not',
      page(ogT,
          '<article>${para('B39_', 39)}</article><div>${p('BODYX_', 500)}</div>'),
      root: 'body',
      has: ['BODYX_']),
  Fx(
      'SR10 first article with exactly 40 non-link chars -> identity (S1 behaviour retained)',
      page(ogT,
          '<article>${para('B40_', 40)}</article><div>${p('BODYY_', 500)}</div>'),
      root: 'identity',
      has: ['B40_'],
      hasNot: ['BODYY_']),
  Fx('SR11 zero-trigger page where main is r0 and plausible -> identity',
      page(ogT, '<main>${p('M_', 300)}</main>'),
      root: 'identity', has: ['M_']),
  // ---------- Title Repair ----------
  Fx(
      'ST1 title in header inside article, og+title with site suffix -> insert once at top',
      page(ogT,
          '<article><header><h1>Alpha Report 2026</h1></header>${p('BODY1_', 600)}</article>'),
      root: 'identity',
      title: 'insert',
      startsWith: '# Alpha Report 2026\n\nBODY1_',
      has: ['BODY1_'],
      countOf: 'Alpha Report 2026',
      count: 1),
  Fx(
      'ST2 title already in body (not dropped) -> no insertion (duplicate guard)',
      page(ogT,
          '<article><h1>Alpha Report 2026</h1>${p('BODY2_', 600)}</article>'),
      title: 'none:present',
      countOf: 'Alpha Report 2026',
      count: 1),
  Fx(
      'ST3 only site-name h1 (equals og:site_name) -> no insertion',
      page('$ogT<meta property="og:site_name" content="Acme Daily">',
          '<article><header><h1>Acme Daily</h1></header>${p('BODY3_', 600)}</article>'),
      title: 'none:no_match',
      hasNot: ['Acme Daily']),
  Fx(
      'ST4 two distinct matching h1s -> ambiguous, none',
      page(
          '<meta property="og:title" content="Alpha Report 2026"><title>Delta Epsilon Zeta | Site</title>',
          '<article><header><h1>Alpha Report 2026</h1><h1>Delta Epsilon Zeta</h1></header>${p('BODY4_', 600)}</article>'),
      title: 'none:ambiguous',
      hasNot: ['Alpha Report 2026']),
  Fx(
      'ST5a short heading that is a SUBSTRING of the title -> no match',
      page('<title>Python Tutorial for Beginners</title>',
          '<article><header><h1>Python Tutorial</h1></header>${p('BODY5_', 600)}</article>'),
      title: 'none:no_match',
      hasNot: ['Python Tutorial']),
  Fx(
      'ST5b heading that is a SUPERSTRING of the title -> no match',
      page('<title>Python Tutorial</title>',
          '<article><header><h1>Python Tutorial for Beginners and More</h1></header>${p('BODY5B_', 600)}</article>'),
      title: 'none:no_match',
      hasNot: ['Beginners']),
  Fx(
      'ST6 site-name suffix h1 only (no og:site_name), title "Article Heading | Acme" -> h1 "Acme" is the shorter segment -> no match',
      page('<title>Article Heading Text | Acme</title>',
          '<article><header><h1>Acme</h1></header>${p('BODY6_', 600)}</article>'),
      title: 'none:no_match',
      hasNot: ['Acme']),
  Fx(
      'ST7 metadata only, no h1 -> nothing inserted',
      page(ogT, '<article>${p('BODY7_', 600)}</article>'),
      title: 'none:no_match',
      hasNot: ['Alpha Report 2026']),
  Fx(
      'ST8 matching h1 inside nav -> ignored',
      page(ogT,
          '<nav><h1>Alpha Report 2026</h1></nav><article>${p('BODY8_', 600)}</article>'),
      title: 'none:no_match',
      hasNot: ['Alpha Report 2026']),
  Fx(
      'ST9 title heading outside the final root -> no insertion',
      page(ogT,
          '<header><h1>Alpha Report 2026</h1></header><article>${p('BODY9_', 600)}</article>'),
      title: 'none:outside_root',
      hasNot: ['Alpha Report 2026']),
  Fx(
      'ST10 normalization: full-width / NBSP / entity / punctuation differences still exact',
      page(
          '<meta property="og:title" content="Ｆｏｏ Bar&nbsp;Baz! – Site"><title>x</title>',
          '<article><header><h1>Foo Bar Baz</h1></header>${p('BODY10_', 600)}</article>'),
      title: 'insert',
      startsWith: '# Foo Bar Baz'),
  Fx(
      'ST11 duplicate guard (b): first line contains title plus extra text -> no insertion',
      page(ogT,
          '<article><div>Alpha Report 2026 by A. Writer</div><header><h1>Alpha Report 2026</h1></header>${p('BODY11_', 600)}</article>'),
      title: 'none:present',
      countOf: 'Alpha Report 2026',
      count: 1),
  Fx(
      'ST12 empty body must not become title-only text',
      page(ogT,
          '<article><header><h1>Alpha Report 2026</h1></header></article><div></div>'),
      title: 'none:empty_body'),
  Fx(
      'ST13 M2 kicker colon prefix: "Kicker：Title | Site" with h1 == middle segment (longest) -> insert',
      page('<title>短い見出し：記事の本当のタイトルはこちらです | サイト</title>',
          '<article><header><h1>記事の本当のタイトルはこちらです</h1></header>${p('BODY13_', 600)}</article>'),
      title: 'insert',
      startsWith: '# 記事の本当のタイトルはこちらです'),
  Fx(
      'ST14 M2 tie for longest segment -> no match',
      page('<title>Alpha Beta | Gamma Delta</title>',
          '<article><header><h1>Alpha Beta</h1></header>${p('BODY14_', 600)}</article>'),
      title: 'none:no_match'),
  Fx(
      'ST15 responsive duplicate h1 copies with the same text (one hidden) -> one insertion',
      page(ogT,
          '<article><header><h1>Alpha Report 2026</h1><h1 aria-hidden="true">Alpha Report 2026</h1></header>${p('BODY15_', 600)}</article>'),
      title: 'insert',
      countOf: 'Alpha Report 2026',
      count: 1),
  Fx(
      'ST16 plain title-text line far below (beyond the first 10 lines, not a heading) does not block the repair',
      page(ogT,
          '<article><header><h1>Alpha Report 2026</h1></header>${List.generate(14, (i) => p('P${i}_', 120)).join()}<div>Alpha Report 2026</div></article>'),
      title: 'insert',
      startsWith: '# Alpha Report 2026'),
  Fx(
      'ST17 heading line equal to the title deep in the body counts as present',
      page(ogT,
          '<article><header><h1>Alpha Report 2026</h1></header>${List.generate(14, (i) => p('Q${i}_', 120)).join()}<h2>Alpha Report 2026</h2>${p('TAIL17_', 120)}</article>'),
      title: 'none:present'),
  Fx(
      'ST18 long lede sentence that begins with the title phrase is body text, not the title -> insert',
      page(ogT,
          '<article><header><h1>Alpha Report 2026</h1></header><p>Alpha Report 2026 is a synthetic document used only to exercise this specification and it keeps going for a good while longer than the title itself.</p>${p('BODY18_', 600)}</article>'),
      title: 'insert',
      startsWith: '# Alpha Report 2026'),
];

void main() {
  group('frozen synthetic fixtures (RA-WEB-N2S, 30)', () {
    test('fixture set is exactly the frozen 30', () {
      expect(frozenFixtures.length, 30);
    });

    for (final c in frozenFixtures) {
      test(c.name, () {
        final r = extractWebContent(c.html);
        if (c.root != null) expect(r.rootAction, c.root, reason: 'rootAction');
        if (c.title != null) {
          expect(r.titleAction, c.title, reason: 'titleAction');
        }
        for (final h in c.has) {
          expect(r.text, contains(h));
        }
        for (final h in c.hasNot) {
          expect(r.text, isNot(contains(h)));
        }
        if (c.startsWith != null) expect(r.text, startsWith(c.startsWith!));
        if (c.countOf != null) {
          expect(occurrences(r.text, c.countOf!), c.count,
              reason: 'count(${c.countOf})');
        }
      });
    }
  });

  group('S1 behaviour pins', () {
    String ex(String body) => extractWebContent(page('', body)).text;

    test('root is article > main > body', () {
      expect(ex('<p>OUT</p><article><p>IN article text ${'x' * 50}</p></article>'),
          'IN article text ${'x' * 50}');
      expect(ex('<p>OUT</p><main><p>IN main text ${'x' * 50}</p></main>'),
          'IN main text ${'x' * 50}');
      expect(ex('<p>IN body text ${'x' * 50}</p>'), 'IN body text ${'x' * 50}');
    });

    test('semantic boilerplate / non-content elements are removed', () {
      final body = '<article>'
          '<nav>NAVTEXT</nav><header>HEADERTEXT</header><aside>ASIDETEXT</aside>'
          '<footer>FOOTERTEXT</footer><form>FORMTEXT</form><button>BTNTEXT</button>'
          '<script>SCRIPTTEXT</script><style>STYLETEXT</style><noscript>NOSCRIPTTEXT</noscript>'
          '<template>TEMPLATETEXT</template><svg>SVGTEXT</svg>'
          '<p>KEEP ${'k' * 60}</p></article>';
      final t = ex(body);
      for (final gone in [
        'NAVTEXT', 'HEADERTEXT', 'ASIDETEXT', 'FOOTERTEXT', 'FORMTEXT', //
        'BTNTEXT', 'SCRIPTTEXT', 'STYLETEXT', 'NOSCRIPTTEXT', 'TEMPLATETEXT',
        'SVGTEXT',
      ]) {
        expect(t, isNot(contains(gone)), reason: gone);
      }
      expect(t, 'KEEP ${'k' * 60}');
    });

    test('hidden subtrees are removed (hidden / aria-hidden / display:none)', () {
      final t = ex('<article><p hidden>HID1</p><p aria-hidden="true">HID2</p>'
          '<p style="color:red; display: none">HID3</p>'
          '<p>SHOWN ${'s' * 60}</p></article>');
      expect(t, 'SHOWN ${'s' * 60}');
    });

    test('headings are emitted as "# " lines with block boundaries kept', () {
      final t = ex('<article><h2>Sub heading</h2><p>First para ${'a' * 50}</p>'
          '<ul><li>one</li><li>two</li></ul><p>Last para ${'b' * 50}</p></article>');
      expect(
          t,
          '# Sub heading\n\nFirst para ${'a' * 50}\n\n- one\n- two\n\nLast para ${'b' * 50}');
    });

    test('whitespace normalization: runs collapsed, blank lines capped, trimmed',
        () {
      final t = ex('<article><p>  a    b   c\t</p>\n\n\n<p>d</p>'
          '<pre>x   y</pre><p>${'e' * 60}</p></article>');
      // S1 clean-up also collapses runs of spaces inside <pre> (frozen behaviour).
      expect(t, 'a b c\n\nd\n\nx y\n\n${'e' * 60}');
    });
  });

  group('IMP01 additions (not part of the frozen 30)', () {
    test('short title (< 4 runes) is rejected even if h1 equals metadata', () {
      final r = extractWebContent(page(
          '<meta property="og:title" content="ABC"><title>ABC</title>',
          '<article><header><h1>ABC</h1></header>${p('SHORT_', 600)}</article>'));
      expect(r.titleAction, 'none:no_match');
      expect(r.text, isNot(contains('ABC')));
    });

    test('a 4-rune title is the smallest accepted (MIN_T boundary)', () {
      final r = extractWebContent(page(
          '<meta property="og:title" content="ABCD"><title>ABCD</title>',
          '<article><header><h1>ABCD</h1></header>${p('FOUR_', 600)}</article>'));
      expect(r.titleAction, 'insert');
      expect(r.text, startsWith('# ABCD\n\nFOUR_'));
    });

    test('S1 passes through unchanged when N2 has nothing to repair', () {
      final body = '<article><h1>Plain Title Here</h1>${p('SAME_', 300)}</article>';
      final r = extractWebContent(page('', body));
      expect(r.rootAction, 'identity');
      expect(r.titleAction, 'none:no_match');
      expect(r.text, startsWith('# Plain Title Here\n\nSAME_'));
    });

    test('empty / odd input does not throw', () {
      expect(extractWebContent('').text, '');
      final odd = extractWebContent('<<<>>>');
      // body holds only 6 chars => near-empty r0, nothing to switch to => S1 text
      expect(odd.rootAction, 'rejected_all');
      expect(odd.titleAction, 'none:no_match');
    });

    test('title insertion is a pure prefix of the root-repaired S1 text', () {
      final withTitle = extractWebContent(page(ogT,
          '<article><header><h1>Alpha Report 2026</h1></header>${p('PFX_', 400)}</article>'));
      final noTitleMeta = extractWebContent(page('',
          '<article><header><h1>Alpha Report 2026</h1></header>${p('PFX_', 400)}</article>'));
      expect(withTitle.titleAction, 'insert');
      expect(withTitle.text, '# Alpha Report 2026\n\n${noTitleMeta.text}');
    });

    test('FetchUrlResult public contract is unchanged', () {
      final r = FetchUrlResult(title: 't', body: 'b');
      expect(r.title, 't');
      expect(r.body, 'b');
    });
  });
}
