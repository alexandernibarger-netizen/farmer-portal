// Supabase project "Lead Farming CRM". The publishable key is safe in the browser;
// row-level security in the database decides what each farmer can see.
window.CRM_CONFIG = {
  SUPABASE_URL: "https://rkjsfuflfuckqyvaychm.supabase.co",
  SUPABASE_KEY: "sb_publishable_n-UVkRvGL1j_rs2it1P6jg_lYH2kuSK",
  PROGRAM_NAME: "Lead Farming Mentoring Program",
  // Enrollment price in dollars; keep it in step with the Stripe Payment Link and the Terms.
  PRICE: 499,
  // Stripe Payment Link for the enrollment (https://buy.stripe.com/...). Leave empty to hide the Pay button.
  PAYMENT_LINK: "https://buy.stripe.com/3cIaEX99WcV9dS3abn5gc01",
  // Alex's Cal.com event for intro calls, as "username/event" (from https://cal.com/username/event).
  // Leave empty and the landing page form still reaches Alex on Telegram; it just shows no calendar.
  CAL_LINK: "",
  // Meta (Facebook/Instagram) pixel ID, digits only, from https://business.facebook.com/events_manager2
  // Leave empty and no pixel or cookie notice loads.
  META_PIXEL_ID: "",
  // Founder video on the landing page: a YouTube or Vimeo link, or a file in the site (e.g. "/media/alex.mp4").
  // Leave empty to hide the "Meet Alex" section.
  FOUNDER_VIDEO: "",
  // Zelle email or phone shown to unpaid farmers. Leave empty to hide.
  ZELLE_TO: "",
};
