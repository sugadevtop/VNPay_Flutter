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
  ///
  /// [deepLink] is injected into the URL as a `callbackurl` query parameter
  /// so the external app knows where to redirect the user back to once its
  /// flow (e.g. bank login, QR confirmation) is done.
  Future<bool> _launchExternalApp(String url, String deepLink) async {
    String cleanUrl = url.trim();
    // Some banks/wallets append a stray trailing comma to the URL.
    if (cleanUrl.endsWith(',')) {
      cleanUrl = cleanUrl.substring(0, cleanUrl.length - 1);
    }

    // Replace the callbackurl query parameter with the deep link so the external app
    final intentRegex = RegExp(r'/?#Intent');
    final match = intentRegex.firstMatch(cleanUrl);

    String newUrl;
    String baseIntentPart = '';

    if (match != null) {
      final uriString = cleanUrl.substring(0, match.start);
      baseIntentPart = cleanUrl.substring(match.start);

      final uri = Uri.parse(uriString);
      final newUri = uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'callbackurl': deepLink,
        },
      );
      newUrl = '${newUri.toString()}$baseIntentPart';
    } else {
      final uri = Uri.parse(cleanUrl);
      final newUri = uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'callbackurl': deepLink,
        },
      );
      newUrl = newUri.toString();
    }

    if (newUrl.contains('intent://')) {
      // Pull apart "intent://HOST/PATH#Intent;scheme=SCHEME;package=PKG;S.browser_fallback_url=URL;end".
      final fragmentIndex = newUrl.indexOf('#Intent;');
      final base = fragmentIndex >= 0
          ? newUrl.substring(newUrl.indexOf('intent://') + 'intent://'.length, fragmentIndex)
          : newUrl.substring(newUrl.indexOf('intent://') + 'intent://'.length);
      final fragment = fragmentIndex >= 0 ? newUrl.substring(fragmentIndex + '#Intent;'.length) : '';

      print("=====>[OLD INTENT URL]: $url");
      print("=====>[NEW INTENT URL]: $newUrl");

      String? scheme;
      String? fallbackUrl;
      for (final part in fragment.split(';')) {
        if (part.startsWith('scheme=')) {
          scheme = part.substring('scheme='.length);
        } else if (part.startsWith('S.browser_fallback_url=')) {
          fallbackUrl = Uri.decodeFull(part.substring('S.browser_fallback_url='.length));
        }
      }

      // Launch the target app directly using its real scheme (e.g. `f5smartaccount://...`).
      if (scheme != null && scheme.isNotEmpty) {
        try {
          // Uri.replace on a host-only intent URI can leave a trailing '/'
          // before the Intent suffix; strip it so the rebuilt app URI is clean.
          final cleanBase = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
          final appUri = Uri.parse('$scheme://$cleanBase');
          if (await launchUrl(appUri, mode: LaunchMode.externalApplication)) {
            return true;
          }
        } catch (_) {
          // The target app is not installed; fall through to the fallback URL.
        }
      }

      // App could not be launched: open the fallback URL instead (usually a
      // web page or app store link).
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
      return await launchUrl(Uri.parse(newUrl), mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

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

    late final URLRequest initialUrlRequest;
    try {
      initialUrlRequest = URLRequest(url: WebUri(paymentUrl));
      print("VNPAY initialUrlRequest built: ${initialUrlRequest.url}");
    } catch (e, st) {
      print("VNPAY failed to build initialUrlRequest: $e\n$st");
      rethrow;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SafeArea(
          child: Scaffold(
            backgroundColor: Colors.white,
            appBar: appBar,
            body: InAppWebView(
              initialUrlRequest: initialUrlRequest,
              initialSettings: InAppWebViewSettings(
                // Allow pages to request opening a new window.
                // Used as a fallback when a page cannot stay in the current WebView.
                javaScriptEnabled: true,
                domStorageEnabled: true,
                javaScriptCanOpenWindowsAutomatically: true,
                supportMultipleWindows: true,
                isInspectable: true,
              ),

              // Inject helper scripts before the page starts loading.
              // Used to keep navigation in the current WebView whenever possible.
              initialUserScripts: UnmodifiableListView([
                UserScript(
                  source: _forceSameWindowJs,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
              ]),
              onReceivedError: (controller, request, error) {
                print("VNPAY onReceivedError: ${error.type} ${error.description} (url: ${request.url})");
              },
              onReceivedHttpError: (controller, request, errorResponse) {
                print("VNPAY onReceivedHttpError: ${errorResponse.statusCode} (url: ${request.url})");
              },
              // TEST ONLY: bypass TLS certificate validation when the device's
              // system trust store lacks the server's root CA (e.g. VNPay sandbox
              // uses a newer Sectigo E46 root missing from older Android WebView
              // trust stores). MUST stay false in production — trusting all certs
              // is an MITM vulnerability.
              onReceivedServerTrustAuthRequest: (controller, challenge) async {
                final host = challenge.protectionSpace.host;
                if (host.contains('sandbox.vnpayment.vn')) {
                  return ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.PROCEED);
                }
                return ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.CANCEL);
              },
              // Main navigation handler.
              // Detects payment callbacks, launches external banking apps,
              // and decides whether to allow or block navigation.
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                print("VNPAY URL: ${navigationAction.request.url}");

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
                  final opened = await _launchExternalApp(url, returnUrl);
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
                  final opened = await _launchExternalApp(url, returnUrl);
                  if (opened) onResponse(VNPayPaymentStatus.openBankingApp);
                  return false;
                }

                await controller.loadUrl(urlRequest: createWindowAction.request);
                return true;
              },
            ),
          ),
        ),
      ),
    );
  }
}