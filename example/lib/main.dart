import 'package:flutter/material.dart';
import 'package:vnpay_flutter/vnpay_flutter.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const Example(),
    );
  }
}

class Example extends StatefulWidget {
  const Example({Key? key}) : super(key: key);

  @override
  State<Example> createState() => _ExampleState();
}

class _ExampleState extends State<Example> {
  VNPayPaymentStatus? responseCode;

  Future<void> onPayment() async {
    await VNPAYFlutter.instance.show(
      context: context,
      paymentUrl: 'xxxxxxx', //https://sandbox.vnpayment.vn/apis/docs/huong-dan-tich-hop/#code-returnurl,
      returnUrl: "xxxxxxx",
      onResponse: (status) {
        setState(() {
          responseCode = status;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text('Response Code: ${responseCode?.name}'),
            TextButton(
              onPressed: onPayment,
              child: const Text('30.000VND'),
            ),
          ],
        ),
      ),
    );
  }
}