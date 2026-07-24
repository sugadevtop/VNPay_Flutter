import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:vnpay_flutter/src/model/enum/vnpay_payment_status.dart';

//[VNPAYFlutter] instance class VNPAY Flutter
class VNPAYFlutter {
  static final VNPAYFlutter _instance = VNPAYFlutter();

  //[instance] Single Ton Init
  static VNPAYFlutter get instance => _instance;

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
    required String returnUrl,
    required Function(VNPayPaymentStatus) onResponse,
    required BuildContext context,
  }) {
    final currentUri = Uri.parse(url);
    final returnUri = Uri.parse(returnUrl.toString());

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
        builder: (context) => _VNPayWebViewPage(
          initialUrlRequest: initialUrlRequest,
          appBar: appBar,
          returnUrl: returnUrl,
          onResponse: onResponse,
          vnpay: this,
        ),
      ),
    );
  }
}

/// Payment WebView screen.
class _VNPayWebViewPage extends StatelessWidget {
  final URLRequest initialUrlRequest;
  final AppBar? appBar;
  final String returnUrl;
  final Function(VNPayPaymentStatus) onResponse;
  final VNPAYFlutter vnpay;

  const _VNPayWebViewPage({
    required this.initialUrlRequest,
    required this.appBar,
    required this.returnUrl,
    required this.onResponse,
    required this.vnpay,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: appBar,
        body: InAppWebView(
          initialUrlRequest: initialUrlRequest,
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            domStorageEnabled: true,
            javaScriptCanOpenWindowsAutomatically: true,
            supportMultipleWindows: true,
            isInspectable: true,
          ),
          onReceivedError: (controller, request, error) {
            print("VNPAY onReceivedError: ${error.type} ${error.description} (url: ${request.url})");
          },
          onReceivedHttpError: (controller, request, errorResponse) {
            print("VNPAY onReceivedHttpError: ${errorResponse.statusCode} (url: ${request.url})");
          },
          // TEST ONLY: bypass TLS certificate validation
          onReceivedServerTrustAuthRequest: (controller, challenge) async {
            final host = challenge.protectionSpace.host;
            print("VNPAY onReceivedServerTrustAuthRequest: host: $host");
            if (host.contains('sandbox.vnpayment.vn') || host.contains('vps-dev02-ssl.teanis.xyz')) {
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
            final policy = vnpay._handleUrl(
              url: url,
              returnUrl: returnUrl,
              onResponse: onResponse,
              context: context,
            );
            if (policy == NavigationActionPolicy.CANCEL) return policy;

            // Non-http/https: external banking app / VNPay app.
            if (currentUri.scheme != 'http' && currentUri.scheme != 'https') {
              final opened = await vnpay._launchExternalApp(url, returnUrl);
              if (opened) {
                onResponse(VNPayPaymentStatus.openBankingApp);
              }
              return NavigationActionPolicy.CANCEL;
            }

            return NavigationActionPolicy.ALLOW;
          },
        ),
      ),
    );
  }
}