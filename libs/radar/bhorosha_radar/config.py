"""Named detector thresholds, frozen for the fixture-first submission cut."""
DECISIONS = frozenset({'allow', 'step_up', 'delay', 'hold', 'block'})  # risk-mw score contract
CELL_TYPES = ('send_money',)  # cells count payments to a payee; salary credits and cash-outs are not attempts
WINDOWS_MIN = (15, 60, 180)  # short burst, hour, and slower campaign
RUN_EVERY_MIN = 15  # bounds first detection latency
BASELINE_WEEKS = 4  # compare matching hour-of-week over the last four weeks
PRIOR_WEEKS = 1.0  # pooled per-cell rate has one week's weight
LAMBDA_FLOOR_PER_HOUR = 1e-4  # positive mean for previously unseen cells
MIN_DISTINCT_SENDERS = 10  # acceptance starts its clock at the tenth attempt
P_THRESHOLD = 1e-7  # fixed Bonferroni-style p branch; report actual universe budget
FALSE_INCIDENT_BUDGET_PER_WEEK = 1.0  # nominal p branch only, not a detector guarantee
VELOCITY_CAP = {15: 12, 60: 25, 180: 40}  # second route for low baseline cells
VELOCITY_CAP_MU_MAX = 3.0  # do not fire a velocity cap on busy populations
PAYDAY_DAYS_OF_MONTH = (10, 11)  # salary period in the synthetic world
PAYDAY_FACTOR_DEFAULT = 3.0  # conservative fallback before an earlier payday exists
PAYDAY_FACTOR_MAX = 10.0  # bound adjustment from a single earlier payday
SIM_DAY_RECENT_DAYS = 30  # old activation days are common and not useful entities
AMOUNT_BANDS = (500, 2000, 5000, 10000, 25000)  # BDT edges, six bands
RECEIVING_KEYS = ('payee', 'payee_onboarding_agent', 'payee_device', 'payee_sim_day', 'payee_till')
SENDER_KEYS = ('sender_district', 'sender_district_band')  # new-payee sends only
INCIDENT_MERGE_GAP_MIN = 180  # repeated firings extend the same incident for three hours
LINK_LOOKBACK_HOURS = 24  # components use only incidents opened in the last day
LINK_BY_AMOUNT = False  # common amounts cause broad accidental components
MIN_CAMPAIGN_ATTEMPTS = 5  # discard tiny components
MIN_CAMPAIGN_SENDERS = 3  # retries by one sender are not a population campaign
SYNCHRONY_SPAN_MIN = 10  # largest share in a ten-minute span
# Common point of cash-out
CASHOUT_TYPE = 'cash_out'  # ledger type of a withdrawal at an agent till: from_acct cashes out, agent_id names the till
CONFIRMATION_LAG_DAYS = 3  # a mule is confirmed three days after its first bad event; equals bhorosha_graph.features.CONFIRMATION_LAG_DAYS (a test pins it)
EARTH_RADIUS_KM = 6371.0088  # IUGG mean radius; the sphere's error (under 0.5%) is metres at till-to-till distances
# Common point of cash-out rules: leads for review, never blocks
TILL_REUSE_DAYS = 30  # a ring keeps using its tills for weeks; a month back spans the three-day confirmation lag ten times
TILL_REUSE_MIN_SEEDS = 2  # one confirmed mule at a till paying out about a hundred times a month is chance; two is reuse. Kept: the Poisson test against the till's own volume does the calibrating, this floor only stops one seed at a near-empty till from flagging
TILL_REUSE_P_THRESHOLD = 1e-3  # a review lead, not an incident: only tills with at least two seeds are tested, so at most 40 tills tested a day gives at most 40 x 7 x 1e-3 = 0.28 nominal false flags a week (an upper bound), inside FALSE_INCIDENT_BUDGET_PER_WEEK; the radar's 1e-7 is sized for thousands of cells tested 96 times a day
CLUSTER_RADIUS_KM = 2.5  # one ring's cash-out run on foot or by rickshaw stays within a neighbourhood
CLUSTER_WINDOW_MIN = 90  # a ring empties its mules within hours of the fraud; ninety minutes holds one run
CLUSTER_MIN_SEEDS = 3  # three distinct confirmed mules in one circle and window is not coincidence (the ticket's rule)
CLUSTER_MIN_CASHOUTS = 6  # floor: a quiet circle cannot fire on a handful (the radar's ten-sender lesson: p alone is optimistic)
CLUSTER_P_THRESHOLD = P_THRESHOLD  # the radar's fixed p branch, reused so both rules mean the same surprise
CANDIDATE_MIN_FIRST_TIME_SENDERS = 3  # a mule collects from several strangers before it cashes out; a customer rarely does
CANDIDATE_LOOKBACK_HOURS = 24  # victims' money reaches a mule within a day of its cash-out
FIRST_TIME_SENDER_TYPES = CELL_TYPES  # money paid in to a payee, as the radar's cells count it; salary and cash-in are not
# The pass-through candidate filter, fixed here before its own measurement and never tuned on it. Added
# after the first-time-sender filter named no candidate on either world (no account inside a till flag or cluster had more
# than one first-time sender). Standard pass-through definition of a money mule: money in from a new counterparty and out
# again as cash within a day, the mule keeping a small cut. It runs beside the first filter, which is unchanged, over the
# same CANDIDATE_LOOKBACK_HOURS before the cash-out.
PASS_THROUGH_MIN_NEW_COUNTERPARTIES = 1  # standard pass-through definition: one stranger's money in is enough when it goes straight out as cash; a mule fed by one victim never shows three first-time senders
PASS_THROUGH_NEW_DAYS = 30  # standard pass-through definition: a counterparty is new when the account had no transaction with it, either way, in the month before its payment; a month spans a customer's regular family and salary cycle
PASS_THROUGH_MIN_SHARE = 0.8  # standard pass-through definition: cash-outs in the lookback at least 80% of everything paid in over it, the rest the mule's cut and fees; a customer who keeps a balance stays below
PASS_THROUGH_IN_TYPES = FIRST_TIME_SENDER_TYPES  # a new counterparty is another account paying in, as the radar's cells count it; salary and cash-in still count toward what was received
