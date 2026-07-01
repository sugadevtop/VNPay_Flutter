import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:vnpay_flutter/src/model/enum/vnpay_payment_status.dart';

//[VNPayHashType] List of Hash Type in VNPAY, default is HMACSHA512
enum VNPayHashType {
  SHA256,
  HMACSHA512,
}

//[BankCode] List of valid payment bank in VNPAY, if not provide, it will be manual select, default is null
enum BankCode { VNPAYQR, VNBANK, INTCARD }

//[VNPayHashTypeExt] Extension to convert from HashType Enum to valid string of VNPAY
extension VNPayHashTypeExt on VNPayHashType {
  String toValueString() {
    switch (this) {
      case VNPayHashType.SHA256:
        return 'SHA256';
      case VNPayHashType.HMACSHA512:
        return 'HmacSHA512';
    }
  }
}

//[VNPAYFlutter] instance class VNPAY Flutter
class VNPAYFlutter {
  static final VNPAYFlutter _instance = VNPAYFlutter();

  //[instance] Single Ton Init
  static VNPAYFlutter get instance => _instance;

  Map<String, dynamic> _sortParams(Map<String, dynamic> params) {
    final sortedParams = <String, dynamic>{};
    final keys = params.keys.toList()..sort();
    for (String key in keys) {
      sortedParams[key] = params[key];
    }
    return sortedParams;
  }

  //[generatePaymentUrl] Generate payment Url with input parameters
  String generatePaymentUrl({
    String url = 'https://sandbox.vnpayment.vn/paymentv2/vpcpay.html',
    required String version,
    String command = 'pay',
    required String tmnCode,
    String locale = 'vn',
    String currencyCode = 'VND',
    required String txnRef,
    String orderInfo = 'Pay Order',
    required double amount,
    required String returnUrl,
    required String ipAdress,
    DateTime? createAt,
    required String vnpayHashKey,
    VNPayHashType vnPayHashType = VNPayHashType.HMACSHA512,
    String vnpayOrderType = 'other',
    BankCode? bankCode,
    required DateTime vnpayExpireDate,
  }) {
    final params = <String, String>{
      'vnp_Version': version,
      'vnp_Command': command,
      'vnp_TmnCode': tmnCode,
      'vnp_Locale': locale,
      'vnp_CurrCode': currencyCode,
      'vnp_TxnRef': txnRef,
      'vnp_OrderInfo': orderInfo,
      'vnp_Amount': (amount * 100).toStringAsFixed(0),
      'vnp_ReturnUrl': returnUrl,
      'vnp_IpAddr': ipAdress,
      'vnp_CreateDate': DateFormat('yyyyMMddHHmmss').format(createAt ?? DateTime.now()).toString(),
      'vnp_OrderType': vnpayOrderType,
      'vnp_ExpireDate': DateFormat('yyyyMMddHHmmss').format(vnpayExpireDate).toString(),
    };
    if (bankCode != null) {
      params['vnp_BankCode'] = bankCode.name;
    }
    var sortedParam = _sortParams(params);
    final hashDataBuffer = StringBuffer();
    sortedParam.forEach((key, value) {
      hashDataBuffer.write(key);
      hashDataBuffer.write('=');
      hashDataBuffer.write(value);
      hashDataBuffer.write('&');
    });
    String hashData = hashDataBuffer.toString().substring(0, hashDataBuffer.length - 1);

    // URL-encode query parameter values to ensure special characters
    // (e.g. spaces, '&', '?', '=') produce a valid payment URL.
    // The hash is still calculated from the original values, matching
    // VNPay's signature validation rules.
    String query = sortedParam.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    String vnpSecureHash = "";

    if (vnPayHashType == VNPayHashType.SHA256) {
      List<int> bytes = utf8.encode(vnpayHashKey + hashData.toString());
      vnpSecureHash = sha256.convert(bytes).toString();
    } else if (vnPayHashType == VNPayHashType.HMACSHA512) {
      vnpSecureHash = Hmac(sha512, utf8.encode(vnpayHashKey)).convert(utf8.encode(hashData)).toString();
    }
    String paymentUrl = "$url?$query&vnp_SecureHashType=${vnPayHashType.toValueString()}&vnp_SecureHash=$vnpSecureHash";
    debugPrint("=====>[PAYMENT URL]: $paymentUrl");
    return paymentUrl;
  }

