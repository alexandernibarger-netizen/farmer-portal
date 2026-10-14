// Where visitors come from, the Meta pixel, and the cookie notice. Loaded after config.js on the
// landing page and in the portal.
// - First visit: utm_* tags, fbclid and ?ref are saved in this browser, so sign-up and the call form can
//   record them later (window.lfMeta()). The first source wins; later visits don't overwrite it.
// - Meta pixel (META_PIXEL_ID in config.js): PageView on every page, Lead when a call is booked,
//   Purchase when an enrollment is paid (window.lfTrack). It sets cookies, so a notice explains that
//   and "No thanks" turns it off in this browser. A browser sending Global Privacy Control never loads it.
(function () {
  var C = window.CRM_CONFIG || {};
  var store = { get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
                set: function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} } };

  // ---- attribution ----
  var q = new URLSearchParams(location.search), seen = {};
  ["utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term", "fbclid", "ref"].forEach(function (k) {
    var v = q.get(k); if (v) seen[k] = v.slice(0, 200);
  });
  if (Object.keys(seen).length && !store.get("lf_attr")) {
    seen.landing = location.pathname.slice(0, 100);
    if (document.referrer && document.referrer.indexOf(location.host) < 0) seen.referrer = document.referrer.slice(0, 200);
    seen.first_seen = new Date().toISOString();
    store.set("lf_attr", JSON.stringify(seen));
  }
  window.lfMeta = function () { try { return JSON.parse(store.get("lf_attr") || "{}"); } catch (e) { return {}; } };

  // ---- Meta pixel ----
  var ID = C.META_PIXEL_ID, gpc = navigator.globalPrivacyControl === true;
  var choice = store.get("lf_cookies");  // "yes" (OK), "no" (No thanks) or null (not answered)
  function loadPixel() {
    if (window.fbq || !ID) return;
    /* Meta's standard pixel loader */
    !function (f, b, e, v, n, t, s) { if (f.fbq) return; n = f.fbq = function () { n.callMethod ? n.callMethod.apply(n, arguments) : n.queue.push(arguments); };
      if (!f._fbq) f._fbq = n; n.push = n; n.loaded = !0; n.version = "2.0"; n.queue = []; t = b.createElement(e); t.async = !0;
      t.src = v; s = b.getElementsByTagName(e)[0]; s.parentNode.insertBefore(t, s); }(window, document, "script", "https://connect.facebook.net/en_US/fbevents.js");
    fbq("init", ID);
    fbq("track", "PageView");
  }
  window.lfTrack = function (event, params) {
    if (window.fbq && choice !== "no" && !gpc) fbq("track", event, params || {});
  };
  if (ID && !gpc && choice !== "no") loadPixel();

  // ---- cookie notice (only when the pixel is configured) ----
  if (!ID || gpc || choice) return;
  function show() {
    var bar = document.createElement("div");
    bar.id = "cookiebar"; bar.setAttribute("role", "region"); bar.setAttribute("aria-label", "Cookie notice");
    bar.style.cssText = "position:fixed;left:12px;right:12px;bottom:12px;z-index:9999;max-width:720px;margin:0 auto;background:#fff;color:#2B3A2E;border:2px solid #E6EBE1;border-bottom-width:5px;border-radius:18px;padding:14px 16px;display:flex;flex-wrap:wrap;gap:10px 14px;align-items:center;font:15px/1.45 Nunito,system-ui,sans-serif;box-shadow:0 8px 24px rgba(0,0,0,.12)";
    bar.innerHTML = '<span style="flex:1 1 320px">We use cookies, including Meta\'s pixel, to see which of our ads bring people here. <a href="/privacy/#cookies" style="color:#2E7A12">Privacy Policy</a></span>'
      + '<span style="display:flex;gap:8px"><button type="button" id="cookieok" style="font:inherit;font-weight:900;border:0;border-radius:12px;padding:9px 16px;background:#58CC02;color:#fff;cursor:pointer">OK</button>'
      + '<button type="button" id="cookieno" style="font:inherit;font-weight:900;border:2px solid #E6EBE1;border-radius:12px;padding:7px 14px;background:#fff;color:#1C7AAE;cursor:pointer">No thanks</button></span>';
    document.body.appendChild(bar);
    document.getElementById("cookieok").onclick = function () { choice = "yes"; store.set("lf_cookies", "yes"); bar.remove(); };
    document.getElementById("cookieno").onclick = function () {
      choice = "no"; store.set("lf_cookies", "no"); bar.remove();
      if (window.fbq) fbq("consent", "revoke");
    };
  }
  if (document.body) show(); else document.addEventListener("DOMContentLoaded", show);
})();
