/**
 * Two languages, one console.
 *
 * The chrome lives here; the editorial text - gate titles, policy statements, why a target has no
 * data - comes from the service with a `_bn` sibling, because those sentences are arguments about
 * the system and belong next to the code that makes them, not in a translation file that drifts.
 *
 * On vocabulary: where a Bangladeshi fraud-ops team would say the English word, the Bangla string
 * transliterates it rather than translating it. "Friction cost" is ফ্রিকশন কস্ট, not ঘর্ষণের দাম -
 * which is correct Bangla and the wrong register, because nobody in a risk meeting says ঘর্ষণ.
 * Plain nouns (অ্যাকাউন্ট, পেমেন্ট, টাকা) stay Bangla; terms of art (ক্যাচ রেট, ফলস পজিটিভ,
 * টাইপোলজি, থ্রেশহোল্ড) are transliterated.
 *
 * `pick` is how a component reaches for the right one: `pick(gate, 'title')` gives `title_bn` in
 * Bangla and falls back to English when a string has not been translated yet, so a missing
 * translation degrades to a readable page rather than a blank one.
 */

import { createContext, useContext } from 'react'

export type Lang = 'en' | 'bn'

type Dict = Record<string, [string, string]>

/** [English, Bangla] */
const STRINGS: Dict = {
  /* The wordmark is live text, never an image, never one colour, never translated - the design
     system is explicit about all three. "Fin" is brandLeaf and "Nest" brandNavy, so the name is
     rendered as two spans rather than fetched from this table. What is here is the subtitle and
     the tagline the mark sits beside. */
  'app.name': ['FinNest Admin', 'ফিননেস্ট অ্যাডমিন'],
  'app.product': ['FinNest', 'ফিননেস্ট'],
  'app.sub': ['Admin', 'অ্যাডমিন'],
  'app.desc': ['FinNest operator console', 'ফিননেস্ট অপারেটর কনসোল'],
  'app.tagline': ['A safe nest for your money', 'আপনার টাকার নিরাপদ ঘর'],
  'app.lede': [
    "The bank's side of the defence: which gate is weakest, what we stopped, and what it cost the people we stopped it for.",
    'প্রতিরক্ষার ব্যাংক-দিক: কোন গেট সবচেয়ে দুর্বল, আমরা কী থামিয়েছি, আর যাদের থামিয়েছি তাদের তাতে কত খরচ হলো।',
  ],
  'banner.synthetic': [
    'SYNTHETIC DATA · FinNest is a fictional provider. Nothing here is evidence about any real customer, bank or country — it describes a generated world.',
    'সিনথেটিক ডেটা · ফিননেস্ট একটি কাল্পনিক প্রোভাইডার। এখানে কিছুই কোনো বাস্তব গ্রাহক, ব্যাংক বা দেশ সম্পর্কে প্রমাণ নয় — এটি একটি তৈরি করা জগতের বর্ণনা।',
  ],

  'login.username': ['Username', 'ইউজারনেম'],
  'login.password': ['Password', 'পাসওয়ার্ড'],
  'login.submit': ['Sign in', 'প্রবেশ করুন'],
  'login.checking': ['Checking…', 'যাচাই করা হচ্ছে…'],
  'login.demo': ['One account, set on the server', 'একটি অ্যাকাউন্ট, সার্ভারে ঠিক করা'],
  'login.override': ['Local development without them: see .env.example.', 'এগুলো ছাড়া লোকাল ডেভেলপমেন্ট: .env.example দেখুন।'],
  'login.foot': [
    'One account, no roles, no reset. Production is Firebase Auth with custom claims — see api/auth.py. Every figure behind this screen is synthetic.',
    'একটি মাত্র অ্যাকাউন্ট, কোনো রোল নেই, রিসেট নেই। প্রোডাকশনে এটি হবে Firebase Auth ও custom claims — দেখুন api/auth.py। এই পর্দার পেছনের প্রতিটি সংখ্যা সিনথেটিক।',
  ],
  'login.wrong': ['Wrong username or password. Check both and try again.', 'ইউজারনেম বা পাসওয়ার্ড ভুল। দুটোই দেখে আবার চেষ্টা করুন।'],
  'login.failed': ['Sign-in did not go through (HTTP {status}). Try again in a moment.', 'সাইন-ইন হয়নি (HTTP {status})। একটু পরে আবার চেষ্টা করুন।'],

  'view.overview': ['Overview', 'ওভারভিউ'],
  'view.overview.hint': ['Everything at a glance', 'এক নজরে সবকিছু'],
  'view.gates': ['Gates', 'গেট'],
  'view.gates.hint': ['The defence, G0 to G7', 'প্রতিরক্ষা, G0 থেকে G7'],
  'view.risk': ['Decisions', 'ডিসিশন'],
  'view.risk.hint': ['What we stopped, and what it cost', 'কী থামালাম, আর তার দাম কত'],
  'view.accounts': ['Accounts', 'অ্যাকাউন্ট'],
  'view.accounts.hint': ['The riskiest accounts, searchable', 'সবচেয়ে ঝুঁকিপূর্ণ অ্যাকাউন্ট, খোঁজা যায়'],
  'view.models': ['Models', 'মডেল'],
  'view.models.hint': ['Health, gates and evals', 'স্বাস্থ্য, গেট আর eval'],
  'view.live': ['Live', 'লাইভ'],
  'view.live.hint': ['What is running, and the service answering now', 'কী কী চলছে, আর সার্ভিস এখন যেভাবে উত্তর দিচ্ছে'],
  'system.rules': ['rules', 'রুল'],
  'system.answer.clear': ['The payment went through. Nothing was shown.', 'পেমেন্টটা হয়ে গেছে। কিছুই দেখানো হয়নি।'],
  'system.v.clear': ['clear', 'ঠিক আছে'],
  'system.v.off': ['could not look', 'দেখতেই পারেনি'],
  'system.write.say': ['Written down before the phone sees it.', 'ফোনে পৌঁছানোর আগেই লিখে রাখা হলো।'],
  'system.notify.say': ['A hold asks the trusted contact to approve it.', 'হোল্ড হলে অনুমোদনের জন্য ট্রাস্টেড কন্টাক্টকে জিজ্ঞেস করা হয়।'],
  'system.investigate.say': [
    'An investigation would start here — nothing starts one. This is gate G4.',
    'এখান থেকেই তদন্ত শুরু হওয়ার কথা — কিন্তু কেউ শুরু করে না। এটাই গেট G4।',
  ],
  'system.byGemini': ['scored by Gemini on /v1/scam/turn', '/v1/scam/turn-এ জেমিনাই স্কোর করেছে'],
  'system.watchlist.say': [
    'The investigator already named this payee — and the payment path never read that list. Gate G4.',
    'ইনভেস্টিগেটর এই প্রাপককে আগেই চিহ্নিত করেছে — আর পেমেন্টের পথ ওই লিস্ট কখনো পড়েইনি। গেট G4।',
  ],
  'system.back': ['Previous step', 'আগের ধাপ'],
  'system.forward': ['Next step', 'পরের ধাপ'],
  'system.pause': ['Pause', 'থামান'],
  'system.resume': ['Resume', 'চালান'],
  'system.speed': ['Speed', 'গতি'],
  'system.rules.idle': ['nothing has triggered yet', 'এখনো কিছু চালু হয়নি'],
  'system.stop': ['Stop', 'থামান'],
  'system.nofire': ['→ no rule uses this', '→ এই তথ্যটা কোনো রুল ব্যবহার করে না'],
  'system.nohits': ['No rule triggered.', 'কোনো রুল চালু হয়নি।'],
  'system.stub.short': ['stub', 'স্টাব'],
  'system.stub': ['stub — not a model yet', 'স্টাব — এখনো মডেল নয়'],
  'system.model': ['model', 'মডেল'],
  'system.models': ['models', 'মডেল'],
  'system.models.title': ['What each model does', 'কোন মডেল কী করে'],
  'system.models.q': ['Five of them, and two are still stubs', 'পাঁচটা, তার দুটো এখনো স্টাব'],
  'system.models.note': [
    'The numbers come from the eval files, never from this page — a retrained model changes them here too. A stub is deterministic logic standing in until its model lands.',
    'সংখ্যাগুলো eval ফাইল থেকে আসে, এই পাতা থেকে নয় — মডেল আবার ট্রেইন হলে এখানেও বদলায়। স্টাব মানে নির্দিষ্ট নিয়মে চলা লজিক, আসল মডেল না আসা পর্যন্ত বদলি।',
  ],
  'system.inside.of': ['inside', 'এর ভিতরে'],
  'system.pick': ['Nothing selected', 'কিছু বাছা হয়নি'],
  'system.pickstep': ['Pick a step', 'একটা ধাপ বাছুন'],
  'system.ongemini': ['on Gemini', 'জেমিনাইতে'],
  'system.title': ['The system, in one picture', 'পুরো সিস্টেম, এক ছবিতে'],
  'system.q': ['Play a payment, or click anything', 'একটা পেমেন্ট চালিয়ে দেখুন, বা যেকোনো কিছুতে ক্লিক করুন'],
  'system.journey': ['One payment, end to end', 'একটা পেমেন্ট, শুরু থেকে শেষ'],
  'system.journey.q': ['Tap send, and this happens', 'পাঠাতে চাপ দিলে যা ঘটে'],
  'system.inside': ['Inside the decision service', 'সিদ্ধান্ত সার্ভিসের ভিতরে'],
  'system.show': ['Show the detail', 'বিস্তারিত দেখুন'],
  'system.hide': ['Hide the detail', 'বিস্তারিত লুকান'],
  'system.router': ['Group', 'গ্রুপ'],
  'system.routes': ['Questions it answers', 'যত প্রশ্নের উত্তর দেয়'],
  'system.source': ['Read from risk-mw’s own source.', 'risk-mw-এর নিজের সোর্স থেকে পড়া।'],
  'info.system': [
    'Four things run: the app on the phone, the service that decides, the investigator that works a case on its own, and this console. The service is the only one that may hold a payment, and everything it answers is written down before the phone sees it.',
    'চারটে জিনিস চলছে: ফোনের অ্যাপ, যে সার্ভিস সিদ্ধান্ত নেয়, যে তদন্তকারী নিজে একটা কেস নিয়ে কাজ করে, আর এই কনসোল। পেমেন্ট আটকানোর অধিকার কেবল সার্ভিসটারই, আর সে যা উত্তর দেয় তার সবই ফোনে পৌঁছানোর আগে লিখে রাখা হয়।',
  ],
  'view.settings': ['Settings', 'সেটিংস'],
  'view.settings.hint': ['Theme, palette, density, session', 'থিম, প্যালেট, ঘনত্ব, সেশন'],

  'top.built': ['built', 'তৈরি'],
  'top.rebuild': ['Rebuild', 'রিবিল্ড'],
  'top.rebuilding': ['recomputing…', 'আবার হিসাব হচ্ছে…'],
  'top.command': ['Command', 'কমান্ড'],
  'top.operator': ['operator', 'অপারেটর'],
  'top.signout': ['Sign out', 'সাইন আউট'],

  'kpi.protected': ['Value protected', 'বাঁচানো টাকা'],
  'kpi.protected.sub': ['fraudulent payments stopped', 'টি ফ্রড পেমেন্ট থামানো'],
  'kpi.friction': ['Friction cost', 'ফ্রিকশন কস্ট'],
  'kpi.friction.sub': ['genuine payments held', 'টি জেনুইন পেমেন্ট আটকানো'],
  'kpi.catch': ['Catch rate', 'ক্যাচ রেট'],
  'kpi.fpr': ['False-positive rate', 'ফলস পজিটিভ রেট'],
  'kpi.of': ['of', 'এর মধ্যে'],

  'gates.title': ['The defence, gate by gate', 'ডিফেন্স, গেট ধরে ধরে'],
  'gates.q': ['Which gate is weakest, and which are not built?', 'কোন গেট সবচেয়ে দুর্বল, আর কোনগুলো বানানোই হয়নি?'],
  'gates.volume': ['volume', 'ভলিউম'],
  'gates.caught': ['caught', 'ধরা পড়েছে'],
  'gates.weakest': ['Weakest link.', 'সবচেয়ে দুর্বল লিংক।'],
  'gates.sees': ['sees', 'দেখে'],
  'gates.full': ['Every gate, in full', 'প্রতিটি গেট, বিস্তারিত'],
  'gates.full.q': ['What it sees, who owns it, and whether it is built', 'কী দেখে, কার দায়িত্ব, আর বানানো হয়েছে কিনা'],
  'gates.owner': ['Owner', 'ওনার'],
  'gates.status': ['Status', 'স্ট্যাটাস'],
  'gates.dash': [
    'A gate with no measurement shows a dash — a zero would read as "this gate caught nothing".',
    'যে গেটের কোনো পরিমাপ নেই সেটি একটি ড্যাশ দেখায় — শূন্য দিলে পড়া যেত "এই গেট কিছুই ধরেনি"।',
  ],

  'targets.title': ['Pilot targets', 'পাইলট টার্গেট'],
  'targets.q': ['Are we hitting the targets we set ourselves?', 'নিজেরা যে লক্ষ্য ঠিক করেছি, তা কি পূরণ হচ্ছে?'],
  'targets.measurable': ['measurable today', 'টি আজ মাপা যাচ্ছে'],
  'targets.target': ['target', 'টার্গেট'],

  'ledger.title': ['What we protected, and what it cost', 'কী রক্ষা করলাম, আর তার দাম কত'],
  'ledger.q': ['Both sides, always together', 'দুই দিক, সবসময় একসাথে'],
  'ledger.note': [
    "Replayed through risk-mw's own rule engine, not a copy of it. Every payment the engine would have stopped is counted against the seed world's own labels.",
    'risk-mw-এর নিজস্ব রুল ইঞ্জিন দিয়েই চালানো, তার নকল দিয়ে নয়। ইঞ্জিন যে পেমেন্টগুলো থামাত, সেগুলো seed জগতের নিজের লেবেলের বিপরীতে গোনা হয়েছে।',
  ],
  'ledger.denominator': ['denominator', 'ডিনমিনেটর'],

  'decisions.title': ['Where the decisions land', 'ডিসিশন কোথায় গিয়ে দাঁড়ায়'],
  'decisions.q': ['Out of every payment scored', 'স্কোর করা প্রতিটি পেমেন্টের মধ্যে'],
  'decisions.allow': ['Allowed', 'ছেড়ে দেওয়া'],
  'decisions.step_up': ['Stepped up', 'স্টেপ-আপ'],
  'decisions.delay': ['Delayed', 'দেরি করানো'],
  'decisions.hold': ['Held', 'আটকে রাখা'],
  'decisions.block': ['Blocked', 'ব্লক'],
  'decisions.noblock': [
    'No payment-scoring model reached block. The one path that can block is a device verdict, not a payment score.',
    'কোনো মডেল block পর্যন্ত যায়নি। অ্যানালিস্ট যে প্রাপককে মিউল বলে নিশ্চিত করেছেন, কেবল তার জন্যই decline আছে।',
  ],
  'codes.title': ['Which rules fired', 'কোন রুলগুলো ফায়ার করেছে'],
  'codes.q': ['And which could not', 'আর কোনগুলো জ্বলতেই পারেনি'],
  'codes.together': ['Fired together:', 'একসাথে ফায়ার করেছে:'],
  'codes.cannot': ['codes could not fire here.', 'টি রুল কোড এখানে ফায়ারই করতে পারেনি।'],

  'matrix.title': ['Are we stopping the right payments?', 'আমরা কি সঠিক পেমেন্টগুলোই থামাচ্ছি?'],
  'matrix.q': ["Against the seed world's own labels", 'seed জগতের নিজের লেবেলের বিপরীতে'],
  'matrix.stopped': ['we stopped', 'আমরা থামিয়েছি'],
  'matrix.through': ['we let through', 'ছেড়ে দিয়েছি'],
  'matrix.fraud': ['actually fraud', 'আসলে ফ্রড'],
  'matrix.genuine': ['actually genuine', 'আসলে জেনুইন'],
  'matrix.caught': ['caught', 'সঠিকভাবে ধরা'],
  'matrix.escaped': ['got through', 'বেরিয়ে গেছে'],
  'matrix.heldwrong': ['held for nothing', 'অযথা আটকানো'],
  'matrix.fine': ['went through fine', 'ঠিকঠাক গেছে'],
  'matrix.never': ['These two numbers are never shown apart.', 'এই দুটি সংখ্যা কখনো আলাদা করে দেখানো হয় না।'],
  'hist.title': ['How the risk scores are spread', 'রিস্ক স্কোরের বণ্টন'],
  'hist.q': ['Square-root heights, so small buckets stay visible', 'বর্গমূল উচ্চতা, যাতে ছোট বাকেটও দেখা যায়'],

  'volume.title': ['Volume, day by day', 'দৈনিক ভলিউম'],
  'volume.q': ['days, two paydays', 'দিন, দুটো পে-ডে'],
  'watch.title': ['Top of the watch-list', 'ওয়াচ-লিস্টের টপ'],
  'watch.q': ['The highest scores, in full on the Accounts view', 'সর্বোচ্চ স্কোরগুলো, পুরোটা অ্যাকাউন্ট পাতায়'],

  'accounts.title': ['Riskiest accounts', 'সবচেয়ে রিস্কি অ্যাকাউন্ট'],
  'accounts.q': ['Which accounts, and on what evidence?', 'কোন অ্যাকাউন্ট, আর কী এভিডেন্সে?'],
  'accounts.search': ['Search account, typology, ring or feature…   ( / )', 'অ্যাকাউন্ট, typology, রিং বা ফিচার খুঁজুন…   ( / )'],
  'accounts.threshold': ['hold threshold', 'হোল্ড থ্রেশহোল্ড'],
  'accounts.allroles': ['all roles', 'সব রোল'],
  'accounts.shown': ['shown', 'দেখাচ্ছে'],
  'accounts.scored_at': ['scored at or above', 'স্কোর করা, যার মান'],
  'accounts.account': ['Account', 'অ্যাকাউন্ট'],
  'accounts.role': ['Role', 'রোল'],
  'accounts.typology': ['Typology', 'টাইপোলজি'],
  'accounts.contrib': ['Top contributions', 'টপ কন্ট্রিবিউশন'],
  'accounts.none': ['No account matches these filters.', 'এই ফিল্টারে কোনো অ্যাকাউন্ট মেলেনি।'],
  'accounts.note': [
    'Every labelled account plus a fixed random sample, so the board does not reshuffle between builds. Click a row to open it.',
    'প্রতিটি লেবেলড অ্যাকাউন্ট আর একটি স্থির র‍্যান্ডম নমুনা, তাই তালিকা প্রতিবার বদলায় না। যেকোনো সারিতে ক্লিক করুন।',
  ],

  'models.title': ['Model health', 'মডেল হেলথ'],
  'models.q': ['Which model is degrading, and which gate did it miss?', 'কোন মডেল খারাপ হচ্ছে, আর কোন গেট মিস করেছে?'],
  'models.model': ['Model', 'মডেল'],
  'models.version': ['Version', 'ভার্সন'],
  'models.headline': ['Headline', 'হেডলাইন'],
  'models.gates': ['Gates', 'গেট'],
  'models.passed': ['all passed', 'সব পাস'],
  'models.missed': ['missed', 'মিস'],
  'models.thresholds': ['Thresholds in force', 'যে থ্রেশহোল্ডগুলো চালু আছে'],
  'models.thresholds.q': ['What the decisions above were made with', 'উপরের সিদ্ধান্তগুলো যা দিয়ে নেওয়া'],

  'policy.title': ['Policy checks', 'পলিসি চেক'],
  'policy.q': ['Did we keep our own rules?', 'আমরা কি নিজেদের পলিসি মেনেছি?'],
  'policy.holding': ['holding', 'ঠিক আছে'],
  'policy.notyet': ['not yet', 'এখনো নয়'],
  'policy.ofholding': ['holding', 'টি ঠিক আছে'],
  'policy.failing.one': ['policy check is not holding.', 'টি পলিসি চেক ঠিক নেই।'],
  'policy.failing.many': ['policy checks are not holding.', 'টি পলিসি চেক ঠিক নেই।'],

  'live.title': ['Live', 'লাইভ'],
  'live.q': ['Is the service answering, and can I open a case now?', 'সার্ভিস কি উত্তর দিচ্ছে, আর এখনই কেস খোলা যাবে?'],
  'live.open_account': ['open account', 'অ্যাকাউন্ট খুলুন'],
  'live.open_case': ['open case', 'কেস খুলুন'],
  'live.investigating': ['investigating…', 'তদন্ত চলছে…'],
  'live.stop': ['stop', 'থামান'],
  'live.known': ['known to the model', 'মডেলের চেনা'],
  'live.unknown': ['unknown to the model', 'মডেলের অচেনা'],
  'live.waiting': ['waiting for the first event…', 'প্রথম ইভেন্টের অপেক্ষায়…'],
  'live.events': ['events · a case takes about 45 seconds', 'টি ইভেন্ট · একটি কেসে প্রায় ৪৫ সেকেন্ড লাগে'],
  'live.ring_missing': ['demo ring unavailable', 'ডেমো রিং পাওয়া যাচ্ছে না'],
  'live.note': [
    'No Gemini route is called by a timer. Health is polled every 30s; everything else here happens because somebody clicked it.',
    'কোনো Gemini রুট টাইমারে ডাকা হয় না। হেলথ প্রতি ৩০ সেকেন্ডে দেখা হয়; বাকি সবকিছু কেউ ক্লিক করলে তবেই ঘটে।',
  ],

  'settings.appearance': ['Appearance', 'চেহারা'],
  'settings.remembered': ['Remembered in this browser', 'এই ব্রাউজারে মনে রাখা হয়'],
  'settings.theme': ['Theme', 'থিম'],
  'settings.density': ['Density', 'ডেনসিটি'],
  'settings.language': ['Language', 'ভাষা'],
  'settings.dark': ['Dark', 'ডার্ক'],
  'settings.light': ['Light', 'লাইট'],
  'settings.comfortable': ['Comfortable', 'আরামদায়ক'],
  'settings.compact': ['Compact', 'কমপ্যাক্ট'],
  'settings.note': [
    'Language, theme and palette are also in the sidebar. System follows your computer; dark suits a screen left open for hours, light suits printing.',
    'ভাষা, থিম আর প্যালেট সাইডবারেও আছে। "সিস্টেমের মতো" আপনার কম্পিউটারকে অনুসরণ করে; ঘণ্টার পর ঘণ্টা খোলা পর্দার জন্য ডার্ক ভালো, প্রিন্টের জন্য লাইট।',
  ],
  'settings.palette': ['Colour palette', 'রঙের প্যালেট'],
  'settings.palette.note': [
    'The same five palettes as the FinNest app. Status colours (held, blocked, allowed) never change with the palette.',
    'ফিননেস্ট অ্যাপের একই পাঁচটি প্যালেট। স্ট্যাটাসের রং (হোল্ড, ব্লক, অনুমোদিত) প্যালেটের সঙ্গে বদলায় না।',
  ],
  /* The preset names are the app's own (app_en.arb / app_bn.arb: presetTeal ... presetSlate). */
  'preset.teal': ['FinNest teal', 'ফিননেস্ট টিল'],
  'preset.padma': ['Padma green', 'পদ্মা সবুজ'],
  'preset.jamdani': ['Jamdani indigo', 'জামদানি নীল'],
  'preset.shapla': ['Shapla plum', 'শাপলা বেগুনি'],
  'preset.slate': ['Monsoon slate', 'বর্ষা স্লেট'],
  'nav.monitor': ['Monitor', 'নজরদারি'],
  'nav.investigate': ['Investigate', 'তদন্ত'],
  'nav.console': ['Settings', 'সেটিংস'],
  'nav.quick': ['Quick settings', 'দ্রুত সেটিংস'],
  'accounts.clear': ['Clear filters', 'ফিল্টার মুছুন'],
  'logs.showall': ['Show every call', 'সব কল দেখুন'],
  'settings.session': ['Session', 'সেশন'],
  'settings.session.q': ['One account, demo-grade', 'একটি অ্যাকাউন্ট, ডেমো মানের'],
  'settings.signedin': ['Signed in as', 'প্রবেশ করেছেন'],
  'settings.expires': ['Expires in', 'মেয়াদ শেষ'],
  'settings.build': ['This build', 'এই বিল্ড'],
  'settings.build.q': ['Where every number on the console came from', 'কনসোলের প্রতিটি সংখ্যা কোথা থেকে এসেছে'],

  'drawer.close': ['close', 'বন্ধ'],
  'drawer.txns': ['Transactions', 'লেনদেন'],
  'drawer.recent': ['showing the most recent 200', 'সাম্প্রতিক ২০০টি দেখানো হচ্ছে'],
  'drawer.shares': ['Shares a device with', 'ডিভাইস শেয়ার করে'],
  'drawer.accounts': ['account(s)', 'টি অ্যাকাউন্টের সাথে'],
  'drawer.when': ['When', 'কখন'],
  'drawer.type': ['Type', 'টাইপ'],
  'drawer.amount': ['Amount', 'অঙ্ক'],
  'drawer.counterparty': ['Counterparty', 'কাউন্টারপার্টি'],
  'drawer.ring': ['Ring', 'রিং'],
  'drawer.mulemodel': ['Mule model', 'মিউল মডেল'],

  'palette.placeholder': ['Jump to a view, or paste an account id…', 'কোনো পাতায় যান, বা একটি অ্যাকাউন্ট আইডি পেস্ট করুন…'],
  'palette.goto': ['Go to', 'যান'],
  'palette.openacct': ['Open account', 'অ্যাকাউন্ট খুলুন'],
  'palette.actions': ['Actions', 'অ্যাকশন'],
  'palette.nothing': ['Nothing matches.', 'কিছুই মেলেনি।'],
  'palette.move': ['move', 'চলাচল'],
  'palette.open': ['open', 'খুলুন'],
  'palette.close': ['close', 'বন্ধ'],
  'palette.rebuild': ['Rebuild the aggregate', 'অ্যাগ্রিগেট আবার বানান'],
  'palette.help': ['Keyboard shortcuts', 'কিবোর্ড শর্টকাট'],
  'palette.switchto': ['Switch to', 'বদলান'],
  'help.keyboard': ['Keyboard', 'কিবোর্ড'],


  /* --- the ⓘ explanations -------------------------------------------------
   * Written for an operations manager, not for the person who built the model.
   * Each one answers "what is this number and why should I care", in one breath.
   */
  'info.protected': [
    'The Taka value of payments we stopped that later turned out to be fraudulent. It is an upper bound: some of these would have failed anyway, and on synthetic data nothing is ever confirmed by a human.',
    'যে পেমেন্টগুলো আমরা থামিয়েছি এবং পরে ফ্রড বলে প্রমাণিত হয়েছে, তার মোট টাকা। এটি একটি সর্বোচ্চ সীমা: এর কিছু এমনিতেও ব্যর্থ হতো, আর সিনথেটিক ডেটায় কোনো কিছুই মানুষ যাচাই করে না।',
  ],
  'info.friction': [
    'The Taka value of payments we held that were perfectly genuine. This is what our caution costs real customers. Shown next to the catch rate on purpose: a catch rate without this number is a sales slide.',
    'যে পেমেন্টগুলো আমরা আটকেছি অথচ সেগুলো পুরোপুরি জেনুইন ছিল, তার মোট টাকা। আমাদের সতর্কতার দাম এটাই, আর সেটা গ্রাহক দেন। ক্যাচ রেটের পাশে ইচ্ছাকৃতভাবে রাখা: এই সংখ্যা ছাড়া ক্যাচ রেট একটা সেলস স্লাইড।',
  ],
  'info.catch': [
    'Of every fraudulent payment in the data, the share we stopped. Only two of the nine rules can fire on this dataset, so treat it as a floor rather than a score.',
    'ডেটার মোট ফ্রড পেমেন্টের মধ্যে আমরা কতটা থামাতে পেরেছি। এই ডেটাসেটে নয়টির মধ্যে মাত্র দুটো রুল ফায়ার করতে পারে, তাই এটাকে সর্বনিম্ন ধরে নিন, স্কোর নয়।',
  ],
  'info.fpr': [
    'Of every genuine payment, the share we held anyway. Every point here is a customer who could not pay. The pilot target is under one false delay per 1,000 customers per month.',
    'মোট জেনুইন পেমেন্টের মধ্যে আমরা কতটা অযথা আটকেছি। এখানকার প্রতিটি পয়েন্ট মানে একজন গ্রাহক টাকা পাঠাতে পারেননি। পাইলট টার্গেট: প্রতি ১,০০০ গ্রাহকে মাসে একটির কম।',
  ],
  'info.denominator': [
    'What the percentages above were divided by. A rate without its denominator can mean anything, so this console never shows one without the other.',
    'উপরের শতাংশগুলো কী দিয়ে ভাগ করা হয়েছে। ডিনমিনেটর ছাড়া যেকোনো রেট দিয়ে যা খুশি বোঝানো যায়, তাই এই কনসোল একটিকে অন্যটি ছাড়া দেখায় না।',
  ],
  'info.badge': [
    'What stands behind this figure. MODEL = a trained model. RULE = a deterministic rule. STUB = placeholder logic, not a model. OFF = built but not running. NO DATA = nothing measures this yet. SYNTHETIC = generated data.',
    'এই সংখ্যার পেছনে কী আছে। MODEL = ট্রেইন করা মডেল। RULE = ডিটারমিনিস্টিক রুল। STUB = অস্থায়ী লজিক, মডেল নয়। OFF = বানানো আছে কিন্তু চলছে না। NO DATA = এখনো কিছুই এটা মাপে না। SYNTHETIC = তৈরি করা ডেটা।',
  ],
  'info.gates': [
    'The defence is a ladder: money has to get past every gate. No gate is strong on its own; five gates each letting a third through stop all but one attempt in 243. A gate with a dash has no measurement, which is not the same as catching nothing.',
    'ডিফেন্সটা একটা মই: টাকাকে প্রতিটা গেট পেরোতে হয়। কোনো গেটই একা শক্তিশালী নয়; পাঁচটা গেট যদি প্রত্যেকে এক-তৃতীয়াংশ ছেড়ে দেয়, তাহলে ২৪৩টির মধ্যে একটি ছাড়া সব আটকে যায়। যে গেটে ড্যাশ আছে তার কোনো পরিমাপ নেই — "কিছুই ধরেনি" আর "মাপা হয়নি" এক জিনিস নয়।',
  ],
  'info.targets': [
    'The numbers the team promised itself in the defence plan. Four of five need a release path that does not exist yet, so they read NO DATA. A target nobody can see is a target nobody hits.',
    'ডিফেন্স প্ল্যানে টিম নিজেকে যে সংখ্যাগুলোর কথা দিয়েছে। পাঁচটির মধ্যে চারটির জন্য এমন একটা রিলিজ পাথ দরকার যা এখনো নেই, তাই সেগুলো NO DATA দেখায়। যে টার্গেট কেউ দেখতে পায় না, সেটা কেউ পূরণও করে না।',
  ],
  'info.matrix': [
    'Four outcomes, one table. Top-left is the work paying off; top-right is money that got away; bottom-left is a customer we inconvenienced for nothing. Moving any threshold trades one of these for another.',
    'চারটি ফলাফল, একটি টেবিল। উপরে-বাঁয়ে কাজটা ফল দিচ্ছে; উপরে-ডানে টাকা বেরিয়ে গেছে; নিচে-বাঁয়ে একজন গ্রাহককে আমরা অযথা ভুগিয়েছি। যেকোনো থ্রেশহোল্ড নাড়ালে একটার বদলে আরেকটা বাড়ে।',
  ],
  'info.histogram': [
    'How many payments landed in each risk band. Bar heights use a square root so a bucket with nine payments is still visible next to one with two thousand; the exact counts are printed below.',
    'প্রতিটি রিস্ক ব্যান্ডে কতগুলো পেমেন্ট পড়েছে। বারের উচ্চতা বর্গমূলে, যাতে নয়টি পেমেন্টের বাকেটও দুই হাজারের পাশে দেখা যায়; সঠিক সংখ্যাগুলো নিচে লেখা।',
  ],
  'info.codes': [
    'Each rule that fired, and how often. Seven of the nine could not fire at all here, because the dataset carries no call state, SIM change or screen share to trigger them — not because those rules never catch anything.',
    'যে রুলগুলো ফায়ার করেছে, আর কতবার। নয়টির মধ্যে সাতটি এখানে ফায়ারই করতে পারেনি, কারণ ডেটায় কল স্টেট, সিম বদল বা স্ক্রিন শেয়ার কিছুই নেই — এই নয় যে ওই রুলগুলো কখনো কিছু ধরে না।',
  ],
  'info.mule': [
    'A trained gradient-boosted model scores every account on how much it behaves like a cash-out mule: money in and straight out again, no salary, fresh links to an account that just had its SIM swapped.',
    'একটি ট্রেইন করা গ্র্যাডিয়েন্ট-বুস্টেড মডেল প্রতিটি অ্যাকাউন্টকে স্কোর করে — সেটি কতটা ক্যাশ-আউট মিউলের মতো আচরণ করে: টাকা ঢুকেই আবার বেরিয়ে যায়, বেতন নেই, সদ্য সিম বদলানো অ্যাকাউন্টের সাথে নতুন যোগাযোগ।',
  ],
  'info.shap': [
    'Which features pushed this account up or down, and by how much. Red bars raised the score, green lowered it. It is the model showing its working, not a guess at why.',
    'কোন ফিচারগুলো এই অ্যাকাউন্টের স্কোর বাড়িয়েছে বা কমিয়েছে, আর কতটা। লাল বার স্কোর বাড়িয়েছে, সবুজ কমিয়েছে। মডেল নিজের হিসাব দেখাচ্ছে, কেন হলো তার অনুমান নয়।',
  ],
  'info.typology': [
    'The pattern a ring follows. The scorer is near perfect on round-tripping and dormant-then-active rings and weak on fan-in-fan-out and OTP takeover, which is exactly the kind of gap a dashboard exists to show.',
    'একটি রিং কোন ধরনের প্যাটার্ন অনুসরণ করে। স্কোরার round-tripping আর dormant-then-active রিংয়ে প্রায় নিখুঁত, কিন্তু fan-in-fan-out আর OTP টেকওভারে দুর্বল — ঠিক এই ফাঁকটা দেখানোর জন্যই ড্যাশবোর্ড থাকে।',
  ],
  'info.policy': [
    'Rules the team wrote down about its own behaviour, checked against what the engine actually did. One of them is failing today and stays on the screen failing until somebody builds a release path.',
    'টিম নিজের আচরণ নিয়ে যে নিয়মগুলো লিখে রেখেছে, আর ইঞ্জিন আসলে কী করেছে তার সাথে মিলিয়ে দেখা। আজ এর একটি ঠিক নেই, আর যতদিন কেউ রিলিজ পাথ না বানায় ততদিন সেটা পর্দায় লাল হয়েই থাকবে।',
  ],
  'info.live': [
    'This panel talks to the deployed service, not to the stored aggregate. Every button here costs a real call, and the investigation runs Gemini, so nothing in it is ever triggered by a timer.',
    'এই প্যানেলটি ডিপ্লয় করা সার্ভিসের সাথে কথা বলে, জমানো অ্যাগ্রিগেটের সাথে নয়। এখানকার প্রতিটি বোতামে একটি আসল কল যায়, আর তদন্তে Gemini চলে — তাই এখানকার কিছুই টাইমারে চালু হয় না।',
  ],
  'info.weakest': [
    'Computed, not written by hand: the lowest per-typology recall in the eval files, plus whichever gates are unbuilt and which detectors are still placeholders.',
    'হাতে লেখা নয়, হিসাব করা: eval ফাইলগুলোর মধ্যে সবচেয়ে কম typology-ভিত্তিক recall, সাথে কোন গেটগুলো বানানো হয়নি আর কোন ডিটেক্টরগুলো এখনো অস্থায়ী।',
  ],
  'ring.focus': ['Focus the ring', 'রিংয়ে ফোকাস'],
  'ring.focus.hint': ['Fly the camera to the accounts the investigation implicated', 'তদন্ত যে অ্যাকাউন্টগুলোকে চিহ্নিত করেছে, ক্যামেরা সেখানে নিয়ে যান'],
  'ring.release': ['Release pins', 'পিন ছাড়ুন'],
  'ring.release.hint': ['Let every dragged account fall back into the simulation', 'টেনে রাখা অ্যাকাউন্টগুলো আবার সিমুলেশনে ছেড়ে দিন'],
  'ring.suspect': ['Implicated', 'চিহ্নিত'],
  'ring.context': ['context', 'প্রেক্ষাপট'],
  'ring.hot': ['touches the ring', 'রিং ছুঁয়েছে'],
  'ring.drag': ['Drag an account and it stays where you drop it', 'অ্যাকাউন্ট টেনে ছেড়ে দিলে সেখানেই থাকবে'],
  'ring.title': ['The ring, as the investigator traversed it', 'ইনভেস্টিগেটর যেভাবে রিংটা ঘুরে দেখেছে'],
  'ring.q': ['Drag to rotate · scroll to zoom · drag an account to pin it · click to open it', 'ঘোরাতে টানুন · জুম করতে স্ক্রল · অ্যাকাউন্ট টেনে পিন করুন · খুলতে ক্লিক'],
  'ring.seed': ['from', 'শুরু'],
  'ring.accounts': ['Accounts reached', 'যত অ্যাকাউন্টে পৌঁছেছে'],
  'ring.onlist': ['on the watch-list', 'ওয়াচ-লিস্টে'],
  'ring.links': ['Links found', 'যত সংযোগ পাওয়া গেছে'],
  'ring.money': ['are money', 'টাকার'],
  'ring.moved': ['Money along those links', 'ওই সংযোগগুলোয় টাকার পরিমাণ'],
  'ring.moved.sub': ['summed from the transactions themselves', 'লেনদেনগুলো থেকেই যোগ করা'],
  'ring.calls': ['Tool calls', 'টুল কল'],
  'ring.nodes': ['Accounts', 'অ্যাকাউন্ট'],
  'ring.edges': ['Links', 'সংযোগ'],
  'ring.foundby': ['found by', 'খুঁজে পেয়েছে'],
  'ring.hint': ['Hover an account for what it is and which call found it', 'কোনো অ্যাকাউন্টে মাউস নিন — সেটা কী আর কোন কল সেটা খুঁজে পেয়েছে'],
  'ring.failed': ['The graph could not be drawn', 'গ্রাফটি আঁকা যায়নি'],
  'ring.note': [
    'Every account and every link here came out of a named tool call in a recorded investigation — the graph each tool result carries with it. Nothing is inferred and no link exists because it would look better if it did. Hover anything to see which call found it.',
    'এখানকার প্রতিটি অ্যাকাউন্ট আর প্রতিটি সংযোগ একটি রেকর্ড করা তদন্তের নির্দিষ্ট টুল কল থেকে এসেছে — প্রতিটি টুল রেজাল্ট যে গ্রাফটুকু সাথে নিয়ে আসে। কিছুই অনুমান করা নয়, আর দেখতে ভালো লাগবে বলে কোনো সংযোগ বানানো হয়নি। যেকোনো কিছুতে মাউস নিলে দেখবেন কোন কল সেটা খুঁজে পেয়েছে।',
  ],
  'info.ring': [
    'Case Zero walks the entity graph one tool call at a time, and every result it gets back carries the nodes and links that call discovered. Replaying a recorded run and accumulating those gives the investigator\'s own view of the ring — which is why each node here names the call that found it.',
    'কেস জিরো এনটিটি গ্রাফে একটা একটা টুল কল দিয়ে এগোয়, আর প্রতিটি রেজাল্ট নিজের সাথে সেই কলের খুঁজে পাওয়া নোড আর সংযোগ নিয়ে আসে। একটি রেকর্ড করা রান রিপ্লে করে সেগুলো জমালে ইনভেস্টিগেটরের নিজের দেখা রিংটাই পাওয়া যায় — সেজন্যই এখানে প্রতিটি নোড বলে দেয় কোন কল তাকে খুঁজে পেয়েছে।',
  ],


  'view.logs': ['Audit log', 'অডিট লগ'],
  'view.logs.hint': ['Every call the service actually answered', 'সার্ভিস আসলে যে কলগুলোর উত্তর দিয়েছে'],
  'logs.title': ['The audit trail', 'অডিট ট্রেইল'],
  'logs.q': ['What happened, not what the replay says would happen', 'কী ঘটেছে — রিপ্লে যা বলে তা নয়'],
  'logs.note': [
    'Every call risk-mw answered is written to Firestore with the request as sent and the response as returned. Unlike the replay, real traffic carries call state, SIM swaps and scam scores, so rule codes the replay can never produce appear here.',
    'risk-mw যে কলগুলোর উত্তর দিয়েছে, প্রতিটি Firestore-এ লেখা হয় — রিকোয়েস্ট যেভাবে গেছে আর রেসপন্স যেভাবে ফিরেছে। রিপ্লের বিপরীতে আসল ট্রাফিকে কল স্টেট, সিম বদল আর স্ক্যাম স্কোর থাকে, তাই রিপ্লে যে রুল কোডগুলো কখনো বানাতে পারে না, সেগুলোও এখানে আসে।',
  ],
  'logs.unavailable': ['The audit trail could not be read', 'অডিট ট্রেইল পড়া যায়নি'],
  'logs.when': ['When', 'কখন'],
  'logs.event': ['What was checked', 'কী চেক হয়েছে'],
  'logs.who': ['Who', 'কে'],
  'logs.outcome': ['Outcome', 'ফলাফল'],
  'logs.txn': ['Transaction', 'লেনদেন'],
  'logs.flags': ['Flags', 'ফ্ল্যাগ'],
  'logs.took': ['Took', 'সময়'],
  'logs.allkinds': ['all calls', 'সব কল'],
  'logs.alldecisions': ['all outcomes', 'সব ফলাফল'],
  'logs.returned': ['rows', 'টি সারি'],
  'logs.facetnote': ['counts are over the rows loaded here', 'গণনা এখানে লোড করা সারিগুলোর'],
  'logs.more': ['load', 'আরও'],
  'logs.of': ['of', '/'],
  'logs.loaded': ['loaded', 'লোড করা'],
  'logs.end': ['that is all of it', 'এটুকুই আছে'],
  'logs.raw': ['The document as it was written', 'ডকুমেন্টটি যেভাবে লেখা হয়েছিল'],
  'logs.none': ['No call matches this filter.', 'এই ফিল্টারে কোনো কল মেলেনি।'],
  'info.audit': [
    'The replay elsewhere in this console says what the rules would decide about the seed world. This says what the deployed service actually answered — the same engine, but with real flags, so rules the seed can never trigger show up here.',
    'এই কনসোলের অন্য জায়গার রিপ্লে বলে seed জগৎ নিয়ে রুল কী সিদ্ধান্ত নিত। এটি বলে ডিপ্লয় করা সার্ভিস আসলে কী উত্তর দিয়েছে — একই ইঞ্জিন, কিন্তু আসল ফ্ল্যাগ সহ, তাই seed যে রুলগুলো কখনো জ্বালাতে পারে না সেগুলোও এখানে দেখা যায়।',
  ],

  'audit.outcome': ['Outcome', 'ফলাফল'],
  'audit.reasons': ['Why — exactly as the customer was told', 'কেন — গ্রাহককে যা বলা হয়েছিল, হুবহু'],
  'audit.reasons.note': [
    'These are the stored strings, not a fresh render. If the wording changed since, this still shows what was shown.',
    'এগুলো জমা থাকা স্ট্রিং, নতুন করে বানানো নয়। পরে লেখা বদলালেও এখানে যা দেখানো হয়েছিল সেটাই থাকবে।',
  ],
  'insight.title': ["Gemini's reading — for the analyst, not shown to the customer", 'জেমিনাইয়ের বিশ্লেষণ — বিশ্লেষকের জন্য, গ্রাহককে দেখানো হয়নি'],
  'insight.loading': ['Gemini is reading this decision…', 'জেমিনাই সিদ্ধান্তটি পড়ছে…'],
  'insight.checks': ['What to check next', 'এরপর যা যাচাই করবেন'],
  'insight.cached': ['read earlier, from the cache', 'আগে পড়া, ক্যাশ থেকে'],
  'insight.fresh': ['read just now in {s} s', 'এইমাত্র {s} সেকেন্ডে পড়া'],
  'insight.retry': ['Try again', 'আবার চেষ্টা করুন'],
  'insight.failed': ['The console could not fetch the reading:', 'কনসোল বিশ্লেষণটি আনতে পারেনি:'],
  'insight.off.timeout': ['Gemini took too long to answer.', 'জেমিনাই উত্তর দিতে বেশি সময় নিয়েছে।'],
  'insight.off.genai_error': ['Gemini could not answer just now.', 'জেমিনাই এই মুহূর্তে উত্তর দিতে পারেনি।'],
  'insight.off.genai_disabled': [
    'Gemini is switched off on this console, so there is no reading. The reasons below are complete.',
    'এই কনসোলে জেমিনাই বন্ধ, তাই কোনো বিশ্লেষণ নেই। নিচের কারণগুলো সম্পূর্ণ।',
  ],
  'insight.off.spend_cap': [
    "The console's Gemini budget is used up until it restarts.",
    'কনসোলের জেমিনাই বাজেট শেষ; রিস্টার্ট না হওয়া পর্যন্ত বিশ্লেষণ বন্ধ।',
  ],
  'insight.off.invalid': [
    "Gemini's answer did not match the stored facts twice, so it is not shown.",
    'জেমিনাইয়ের উত্তর দুইবার জমা থাকা তথ্যের সাথে মেলেনি, তাই দেখানো হচ্ছে না।',
  ],
  'insight.off.not_a_score': ['Only a scored payment with reasons gets a reading.', 'শুধু কারণসহ স্কোর হওয়া লেনদেনের বিশ্লেষণ হয়।'],
  'insight.off.nothing_fired': ['Only a scored payment with reasons gets a reading.', 'শুধু কারণসহ স্কোর হওয়া লেনদেনের বিশ্লেষণ হয়।'],
  'insight.off.unreadable': [
    'This row is not in the shape a reading needs, so Gemini was not asked.',
    'এই সারিটি বিশ্লেষণের উপযোগী আকারে নেই, তাই জেমিনাইকে জিজ্ঞেস করা হয়নি।',
  ],
  'insight.off.other': ['No reading ({reason}).', 'কোনো বিশ্লেষণ নেই ({reason})।'],
  'insight.note': [
    "Gemini reads the stored decision: its reasons, their weights, what each reason asks for, and where each signal came from. It is not given the phone's app list or any id but the accounts'. Before it is shown, every code and number it writes is checked against this row, and a reading that fails twice is not shown. It explains the decision and never changes it. The customer's reasons below are the record.",
    'জেমিনাই জমা থাকা সিদ্ধান্তটি পড়ে: কারণগুলো, তাদের ওজন, প্রতিটি কারণ কী চেয়েছে, আর প্রতিটি সিগন্যাল কোথা থেকে এসেছে। ফোনের অ্যাপ-তালিকা বা অ্যাকাউন্ট ছাড়া অন্য কোনো আইডি তাকে দেওয়া হয় না। দেখানোর আগে তার লেখা প্রতিটি কোড ও সংখ্যা এই সারির সাথে মিলিয়ে দেখা হয়; দুইবার না মিললে দেখানো হয় না। এটি সিদ্ধান্ত ব্যাখ্যা করে, কখনো বদলায় না। নিচের গ্রাহকের কারণগুলোই আসল রেকর্ড।',
  ],
  'audit.actions': ['What the app was told to do', 'অ্যাপকে যা করতে বলা হয়েছিল'],
  'audit.request': ['The request as scored', 'যে রিকোয়েস্টের উপর স্কোর হয়েছে'],
  'audit.request.note': [
    'Not the body the app posted: risk-mw records the request after merging the device signals, the stored app-safety verdict and the scam session, so this is what the rules actually read.',
    'অ্যাপ যে বডি পাঠিয়েছে ঠিক সেটা নয় — risk-mw ডিভাইস সিগন্যাল, জমা থাকা অ্যাপ-সেফটি ভারডিক্ট আর স্ক্যাম সেশন মিশিয়ে নেওয়ার পরে রিকোয়েস্টটা লেখে, তাই রুলগুলো আসলে এটাই পড়েছে।',
  ],
  'audit.response': ['The response', 'রেসপন্স'],
  'audit.flags': ['Signals that were on', 'যে সিগন্যালগুলো চালু ছিল'],
  'audit.flags.note': [
    'Some of these are demo-panel switches standing in for telephony a phone on a stage cannot produce; others — the app-safety verdict, the scam score, the payee score — were measured by the services themselves. The response carries signal_sources where it knows which was which.',
    'এগুলোর কিছু ডেমো প্যানেলের সুইচ — মঞ্চের ফোন যে টেলিকম সিগন্যাল বানাতে পারে না, তার বদলি; আর কিছু সার্ভিসগুলো নিজেরাই মেপেছে — অ্যাপ-সেফটি ভারডিক্ট, স্ক্যাম স্কোর, পেয়ি স্কোর। কোনটা কোনটা, রেসপন্সের signal_sources সেটা জানা থাকলে বলে দেয়।',
  ],
  'audit.showraw': ['show the stored document', 'জমা থাকা ডকুমেন্ট দেখুন'],
  'audit.redacted': [
    'Redacted for display: a caller number keeps its last three digits, a transcript its first forty characters, an installed-app list only its length. The reasons the customer was shown are untouched. Nothing is removed from storage.',
    'দেখানোর জন্য ঢেকে দেওয়া: কলারের নম্বরের শেষ তিনটি অঙ্ক থাকে, ট্রান্সক্রিপ্টের প্রথম চল্লিশ অক্ষর, ইনস্টল করা অ্যাপের শুধু সংখ্যাটা। গ্রাহককে যে কারণগুলো দেখানো হয়েছিল, সেগুলো অক্ষত। জমা থাকা ডকুমেন্ট থেকে কিছুই মোছা হয়নি।',
  ],
  'audit.hideraw': ['hide the document', 'ডকুমেন্ট লুকান'],
  'audit.copy': ['copy JSON', 'JSON কপি'],
  'logs.live': ['live', 'লাইভ'],
  'logs.paused': ['paused', 'থামানো'],
  'logs.ago': ['Ago', 'কত আগে'],
  'logs.updated': ['updated', 'আপডেট'],
  'logs.new': ['new', 'নতুন'],
  'logs.model': ['Model', 'মডেল'],
  'logs.session': ['Session', 'সেশন'],

  'view.cases': ['Case Zero', 'কেস জিরো'],
  'view.cases.hint': ['What the investigator found, and what we did about it', 'ইনভেস্টিগেটর যা পেয়েছে, আর আমরা তা নিয়ে কী করেছি'],
  'view.campaigns': ['Incidents', 'ঘটনা'],
  'view.campaigns.hint': ['Which burst is a campaign, and the evidence behind it', 'কোন ঘটনা প্রতারণা অভিযান, আর তার পেছনের প্রমাণ'],
  'view.cashout': ['Cash-out map', 'ক্যাশ-আউট ম্যাপ'],
  'view.cashout.hint': ['Where confirmed mules cash out, and who else did', 'নিশ্চিত মিউলরা কোথায় ক্যাশ-আউট করে, আর সেখানে আর কে করেছে'],

  'cases.title': ['Case Zero, and the gap it leaves', 'কেস জিরো, আর যে ফাঁকটা থেকে যায়'],
  'cases.q': ['The investigator names accounts. The payment path does not read the list.', 'ইনভেস্টিগেটর অ্যাকাউন্টের নাম বলে। পেমেন্ট পাথ সেই লিস্ট পড়ে না।'],
  'cases.held': ['cases held', 'টি কেস আছে'],
  'cases.unreachable': ['investigator unreachable', 'ইনভেস্টিগেটরে পৌঁছানো যাচ্ছে না'],
  'cases.watchlisted': ['Accounts on the watch-list', 'ওয়াচ-লিস্টে থাকা অ্যাকাউন্ট'],
  'cases.watchlisted.sub': ['named by a finished investigation', 'শেষ হওয়া তদন্ত যাদের নাম বলেছে'],
  'cases.payments': ['Payments that reached them', 'তাদের কাছে পৌঁছানো পেমেন্ট'],
  'cases.stopped': ['Stopped by the rules', 'রুল যতগুলো থামিয়েছে'],
  'cases.ofthose': ['of those payments', 'ওই পেমেন্টগুলোর'],
  'cases.missed': ['Went through anyway', 'তবু চলে গেছে'],
  'cases.missed.sub': ['to an account already implicated', 'আগেই চিহ্নিত অ্যাকাউন্টে'],
  'cases.gap.title': ['This is gate G4, measured.', 'এটাই G4 গেট, মেপে দেখা।'],
  'cases.gap.body': [
    'The payment path reads the mule model, not this list. The model scores most of these accounts near zero — the investigator named them from money flow and shared identities, which the scorer does not see. Until G4 reads the watch-list, an investigation finishing changes nothing at the till.',
    'পেমেন্ট পাথ মিউল মডেল পড়ে, এই লিস্ট নয়। মডেল এই অ্যাকাউন্টগুলোর বেশির ভাগকেই প্রায় শূন্য স্কোর দেয় — ইনভেস্টিগেটর এদের নাম বলেছে টাকার প্রবাহ আর শেয়ার করা পরিচয় দেখে, যা স্কোরার দেখে না। G4 যতদিন ওয়াচ-লিস্ট না পড়ে, ততদিন একটা তদন্ত শেষ হলেও টিলে কিছুই বদলায় না।',
  ],
  'cases.watchlist': ['The watch-list', 'ওয়াচ-লিস্ট'],
  'cases.watchlist.q': ['Each account, the facts behind it, and what the payment path did', 'প্রতিটি অ্যাকাউন্ট, তার পেছনের ফ্যাক্ট, আর পেমেন্ট পাথ কী করেছে'],
  'cases.watchlist.note': [
    'Click a row for the facts the investigator cited. The model score beside it is the mule scorer, which is what the payment path actually reads.',
    'ফ্যাক্টগুলো দেখতে যেকোনো সারিতে ক্লিক করুন। পাশের মডেল স্কোরটি মিউল স্কোরারের — পেমেন্ট পাথ আসলে এটাই পড়ে।',
  ],
  'cases.col.payments': ['payments', 'পেমেন্ট'],
  'cases.col.stopped': ['stopped', 'থেমেছে'],
  'cases.col.case': ['case', 'কেস'],
  'cases.facts': ['What the investigator cited', 'ইনভেস্টিগেটর যা উদ্ধৃত করেছে'],
  'cases.approved': ['analyst approved', 'অ্যানালিস্ট অনুমোদিত'],
  'cases.unapproved': ['not yet reviewed by an analyst', 'অ্যানালিস্ট এখনো দেখেননি'],
  'cases.replay': ['Recorded agent run', 'রেকর্ড করা এজেন্ট রান'],
  'cases.replay.q': ['The whole tool loop, with no Gemini spend', 'পুরো টুল লুপ, কোনো Gemini খরচ ছাড়াই'],
  'cases.replay.load': ['load the replay', 'রিপ্লে লোড করুন'],
  'cases.replay.hint': [
    'A recorded investigation, replayed from Case Zero. Nothing here calls the model, so it is safe to open during a demo.',
    'কেস জিরো থেকে রেকর্ড করা একটি তদন্ত। এখানে কিছুই মডেলকে ডাকে না, তাই ডেমোর সময় নিরাপদে খোলা যায়।',
  ],

  'casefile.title': ['Case file', 'কেস ফাইল'],
  'casefile.q': ['Everything the investigation found, and who decided what', 'তদন্তে যা পাওয়া গেছে, আর কোন সিদ্ধান্ত কে নিয়েছে'],
  'casefile.open': ['Open the case file', 'কেস ফাইল খুলুন'],
  'casefile.close': ['Close the case file', 'কেস ফাইল বন্ধ করুন'],
  'casefile.live': ['Live case', 'লাইভ কেস'],
  'casefile.recorded': ['Recorded run', 'রেকর্ড করা রান'],
  'casefile.status.done': ['Complete', 'সম্পূর্ণ'],
  'casefile.status.degraded': ['Complete, unproven claims removed', 'সম্পূর্ণ, প্রমাণহীন দাবি বাদ'],
  'casefile.status.failed': ['Failed', 'ব্যর্থ'],
  'casefile.status.unknown': ['Status unknown', 'অবস্থা অজানা'],
  'casefile.seed': ['Started from', 'শুরু'],
  'casefile.asof': ['as of', 'সময়'],
  'casefile.action': ['Final action', 'চূড়ান্ত পদক্ষেপ'],
  'casefile.floor': ["Code's minimum from the score", 'স্কোর থেকে কোডের ন্যূনতম'],
  'casefile.score': ['Mule model score', 'মিউল মডেলের স্কোর'],
  'casefile.proposed': ['Investigator proposed', 'তদন্তকারীর প্রস্তাব'],
  'casefile.escalated': ['raised one step above the minimum, with a proven red flag', 'প্রমাণিত রেড ফ্ল্যাগসহ ন্যূনতমের চেয়ে এক ধাপ বেশি'],
  'casefile.not_escalated': ['not raised above the minimum', 'ন্যূনতমের ওপরে তোলা হয়নি'],
  'casefile.typology': ['Pattern', 'ধরন'],
  'casefile.narrative': ['Summary', 'সারসংক্ষেপ'],
  'casefile.narrative.other': ['Read it in Bangla', 'ইংরেজিতে পড়ুন'],
  'casefile.members': ['Accounts in the ring', 'রিংয়ের অ্যাকাউন্ট'],
  'casefile.col.evidence': ['Evidence (tool calls)', 'প্রমাণ (টুল কল)'],
  'casefile.flags': ['Red flags', 'রেড ফ্ল্যাগ'],
  'casefile.col.flag': ['Flag', 'ফ্ল্যাগ'],
  'casefile.col.wrote': ['What the investigator wrote', 'তদন্তকারী যা লিখেছে'],
  'casefile.timeline': ['Timeline', 'সময়রেখা'],
  'casefile.col.time': ['Time', 'সময়'],
  'casefile.col.event': ['What happened', 'কী ঘটেছে'],
  'casefile.excluded': ['Checked and ruled out', 'যাচাই করে বাদ দেওয়া'],
  'casefile.col.reason': ['Why', 'কেন'],
  'casefile.reasons': ['Why the mule model scored the starting account', 'মিউল মডেল শুরুর অ্যাকাউন্টকে কেন এই স্কোর দিয়েছে'],
  'casefile.col.feature': ['Feature', 'ফিচার'],
  'casefile.col.value': ['Value', 'মান'],
  'casefile.col.contribution': ['Pushed the score', 'স্কোরে প্রভাব'],
  'casefile.checks': ['Checks code ran', 'কোডের যাচাই'],
  'casefile.check.citations.ok': ['Every id, amount and time matched a tool output on the first pass', 'প্রথমবারেই প্রতিটা আইডি, টাকা ও সময় টুলের ফলাফলের সাথে মিলেছে'],
  'casefile.check.citations.retry': ['Some claims did not match a tool output at first; the writer was asked once more', 'প্রথমবার কিছু দাবি টুলের ফলাফলের সাথে মেলেনি; লেখককে আরেকবার লিখতে বলা হয়েছে'],
  'casefile.check.kept': ['Membership re-checked, accounts kept', 'সদস্যপদ আবার যাচাই, রাখা অ্যাকাউন্ট'],
  'casefile.check.moved': ['moved to ruled out', 'বাদের তালিকায় সরানো'],
  'casefile.check.flags': ['Red flags removed for weak evidence', 'দুর্বল প্রমাণের জন্য বাদ দেওয়া রেড ফ্ল্যাগ'],
  'casefile.run': ['The run', 'রান'],
  'casefile.run.calls': ['Tool calls', 'টুল কল'],
  'casefile.run.turns': ['Gemini turns', 'Gemini টার্ন'],
  'casefile.run.tokens': ['tokens in / out', 'টোকেন ইন / আউট'],
  'casefile.run.cost': ['Cost', 'খরচ'],
  'casefile.run.time': ['Time', 'সময়'],
  'casefile.run.llm': ['Gemini', 'জেমিনাই'],
  'casefile.run.llm_time': ['Gemini time', 'Gemini-র সময়'],
  'casefile.run.seconds': ['s', 'সে.'],
  'casefile.path': ['The investigation path, call by call', 'তদন্তের পথ, কল ধরে ধরে'],
  'casefile.limitations': ['Limitations', 'সীমাবদ্ধতা'],
  'casefile.raw': ['The raw events', 'মূল ইভেন্টগুলো'],

  'info.casezero': [
    'Case Zero is the Gemini investigator. It starts from one flagged account, calls graph tools, and writes a case naming every ring member with the tool call that proves it. Its output is a watch-list of payees.',
    'কেস জিরো হলো Gemini ইনভেস্টিগেটর। এটি একটি ফ্ল্যাগ করা অ্যাকাউন্ট থেকে শুরু করে, গ্রাফ টুল ডাকে, আর এমন একটি কেস লেখে যেখানে রিংয়ের প্রতিটি সদস্যের নাম আছে — সাথে যে টুল কল সেটা প্রমাণ করে। এর ফল একটি প্রাপকের ওয়াচ-লিস্ট।',
  ],
  'info.gap': [
    'Payments in the replayed dataset whose recipient was already on the watch-list. The rule engine never consulted that list; it only reads the mule model score, which rates most of these accounts near zero.',
    'রিপ্লে করা ডেটাসেটের যেসব পেমেন্টের প্রাপক আগে থেকেই ওয়াচ-লিস্টে ছিল। রুল ইঞ্জিন ওই লিস্ট কখনো দেখেনি; এটি কেবল মিউল মডেলের স্কোর পড়ে, যা এই অ্যাকাউন্টগুলোর বেশির ভাগকে প্রায় শূন্য দেয়।',
  ],
  'info.disagree': [
    'The investigator and the scorer disagree here on purpose. The scorer learns from one account\'s own behaviour; the investigator follows money between accounts and shared identities. A second-layer mule can look blameless on its own and obvious in the chain.',
    'এখানে ইনভেস্টিগেটর আর স্কোরার ইচ্ছাকৃতভাবেই একমত নয়। স্কোরার একটি অ্যাকাউন্টের নিজের আচরণ থেকে শেখে; ইনভেস্টিগেটর অ্যাকাউন্টের মধ্যে টাকার চলাচল আর শেয়ার করা পরিচয় অনুসরণ করে। দ্বিতীয় স্তরের একটি মিউল একা দেখলে নিরীহ, চেইনে দেখলে স্পষ্ট।',
  ],
  'info.replay': [
    'A recorded run of the investigator: every tool call, its result, the draft, the validator and the final report. Replaying it costs nothing, which is why it exists.',
    'ইনভেস্টিগেটরের একটি রেকর্ড করা রান: প্রতিটি টুল কল, তার ফল, খসড়া, ভ্যালিডেটর আর চূড়ান্ত রিপোর্ট। রিপ্লে করতে কোনো খরচ নেই — সেজন্যই এটা আছে।',
  ],

  'daily.scored': ['scored', 'স্কোর করা'],
  'daily.stopped': ['stopped', 'থামানো'],
  'daily.hover': ['hover a day for its numbers', 'যেকোনো দিনের উপর মাউস নিন'],
  'typology.title': ['Where the model is weak', 'মডেল কোথায় দুর্বল'],
  'typology.q': ['Ring-level recall by typology — click one to filter the accounts', 'টাইপোলজি অনুযায়ী ring-level recall — ফিল্টার করতে ক্লিক করুন'],
  'typology.label': ['ring recall @50', 'রিং রিকল @৫০'],
  'typology.foot': ['0 · 0.75 is the bar for a ring counted as recovered · 1', '০ · ০.৭৫ হলো একটি রিংকে উদ্ধার হওয়া ধরার সীমা · ১'],
  'share.title': ['The decision mix', 'ডিসিশন মিক্স'],

  'loading': ['loading…', 'লোড হচ্ছে…'],
  'error.load': ['Could not load the aggregate:', 'অ্যাগ্রিগেট লোড করা যায়নি:'],
  'error.running': ['Is the service running?', 'সার্ভিসটি কি চলছে?'],
  /* --- added with the design-system pass: every chrome string has a Bangla sibling --- */
  'badge.MODEL': ['model', 'মডেল'],
  'badge.RULE': ['rule', 'রুল'],
  'badge.STUB': ['stub', 'স্টাব'],
  'badge.OFF': ['off', 'বন্ধ'],
  'badge.NONE': ['not built', 'বানানো হয়নি'],
  'badge.NO DATA': ['no data', 'ডেটা নেই'],
  'badge.SYNTHETIC': ['synthetic', 'সিনথেটিক'],
  'badge.LIVE': ['live', 'লাইভ'],
  'band.low': ['low', 'কম'],
  'band.medium': ['medium', 'মাঝারি'],
  'band.high': ['high', 'বেশি'],
  'band.critical': ['critical', 'গুরুতর'],

  'top.failing': ['policy checks failing', 'টি পলিসি চেক ব্যর্থ'],
  'top.synthetic.title': ['Nothing here describes a real customer', 'এখানে কিছুই কোনো বাস্তব গ্রাহকের কথা নয়'],
  'top.built.title': ['Aggregate built', 'অ্যাগ্রিগেট তৈরি'],
  'top.rebuild.title': ['Recompute the aggregate from the seed world', 'seed জগৎ থেকে অ্যাগ্রিগেট আবার হিসাব করুন'],
  'top.menu': ['Views', 'ভিউ'],

  'settings.system': ['System', 'সিস্টেমের মতো'],
  'settings.token': ['Token', 'টোকেন'],
  'settings.token.value': ['HMAC-SHA256, server-signed', 'HMAC-SHA256, সার্ভারে সই করা'],
  'settings.notprod.title': ['This is not production sign-in.', 'এটি প্রোডাকশনের সাইন-ইন নয়।'],
  'settings.notprod.body': [
    'One account, no roles, no reset, no lockout. The password is checked on the server with PBKDF2 and the token is signed and expires: enough to keep the console off a public URL. Production is Firebase Auth with custom claims (analyst, manager, scientist, compliance) checked on every route. See api/auth.py.',
    'একটি মাত্র অ্যাকাউন্ট; কোনো রোল, রিসেট বা লকআউট নেই। পাসওয়ার্ড সার্ভারে PBKDF2 দিয়ে যাচাই হয়, টোকেন সই করা এবং মেয়াদ শেষ হয়: কনসোলকে পাবলিক URL থেকে আড়ালে রাখতে এটুকুই যথেষ্ট। প্রোডাকশনে হবে Firebase Auth ও custom claims (analyst, manager, scientist, compliance), প্রতিটি রুটে যাচাই করা। দেখুন api/auth.py।',
  ],
  'settings.row.built': ['Aggregate built', 'অ্যাগ্রিগেট তৈরি'],
  'settings.row.seed': ['Seed', 'সিড'],
  'settings.row.checksum': ['checksum', 'চেকসাম'],
  'settings.row.engine': ['Rule engine', 'রুল ইঞ্জিন'],
  'settings.row.mule': ['Mule model', 'মিউল মডেল'],
  'settings.row.data': ['Data', 'ডেটা'],
  'settings.row.data.value': ['a generated world, not a real ledger', 'তৈরি করা একটি জগৎ, বাস্তব লেজার নয়'],
  'unit.hours': ['h', 'ঘণ্টা'],
  'unit.seconds': ['s', 'সে'],

  'models.eval': ['eval', 'ইভ্যাল'],
  'models.cost': ['eval cost', 'ইভ্যাল খরচ'],
  'models.thresholds.note': [
    "Read live from {service}'s settings, not copied into this console. Changing one there changes this page.",
    '{service}-এর সেটিংস থেকে সরাসরি পড়া, এই কনসোলে কপি করা নয়। সেখানে একটি বদলালে এই পাতাও বদলায়।',
  ],
  'matrix.sentence': [
    'With only two of the nine rules able to fire, {catch} fraudulent payments stopped and {miss} got through: a {rate} catch rate. Of the {genuine} genuine payments, {fp} were held: {fpr}.',
    'নয়টি রুলের মধ্যে কেবল দুটি ফায়ার করতে পারে; তাতেই {catch}টি ফ্রড পেমেন্ট থেমেছে আর {miss}টি চলে গেছে: ক্যাচ রেট {rate}। {genuine}টি জেনুইন পেমেন্টের মধ্যে {fp}টি আটকানো হয়েছে: {fpr}।',
  ],
  'hist.payments': ['payments', 'টি পেমেন্ট'],
  'accounts.unlabelled': ['unlabelled', 'লেবেল নেই'],
  'live.checking': ['checking…', 'যাচাই হচ্ছে…'],
  'live.confidence': ['confidence', 'কনফিডেন্স'],
  'audit.newpayee': ['new payee', 'নতুন প্রাপক'],
  'audit.session': ['session', 'সেশন'],
  'audit.user': ['user', 'ইউজার'],
  'audit.risk': ['risk', 'ঝুঁকি'],
  'audit.weight': ['weight', 'ওজন'],

  /* The App Safety section of the audit drawer: the check result the phone sent with a score. */
  'appsafety.title': ["App Safety — the phone's report", 'অ্যাপ সেফটি — ফোনের রিপোর্ট'],
  'appsafety.note': [
    'What the phone sent with this score: the result of its last App Safety Check. It can only raise the verdict the rules read, never lower it, and it counts only until its valid-until time. risk-mw keeps the most severe findings and counts the rest. The app_safety_verdict signal below is the verdict the rules actually used.',
    'এই স্কোরের সাথে ফোন যা পাঠিয়েছে: তার শেষ অ্যাপ সেফটি চেকের ফল। এটি রুলগুলোর পড়া ভারডিক্ট কেবল বাড়াতে পারে, কখনো কমাতে পারে না, আর মেয়াদ থাকা পর্যন্তই গোনা হয়। risk-mw সবচেয়ে গুরুতর ফাইন্ডিংগুলো রাখে, বাকিগুলো শুধু গোনে। নিচের app_safety_verdict সিগন্যালটিই রুলগুলো আসলে ব্যবহার করেছে।',
  ],
  'appsafety.verdict.SAFE': ['Safe', 'নিরাপদ'],
  'appsafety.verdict.CAUTION': ['Caution', 'সতর্কতা'],
  'appsafety.verdict.BLOCK': ['Block', 'ব্লক'],
  'appsafety.simulated': ['Simulated — a demo check, not a real one', 'সিমুলেটেড — ডেমো চেক, আসল নয়'],
  'appsafety.source': ['source', 'উৎস'],
  'appsafety.source.check': ['the check the phone last ran', 'ফোনের সর্বশেষ চালানো চেক'],
  'appsafety.source.latest': [
    "the server's stored verdict, fetched when the phone's own check failed",
    'সার্ভারে জমা থাকা ভারডিক্ট, ফোনের নিজের চেক ব্যর্থ হওয়ায় আনা',
  ],
  'appsafety.attestation': ['attestation', 'অ্যাটেস্টেশন'],
  'appsafety.att.none': ['no integrity token was sent', 'কোনো ইন্টেগ্রিটি টোকেন পাঠানো হয়নি'],
  'appsafety.att.failed': ['the integrity token could not be verified', 'ইন্টেগ্রিটি টোকেন যাচাই করা যায়নি'],
  'appsafety.att.tampered': [
    'not the app FinNest ships: modified, re-signed or another package',
    'ফিননেস্টের পাঠানো অ্যাপ নয়: বদলানো, নতুন করে সই করা বা অন্য প্যাকেজ',
  ],
  'appsafety.att.mismatch': ['the token was made for a different app list', 'টোকেনটি অন্য একটি অ্যাপ-তালিকার জন্য বানানো'],
  'appsafety.att.unbound': ['the token is not tied to this app list', 'টোকেনটি এই অ্যাপ-তালিকার সাথে বাঁধা নয়'],
  'appsafety.att.virtual': ['Google vouches only for a virtual device (an emulator)', 'গুগল কেবল একটি ভার্চুয়াল ডিভাইস (এমুলেটর) হিসেবে নিশ্চিত করেছে'],
  'appsafety.att.basic': ['basic integrity only: the phone may be rooted or uncertified', 'শুধু বেসিক ইন্টেগ্রিটি: ফোনটি রুট করা বা অসার্টিফায়েড হতে পারে'],
  'appsafety.att.device': ['device integrity: a genuine Android phone', 'ডিভাইস ইন্টেগ্রিটি: আসল অ্যান্ড্রয়েড ফোন'],
  'appsafety.att.strong': ['strong integrity: a genuine phone with recent security updates', 'স্ট্রং ইন্টেগ্রিটি: সাম্প্রতিক সিকিউরিটি আপডেটসহ আসল ফোন'],
  'appsafety.checked': ['checked', 'চেক করা হয়েছে'],
  'appsafety.valid': ['valid until', 'বৈধ যতক্ষণ'],
  'appsafety.check': ['check id', 'চেক আইডি'],
  'appsafety.findings': ['What the check found', 'চেকে যা পাওয়া গেছে'],
  'appsafety.findings.none': ['No findings in the report.', 'রিপোর্টে কোনো ফাইন্ডিং নেই।'],
  'appsafety.severity.low': ['low', 'কম'],
  'appsafety.severity.medium': ['medium', 'মাঝারি'],
  'appsafety.severity.high': ['high', 'বেশি'],
  'appsafety.severity.critical': ['critical', 'গুরুতর'],
  'appsafety.scope.app': ['an app', 'একটি অ্যাপ'],
  'appsafety.scope.device': ['the phone itself', 'ফোন নিজেই'],
  'appsafety.dropped': [
    '+ {n} less severe findings, cut by risk-mw to keep the record small',
    '+ আরও {n}টি কম গুরুতর ফাইন্ডিং, রেকর্ড ছোট রাখতে risk-mw বাদ দিয়েছে',
  ],
  'appsafety.ignored': ["Ignored: this score did not use the phone's copy.", 'উপেক্ষা করা হয়েছে: এই স্কোর ফোনের কপিটি ব্যবহার করেনি।'],
  'appsafety.ignored.expired': ['It had expired before this score.', 'এই স্কোরের আগেই এর মেয়াদ শেষ হয়ে গিয়েছিল।'],
  'appsafety.ignored.simulated': [
    'It was a simulated verdict, and the service is not in demo mode.',
    'এটি সিমুলেটেড ভারডিক্ট ছিল, আর সার্ভিসটি ডেমো মোডে নেই।',
  ],
  'appsafety.ignored.other': ['risk-mw recorded the reason as "{reason}".', 'risk-mw কারণ হিসেবে লিখেছে "{reason}"।'],

  'help.then': ['then', 'তারপর'],
  'help.palette': ['command palette: jump anywhere, or paste an account id', 'কমান্ড প্যালেট: যেকোনো জায়গায় যান, বা একটি অ্যাকাউন্ট আইডি পেস্ট করুন'],
  'help.search': ['focus the search on a view that has one', 'যে ভিউতে সার্চ আছে, সেখানে সার্চে যান'],
  'help.help': ['this help', 'এই সহায়তা'],
  'help.esc': ['close whatever is open', 'যা খোলা আছে তা বন্ধ করুন'],

  'info.button': ['What this means', 'এর মানে কী'],
  'more.about': ['How to read this', 'এটি কীভাবে পড়বেন'],
  'toast.error': ['Problem', 'সমস্যা'],
  'toast.good': ['Done', 'হয়ে গেছে'],
  'toast.info': ['Note', 'তথ্য'],
  'action.retry': ['Try again', 'আবার চেষ্টা করুন'],
  'error.next': ['Try again in a moment. If it keeps failing, check that the service is running.', 'একটু পরে আবার চেষ্টা করুন। বারবার না হলে দেখুন সার্ভিসটি চলছে কিনা।'],
  'toast.rebuilt': ['Aggregate rebuilt from the seed world.', 'seed ডেটা থেকে অ্যাগ্রিগেট আবার বানানো হয়েছে।'],
}

