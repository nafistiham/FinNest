// Render the audit drawer's Gemini reading with the real strings, in both languages, without a browser.
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
const {GeminiInsight} = compile('components/GeminiInsight.tsx', name => {
  if (name === 'react') return react;
  if (name === 'react/jsx-runtime') return jsx;
  if (name.endsWith('/i18n')) return i18n;
  if (name.endsWith('/format')) return format;
  if (name.endsWith('/primitives')) return {Chip: 'Chip', Explainer: 'Explainer'};
  if (name.endsWith('/Wordmark')) return {Icon: 'Icon'};
  throw new Error(`unexpected import ${name}`);
});

function expand(node) {
  if (Array.isArray(node)) return node.map(expand);
  if (!node || typeof node !== 'object') return node;
  if (typeof node.type === 'function') return expand(node.type(node.props));
  return {type: node.type, props: {...node.props, children: expand(node.props?.children)}};
}
let retried = 0;
function render(state, language = 'en') {
  lang = language;
  format.setFormatLang(language);
  return expand(GeminiInsight({state, onRetry: () => { retried += 1; }}));
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
const t = (key, vars) => { const {t: tr} = i18n.useT(); return tr(key, vars); };
const buttons = tree => all(tree, el => el.type === 'button');

const insight = {
  summary_en: 'Held because the scam call set the score at 0.95 and asked for the hold.',
  summary_bn: 'প্রতারণার কল ০.৯৫ ওজনে স্কোর ঠিক করেছে এবং আটকে রাখতে বলেছে।',
  drivers: [
    {code: 'SCAM_CONVERSATION', weight: 0.95, reading_en: 'Set the score and asked for the hold.', reading_bn: 'স্কোর ঠিক করেছে, আটকে রাখতে বলেছে।'},
    {code: 'APP_SAFETY_CAUTION', weight: 0.59, reading_en: 'Never changes a decision by itself.', reading_bn: 'নিজে সিদ্ধান্ত বদলায় না।'},
  ],
  next_checks: [{en: 'Open the same session\'s scam turns.', bn: 'একই সেশনের স্ক্যাম টার্ন দেখুন।'}],
  caveat_en: 'The call was set from the demo panel.',
  caveat_bn: 'কলটি ডেমো প্যানেল থেকে বসানো।',
};
const ready = {status: 'done', answer: {available: true, insight, model_id: 'gemini-3.8-flash', cached: true, latency_ms: 5600}};

// A reading: the active language only, every reason read, the caveat as a neutral note, and where it came from.
for (const language of ['en', 'bn']) {
  const tree = render(ready, language);
  const words = text(tree);
  const other = language === 'en' ? 'bn' : 'en';
  assert.doesNotMatch(words, /insight\./, `an untranslated key in ${language}: ${words}`);
  assert.ok(words.includes(t('insight.title')), `${language}: no heading`);
  assert.ok(words.includes(insight[`summary_${language}`]), `${language}: no summary`);
  assert.ok(!words.includes(insight[`summary_${other}`]), `${language}: shows the other language too`);
  for (const driver of insight.drivers) {
    assert.ok(words.includes(driver.code), `${language}: ${driver.code} missing`);
    assert.ok(words.includes(driver[`reading_${language}`]), `${language}: ${driver.code}'s reading missing`);
    assert.ok(words.includes(format.digits(String(driver.weight))), `${language}: ${driver.code}'s weight missing`);
  }
  assert.ok(words.includes(t('insight.checks')) && words.includes(insight.next_checks[0][language]), `${language}: no checks`);
  const caveat = all(tree, el => typeof el.props?.className === 'string' && el.props.className.includes('note info'));
  assert.ok(caveat.length === 1 && text(caveat[0]).includes(insight[`caveat_${language}`]), `${language}: the caveat is not an info note`);
  assert.ok(all(caveat[0], el => el.type === 'Icon').length > 0, 'the caveat has an icon beside its words');
  assert.ok(words.includes('gemini-3.8-flash') && words.includes(t('insight.cached')), `${language}: provenance missing`);
  assert.ok(!all(tree, el => el.type === 'Chip').some(chip => chip.props.kind === 'bad'), 'no red: nothing here is a block');
  const said = all(tree, el => el.props?.lang === language);
  assert.ok(said.length > 0, `${language}: Gemini's text is not marked lang="${language}"`);
  assert.equal(buttons(tree).length, 0, 'a reading has nothing to retry');
}
assert.ok(text(render(ready, 'bn')).includes('০.৯৫'), 'Bangla digits in Bangla');
assert.ok(!text(render({...ready, answer: {...ready.answer, cached: false}})).includes(t('insight.cached')), 'a fresh reading is not called cached');

// The reading replaces the skeleton in a polite live region, so a screen reader hears it arrive.
for (const state of [ready, {status: 'loading'}, {status: 'failed', message: 'x'}]) {
  assert.equal(all(render(state), el => el.props?.['aria-live'] === 'polite').length, 1, `${state.status}: no live region`);
}

// Waiting: a skeleton with words, not a spinner.
const waiting = render({status: 'loading'});
assert.ok(all(waiting, el => el.props?.['aria-busy'] === 'true').length === 1, 'the loading state is a busy skeleton');
assert.ok(text(waiting).includes(t('insight.loading')));

// No reading: say why, offer a retry only where trying again can help.
for (const [reason, retry] of [['timeout', true], ['genai_error', true], ['genai_disabled', false], ['spend_cap', false],
                               ['invalid', false], ['unreadable', false]]) {
  for (const language of ['en', 'bn']) {
    const tree = render({status: 'done', answer: {available: false, reason}}, language);
    const words = text(tree);
    assert.ok(words.includes(t(`insight.off.${reason}`)), `${reason}/${language}: the reason is not worded: ${words}`);
    assert.equal(buttons(tree).length, retry ? 1 : 0, `${reason}: retry offered wrongly`);
  }
}
const unknown = text(render({status: 'done', answer: {available: false, reason: 'brand_new_code'}}));
assert.ok(unknown.includes(t('insight.off.other', {reason: 'brand_new_code'})), 'a new code still reads');
const failed = render({status: 'failed', message: '502 Bad Gateway'});
assert.ok(text(failed).includes(t('insight.failed')) && text(failed).includes('502 Bad Gateway'));
const before = retried;
buttons(failed)[0].props.onClick();
assert.equal(retried, before + 1, 'the retry button asks again');
assert.ok(text(failed).includes(t('insight.retry')));
console.log('ok');
