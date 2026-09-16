/// Injected into Gmail to report the inbox unread count to native code, which shows it
/// as a Dock badge. Two sources, in order of preference:
///  1. The "Inbox" item in Gmail's left navigation (its aria-label reads "Inbox 12 unread",
///     and it carries a `.bsU` count span). Reflects the UI instantly and works in any view.
///  2. Gmail's own Atom feed (`/mail/feed/atom`), same-origin so cookies apply. Used when
///     the nav isn't rendered (e.g. collapsed / basic HTML / still loading).
enum UnreadBadgeScript {
    static let handlerName = "gmailUnread"

    static let script = """
    (function () {
      if (window.__gmailWrapperUnread) { return; }
      window.__gmailWrapperUnread = true;

      var last = null;
      var lastFeedAt = 0;
      var feedInFlight = false;

      function post(count, source) {
        count = Math.max(0, count | 0);
        if (count === last) { return; }
        last = count;
        try {
          window.webkit.messageHandlers.\(handlerName).postMessage({ count: count, source: source });
        } catch (e) {}
      }

      function parseInt10(text) {
        var m = String(text || '').replace(/[,.\\s]/g, '').match(/\\d+/);
        return m ? parseInt(m[0], 10) : null;
      }

      // Returns the count from the nav, or null if the Inbox nav item can't be found.
      function readFromNav() {
        // Gmail has several role=navigation regions; the label list isn't always the
        // first, so look document-wide for the Inbox link.
        var links = document.querySelectorAll('a[href*="#inbox"]');
        if (!links.length) { return null; }
        for (var i = 0; i < links.length; i++) {
          var link = links[i];
          var label = link.getAttribute('aria-label') || '';
          // Skip the Gmail logo (also href="#inbox") and anything that isn't the Inbox row.
          if (!/inbox/i.test(label) && !/inbox/i.test(link.textContent || '')) { continue; }
          var m = label.match(/(\\d[\\d,.]*)\\s+unread/i);
          if (m) { return parseInt10(m[1]); }
          // Inbox item exists but no "unread" in label: either zero unread, or the count
          // lives in a sibling span.
          var row = link.closest('div');
          for (var up = 0; row && up < 4; up++) {
            var span = row.querySelector('.bsU');
            if (span) {
              var n = parseInt10(span.textContent);
              return n === null ? 0 : n;
            }
            row = row.parentElement;
          }
          return 0;
        }
        return null;
      }

      function readFromFeed() {
        var now = Date.now();
        if (feedInFlight || now - lastFeedAt < 60000) { return; }
        feedInFlight = true;
        lastFeedAt = now;
        fetch('/mail/feed/atom', { credentials: 'include', cache: 'no-store' })
          .then(function (r) { return r.ok ? r.text() : ''; })
          .then(function (xml) {
            var m = xml.match(/<fullcount>(\\d+)<\\/fullcount>/);
            if (m) { post(parseInt(m[1], 10), 'feed'); }
          })
          .catch(function () {})
          .finally(function () { feedInFlight = false; });
      }

      var scheduled = false;
      function update() {
        scheduled = false;
        var n = readFromNav();
        if (n !== null) { post(n, 'nav'); } else { readFromFeed(); }
      }
      function schedule() {
        if (scheduled) { return; }
        scheduled = true;
        setTimeout(update, 400);
      }

      function start() {
        update();
        try {
          new MutationObserver(schedule).observe(document.body, {
            childList: true, subtree: true, characterData: true,
            attributes: true, attributeFilter: ['aria-label']
          });
        } catch (e) {}
        setInterval(update, 5000);
      }

      if (document.body) { start(); } else { document.addEventListener('DOMContentLoaded', start); }
    })();
    """
}
