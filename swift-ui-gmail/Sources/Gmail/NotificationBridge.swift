import AppKit
import UserNotifications

/// WKWebView has no Web Notifications support on macOS, so we replace `window.Notification`
/// with a shim that forwards to native code, which posts a macOS notification instead.
enum NotificationBridge {
    static let handlerName = "gmailNotify"
    static let clickCallback = "__gmailWrapperNotificationClicked"

    static let script = """
    (function () {
      if (window.__gmailWrapperNotificationShim) { return; }
      window.__gmailWrapperNotificationShim = true;

      var instances = {};
      var counter = 0;

      function ShimNotification(title, options) {
        options = options || {};
        this.title = String(title || '');
        this.body = String(options.body || '');
        this.tag = String(options.tag || '');
        this.icon = options.icon || '';
        this.data = options.data;
        this.onclick = null; this.onclose = null; this.onerror = null; this.onshow = null;
        this._id = String(++counter);
        instances[this._id] = this;
        try {
          window.webkit.messageHandlers.\(handlerName).postMessage({
            id: this._id, title: this.title, body: this.body, tag: this.tag
          });
        } catch (e) {}
        var self = this;
        setTimeout(function () { if (typeof self.onshow === 'function') { self.onshow(new Event('show')); } }, 0);
      }

      ShimNotification.prototype.close = function () {
        delete instances[this._id];
        if (typeof this.onclose === 'function') { this.onclose(new Event('close')); }
      };
      ShimNotification.prototype.addEventListener = function (type, fn) { this['on' + type] = fn; };
      ShimNotification.prototype.removeEventListener = function (type) { this['on' + type] = null; };
      ShimNotification.prototype.dispatchEvent = function () { return true; };

      ShimNotification.permission = 'granted';
      ShimNotification.maxActions = 0;
      ShimNotification.requestPermission = function (callback) {
        var p = Promise.resolve('granted');
        if (typeof callback === 'function') { p.then(callback); }
        return p;
      };

      window.\(clickCallback) = function (id) {
        var n = instances[id];
        if (n && typeof n.onclick === 'function') { n.onclick(new Event('click')); }
        window.focus();
      };

      window.Notification = ShimNotification;
    })();
    """
}

/// Thin wrapper over UNUserNotificationCenter that is safe to call when the binary is run
/// outside an .app bundle (where UNUserNotificationCenter would crash).
enum NotificationSupport {
    static let isAvailable: Bool = {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }()

    static func requestAuthorization(delegate: UNUserNotificationCenterDelegate) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(title: String, body: String, identifier: String = UUID().uuidString, userInfo: [String: Any]) {
        guard isAvailable else {
            NSLog("[notification] %@ — %@", title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
