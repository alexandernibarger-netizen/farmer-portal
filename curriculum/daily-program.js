// Julian Nibarger's "The Daily Program": a teacher lesson only his students see (Learn > Teacher lesson).
// Part 1 (their why) is mandatory: the rest stays locked until they send it to Julian. Steps 1-7 run every day,
// and the last part is the nightly numbers they send him. Julian has no slide deck, so each "slide" is a part.
// His own promises (the accountability checklist on My students) are listed at the bottom.
window.TEACHER_LESSONS = window.TEACHER_LESSONS || {};
window.TEACHER_LESSONS["daily-program"] = {
  title: "The Daily Program",
  by: "Julian Nibarger",
  sub: "Seven steps, every day, for 8 days.",
  whyGate: true,   // part 1 must be sent before the rest opens
  unit: "part",    // the teacher steps through parts, not slides of a deck
  parts: [
    ["Your why", "Mandatory first", "Why are you doing this, and why is it important to you?"],
    ["Build your confidence", "Step 1", "Practice the script out loud before every dial. Nerves are normal, and they fade."],
    ["Pick 3 trades, build your list", "Step 2", "Find about 30 local contractors, and add new ones every day."],
    ["Contact contractors", "Step 3", "20 real conversations a day, and at least 1 confirmed contractor."],
    ["Run the call with control", "Step 4", "State the 20% fee as fact, and get the agreement in writing."],
    ["Find homeowners", "Step 5", "Find homeowners who need work on Nextdoor and Facebook. Aim for 10 conversations and 5 leads a day."],
    ["Match and send", "Step 6", "Send each lead to a signed contractor, and confirm the estimate is booked."],
    ["Close and collect", "Step 7", "Confirm the job, and invoice your commission on the paid day."],
    ["Tonight’s numbers", "Every night", "Send your numbers to Julian every night, and make sure they’re in the CRM."],
  ],
  screens: [[0, "why1"], [0, "why2"], [1, "conf"], [2, "list"], [3, "contact1"], [3, "contact2"], [4, "control"], [5, "home"], [6, "match"], [7, "collect"], [8, "night"]],
  // one "slide" per part
  slidePart: [0, 1, 2, 3, 4, 5, 6, 7, 8],
  slideName: ["Your why", "Build your confidence", "Pick 3 trades, build your list", "Contact contractors", "Run the call with control",
    "Find homeowners", "Match and send", "Close and collect", "Tonight’s numbers"],
  notes: [
    ["Kickoff · 10 min", "Everyone writes their why before anything else.", "Share your promise and how the 8 days work. Give them 5 minutes to write their why, then have a couple read theirs out loud.", "The two why questions. Steps 1 to 7 stay locked until they send it."],
    ["Kickoff · 5 min", "Nerves are normal, and they fade.", "Say the script out loud together, then have each student say it once on their own.", "The five script lines and the practiced-out-loud tick."],
    ["Kickoff · 5 min", "Three trades, about 30 contractors, and the list grows every day.", "Each student picks their 3 trades live and adds 5 contractors to the CRM before the call ends.", "The trade picker and their list counter."],
    ["Kickoff · 10 min", "Only real conversations count. 20 a day.", "Demo a live contractor call on speaker so they hear what a real conversation sounds like.", "What counts and what doesn’t, then their +1 counters."],
    ["Kickoff · 10 min", "The 20% is a fact, not a question. Nothing moves until it’s in writing.", "You play the contractor and role-play objections with each student, one by one.", "Say it as fact, and the three steps to get it in writing."],
    ["Kickoff · 5 min", "Be a neighbor, not a salesman.", "Pull up a real Nextdoor or Facebook post and write the reply together.", "What to look for, the neighbor reply, and their counters."],
    ["Kickoff · 5 min", "Every lead goes to a signed contractor, and you confirm the estimate.", "Walk through sending one lead and marking it in the CRM.", "Match, send, confirm the estimate."],
    ["Kickoff · 5 min", "Confirm the job, invoice on the paid day.", "Show where to log a closed lead with the fee so it counts toward $1,000.", "Confirm, invoice, log, and the after-job text."],
    ["Kickoff · 5 min", "Numbers every night, no exceptions.", "Set the time numbers are due and start the group text.", "The five numbers, the CRM tick, and Send to Julian."],
  ],
  pacingTitle: "Kickoff call pacing",
  pacing: [["10 min", "Your promise, the 8 days, and everyone writes their why", "Part 1"], ["10 min", "Confidence and picking 3 trades", "Parts 2–3"],
    ["20 min", "Live contractor call demo, then role-play objections with each student", "Parts 4–5"], ["15 min", "Homeowners, matching, and closing", "Parts 6–8"],
    ["5 min", "Nightly numbers: set the deadline and start the group text", "Part 9"]],
  tip: "Teach by doing: live calls and role play beat explaining.",
  // the nightly numbers: [key, label, daily target or null, hint]
  numbers: [["conv", "Real conversations", 20, "Goal 20"], ["conf", "Contractors confirmed", 1, "Goal 1"], ["leads", "Homeowner leads", 5, "Goal 5"],
    ["sent", "Leads sent", null, "To signed contractors"], ["est", "Estimates booked", null, "Confirmed"]],
  goal: 1000,  // each student, in commission, by day 8
  days: 8,
  // Julian's promises, ticked on My students. [key, what, detail]
  promise: "I will keep up with you every day, make sure no one falls behind, and help anyone who does.",
  standard: "The standard: a conversation only counts if a real person answered and the student pitched them. Target is 20 per day.",
  promises: {
    nightly: [
      ["collect", "Collect every student’s numbers (group text or private text)", "Ticks itself when every student has sent theirs. Tap a name if they texted you instead."],
      ["review", "Go through each student’s numbers", "Check: 20 real conversations, contractors confirmed, homeowner leads, leads sent, estimates booked."],
      ["crm", "Make sure everyone’s numbers are logged in the CRM", "The sheet below shows who says they logged today."],
      ["behind", "Spot anyone falling behind and work with them one on one", "Make sure they treat this like a priority, not a willy-nilly job."],
      ["stepin", "Step in fast: find the leak, give one clear next action", "The yellow box shows where each student is leaking."],
    ],
    today: [
      ["groupcall", "Mandatory group call", "Wins, numbers, Q&A, what we could do better, one commitment each. Every other day: days 1, 3, 5, 7."],
      ["teach", "Teach by doing", "Live calls and role-play objections with each student over the 8 days."],
    ],
    program: [
      ["kickoff", "Kickoff call: walk through the program and demo a live contractor call", "Ticking this starts day 1."],
      ["wrap", "Day 8 wrap-up: review everyone’s final numbers", "Shows up on day 8."],
      ["oneonone", "Day 8: book a one-on-one for anyone short of $1,000", "Anyone under $1,000 on the sheet gets flagged."],
    ],
  },
  script: ["“Hey, this is [your name]. I saw your business on Facebook.”", "“Are y’all staying busy? Could you take on more work?”",
    "“I work with local homeowners and send jobs to contractors I trust.”", "“We just take 20% per job.”", "“I just need your name, company name, and phone number.”"],
  html: {
    why2: `<div class="cc-dark"><b>Goal: $200 a day in commission.</b>All seven steps run every day. It’s a goal to aim at, not a promise: what you make depends on the work you put in.</div>
      <div class="cc-grid3">
        <div class="cc-box"><div class="cc-lbl cc-green">Every night</div>Text Julian your numbers (group text or private text) and make sure they’re logged in the CRM.</div>
        <div class="cc-box"><div class="cc-lbl cc-blue">Every other day</div>Mandatory group call: wins, numbers, Q&amp;A, what we could do better, and one commitment from you.</div>
        <div class="cc-box"><div class="cc-lbl">Day 8</div>Wrap-up. We review your final numbers. Short of $1,000? Julian books a one-on-one with you.</div></div>
      <div class="cc-script cc-big"><div class="cc-lbl">Julian’s promise to you</div><b>“I will keep up with you every day, make sure no one falls behind, and help anyone who does.”</b></div>
      <div class="cc-note">Treat this like a priority, not a side thing. Fall behind and Julian will work with you one on one.</div>`,
    contact1: `<div class="cc-lbl">A conversation only counts if a real person answered and you pitched them</div>
      <div class="cc-grid2 cc-big cc-tall">
        <div class="cc-box"><div class="cc-lbl cc-green">Counts</div>The owner or someone who can decide picks up<br>You get through your pitch, whatever they answer<br>They say no after hearing it (still counts)</div>
        <div class="cc-box cc-bad"><div class="cc-lbl cc-red">Doesn’t count</div>Voicemail or no answer<br>They hang up before you pitch<br>A text with no reply</div></div>
      <div class="cc-grid2 cc-big">
        <div class="cc-script"><div class="cc-lbl">Every day</div><b>20 real conversations</b></div>
        <div class="cc-script"><div class="cc-lbl">Every day</div><b>At least 1 confirmed contractor</b></div></div>
      <div class="cc-note">This is the standard Julian checks every night. Be honest with your count.</div>`,
    control: `<div class="cc-grid2 cc-big">
        <div class="cc-box"><div class="cc-lbl cc-green">Say it as fact</div><b>“We take 20% per job.”</b></div>
        <div class="cc-box cc-bad"><div class="cc-lbl cc-red">Not as a question</div>“Would 20% maybe work for you?”</div></div>
      <div class="cc-lbl">Then get it in writing, before any lead</div>
      <div class="cc-stack">
        <div class="cc-box cc-row"><span class="cc-num">1</span><div>Right after the call, text the terms: <b>“Great talking to you. Confirming: I send you jobs, and you pay me 20% of each job I send. Reply YES to confirm.”</b></div></div>
        <div class="cc-box cc-row"><span class="cc-num">2</span><div>Wait for their reply agreeing. A text with no reply doesn’t count.</div></div>
        <div class="cc-box cc-row"><span class="cc-num cc-go">3</span><div>Or have them sign the Contractor Referral Agreement. Then mark them confirmed in the CRM.</div></div></div>
      <div class="cc-note">No agreement in writing, no leads.</div>`,
    match: `<div class="cc-stack cc-big">
        <div class="cc-box cc-row"><span class="cc-num">1</span><div><b>Match.</b> Pick a contractor in that trade who already agreed to 20% in writing.</div></div>
        <div class="cc-box cc-row"><span class="cc-num">2</span><div><b>Send.</b> Text them: “Hey, [homeowner] will be reaching out soon about [job]. Please keep me updated on whether they reach out and what the verdict ends up being.”</div></div>
        <div class="cc-box cc-row"><span class="cc-num cc-go">3</span><div><b>Confirm the estimate is booked.</b> Check with the contractor and the homeowner, then mark it in the CRM.</div></div></div>
      <div class="cc-note">No estimate booked by the next day? Follow up. Contractor goes quiet? Send the next lead to someone else.</div>`,
    collect: `<div class="cc-stack cc-big">
        <div class="cc-box cc-row"><span class="cc-num">1</span><div><b>Confirm the job.</b> Check with both the homeowner and the contractor that it’s going ahead, and for how much.</div></div>
        <div class="cc-box cc-row"><span class="cc-num">2</span><div><b>Invoice on the paid day.</b> The day the homeowner pays the contractor, send your invoice for 20% of the job.</div></div>
        <div class="cc-box cc-row"><span class="cc-num cc-go">3</span><div><b>Log it.</b> Mark the lead closed in the CRM with your fee, so it counts toward your goal.</div></div></div>
      <div class="cc-script"><b>After the job, text the homeowner:</b> “Hey, I hope everything turned out well for you. If you ever want to be connected with anyone else for other jobs you have planned, I’d be happy to help.”</div>`,
  },
};
