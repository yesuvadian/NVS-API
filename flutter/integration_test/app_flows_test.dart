// Mocked-backend integration tests: the real app on a real device (Windows
// desktop here) against the in-memory FakeCfmsApi, so they run anywhere,
// including CI, with no server or database.
//
//   flutter test integration_test/app_flows_test.dart -d windows

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/flows.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'login validation and wrong password',
    loginValidationAndWrongPassword,
  );
  testWidgets(
    'super admin sees the platform overview',
    superAdminSeesPlatformOverview,
  );
  testWidgets(
    'super admin creates, edits and publishes a Tamil language pack',
    superAdminLanguagePackCrud,
  );
  testWidgets(
    'first login changes password then shows the tenant overview',
    firstLoginChangesPasswordThenShowsTenantOverview,
  );
  testWidgets(
    'menu follows privileges and enabled modules',
    menuFollowsPrivilegesAndModules,
  );
  testWidgets(
    'members: list, load more, create with duplicate reason, stale edit',
    membersListCreateDuplicateAndStaleEdit,
  );
  testWidgets('switching to Tamil does not crash', tamilSwitchDoesNotCrash);
}
