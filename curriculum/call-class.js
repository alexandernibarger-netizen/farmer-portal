// Vincent Beck's "Cold Calling & Confidence" class: a teacher lesson only his students see (Learn > Teacher lesson).
// Follows his 17-slide deck. Each part is one or more screens that fit without scrolling; the app adds the
// interactive bits (talking-points tick, role play, feedback, challenge, tracking, discussion).
window.TEACHER_LESSONS = window.TEACHER_LESSONS || {};
window.TEACHER_LESSONS["call-confidence"] = {
  title: "Cold Calling & Confidence",
  by: "Vincent Beck",
  sub: "Starting conversations, handling rejection, and building contractor relationships.",
  // [title, slides, the one line to remember]
  parts: [
    ["Mindset", "Slides 2–4", "A cold call is not a demand for a yes. It is a respectful way to check whether there may be a fit."],
    ["Preparation", "Slide 5", "Preparation lowers anxiety and keeps you from wasting a contractor’s time."],
    ["Call flow", "Slide 6", "You don’t need to memorize every word. Remember the sequence."],
    ["Talking points", "Slide 7", "No script, just bullet points. You are not a salesman."],
    ["Ask & listen", "Slide 8", "Learn about the contractor before you pitch."],
    ["Your offer", "Slide 9", "Trust beats a big claim. Never promise leads, jobs, or earnings you can’t back up."],
    ["Objections", "Slide 10", "Respond calmly, never argue. A clear no is a reason to end politely."],
    ["Delivery", "Slide 11", "Confidence is heard in your pace, clarity, and listening."],
    ["Role play & feedback", "Slide 12", "Make it feel real. Pair up and switch roles after each round."],
    ["Confidence challenge", "Slide 13", "Start small. Build consistency. Review, don’t judge yourself."],
    ["Tracking & trust", "Slides 14–15", "Track the process, not just the wins, and protect the trust people give you."],
    ["Final takeaway", "Slide 16", "Confidence comes from keeping promises to yourself."],
  ],
  // [part index, screen key], in order
  screens: [[0, "m1"], [0, "m2"], [0, "m3"], [1, "prep"], [2, "flow"], [3, "talk"], [4, "ask"], [5, "offer"], [6, "obj"], [7, "deliv"],
    [8, "rp1"], [8, "rp2"], [9, "chal"], [10, "trk1"], [10, "trk2"], [11, "close"]],
  firstSlide: [2, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16],
  // slide 1..17 -> part index (title and instructor notes fall on the nearest part)
  slidePart: [0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 11, 11],
  slideName: ["Title", "What you’ll learn", "Why it feels uncomfortable", "Start a conversation", "Preparation", "Call flow", "Talking points", "Ask & listen",
    "Your offer", "Objections", "Delivery", "Role play", "Confidence challenge", "Tracking", "Trust", "Final takeaway", "Instructor notes (only you)"],
  // For the teacher, per part: [time, the point to land, do with the class, what students are seeing]
  notes: [
    ["Slides 2–4 · 5 min", "Take the pressure off. A cold call is a conversation, not a demand for a yes.", "Ask each student which fear is biggest for them: rejection, sounding awkward, or the unknown.", "What you’ll learn, the three fear cards, then Don’t aim to / Aim to / Success can mean."],
    ["Slide 5 · part of 8 min", "Preparation lowers anxiety.", "Run the 30-second reset together: sit tall, one slow breath, relax jaw and shoulders, slight smile.", "The homework checklist and the 30-second reset card."],
    ["Slide 6 · part of 8 min", "Remember the sequence, not the words.", "Have one student say the five steps from memory: Open, Ask, Listen, Explain, Next step.", "The five numbered steps."],
    ["Slide 7 · part of 8 min", "No script. You are not a salesman.", "Each student says the talking points out loud once, in their own words. Stop anyone who sounds like they’re reading.", "The eight talking points, including “We just take 20% per job.”"],
    ["Slide 8 · part of 8 min", "Learn about the contractor before you pitch.", "Pairs ask each other the five questions, one minute each.", "The five questions, ending with the big question."],
    ["Slide 9 · part of 7 min", "Trust beats a big claim.", "Have each student say their “just starting” line out loud. Remind them: 20%, and terms in writing before any lead.", "The three offer cards."],
    ["Slide 10 · part of 7 min", "Respond calmly, never argue.", "You play the contractor and throw each of the four objections at a different student.", "The four objection cards."],
    ["Slide 11 · part of 7 min", "Confidence is pace, clarity, and listening.", "One student says the talking points fast, then slow. The class picks which one sounded confident.", "Slow down, Use plain words, Listen first."],
    ["Slide 12 · 12 min", "Make it feel real.", "Shuffle pairs, then run all three rounds (Busy, Skeptical, Interested), switching roles each round. Feedback rule: one thing done well, one thing to improve.", "Their partner, the round, and the feedback form that sends to you."],
    ["Slide 13 · part of 5 min", "Start small, build consistency.", "Everyone picks a day this week for their 3–5 practice calls.", "The five challenge steps and the practice-call counter."],
    ["Slides 14–15 · part of 5 min", "Track the process, protect trust.", "Show where to tap +1. Stress the do-not-contact rule and getting fees in writing.", "The six numbers, then the trust rules."],
    ["Slide 16 · part of 5 min", "Confidence comes from keeping promises to yourself.", "Ask the discussion question. Everyone answers before they leave.", "The takeaway and the discussion box, which sends their answer to you."],
  ],
  pacing: [["5 min", "Mindset and objectives", "Slides 2–4"], ["8 min", "Preparation, call flow, and talking points", "Slides 5–8"],
    ["7 min", "Offer, objections, and delivery", "Slides 9–11"], ["12 min", "Pair role play and feedback", "Slide 12"], ["5 min", "Challenge, tracking, and close", "Slides 13–16"]],
  tip: "Reward honesty, clarity, listening, and respectful exits, not just getting a yes.",
  rounds: [
    ["Round 1 · Busy", "“I’m in the middle of a job. What’s this about?”", "Give a 10-second explanation and ask for a better time."],
    ["Round 2 · Skeptical", "“How do I know this is real?”", "Explain the process honestly without claims you can’t back up."],
    ["Round 3 · Interested", "“Maybe. What would you need from me?”", "Ask about their services, location, and next steps."],
  ],
  challenge: ["Say your talking points out loud five times", "Practice three objections with a partner", "Research five legitimate local contractors",
    "Make 3–5 respectful practice calls when ready", "Write down one lesson and one improvement"],
  metrics: [["calls", "Calls made", "Consistency and effort"], ["answered", "Calls answered", "How often you reach someone"],
    ["convos", "Real conversations", "Reaching decision-makers"], ["interested", "Interested", "Possible partners"],
    ["agreed", "Agreements", "Terms clearly accepted"], ["follow", "Follow-ups done", "Honoring next steps"]],
  talking: ["“I saw your business on Facebook.”", "“Are y’all staying busy? Could you take on more work?”", "“I work with local businesses and get them leads.”",
    "“Work is piling up.”", "“Looking to replace him.”", "“We just take 20% per job.”", "“If that sounds good, I’d love to start working with you.”",
    "“I just need your name, company name, and phone number.”"],
  // Static screens
  html: {
    m1: `<div class="cc-lbl">By the end of this class you can make a professional first call and learn from it</div>
      <div class="cc-grid2 cc-big">
        <div class="cc-box"><div class="cc-k">01</div><b>Mindset</b><br>Less pressure. Know what a cold call is, and isn’t.</div>
        <div class="cc-box"><div class="cc-k">02</div><b>Script</b><br>Open naturally, ask good questions, explain honestly.</div>
        <div class="cc-box"><div class="cc-k">03</div><b>Objections</b><br>Stay calm. No arguing, pressure, or promises.</div>
        <div class="cc-box"><div class="cc-k">04</div><b>Repetition</b><br>Practice, track results, get better one call at a time.</div></div>`,
    m2: `<div class="cc-lbl">Why it feels uncomfortable</div>
      <div class="cc-grid3">
        <div class="cc-box"><div class="cc-lbl">Fear of rejection</div><b class="cc-q">“What if they say no?”</b><p>A no is information, not a verdict on your worth. Just move on, they are not worth it anyway.</p></div>
        <div class="cc-box"><div class="cc-lbl">Fear of sounding awkward</div><b class="cc-q">“What if I mess up?”</b><p>You’re allowed to pause, restart, and speak naturally. It’s a normal conversation with a regular person just like you.</p></div>
        <div class="cc-box"><div class="cc-lbl">Fear of the unknown</div><b class="cc-q">“What if they ask something?”</b><p>Prepare for common questions. Be honest when you don’t know.</p></div></div>
      <div class="cc-note">Remember: confidence is built through action, not by waiting until you feel fearless.</div>`,
    m3: `<div class="cc-lbl">Your job is to start a conversation</div>
      <div class="cc-grid3 cc-big cc-tall">
        <div class="cc-box cc-bad"><div class="cc-lbl cc-red">Don’t aim to</div>Convince everybody<br>Sound perfect<br>Close a deal instantly</div>
        <div class="cc-box"><div class="cc-lbl cc-green">Aim to</div>Be clear and respectful<br>Get them on your side<br>Find out if they’re a good fit</div>
        <div class="cc-box"><div class="cc-lbl cc-blue">Success can mean</div>A conversation that ends in a partnership<br>Getting them one single job<br>A follow-up where they’re begging you for work</div></div>`,
    prep: `<div class="cc-split">
      <div class="cc-stack cc-main"><div class="cc-lbl">Do your homework before dialing</div>
        <div class="cc-script">Know the contractor’s <b>trade, service area, and business name</b>.</div>
        <div class="cc-script">Know your honest offer: what you do, how referrals work, and what you <b>don’t</b> promise.</div>
        <div class="cc-script">Keep your talking points and a few questions in front of you.</div>
        <div class="cc-script">Pick a quiet place, speak clearly, and keep your notes organized.</div>
        <div class="cc-script">Set a small goal, like <b>3–5 calls</b>, instead of chasing a perfect outcome.</div></div>
      <div class="cc-reset"><div class="cc-lbl">30-second reset</div>Sit or stand tall.<br>Take one slow breath.<br>Relax your jaw and shoulders.<br>Smile slightly and speak at a steady pace.</div></div>`,
    flow: `<div class="cc-stack cc-big">
      <div class="cc-box cc-row"><span class="cc-num">1</span><div><b>Open.</b> Introduce yourself and acknowledge you’re interrupting.</div></div>
      <div class="cc-box cc-row"><span class="cc-num">2</span><div><b>Ask.</b> Are they staying busy, and can they take on more clients? Whatever they say, keep going.</div></div>
      <div class="cc-box cc-row"><span class="cc-num">3</span><div><b>Listen.</b> Ask what jobs and service areas fit them best.</div></div>
      <div class="cc-box cc-row"><span class="cc-num">4</span><div><b>Explain.</b> Your process, honestly: what you offer and how you can help them.</div></div>
      <div class="cc-box cc-row"><span class="cc-num cc-go">5</span><div><b>Next step.</b> Get their info for your CRM and tell them you’ll reach out.</div></div></div>`,
    ask: `<div class="cc-stack cc-big">
      <div class="cc-box cc-qa"><b>Capacity</b><span>“Are you currently taking on new jobs?”</span></div>
      <div class="cc-box cc-qa"><b>Best-fit work</b><span>“What types of jobs are you most interested in?”</span></div>
      <div class="cc-box cc-qa"><b>Service area</b><span>“Which cities or neighborhoods do you cover?”</span></div>
      <div class="cc-box cc-qa"><b>Lead preferences</b><span>“What do you need to know before you take a lead?”</span></div>
      <div class="cc-box cc-qa cc-gold"><b>The big question</b><span>“Do you like money? Because I only work with people who like money.”</span></div></div>`,
    offer: `<div class="cc-grid3 cc-big">
        <div class="cc-box"><div class="cc-lbl">If you’re just starting</div>“I’m building a local referral network and looking for reliable contractors before I begin sending opportunities.”</div>
        <div class="cc-box"><div class="cc-lbl">If you already have leads</div>Explain where inquiries come from, what makes them qualified, and what information is shared.</div>
        <div class="cc-box"><div class="cc-lbl">Be clear on terms</div>Fees, when you get paid, exclusivity, invalid leads, and how finished jobs get reported.</div></div>
      <div class="cc-note">A good partnership is clear on both sides before any customer information is shared.</div>`,
    obj: `<div class="cc-grid2">
        <div class="cc-box"><b class="cc-q">“We’re not interested.”</b><p><b class="cc-green">You:</b> “Understood. Thanks for your time. Have a good one.”</p></div>
        <div class="cc-box"><b class="cc-q">“How much does it cost?”</b><p><b class="cc-green">You:</b> “I send you leads, you just send 20%. I don’t get paid until you get paid.”</p></div>
        <div class="cc-box"><b class="cc-q">“Do you have leads right now?”</b><p><b class="cc-green">You:</b> “I’m building the network now, so I want to be upfront about where things stand.”</p></div>
        <div class="cc-box"><b class="cc-q">“Send me information.”</b><p><b class="cc-green">You:</b> “Sure. I’ll shoot you a text and tell you more.”</p></div></div>
      <div class="cc-note">If they ask not to be contacted again, thank them and honor it.</div>`,
    deliv: `<div class="cc-grid3 cc-big">
        <div class="cc-box"><div class="cc-lbl cc-green">Slow down</div>Pause after questions. Don’t rush to fill every silence.</div>
        <div class="cc-box"><div class="cc-lbl cc-green">Use plain words</div>Talk like a real person. Don’t sound like you’re reading an ad.</div>
        <div class="cc-box"><div class="cc-lbl cc-green">Listen first</div>Let the contractor finish. Say back what you heard before you answer.</div></div>
      <div class="cc-script"><b>Try this:</b> record a practice call and listen back for speed, clarity, and whether you sound natural.</div>`,
    trk2: `<div class="cc-lbl">Protect trust</div><div class="cc-grid2">
        <div class="cc-script">Use real business contact info and say who you are.</div>
        <div class="cc-script">Respect “don’t contact me again”. Don’t push after a clear no.</div>
        <div class="cc-script">Follow calling, texting, privacy, and marketing rules.</div>
        <div class="cc-script">Get permission before sharing a homeowner’s personal info.</div>
        <div class="cc-script">Put fees, payment timing, lead rules, and disputes in writing.</div>
        <div class="cc-script">Never fake demand, testimonials, results, or a contractor relationship.</div></div>
      <div class="cc-note">Not sure about a legal rule? Pause and ask your teacher or Alex first.</div>`,
  },
};