  /// Opens an external application for non-HTTP(S) URLs such as
  /// banking app deep links, VNPay links, or Android intent URLs.
  /// Returns true if an external application is launched successfully.
  Future<bool> _launchExternalApp(String url) async {
    // Android intent URL: intent://HOST/PATH#Intent;scheme=SCHEME;package=PKG;S.browser_fallback_url=URL;end
    if (url.startsWith('intent://')) {
      final fragmentIndex = url.indexOf('#Intent;');
      final base = fragmentIndex >= 0 ? url.substring('intent://'.length, fragmentIndex) : url.substring('intent://'.length);
      final fragment = fragmentIndex >= 0 ? url.substring(fragmentIndex + '#Intent;'.length) : '';

      String? scheme;
      String? fallbackUrl;
      for (final part in fragment.split(';')) {
        if (part.startsWith('scheme=')) {
          scheme = part.substring('scheme='.length);
        } else if (part.startsWith('S.browser_fallback_url=')) {
          fallbackUrl = Uri.decodeFull(part.substring('S.browser_fallback_url='.length));
        }
      }

      // Launch the target application if available.
      if (scheme != null && scheme.isNotEmpty) {
        try {
          final appUri = Uri.parse('$scheme://$base');
          if (await launchUrl(appUri, mode: LaunchMode.externalApplication)) {
            return true;
          }
        } catch (_) {
          // Failed to launch the target app. Try the fallback URL instead.
        }
      }

      // Open the fallback URL if the target application cannot be launched.
      if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
        try {
          return await launchUrl(Uri.parse(fallbackUrl), mode: LaunchMode.externalApplication);
        } catch (_) {
          return false;
        }
      }
      return false;
    }

