// Exercise the actual component's asynchronous state transitions without a browser or network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const ts = require(path.join(root, 'web/node_modules/typescript'));
const fixture = JSON.parse(fs.readFileSync(path.join(root, 'fixtures/campaigns.json')));
function compile(file, requireModule) {
  const module = {exports: {}};
  const js = ts.transpileModule(fs.readFileSync(path.join(root, 'web/src', file), 'utf8'), {
    compilerOptions: {module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX},
  }).outputText;
  vm.runInNewContext(`(function(require,exports,module){${js}\n})`, {console, Intl, Date, Map, Set})(requireModule, module.exports, module);
  return module.exports;
}
const lib = compile('lib/campaigns.ts', () => ({}));
const pending = [], hooks = [], effects = [], cache = [];
let cursor = 0;
const same = (a, b) => a && b && a.length === b.length && a.every((v, i) => Object.is(v, b[i]));
const react = {
  useState(initial) {
    const i = cursor++;
    if (!(i in hooks)) hooks[i] = initial;
    return [hooks[i], value => {hooks[i] = typeof value === 'function' ? value(hooks[i]) : value;}];
  },
  useRef(initial) {const i = cursor++; return hooks[i] ??= {current: initial};},
  useEffect(fn, deps) {const i = cursor++; if (!same(cache[i], deps)) {cache[i] = deps; effects.push(fn);}},
  useCallback(fn, deps) {const i = cursor++; if (!same(cache[i]?.deps, deps)) cache[i] = {deps, fn}; return cache[i].fn;},
  useMemo(fn, deps) {const i = cursor++; if (!same(cache[i]?.deps, deps)) cache[i] = {deps, value: fn()}; return cache[i].value;},
};
const jsx = {Fragment: 'Fragment', jsx: (type, props) => ({type, props}), jsxs: (type, props) => ({type, props})};
const api = {
  getCampaigns: async () => ({...fixture, available: true}),
  getCampaignIncident: id => new Promise((resolve, reject) => pending.push({id, resolve, reject})),
};
const view = compile('components/views/CampaignsView.tsx', name => {
  if (name === 'react') return react;
  if (name === 'react/jsx-runtime') return jsx;
  if (name.endsWith('/api')) return api;
  if (name.endsWith('/campaigns')) return lib;
  if (name.endsWith('/campaignStrings')) return {useCT: () => key => key};
  if (name.endsWith('/i18n')) return {useT: () => ({t: key => key})};
  return new Proxy({}, {get: (_obj, key) => key});
}).CampaignsView;
function render() {cursor = 0; const tree = view(); effects.splice(0).forEach(fn => fn()); return tree;}
function find(tree, predicate) {
  if (!tree || typeof tree !== 'object') return null;
  if (predicate(tree)) return tree;
  for (const child of [tree.props?.children].flat(Infinity)) {const found = find(child, predicate); if (found) return found;}
  return null;
}
function text(tree) {
  if (typeof tree === 'string' || typeof tree === 'number') return String(tree);
  return [tree?.props?.children].flat(Infinity).map(child => child === tree ? '' : text(child)).join(' ');
}
const node = (tree, type) => find(tree, item => item.type === type);
const tick = () => new Promise(setImmediate);
const detail = id => ({available: true, incident: fixture.incidents.find(i => i.incident_id === id), campaigns: [], firings: [], attempts: []});
(async () => {
  render(); await tick(); let tree = render();
  const first = pending.shift();
  assert.ok(first, 'initial incident request starts');
  if (['unavailable', 'reselect-failed'].includes(process.argv[2])) {
    first.resolve({available: false, reason: 'fixture missing', incident: null, campaigns: [], firings: [], attempts: []});
    await tick(); tree = render();
    assert.ok(text(tree).includes('fixture missing'), 'unavailable reason remains visible');
    if (process.argv[2] === 'reselect-failed') {
      node(tree, 'IncidentList').props.onSelect(first.id); tree = render();
      assert.ok(text(tree).includes('fixture missing'), 'reselecting the failed incident must preserve recovery');
    }
    const retry = find(tree, item => item.type === 'button' && text(item).includes('cv.retry'));
    assert.ok(retry, 'unavailable detail offers retry');
    retry.props.onClick(); render();
    const request = pending.shift(); assert.equal(request.id, first.id);
    request.resolve(detail(request.id)); await tick(); tree = render();
    assert.equal(node(tree, 'CampaignActions').props.detail.incident.incident_id, first.id);
    assert.ok(!text(tree).includes('fixture missing'), 'successful retry clears the error');
  } else {
    const secondId = fixture.incidents.find(i => i.incident_id !== first.id).incident_id;
    node(tree, 'IncidentList').props.onSelect(secondId); render();
    const second = pending.shift(); assert.equal(second.id, secondId);
    if (process.argv[2] === 'late-error') {
      second.resolve(detail(second.id)); await tick(); render();
      first.reject(new Error('obsolete request failed')); await tick(); tree = render();
      assert.equal(node(tree, 'CampaignActions').props.detail.incident.incident_id, secondId);
      assert.ok(!text(tree).includes('obsolete request failed'), 'old failure must not affect current selection');
    } else {
      second.reject(new Error('current request failed')); await tick(); render();
      first.resolve(detail(first.id)); await tick(); tree = render();
      assert.ok(text(tree).includes('current request failed'));
      assert.equal(node(tree, 'CampaignActions').props.detail, null, 'old success must not become the displayed detail');
    }
  }
  console.log('PASS', process.argv[2]);
})().catch(error => {console.error(error); process.exitCode = 1;});
