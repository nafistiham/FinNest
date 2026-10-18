/**
 * The Incidents view's own strings, English and Bangla.
 *
 * Kept beside the view rather than in lib/i18n.ts so the shared table only gains its two
 * registration keys (`view.campaigns` and its hint). Decision labels are not here: the view reads the
 * console's existing `decisions.*`, so it and the Decisions panel can never disagree.
 *
 * Bangla wording follows the incident-view design's draft inventory; native review is pending.
 */

import { useContext } from 'react'
import { LangContext } from './i18n'

/** [English, Bangla] */
const STRINGS: Record<string, [string, string]> = {
  'cv.detection': [
    "Detection only: the analyst acts outside this view. Every figure is from FinNest's synthetic campaign world (data/seed-campaign), run through the radar when the fixture was built; no request re-runs it.",
    'শুধু শনাক্তকরণ: অ্যানালিস্ট এই পর্দার বাইরে পদক্ষেপ নেন। প্রতিটি সংখ্যা ফিননেস্টের সিনথেটিক ক্যাম্পেইন জগৎ (data/seed-campaign) থেকে, ফিক্সচার তৈরির সময় রাডারে চালানো; কোনো রিকোয়েস্ট এটি আবার চালায় না।',
  ],
  'cv.unavailable': ['The radar fixture is not available', 'রাডারের ফিক্সচার পাওয়া যাচ্ছে না'],
  'cv.retry': ['retry', 'আবার চেষ্টা'],
  'cv.stale': ['Could not load this incident; the last rows loaded stay on screen.', 'এই ঘটনা লোড করা যায়নি; শেষ লোড করা তথ্য পর্দায় থাকছে।'],
  'cv.nodata': ['No data', 'তথ্য নেই'],

  'cv.campaigns': ['Campaigns the radar linked', 'রাডার যে প্রতারণা অভিযানগুলো যুক্ত করেছে'],
  'cv.campaigns.q': ['Ranked by the radar’s own score; money is eval-only', 'রাডারের নিজের স্কোরে সাজানো; টাকার হিসাব শুধু eval'],
  'cv.col.campaign': ['Campaign', 'প্রতারণা অভিযান'],
  'cv.col.opened': ['Opened', 'শনাক্তের সময়'],
  'cv.col.payees': ['Payees', 'প্রাপক'],
  'cv.col.senders': ['Senders', 'প্রেরক'],
  'cv.col.sync': ['Synchrony', 'সময়গত মিল'],
  'cv.col.conc': ['Concentration', 'কেন্দ্রীভবন'],
  'cv.col.rank': ['Rank', 'ক্রমমান'],
  'cv.col.money': ['Still inside at the flag', 'সংকেতের সময় এখনও ভেতরে'],
  'cv.evalmatch': ['eval match', 'eval মিল'],
  'cv.superseded': ['Earlier snapshots, kept by the radar and superseded:', 'রাডারের রাখা আগের স্ন্যাপশট, পরেরটি দিয়ে প্রতিস্থাপিত:'],
  'cv.superseded.why': [
    'The radar names a campaign after its earliest attempt; when a component later reached back in time it got a new id, and the old snapshot stayed.',
    'রাডার একটি অভিযানের নাম দেয় তার প্রথম চেষ্টা দিয়ে; পরে কম্পোনেন্ট আগের সময়ে বিস্তৃত হলে নতুন আইডি পায়, আর পুরোনো স্ন্যাপশট থেকে যায়।',
  ],
  'cv.within': ['inside', 'ভেতরে'],

  'cv.incidents': ['Open and recent incidents', 'চলমান ও সাম্প্রতিক ঘটনা'],
  'cv.rankby': ['Rank by', 'সাজানোর ভিত্তি'],
  'cv.rank.surprise': ['Surprise', 'অস্বাভাবিকতা'],
  'cv.rank.retained': ['Money retained at flag, demo/eval only', 'ফ্ল্যাগের সময় ভেতরে থাকা টাকা, শুধু ডেমো/eval'],
  'cv.rank.inside': ['Money inside, ledger (proposed, no data)', 'লেজার অনুযায়ী ভেতরে থাকা টাকা (প্রস্তাবিত, তথ্য নেই)'],
  'cv.rank.note': [
    'The money rank sorts by an eval-only field computed from generated truth; it belongs to the walkthrough, not to production.',
    'টাকার ভিত্তিতে সাজানো একটি eval-মাত্র ফিল্ডে, যা তৈরি করা সত্য থেকে হিসাব করা; এটি ডেমোর জন্য, প্রোডাকশনের জন্য নয়।',
  ],
  'cv.scope.all': ['All', 'সব'],
  'cv.scope.campaign': ['This campaign', 'এই অভিযান'],
  'cv.evalonly': ['eval only', 'শুধু eval'],
  'cv.class.benign_only': ['benign only', 'শুধু নির্দোষ'],
  'cv.class.mixed': ['mixed', 'মিশ্র'],
  'cv.class.fraud_dominant': ['fraud dominant', 'প্রতারণা-প্রধান'],
  'cv.class.note': ['Never an input to detection or rank.', 'শনাক্তকরণ বা সাজানোর ইনপুট কখনো নয়।'],

  'cv.incident': ['Incident', 'ঘটনা'],
  'cv.opened': ['Opened', 'শনাক্তের সময়'],
  'cv.lastfiring': ['Last firing', 'সর্বশেষ সংকেত'],
  'cv.surprise': ['Surprise', 'অস্বাভাবিকতা'],
  'cv.reason': ['Reason', 'কারণ'],
  'cv.window': ['Window', 'সময়সীমা'],
  'cv.cellkey': ['Cell / key', 'শনাক্তকরণের ক্ষেত্র / সূচক'],
  'cv.obsexp': ['Observed / expected', 'দেখা গেছে / প্রত্যাশিত'],
  'cv.obsexp.sub': ['distinct senders in the window', 'সময়সীমার মধ্যে আলাদা প্রেরক'],
  'cv.baseline': ['Baseline', 'স্বাভাবিক মাত্রা'],
  'cv.payday': ['payday factor', 'বেতন-দিনের গুণক'],
  'cv.attached': ['attempts attached', 'যুক্ত লেনদেনের চেষ্টা'],
  'cv.campaign': ['Campaign', 'প্রতারণা অভিযান'],
  'cv.nocampaign': ['No campaign yet', 'এখনও অভিযান যুক্ত হয়নি'],
  'cv.choose': [
    'This incident sits in more than one campaign. Choose one; none is picked for you.',
    'এই ঘটনা একাধিক অভিযানে আছে। একটি বেছে নিন; নিজে থেকে কোনোটি বাছা হয়নি।',
  ],
  'cv.earlier': ['earlier snapshot', 'আগের স্ন্যাপশট'],
  'cv.actionstaken': ['Actions taken', 'নেওয়া পদক্ষেপ'],
  'cv.notwired': ['Not wired', 'এখনও যুক্ত হয়নি'],

  'cv.money': ['Money still inside at the flag', 'সংকেতের সময় এখনও ব্যবস্থার ভেতরে থাকা টাকা'],
  'cv.money.na': ['n/a: nothing credited by flag', 'প্রযোজ্য নয়: সংকেতের আগে কোনো টাকা জমা হয়নি'],
  'cv.credited': ['BDT credited by the flag', 'টাকা সংকেতের আগে জমা হয়েছে'],
  'cv.cashedout': ['Cashed out by flag', 'সংকেতের আগে নগদ তোলা হয়েছে'],
  'cv.afterflag': ['Allowed after flag, outside the denominator', 'সংকেতের পরে ছেড়ে দেওয়া, হরের বাইরে'],
  'cv.flag': ['Campaign flagged', 'অভিযান শনাক্ত'],
  'cv.ttf': ['min after the tenth victim payment', 'মিনিট, দশম ভুক্তভোগীর পেমেন্টের পরে'],
  'cv.money.note': [
    'Retained at the flag, computed from generated truth: demo / eval only, and not money saved.',
    'সংকেতের সময় ভেতরে থাকা টাকা, তৈরি করা সত্য থেকে হিসাব: শুধু ডেমো/eval, বাঁচানো টাকা নয়।',
  ],
  'cv.money.noeval': [
    'No evaluation row joins this campaign: only the three injected call-centre campaigns were scored.',
    'কোনো eval সারি এই অভিযানের সাথে মেলে না: শুধু তিনটি কল-সেন্টার অভিযান মাপা হয়েছে।',
  ],
  'cv.money.pick': ['Choose a campaign to see its money.', 'টাকার হিসাব দেখতে একটি অভিযান বেছে নিন।'],
  'cv.inside': ['Money inside, ledger (proposed)', 'লেজার অনুযায়ী ভেতরে থাকা টাকা (প্রস্তাবিত)'],
  'cv.inside.sub': ['Truth-free, from the ledger as of the campaign; no producer yet.', 'সত্য-নিরপেক্ষ, অভিযানের সময় পর্যন্ত লেজার থেকে; এখনও কোনো উৎপাদক নেই।'],

  'cv.measures': ['Eval measures', 'eval-এর মাপকাঠি'],
  'cv.measure': ['Measure', 'মাপকাঠি'],
  'cv.value': ['Value', 'মান'],
  'cv.target': ['Target', 'লক্ষ্য'],
  'cv.status': ['Status', 'অবস্থা'],
  'cv.gates.passed': ['every measure passed', 'সব মাপকাঠি পাস'],
  'cv.gates.failed': ['missed', 'মিস'],
  'cv.gates.unmeasured': ['not all measured', 'সব মাপা হয়নি'],
  'cv.caveat': ['Caveat', 'সতর্কতা'],
  'cv.payeenote': ['Payee note', 'প্রাপক নিয়ে মন্তব্য'],
  'cv.source': ['Source / as of', 'উৎস / তথ্যের সময়'],

  'cv.map': ['Sender districts', 'প্রেরকদের জেলা'],
  'cv.map.legend': ['Shaded by distinct senders · payee districts outlined', 'আলাদা প্রেরকের সংখ্যা অনুযায়ী ছায়া · প্রাপকদের জেলা রেখা দিয়ে চিহ্নিত'],
  'cv.map.note': [
    'Shading is distinct senders in the incident, not attempts, against the busiest district in it. Real district boundaries; the senders inside them are synthetic.',
    'ছায়ার গাঢ়ত্ব ঘটনার আলাদা প্রেরকের সংখ্যা, চেষ্টার সংখ্যা নয় — ঘটনার সবচেয়ে ব্যস্ত জেলার তুলনায়। জেলার সীমানা আসল; ভিতরের প্রেরকেরা সিনথেটিক।',
  ],
  'cv.unknown': ['Unknown district', 'অজানা জেলা'],

  'cv.timeline': ['Attempts and baseline', 'লেনদেনের চেষ্টা ও স্বাভাবিক মাত্রা'],
  'cv.band': ['Flat expected band', 'প্রত্যাশিত মাত্রার সমতল রেখা'],
  'cv.band.note': [
    'Expected is the incident’s baseline held flat: the radar writes only the runs that fired, so there is no series to draw and no confidence interval. Dots are those runs’ distinct-sender counts.',
    'প্রত্যাশিত মান ঘটনার স্বাভাবিক মাত্রা, সমতল রাখা: রাডার শুধু যে রানগুলো সংকেত দিয়েছে সেগুলো লেখে, তাই আঁকার মতো ধারাবাহিক তথ্য বা কনফিডেন্স ইন্টারভাল নেই। বিন্দুগুলো সেই রানগুলোর আলাদা প্রেরকের সংখ্যা।',
  ],
  'cv.firing': ['Firing / opening', 'সংকেত / ঘটনা শনাক্ত'],
  'cv.tenth': ['Tenth attempt', 'দশম চেষ্টা'],
  'cv.expected': ['expected', 'প্রত্যাশিত'],
  'cv.opened.short': ['opened', 'শনাক্ত'],
  'cv.k': ['distinct senders per window', 'প্রতি সময়সীমায় আলাদা প্রেরক'],

  'cv.graph': ['Campaign graph', 'প্রতারণা অভিযানের সংযোগচিত্র'],
  'cv.graph.note': [
    'Thin lines: attempted payments, holds included, not transfers. Blue: a payee joined to an entity an evidence triple names; hover for the triples, click to light their payments. Dashed amber: an entity the payees share as of the campaign that no triple needed. Dotted: known next hops, context only.',
    'সরু রেখা: পেমেন্টের চেষ্টা, আটকে রাখাগুলোসহ, টাকা পাঠানো নয়। নীল: প্রমাণের ত্রয়ীতে নাম থাকা সত্তার সাথে প্রাপকের সংযোগ; ত্রয়ী দেখতে মাউস রাখুন, পেমেন্ট আলোকিত করতে ক্লিক করুন। ছেঁড়া হলুদ: প্রাপকদের শেয়ার করা সত্তা যা কোনো ত্রয়ীতে লাগেনি। বিন্দু রেখা: জানা পরবর্তী প্রাপক, শুধু প্রসঙ্গ।',
  ],
  'cv.sender': ['Sender / victim', 'প্রেরক / ভুক্তভোগী'],
  'cv.payee': ['Payee', 'প্রাপক'],
  'cv.linking': ['linking entity', 'সংযোগকারী সত্তা'],
  'cv.nexthop': ['Next hop', 'পরবর্তী প্রাপক'],
  'cv.kind.payee_onboarding_agent': ['onboarding agent', 'নিবন্ধনকারী এজেন্ট'],
  'cv.kind.payee_till': ['agent till', 'এজেন্ট পয়েন্ট'],
  'cv.kind.payee_sim_day': ['SIM activation day', 'সিম চালুর দিন'],
  'cv.kind.payee_device': ['device', 'ডিভাইস'],
  'cv.kind.payee': ['payee, as a next hop', 'প্রাপক, পরবর্তী হিসেবে'],
  'cv.shared': ['shared, not evidence', 'শেয়ার করা, প্রমাণ নয়'],
  'cv.district': ['District', 'জেলা'],
  'cv.payeetable.note': [
    'As of each payee’s last attempt in the campaign. Bold: entities an evidence triple names; the rest is context and never drawn as a link.',
    'অভিযানে প্রতিটি প্রাপকের শেষ চেষ্টার সময় অনুযায়ী। মোটা অক্ষর: প্রমাণের ত্রয়ীতে নাম থাকা সত্তা; বাকিটা প্রসঙ্গ, কখনো সংযোগ হিসেবে আঁকা হয় না।',
  ],
  'cv.evidence': ['Link evidence', 'সংযোগের প্রমাণ'],
  'cv.evidence.summary': ['triples, one per linked attempt', 'ত্রয়ী, প্রতিটি যুক্ত চেষ্টার জন্য একটি'],
  'cv.syncconcrank': ['Synchrony / concentration / rank', 'সময়গত মিল / কেন্দ্রীভবন / ক্রমমান'],
  'cv.asof': ['as of', 'তথ্যের সময়'],
  'cv.tills': ['Agent tills', 'এজেন্ট পয়েন্ট'],

  'cv.actions': ['Actions', 'পদক্ষেপ'],
  'cv.actions.q': ['Detection only: every control here is off', 'শুধু শনাক্তকরণ: এখানকার প্রতিটি নিয়ন্ত্রণ বন্ধ'],
  'cv.act.casezero': ['Send to Case Zero', 'কেস জিরোতে পাঠান'],
  'cv.act.casezero.chip': ['Not wired in this view', 'এই পর্দায় যুক্ত নয়'],
  'cv.act.casezero.why': [
    'The campaign world’s payees are not in the demo seed Case Zero investigates, so this view sends nothing.',
    'ক্যাম্পেইন জগতের প্রাপকরা কেস জিরোর ডেমো seed-এ নেই, তাই এই পর্দা কিছু পাঠায় না।',
  ],
  'cv.act.cool': ['Cool payees and next hop', 'প্রাপক ও পরবর্তী প্রাপকের লেনদেন সাময়িক ধীর করুন'],
  'cv.act.suspend': ['Suspend till', 'এজেন্ট পয়েন্ট সাময়িক বন্ধ করুন'],
  'cv.act.warn': ['Send assistant warning', 'সহকারীর সতর্কবার্তা পাঠান'],
  'cv.act.benign': ['Mark as benign', 'নিরাপদ হিসেবে চিহ্নিত করুন'],
  'cv.act.note': [
    'Cooling would delay, never decline. A warning would reach every sender, held ones included. Confirmation and an audit row per action are not built yet; no control here sends a request.',
    'ধীর করা মানে দেরি, কখনো প্রত্যাখ্যান নয়। সতর্কবার্তা প্রত্যেক প্রেরকের কাছে যাবে, আটকে রাখাদেরও। প্রতিটি পদক্ষেপের নিশ্চিতকরণ ও অডিট এখনও তৈরি হয়নি; এখানকার কোনো নিয়ন্ত্রণ রিকোয়েস্ট পাঠায় না।',
  ],
  'cv.export.json': ['Export JSON', 'জেসন ফাইল নামান'],
  'cv.export.csv': ['Export CSV', 'সিএসভি ফাইল নামান'],
}

export function useCT(): (key: string) => string {
  const index = useContext(LangContext) === 'bn' ? 1 : 0
  return (key: string): string => STRINGS[key]?.[index] ?? STRINGS[key]?.[0] ?? key
}

/** The eight synth districts' Bangla names. */
export const DISTRICT_BN: Record<string, string> = {
  Dhaka: 'ঢাকা', Gazipur: 'গাজীপুর', Chattogram: 'চট্টগ্রাম', Rangpur: 'রংপুর',
  Sylhet: 'সিলেট', Bhola: 'ভোলা', Narayanganj: 'নারায়ণগঞ্জ', Khulna: 'খুলনা',
}
