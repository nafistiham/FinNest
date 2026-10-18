// Render the audit drawer's App Safety section with the real strings, in both languages, without a browser.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const ts = require(path.join(root, 'web/node_modules/typescript'));
function compile(file, requireModule) {
  const module = {exports: {}};
  const js = ts.transpileModule(fs.readFileSync(path.join(root, 'web/src', file), 'utf8'), {
    compilerOptions: {module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX},
  }).outputText;
  vm.runInNewContext(`(function(require,exports,module){${js}\n})`, {console, Intl, Date, Map, Set})(requireModule, module.exports, module);
  return module.exports;
}
let lang = 'en';
const react = {createContext: value => ({value}), useContext: () => lang};
const jsx = {Fragment: 'Fragment', jsx: (type, props) => ({type, props}), jsxs: (type, props) => ({type, props})};
const i18n = compile('lib/i18n.ts', name => (name === 'react' ? react : {}));
const format = compile('lib/format.ts', () => ({}));
const {AppSafetyReport} = compile('components/AppSafetyReport.tsx', name => {
  if (name === 'react') return react;
  if (name === 'react/jsx-runtime') return jsx;
  if (name.endsWith('/i18n')) return i18n;
  if (name.endsWith('/format')) return format;
  if (name.endsWith('/primitives')) return {Chip: 'Chip', Explainer: 'Explainer'};
  if (name.endsWith('/Wordmark')) return {Icon: 'Icon'};
  throw new Error(`unexpected import ${name}`);
});

// Function components are called, so the tree holds only host elements and the mocked primitives.
function expand(node) {
  if (Array.isArray(node)) return node.map(expand);
  if (!node || typeof node !== 'object') return node;
  if (typeof node.type === 'function') return expand(node.type(node.props));
  return {type: node.type, props: {...node.props, children: expand(node.props?.children)}};
}
function render(inputs, language = 'en') {
  lang = language;
  format.setFormatLang(language);
  return expand(AppSafetyReport({inputs}));
}
function all(tree, predicate, out = []) {
  if (Array.isArray(tree)) tree.forEach(child => all(child, predicate, out));
  else if (tree && typeof tree === 'object') {
    if (predicate(tree)) out.push(tree);
    all(tree.props?.children, predicate, out);
  }
  return out;
}
function text(tree) {
  if (typeof tree === 'string' || typeof tree === 'number') return String(tree);
  if (Array.isArray(tree)) return tree.map(text).join(' ');
  if (!tree || typeof tree !== 'object') return '';
  return text(tree.props?.children);
}
const chips = tree => all(tree, el => el.type === 'Chip');
const chipWith = (tree, words) => chips(tree).find(chip => text(chip).includes(words));
const hasIcon = chip => all(chip, el => el.type === 'Icon').length > 0;
const t = (key, vars) => { const {t: tr} = i18n.useT(); return tr(key, vars); };

const report = {
  verdict: 'CAUTION', risk_score: 0.52, source: 'latest', simulated_verdict: true, attestation: 'tampered',
  check_id: 'chk_7f3a', checked_at: '2026-10-17T10:00:00+06:00', valid_until: '2026-10-17T10:15:00+06:00',
  findings: [
    {package: '', signal: 'rooted', severity: 'critical', scope: 'device'},
    {package: 'com.evil.overlay', signal: 'overlay_permission', severity: 'high', scope: 'app'},
  ],
  findings_dropped: 3,
};

// A counted CAUTION report: amber, never red; every field the report carries is on screen.
for (const language of ['en', 'bn']) {
  const tree = render({app_safety: report}, language);
  const words = text(tree);
  assert.ok(tree, 'a report renders');
  assert.doesNotMatch(words, /appsafety\./, `an untranslated key in ${language}: ${words}`);
  const verdict = chipWith(tree, t('appsafety.verdict.CAUTION'));
  assert.ok(verdict, `no CAUTION chip in ${language}: ${words}`);
  assert.equal(verdict.props.kind, 'warn', 'CAUTION is amber');
  assert.ok(hasIcon(verdict), 'the verdict has an icon beside its word');
  assert.ok(!chips(tree).some(chip => chip.props.kind === 'bad'), 'red is for BLOCK only');
  const simulated = chipWith(tree, t('appsafety.simulated'));
  assert.ok(simulated && simulated.props.kind === 'warn' && hasIcon(simulated), 'the simulated verdict is labelled, amber, with an icon');
  for (const shown of [t('appsafety.source.latest'), 'tampered', t('appsafety.att.tampered'), 'chk_7f3a',
                       format.dhakaTime(report.valid_until), 'rooted', 'overlay_permission', 'com.evil.overlay',
                       t('appsafety.severity.critical'), t('appsafety.severity.high'), t('appsafety.dropped', {n: format.digits('3')})]) {
    assert.ok(words.includes(shown), `${language}: "${shown}" is not shown in: ${words}`);
  }
  assert.ok(!words.includes(t('appsafety.ignored')), 'a counted report is not called ignored');
}
assert.notEqual(text(render({app_safety: report}, 'en')), text(render({app_safety: report}, 'bn')), 'the two languages differ');
assert.ok(text(render({app_safety: report}, 'bn')).includes('৩'), 'Bangla digits in Bangla');
// A phone that sent 5,000 findings: the count is grouped like every other number on the console.
assert.ok(text(render({app_safety: {...report, findings_dropped: 4950}}, 'en')).includes(t('appsafety.dropped', {n: '4,950'})));
assert.ok(text(render({app_safety: {...report, findings_dropped: 4950}}, 'bn')).includes(t('appsafety.dropped', {n: '৪,৯৫০'})));

// BLOCK is red, SAFE green; nothing dropped and nothing found say so plainly.
assert.equal(chipWith(render({app_safety: {...report, verdict: 'BLOCK'}}), t('appsafety.verdict.BLOCK')).props.kind, 'bad');
const safe = render({app_safety: {verdict: 'SAFE', risk_score: 0.02, source: 'check', findings: [], findings_dropped: 0}});
assert.equal(chipWith(safe, t('appsafety.verdict.SAFE')).props.kind, 'good');
assert.ok(!chipWith(safe, t('appsafety.simulated')), 'a real verdict carries no simulated tag');
assert.ok(text(safe).includes(t('appsafety.findings.none')));
assert.ok(text(safe).includes(t('appsafety.source.check')));
assert.ok(!text(safe).includes(t('appsafety.dropped', {n: '0'})), 'no dropped line at zero');

// A copy risk-mw ignored: what the phone sent, and why it did not count.
for (const [reason, why] of [['expired', t('appsafety.ignored.expired')], ['simulated', t('appsafety.ignored.simulated')],
                             ['unheard_of', t('appsafety.ignored.other', {reason: 'unheard_of'})]]) {
  const tree = render({app_safety: null, app_safety_ignored: {reason, sent: report}});
  const words = text(tree);
  assert.ok(words.includes(t('appsafety.ignored')), `${reason}: not marked ignored: ${words}`);
  assert.ok(words.includes(why), `${reason}: the reason is missing: ${words}`);
  assert.ok(chipWith(tree, t('appsafety.verdict.CAUTION')), `${reason}: what was sent is still shown`);
}

// A score row without the block renders nothing.
assert.equal(render({demo_flags: {}}), null);
assert.equal(render({}), null);
console.log('ok');
