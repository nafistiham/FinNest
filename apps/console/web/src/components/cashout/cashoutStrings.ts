/**
 * The cash-out map's own strings, English and Bangla.
 *
 * Kept beside the view, as lib/campaignStrings.ts is, so the shared table in lib/i18n.ts only
 * gains its two registration keys (`view.cashout` and its hint). `{name}` placeholders are filled by
 * the caller with figures read from the fixture; no sentence here carries a number of its own.
 * Operator figures stay in Western digits in both languages, as the rest of the console does.
 * Bangla is a first draft; native review is pending, as for the Incidents view.
 */

import { useContext } from 'react'
import { LangContext } from '../../lib/i18n'

/** [English, Bangla] */
const STRINGS: Record<string, [string, string]> = {
  'xo.title': ['Where the money comes out', 'টাকা কোথায় তোলা হচ্ছে'],
  'xo.lede': [
    "Confirmed mules cashing out at one FinNest agent till more often than the till's own volume predicts flag that till; three of them inside 2.5 km and 90 minutes open a cluster. Anyone else who cashed out there and also passes a candidate filter becomes a lead for an analyst, never a block. Every figure is from FinNest's synthetic campaign world (data/seed-campaign), replayed through the radar's rules when the fixture was built; no request re-runs them.",
    'নিশ্চিত মিউলরা যদি ফিননেস্টের একটি এজেন্ট পয়েন্টে সেই পয়েন্টের নিজের লেনদেনের তুলনায় বেশি ক্যাশ-আউট করে, পয়েন্টটি ফ্ল্যাগ হয়; 2.5 কিমি ও 90 মিনিটের মধ্যে তিনজন হলে একটি ক্লাস্টার খোলে। সেখানে আর যে ক্যাশ-আউট করেছে এবং ক্যান্ডিডেট ফিল্টারও পার করেছে, সে অ্যানালিস্টের জন্য একটি লিড — কখনো ব্লক নয়। প্রতিটি সংখ্যা ফিননেস্টের সিনথেটিক ক্যাম্পেইন জগৎ (data/seed-campaign) থেকে, ফিক্সচার তৈরির সময় রাডারের রুলে চালানো; কোনো রিকোয়েস্ট এগুলো আবার চালায় না।',
  ],
  'xo.unavailable': ['The cash-out fixture is not available', 'ক্যাশ-আউট ফিক্সচার পাওয়া যাচ্ছে না'],
  'xo.retry': ['retry', 'আবার চেষ্টা'],
  'xo.stale': ['Could not load this day; the last day loaded stays on screen.', 'এই দিনটি লোড করা যায়নি; শেষ লোড করা দিনটি পর্দায় থাকছে।'],
  'xo.none': ['No daily run has a till flag or a cluster.', 'কোনো দৈনিক রানে টিল ফ্ল্যাগ বা ক্লাস্টার নেই।'],

  'xo.day': ['Day', 'দিন'],
  'xo.day.hint': [
    'Days with a till flag or a cluster, newest first. A day is the run at 00:00, which closes the day before.',
    'যেসব দিনে টিল ফ্ল্যাগ বা ক্লাস্টার আছে, নতুনটি আগে। একটি দিন মানে 00:00-এর রান, যা আগের দিনটি বন্ধ করে।',
  ],
  'xo.day.flagged': ['flagged', 'ফ্ল্যাগ'],
  'xo.day.noflag': ['no till flag', 'টিল ফ্ল্যাগ নেই'],
  'xo.day.clusters': ['replayed clusters', 'রিপ্লে করা ক্লাস্টার'],
  'xo.run': [
    'Run at 00:00 on {date}: {seeds} confirmed mules known, {cashouts} cash-outs in the day it closes ({closed}).',
    '{date} তারিখ 00:00-এর রান: {seeds} জন নিশ্চিত মিউল জানা, যে দিনটি বন্ধ করে ({closed}) তাতে {cashouts}টি ক্যাশ-আউট।',
  ],
  'xo.focus': ['Look at', 'দেখুন'],
  'xo.seeds.short': ['seeds', 'সিড'],

  'xo.overview': ['Bangladesh', 'বাংলাদেশ'],
  'xo.overview.note': [
    "{n} FinNest agent tills at their seed coordinates. The box is the area on the right; rings are the day's flagged tills. Real district boundaries; the tills inside them are synthetic.",
    '{n}টি ফিননেস্ট এজেন্ট পয়েন্ট, seed-এর স্থানাঙ্কে। বাক্সটি ডানের এলাকা; বৃত্তগুলো দিনের ফ্ল্যাগ করা পয়েন্ট। জেলার সীমানা আসল; ভিতরের পয়েন্টগুলো সিনথেটিক।',
  ],
  'xo.zoom.till': ['Around till {id}', '{id} পয়েন্টের চারপাশ'],
  'xo.zoom.cluster': ['Around the replayed cluster', 'রিপ্লে করা ক্লাস্টারের চারপাশ'],
  'xo.km': ['1 km', '1 কিমি'],
  'xo.lg.seed': ['confirmed mule (seed)', 'নিশ্চিত মিউল (সিড)'],
  'xo.lg.cand': ['candidate: a lead for review', 'ক্যান্ডিডেট: রিভিউয়ের জন্য লিড'],
  'xo.lg.inside': ['at the flagged till or in the circle, not a candidate', 'ফ্ল্যাগ করা পয়েন্টে বা বৃত্তে, ক্যান্ডিডেট নয়'],
  'xo.lg.ord': ['ordinary cash-out', 'সাধারণ ক্যাশ-আউট'],
  'xo.lg.till': ['agent till', 'এজেন্ট পয়েন্ট'],
  'xo.lg.circle': ['cluster: {km} km and {min} minutes', 'ক্লাস্টার: {km} কিমি ও {min} মিনিট'],
  'xo.lg.earlier': ['faded: before this day, inside the {days}-day reuse window', 'ফিকে: এই দিনের আগে, {days} দিনের সময়সীমার ভেতরে'],
  'xo.zoom.note': [
    'Real streets, waterways and place names under the grid. Dots sit in a spiral around their till so they can be counted: every cash-out happens at the till itself. Click a dashed circle to look at that cluster.',
    'গ্রিডের নিচে আসল রাস্তা, জলপথ আর এলাকার নাম। বিন্দুগুলো গোনার সুবিধার জন্য পয়েন্টের চারপাশে প্যাঁচানো সাজানো: প্রতিটি ক্যাশ-আউট পয়েন্টেই হয়। কোনো ক্লাস্টার দেখতে ছেঁড়া বৃত্তে ক্লিক করুন।',
  ],
  'xo.circle.label': ['replay · {when}', 'রিপ্লে · {when}'],

  'xo.incident': ['Incident', 'ঘটনা'],
  'xo.flag.title': ['Till {id} flagged: till reuse', '{id} পয়েন্ট ফ্ল্যাগ: বারবার ব্যবহার'],
  'xo.flag.sub': [
    '{n} confirmed mules cashed out here in the last {days} days.',
    'গত {days} দিনে {n} জন নিশ্চিত মিউল এখানে ক্যাশ-আউট করেছে।',
  ],
  'xo.seeds': ['Confirmed mules here', 'এখানে নিশ্চিত মিউল'],
  'xo.seeds.sub': ['seed accounts, last {days} days', 'সিড অ্যাকাউন্ট, গত {days} দিন'],
  'xo.expected': ['Expected', 'প্রত্যাশিত'],
  'xo.expected.sub': ["at the network's share of seeds, over this till's {n} accounts", 'নেটওয়ার্কে সিডের অনুপাতে, এই পয়েন্টের {n}টি অ্যাকাউন্টে'],
  'xo.unusual': ['How unusual', 'কতটা অস্বাভাবিক'],
  'xo.unusual.sub': ['Poisson tail; fires at {p} or below', 'পয়সন টেইল; {p} বা তার নিচে হলে সংকেত'],
  'xo.cands': ['Candidates here', 'এখানে ক্যান্ডিডেট'],
  'xo.cands.sub': ['leads for review, never a block', 'রিভিউয়ের লিড, কখনো ব্লক নয়'],
  'xo.firstseen': ['First seen', 'প্রথম দেখা'],
  'xo.lastseed': ['Last seed cash-out', 'শেষ সিড ক্যাশ-আউট'],
  'xo.seedlist': ['Seed accounts', 'সিড অ্যাকাউন্ট'],
  'xo.eval.flags': [
    'Flagged tills had an uncaught mule cash out within {h} days {right} times in {scored}, against {base} for any till; synthetic world.',
    'ফ্ল্যাগ করা পয়েন্টে {h} দিনের মধ্যে ধরা-না-পড়া মিউল ক্যাশ-আউট করেছে {scored} বারে {right} বার, যেকোনো পয়েন্টে {base}; সিনথেটিক জগৎ।',
  ],
  'xo.eval.clusters': [
    '{n} replayed clusters on this world ({events} distinct events); {live} fired live: a seed is confirmed {lag} days after its first bad event, and a ring empties its mules within hours.',
    'এই জগতে {n}টি রিপ্লে করা ক্লাস্টার ({events}টি আলাদা ঘটনা); লাইভে সংকেত দিয়েছে {live}টি: একটি সিড প্রথম খারাপ লেনদেনের {lag} দিন পরে নিশ্চিত হয়, আর একটি রিং কয়েক ঘণ্টায় তার মিউলদের খালি করে ফেলে।',
  ],
  'xo.eval.none': ['No evaluation in the fixture.', 'ফিক্সচারে কোনো eval নেই।'],

  'xo.filter': ['Candidate filter', 'ক্যান্ডিডেট ফিল্টার'],
  'xo.filter.first_time_senders': ['First-time senders', 'প্রথমবারের প্রেরক'],
  'xo.filter.pass_through': ['Pass-through', 'পাস-থ্রু'],
  'xo.filter.note': [
    'The first-time-sender filter was set first and names no one on this world; the pass-through filter was added after that, with its constants fixed before its own measurement.',
    'প্রথমবারের-প্রেরক ফিল্টার আগে ঠিক করা, এবং এই জগতে কাউকে চিহ্নিত করে না; পাস-থ্রু ফিল্টার পরে যোগ হয়েছে, তার কনস্ট্যান্ট নিজের মাপের আগেই ঠিক করা।',
  ],
  'xo.col.acct': ['Account', 'অ্যাকাউন্ট'],
  'xo.col.till': ['Till', 'পয়েন্ট'],
  'xo.col.time': ['Cashed out', 'ক্যাশ-আউট'],
  'xo.col.amount': ['৳', '৳'],
  'xo.col.outcome': ['Outcome', 'ফলাফল'],
  'xo.out.mule': ['mule', 'মিউল'],
  'xo.out.not_mule': ['not a mule', 'মিউল নয়'],
  'xo.out.title': ['eval only: labelled {labelled}; confirmed {confirmed}; lead {lead} days', 'শুধু eval: লেবেল {labelled}; নিশ্চিত {confirmed}; আগাম {lead} দিন'],
  'xo.cand.detail': [
    'in ৳{in} from {nc} new counterparty, out ৳{out} (share {share}) · first-time senders {fts} · first named {first}',
    'এসেছে ৳{in}, {nc}টি নতুন লেনদেনকারী থেকে; তোলা ৳{out} (অনুপাত {share}) · প্রথমবারের প্রেরক {fts} · প্রথম নাম {first}',
  ],
  'xo.cand.drawdown': [
    'cashed out {x} times what came in: it drew down its own balance',
    'যা এসেছে তার {x} গুণ তুলেছে: নিজের জমানো টাকা তুলেছে',
  ],
  'xo.cand.none': ['No candidate here under this filter on this day.', 'এই দিনে এই ফিল্টারে এখানে কোনো ক্যান্ডিডেট নেই।'],
  'xo.heldback': [
    "{n} other accounts inside this day's flags and clusters were held back by this filter.",
    'এই দিনের ফ্ল্যাগ ও ক্লাস্টারের ভেতরের আরও {n}টি অ্যাকাউন্ট এই ফিল্টারে আটকে গেছে।',
  ],
  'xo.late': [
    "{n} of the true candidates ({accts}) are confirmed on {date}, after the world's last daily run ({last}); the evaluation counts them true, with their lead, and so does this table.",
    'সত্যিকারের ক্যান্ডিডেটদের {n} জন ({accts}) নিশ্চিত হয় {date} তারিখে, জগতের শেষ দৈনিক রানের ({last}) পরে; eval তাদের সত্য ধরে, আগাম সময়সহ, এই টেবিলও তাই।',
  ],

  'xo.cluster.title': ['Cluster {id}', 'ক্লাস্টার {id}'],
  'xo.replay.line': [
    "Replayed: the 90-minute circle run again over a day already past with the mules confirmed by this run's midnight. It did not fire as it happened, because those mules were confirmed days later.",
    'রিপ্লে: 90 মিনিটের বৃত্তটি অতীতের একটি দিনে আবার চালানো, এই রানের মধ্যরাত পর্যন্ত নিশ্চিত মিউলদের দিয়ে। ঘটনার সময় এটি সংকেত দেয়নি, কারণ ওই মিউলরা কয়েক দিন পরে নিশ্চিত হয়েছে।',
  ],
  'xo.live.line': ['Live: the circle fired as it happened, with the mules confirmed at that moment.', 'লাইভ: ঘটনার সময়েই বৃত্তটি সংকেত দিয়েছে, তখন পর্যন্ত নিশ্চিত মিউলদের দিয়ে।'],
  'xo.cluster.seeds': ['Confirmed mules in the circle', 'বৃত্তে নিশ্চিত মিউল'],
  'xo.cluster.seeds.sub': ['opened it: {min} or more', 'যারা এটি খুলেছে: {min} বা বেশি'],
  'xo.cluster.obs': ['Cash-outs in the circle', 'বৃত্তে ক্যাশ-আউট'],
  'xo.cluster.obs.sub': ['against {e} expected at this place and hour', 'এই জায়গা ও সময়ে প্রত্যাশিত {e}'],
  'xo.cluster.window': ['Window', 'সময়সীমা'],
  'xo.cluster.where': ['{km} km around {tills}', '{tills}-এর চারপাশে {km} কিমি'],
  'xo.members': ['Inside the circle and window', 'বৃত্ত ও সময়সীমার ভেতরে'],
  'xo.member.seed': ['confirmed mule', 'নিশ্চিত মিউল'],
  'xo.member.candidate': ['candidate', 'ক্যান্ডিডেট'],
  'xo.member.inside': ['not flagged', 'ফ্ল্যাগ নয়'],

  'xo.actions': ['Next', 'পরের ধাপ'],
  'xo.act.casezero': ['Send the candidates to Case Zero', 'ক্যান্ডিডেটদের কেস জিরোতে পাঠান'],
  'xo.act.review': ['Ask an analyst to review the till', 'একজন অ্যানালিস্টকে পয়েন্টটি দেখতে বলুন'],
  'xo.act.watch': ['Add a confirmed lead to the watch-list', 'নিশ্চিত লিড ওয়াচ-লিস্টে যোগ করুন'],
  'xo.notwired': ['not wired', 'যুক্ত হয়নি'],
  'xo.never': [
    'Leads for review, never a block: nothing on this map stops a payment, and a flag is a place to look, not a finding about the agent who runs the till.',
    'রিভিউয়ের লিড, কখনো ব্লক নয়: এই ম্যাপের কিছুই কোনো পেমেন্ট থামায় না, আর ফ্ল্যাগ মানে দেখার জায়গা — পয়েন্ট চালানো এজেন্ট সম্পর্কে কোনো সিদ্ধান্ত নয়।',
  ],

  'xo.strip': ['The day, 15 minutes at a time', 'দিনটি, 15 মিনিট করে'],
  'xo.play': ['Play the day', 'দিনটি চালান'],
  'xo.pause': ['Pause', 'থামান'],
  'xo.time': ['Time', 'সময়'],
  'xo.strip.till': [
    "Bars count cash-outs at {id} per 15 minutes on {date}: red for confirmed mules, amber for candidates. The fixture holds no per-hour baseline for a till, so no band is drawn: the flag compares {days} days of seeds with the till's own volume (the panel).",
    'বারগুলো {date} তারিখে {id} পয়েন্টে প্রতি 15 মিনিটের ক্যাশ-আউট গোনে: লাল নিশ্চিত মিউল, হলুদ ক্যান্ডিডেট। ফিক্সচারে পয়েন্টের ঘণ্টাভিত্তিক স্বাভাবিক মাত্রা নেই, তাই কোনো ব্যান্ড আঁকা হয়নি: ফ্ল্যাগ {days} দিনের সিডকে পয়েন্টের নিজের লেনদেনের সাথে তুলনা করে (প্যানেলে)।',
  ],
  'xo.strip.cluster': [
    "Bars count the circle's own cash-outs per 15 minutes on {date}; the fixture keeps a cluster's members, not the rest of that day. The band is the circle's expected count per 15 minutes for that place and hour, up to two standard deviations above it; the dashed line is the moment it opened.",
    'বারগুলো {date} তারিখে বৃত্তের নিজের ক্যাশ-আউট প্রতি 15 মিনিটে গোনে; ফিক্সচার ক্লাস্টারের সদস্যদের রাখে, সেই দিনের বাকিদের নয়। ব্যান্ডটি সেই জায়গা ও সময়ে প্রতি 15 মিনিটের প্রত্যাশিত সংখ্যা, তার ওপরে দুই স্ট্যান্ডার্ড ডেভিয়েশন পর্যন্ত; ছেঁড়া রেখাটি ক্লাস্টার খোলার মুহূর্ত।',
  ],
  'xo.opens': ['cluster opens {t}', 'ক্লাস্টার খোলে {t}'],
  'xo.expected.band': ['expected', 'প্রত্যাশিত'],

  'xo.p.below': ['below 1 in 10¹²', '10¹²-এ 1-এর কম'],
  'xo.p.onein': ['1 in {n}', '{n}-এ 1'],
  'xo.vs': ['{o} vs {e} expected', '{o} বনাম প্রত্যাশিত {e}'],
}

export type Fill = Record<string, string | number>

/** `xt(key, {name: value})`: the string in the current language with its placeholders filled. */
export function useXT(): (key: string, fill?: Fill) => string {
  const index = useContext(LangContext) === 'bn' ? 1 : 0
  return (key: string, fill?: Fill): string => {
    const text = STRINGS[key]?.[index] ?? STRINGS[key]?.[0] ?? key
    return fill ? text.replace(/\{(\w+)\}/g, (whole, name: string) => (name in fill ? String(fill[name]) : whole)) : text
  }
}