export const LangContext = createContext<Lang>('bn')

type T = (key: string, vars?: Record<string, string>) => string
type Pick = <R extends object>(row: R, field: string) => string

/* One `t` and one `pick` per language, made once. They used to be new functions on every render,
   and App's `load` lists `t` in its dependencies, so every render made a new `load`, the effect
   that calls it ran again, the overview came back as a new object, and the console re-rendered
   and re-fetched in a loop for as long as it was open (about 6 requests a second against Cloud
   Run, hundreds locally). Stable functions end the loop. */
const make = (lang: Lang): { t: T; pick: Pick } => {
  const index = lang === 'bn' ? 1 : 0
  const t: T = (key, vars) => {
    let text = STRINGS[key]?.[index] ?? STRINGS[key]?.[0] ?? key
    if (vars) for (const [name, value] of Object.entries(vars)) text = text.split(`{${name}}`).join(value)
    return text
  }
  /** Server-side editorial text: `title` in English, `title_bn` in Bangla, English if untranslated. */
  const pick: Pick = (row, field) => {
    const record = row as Record<string, unknown>
    const translated = lang === 'bn' ? record[`${field}_bn`] : undefined
    return String(translated ?? record[field] ?? '')
  }
  return { t, pick }
}
const BY_LANG: Record<Lang, { t: T; pick: Pick }> = { en: make('en'), bn: make('bn') }

export function useT(): { t: T; lang: Lang; pick: Pick } {
  const lang = useContext(LangContext)
  const { t, pick } = BY_LANG[lang] ?? BY_LANG.bn
  return { t, lang, pick }
}

/** Bangla digits for Bangla copy. Operator tables stay Western; prose does not have to. */
export const bnDigits = (value: string): string =>
  value.replace(/[0-9]/g, (digit) => '০১২৩৪৫৬৭৮৯'[Number(digit)]!)

/** The label for a wire value (`hold`, `critical`) in the active language; the wire value itself
    when no label is written, so a new value from the service still reads rather than vanishing. */
export const label = (t: (key: string) => string, group: string, value: string): string => {
  const key = `${group}.${value}`
  const text = t(key)
  return text === key ? value : text
}