    // Launch other custom URL schemes directly.
    try {
      return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  // Force links and window.open() to stay in the current WebView.
  // This keeps the payment flow in a single WebView whenever possible.
  static const String _forceSameWindowJs = '''
(function() {
  try {
    window.open = function(url) {
      if (url) { window.location.href = url; }
      return window;
    };
    if (!window.__vnpaySameWindowPatched__) {
      window.__vnpaySameWindowPatched__ = true;
      document.addEventListener('click', function(e) {
        var el = e.target;
        while (el && el.tagName !== 'A') { el = el.parentElement; }
        if (el && el.target && el.target !== '_self') { el.target = '_self'; }
      }, true);
    }
  } catch (e) {}
})();
''';

  /// Returns the payment status from a VNPay SDK callback host.
  VNPayPaymentStatus _statusFromSentinel(String host) {
    if (host.startsWith('success')) return VNPayPaymentStatus.success;
    if (host.startsWith('cancel')) return VNPayPaymentStatus.cancelled;
    if (host.startsWith('fail')) return VNPayPaymentStatus.failed;
    return VNPayPaymentStatus.unknown;
  }

  /// Handles payment callback URLs and determines whether the navigation should continue or be intercepted.
  NavigationActionPolicy _handleUrl({
    required String url,
    required Uri returnUri,
    required Function(VNPayPaymentStatus) onResponse,
    required BuildContext context,
  }) {
    final currentUri = Uri.parse(url);

    final hasVnpResult = currentUri.queryParameters.containsKey('vnp_ResponseCode') || currentUri.queryParameters.containsKey('vnp_TxnRef');
    final hostPathMatch = currentUri.host == returnUri.host && currentUri.path == returnUri.path;
    final isSentinel = currentUri.host.endsWith('sdk.merchantbackapp');
    final isCallback = isSentinel || (hostPathMatch && hasVnpResult);

    if (isCallback) {
      final status = isSentinel ? _statusFromSentinel(currentUri.host) : getPaymentStatus(currentUri.queryParameters);
      onResponse(status);
      Navigator.of(context).pop();
      return NavigationActionPolicy.CANCEL;
    }

    return NavigationActionPolicy.ALLOW;
  }

  /// Show payment webview
  ///
  /// [onPaymentSuccess], [onPaymentCancel], [onPaymentFailed], [onOpenBankingApp] callback when payment success, cancel, failed, open banking app on app
  Future<void> show({
    required BuildContext context,
    required String paymentUrl,
    required String returnUrl,
    AppBar? appBar,
    Function()? onWebPaymentComplete,
    required Function(VNPayPaymentStatus) onResponse,
  }) async {
    if (kIsWeb) {
      await launchUrlString(
        paymentUrl,
        webOnlyWindowName: '_self',
      );
      if (onWebPaymentComplete != null) {
        onWebPaymentComplete();
      }
      return;
    }

    final returnUri = Uri.parse(returnUrl);

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SafeArea(
          child: Scaffold(
            backgroundColor: Colors.white,
            appBar: appBar != null
                ? appBar
                : AppBar(
              backgroundColor: Colors.black.withValues(alpha: 0.1),
            ),
            body: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(paymentUrl)),
              initialSettings: InAppWebViewSettings(
                // Allow pages to request opening a new window.
                // Used as a fallback when a page cannot stay in the current WebView.
                javaScriptEnabled: true,
                javaScriptCanOpenWindowsAutomatically: true,
                supportMultipleWindows: true,
              ),

              // Inject helper scripts before the page starts loading.
              // Used to keep navigation in the current WebView whenever possible.
              initialUserScripts: UnmodifiableListView([
                UserScript(
                  source: _forceSameWindowJs,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
              ]),

              // Main navigation handler.
              // Detects payment callbacks, launches external banking apps,
              // and decides whether to allow or block navigation.
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                print("============ VNPAY==============");
                print("URL: ${navigationAction.request.url}");
                print("Method: ${navigationAction.request.method}");

                final url = navigationAction.request.url?.toString() ?? '';
                if (url.isEmpty) return NavigationActionPolicy.ALLOW;

                final currentUri = Uri.parse(url);

                // Check callback/sentinel before proceeding.
                final policy = _handleUrl(
                  url: url,
                  returnUri: returnUri,
                  onResponse: onResponse,
                  context: context,
                );
                if (policy == NavigationActionPolicy.CANCEL) return policy;

                // Non-http/https: external banking app / VNPay app.
                if (currentUri.scheme != 'http' && currentUri.scheme != 'https') {
                  final opened = await _launchExternalApp(url);
                  if (opened) onResponse(VNPayPaymentStatus.openBankingApp);
                  return NavigationActionPolicy.CANCEL;
                }

                return NavigationActionPolicy.ALLOW;
              },

              // Fallback for pages that request opening a new window.
              // Handles payment callbacks and external app links if they
              // are delivered through a new window instead of normal navigation.
              onCreateWindow: (controller, createWindowAction) async {
                final url = createWindowAction.request.url?.toString() ?? '';
                if (url.isEmpty) return false;

                final currentUri = Uri.parse(url);
                final isSentinel = currentUri.host.endsWith('sdk.merchantbackapp');

                if (isSentinel) {
                  onResponse(_statusFromSentinel(currentUri.host));
                  Navigator.of(context).pop();
                  return false;
                }

                if (currentUri.scheme != 'http' && currentUri.scheme != 'https') {
                  final opened = await _launchExternalApp(url);
                  if (opened) onResponse(VNPayPaymentStatus.openBankingApp);
                  return false;
                }

                return false;
              },
            ),
          ),
        ),
      ),
    );
  }
}
