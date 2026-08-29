import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/api/api_client.dart';
import 'core/api/server_address.dart';
import 'core/api/token_store.dart';
import 'core/files/save_destination.dart';
import 'features/auth/auth_repository.dart';
import 'features/auth/session_controller.dart';
import 'features/editor/editor_repository.dart';
import 'features/pdf/pdf_repository.dart';
import 'features/user/user_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Wired by hand: the graph is small enough that a container would be more
  // machinery than the app needs.
  final tokens = TokenStore();
  final address = ServerAddress();
  // Read before the first request goes out, or the app would briefly use the
  // compiled-in default and fail against a backend that has moved.
  await address.load();
  final saveDestination = SaveDestinationStore();
  await saveDestination.load();
  final client = ApiClient(tokens: tokens, address: address);

  runApp(
    MultiProvider(
      providers: [
        Provider.value(value: client),
        ChangeNotifierProvider.value(value: address),
        ChangeNotifierProvider.value(value: saveDestination),
        Provider(create: (_) => PdfRepository(client, saveDestination)),
        Provider(create: (_) => EditorRepository(client, saveDestination)),
        ChangeNotifierProvider(
          create: (_) => SessionController(
            client: client,
            auth: AuthRepository(client: client, tokens: tokens),
            users: UserRepository(client),
            tokens: tokens,
          )..bootstrap(),
        ),
      ],
      child: const PdfreeditorApp(),
    ),
  );
}
