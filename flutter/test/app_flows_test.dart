// Whole-app journeys against the in-memory fake API (widget-test runner).
// The same flows run on a real device in integration_test/app_flows_test.dart.

import 'package:flutter_test/flutter_test.dart';

import 'support/flows.dart';

void main() {
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
