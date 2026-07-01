enum VNPayPaymentStatus {
  success,
  cancelled,
  failed,
  openBankingApp,
  unknown,
}

VNPayPaymentStatus getPaymentStatus(Map<String, String> params) {
  switch (params['vnp_ResponseCode']) {
    case '00':
      return VNPayPaymentStatus.success;
    case '24':
      return VNPayPaymentStatus.cancelled;
    case '10':
      return VNPayPaymentStatus.openBankingApp;
    case '99':
      return VNPayPaymentStatus.failed;
    default:
      return VNPayPaymentStatus.unknown;
  }
}