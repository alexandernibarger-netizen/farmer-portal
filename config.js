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
  // Zelle email or phone shown to unpaid farmers. Leave empty to hide.
  ZELLE_TO: "",
};
