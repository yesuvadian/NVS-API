// Unit tests for AuthProvider and OrganisationProvider (services faked).

import 'package:cfms_portal/providers/auth_provider.dart';
import 'package:cfms_portal/providers/organisation_provider.dart';
import 'package:cfms_portal/services/auth_service.dart';
import 'package:cfms_portal/services/organisation_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_api.dart';

void main() {
  group('AuthProvider', () {
    late FakeCfmsApi api;
    late AuthProvider auth;

    setUp(() {
      api = FakeCfmsApi();
      auth = AuthProvider(ApiAuthService(api.config()));
    });

    test('signs in and loads tenant capabilities', () async {
      await auth.signIn('emp@demo.example.com', 'Staff@12345', 'en');

      expect(auth.session!.role, WorkspaceRole.tenant);
      expect(auth.session!.roleCode, 'EMP');
      expect(auth.session!.permissions, contains('member.create'));
      expect(auth.session!.modules, contains('MEMBER'));
      expect(auth.isLoading, isFalse);
      expect(auth.errorMessage, isNull);
    });

    test(
      'wrong password keeps the user signed out with the server message',
      () async {
        await auth.signIn('emp@demo.example.com', 'nope', 'en');

        expect(auth.session, isNull);
        expect(auth.errorCode, 'INVALID_CREDENTIALS');
        expect(auth.errorMessage, 'The username or password is incorrect.');
      },
    );

    test(
      'first login: no capabilities until the password is changed',
      () async {
        await auth.signIn('admin@demo.example.com', 'Welcome@123', 'en');
        expect(auth.session!.mustChangePassword, isTrue);
        expect(auth.session!.permissions, isEmpty);
        expect(api.count('GET', '/auth/tenant-capabilities'), 0);

        await auth.changeInitialPassword('wrong', 'Welcome@12345', 'en');
        expect(auth.errorCode, 'INVALID_CREDENTIALS');
        expect(auth.session!.mustChangePassword, isTrue);

        await auth.changeInitialPassword('Welcome@123', 'Welcome@12345', 'en');
        expect(auth.session!.mustChangePassword, isFalse);
        expect(auth.session!.permissions, contains('user_role.edit'));
      },
    );

    test('super admin gets platform permissions', () async {
      await auth.signIn('superadmin@example.com', 'Platform@123', 'en');
      expect(auth.session!.role, WorkspaceRole.superAdmin);
      expect(auth.session!.permissions, contains('tenants:can_edit'));
    });

    test('sign out calls the API and clears the session', () async {
      await auth.signIn('emp@demo.example.com', 'Staff@12345', 'en');
      await auth.signOut('en');
      expect(auth.session, isNull);
      expect(api.count('POST', '/auth/logout'), 1);
    });

    test(
      'expired session found by the session check signs the user out',
      () async {
        await auth.signIn('emp@demo.example.com', 'Staff@12345', 'en');
        api.users.removeWhere((u) => u.id == 'u-emp'); // token no longer valid
        await auth.verifySession('en');
        expect(auth.session, isNull);
        expect(auth.errorMessage, 'Please sign in to continue.');
      },
    );

    test('expireSession keeps the message and code for the login screen', () {
      auth.expireSession(
        'Organisation disabled',
        code: 'ORGANISATION_DISABLED',
      );
      expect(auth.session, isNull);
      expect(auth.errorCode, 'ORGANISATION_DISABLED');
    });
  });

  group('OrganisationProvider', () {
    test('loads organisations for the super admin', () async {
      final api = FakeCfmsApi();
      final provider = OrganisationProvider(
        OrganisationService(api.config()),
        'token-pu-1',
        () => 'en',
        10,
      );
      await provider.load();
      expect(provider.organisations.single.code, 'demo');
      expect(provider.hasMore, isFalse);
      expect(provider.error, isNull);
    });

    test('reports session expiry', () async {
      final api = FakeCfmsApi();
      String? expired;
      final provider = OrganisationProvider(
        OrganisationService(api.config()),
        'token-unknown',
        () => 'en',
        10,
        onSessionExpired: (message, code) => expired = code,
      );
      await provider.load();
      expect(provider.error, 'Please sign in to continue.');
      expect(expired, 'NOT_SIGNED_IN');
    });
  });
}
