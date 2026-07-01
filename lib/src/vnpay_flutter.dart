import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
    String query = sortedParam.entries.map((e) => '${e.key}=${e.value}').join('&'); //Uri(host: url, queryParameters: sortedParam).query;
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

  /// Mo app ngoai cho cac URL khong phai http/https (deeplink app ngan hang,
  /// VNPay, hoac Android `intent://`). Goi launchUrl truc tiep, KHONG dung
  /// canLaunchUrl, de tranh bi package visibility cua Android 11+ (<queries>)
  /// chan - giong cach startActivity cua SDK native VNPay. Tra ve true neu mo
  /// duoc.
  Future<bool> _launchExternalApp(String url) async {
    // Android intent URL:
    // intent://HOST/PATH#Intent;scheme=SCHEME;package=PKG;S.browser_fallback_url=URL;end
    if (url.startsWith('intent://')) {
      final fragmentIndex = url.indexOf('#Intent;');
      final base = fragmentIndex >= 0
          ? url.substring('intent://'.length, fragmentIndex)
          : url.substring('intent://'.length);
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

      // Thu mo app dich bang scheme that (vd: vnpayapp://...).
      if (scheme != null && scheme.isNotEmpty) {
        try {
          final appUri = Uri.parse('$scheme://$base');
          if (await launchUrl(appUri, mode: LaunchMode.externalApplication)) {
            return true;
          }
        } catch (_) {
          // Khong co app cai dat -> roi xuong link du phong ben duoi.
        }
      }
      // Khong mo duoc app -> mo link du phong (thuong la trang tai app / web).
      if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
        try {
          return await launchUrl(Uri.parse(fallbackUrl), mode: LaunchMode.externalApplication);
        } catch (_) {
          return false;
        }
      }
      return false;
    }

    // Cac custom scheme khac (deeplink truc tiep cua app ngan hang/VNPay).
    try {
      return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// Show payment webview
  ///
  /// [onPaymentSuccess], [onPaymentCancel], [onPaymentFailed], [onOpenBankingApp] callback when payment success, cancel, failed, open banking app on app
  Future<void> show({
    required BuildContext context,
    required String paymentUrl,
    required String returnUrl,
    AppBar? appBar,
    Function(Map<String, dynamic>)? onPaymentSuccess,
    Function(Map<String, dynamic>)? onPaymentCancel,
    Function(Map<String, dynamic>)? onPaymentFailed,
    Function(Map<String, dynamic>)? onOpenBankingApp,
    Function()? onWebPaymentComplete,
  }) async {
    if (kIsWeb) {
      await launchUrlString(
        paymentUrl,
        webOnlyWindowName: '_self',
      );
      if (onWebPaymentComplete != null) {
        onWebPaymentComplete();
      }
    } else {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) async {
              final url = request.url;
              final currentUri = Uri.parse(url);
              final returnUri = Uri.parse(returnUrl);

              final isCallback = currentUri.scheme == returnUri.scheme &&
                  currentUri.host == returnUri.host &&
                  currentUri.path == returnUri.path &&
                  returnUri.queryParameters.entries.every(
                        (e) => currentUri.queryParameters[e.key] == e.value,
                  );

              if (isCallback) {
                final params = Uri.parse(url).queryParameters;
                final responseCode = params['vnp_ResponseCode'];

                switch (responseCode) {
                  case '00':
                    onPaymentSuccess?.call(params);
                  case '24':
                    onPaymentCancel?.call(params);
                  case '99':
                    onPaymentFailed?.call(params);
                  case '10':
                    onOpenBankingApp?.call(params);
                }

                Navigator.of(context).pop();

                return NavigationDecision.prevent;
              }

              // WebView chỉ tải được http/https. Các scheme khác (intent://,
              // deeplink app ngân hàng/VNPay...) phải mở bằng app ngoài, nếu
              // không sẽ lỗi net::ERR_UNKNOWN_URL_SCHEME.
              if (currentUri.scheme != 'http' && currentUri.scheme != 'https') {
                await _launchExternalApp(url);
                return NavigationDecision.prevent;
              }

              return NavigationDecision.navigate;
            },
          ),
        )
        ..loadRequest(Uri.parse(paymentUrl));

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
              body: WebViewWidget(
                controller: controller,
              ),
            ),
          ),
        ),
      );
    }
  }
}