import 'package:at_client/at_client.dart';
import 'package:mocktail/mocktail.dart';
import 'package:noports_core/npp.dart';
import 'package:test/test.dart';

import '../sshnp/sshnp_mocks.dart';

void main() {
  group('Given the policy manager RPC of policy service @policy', () {
    const policy = '@policy';

    late MockAtClient atClient;
    late NppCache cache;
    late List<Map<String, dynamic>> events;
    late ManagerRpcCallbacks callbacks;

    ManagerRpcCallbacks callbacksWith({
      NppOperationHooks? hooks,
      Future<void> Function(Map<String, dynamic> event)? onEvent,
    }) => ManagerRpcCallbacks(
      atClient: atClient,
      nppCache: cache,
      binariesVersion: '1.2.3',
      handler: NppRequestHandler(nppCache: cache),
      policyAtsign: policy.toAtsign(),
      onEvent: onEvent ?? (event) async => events.add(event),
      nppOperationHooks: hooks,
    );

    setUp(() {
      atClient = MockAtClient();
      when(() => atClient.getCurrentAtSign()).thenReturn(policy);
      cache = NppCache();
      events = [];
      callbacks = callbacksWith();
    });

    /// [from] sends [payload] to the manager RPC; returns the answer.
    Future<AtRpcResp> send(
      Map<String, dynamic> payload, {
      String from = policy,
    }) => callbacks.handleRequest(AtRpcReq.create(payload), from);

    Future<AtRpcResp> put(String target, Map<String, dynamic> value) =>
        send({'operation': 'put', 'target': target, 'value': value});

    Future<AtRpcResp> delete(String target, String idKey, String id) => send({
      'operation': 'delete',
      'target': target,
      'value': {idKey: id},
    });

    /// One rule of each kind, in an order whose references resolve, with
    /// the payload key its id is sent back under and named by in a delete.
    final rulesOfEachKind = <(String, String, Map<String, dynamic>)>[
      ('Client', 'clientId', {'name': 'Alice', 'atSign': '@alice'}),
      ('ClientGroup', 'clientGroupId', {'name': 'admins'}),
      (
        'ClientGroupMember',
        'clientGroupMemberId',
        {'clientId': '1', 'clientGroupId': '1'},
      ),
      ('Daemon', 'daemonId', {'atSign': '@daemon'}),
      (
        'Service',
        'serviceId',
        {'daemonId': '1', 'deviceName': 'pi', 'deviceGroupName': '__none__'},
      ),
      (
        'ServiceACL',
        'serviceACLId',
        {'serviceId': '1', 'clientGroupId': '1', 'permitOpen': 'localhost:22'},
      ),
    ];

    test(
      'when @policy puts a Client, then it is stored, and one ruleStored'
      ' event names @policy, the kind, the new id and the stored rule',
      () async {
        final response = await put('Client', {
          'name': 'Alice',
          'atSign': '@alice',
        });

        expect(response.respType, AtRpcRespType.success);
        expect(events, hasLength(1));
        final event = events.single;
        expect(event['event'], 'ruleStored');
        expect(event['timestamp'], endsWith('Z'));
        expect(event['policyAtsign'], policy);
        expect(event['fromAtsign'], policy);
        expect(event['kind'], 'Client');
        expect(event['id'], '1');
        expect(event['rule'], {'id': '1', 'name': 'Alice', 'atSign': '@alice'});
      },
    );

    test('when @policy puts then deletes one rule of each kind, then each put'
        ' sends ruleStored and each delete sends ruleDeleted, naming its kind'
        ' and id', () async {
      for (final (target, idKey, value) in rulesOfEachKind) {
        final response = await put(target, value);
        expect(response.respType, AtRpcRespType.success, reason: target);
        expect(response.payload[idKey], '1', reason: target);
      }
      for (final (target, idKey, _) in rulesOfEachKind.reversed) {
        final response = await delete(target, idKey, '1');
        expect(response.respType, AtRpcRespType.success, reason: target);
      }

      final kinds = [for (final (target, _, _) in rulesOfEachKind) target];
      expect(events.map((e) => (e['event'], e['kind'], e['id'])), [
        for (final kind in kinds) ('ruleStored', kind, '1'),
        for (final kind in kinds.reversed) ('ruleDeleted', kind, '1'),
      ]);
      for (final (i, (_, _, value)) in rulesOfEachKind.indexed) {
        expect(events[i]['rule'], {'id': '1', ...value});
      }
      expect(cache.clients, isEmpty);
      expect(cache.serviceACLs, isEmpty);
    });

    test(
      'when @policy puts a Client whose atSign is already a client, then the'
      ' request fails as before, and one ruleChangeFailed event says why',
      () async {
        await put('Client', {'name': 'Alice', 'atSign': '@alice'});
        events.clear();

        await expectLater(
          put('Client', {'name': 'Alice again', 'atSign': '@alice'}),
          throwsException,
        );

        expect(cache.clients, hasLength(1));
        expect(events, hasLength(1));
        final event = events.single;
        expect(event['event'], 'ruleChangeFailed');
        expect(event['fromAtsign'], policy);
        expect(event['operation'], 'put');
        expect(event['kind'], 'Client');
        expect(event['error'], contains('already exists'));
      },
    );

    test('when @policy deletes a Client that does not exist, then the request'
        ' fails as before, and one ruleChangeFailed event is sent', () async {
      await expectLater(delete('Client', 'clientId', '9'), throwsStateError);

      expect(events.single['event'], 'ruleChangeFailed');
      expect(events.single['operation'], 'delete');
      expect(events.single['kind'], 'Client');
    });

    test("when @policy puts a Client without the JSON a Client needs, then"
        " the request fails as before, and ruleChangeFailed is sent", () async {
      await expectLater(put('Client', {'name': 'Alice'}), throwsA(anything));

      expect(events.single['event'], 'ruleChangeFailed');
      expect(events.single['kind'], 'Client');
    });

    test('when @policy puts an unknown kind of rule, then the answer is an'
        ' error, and ruleChangeFailed carries its message', () async {
      final response = await put('Widget', {'name': 'w'});

      expect(response.respType, AtRpcRespType.error);
      expect(events.single['event'], 'ruleChangeFailed');
      expect(events.single['kind'], 'Widget');
      expect(
        events.single['error'],
        'Unknown target for put operation: Widget',
      );
    });

    test("when @policy puts a Client and the pre-put hook throws, then it isn't"
        ' stored, and ruleChangeFailed, not ruleStored, is sent', () async {
      callbacks = callbacksWith(
        hooks: NppOperationHooks(
          prePutClient: (_) async => throw Exception('db down'),
        ),
      );

      final response = await put('Client', {
        'name': 'Alice',
        'atSign': '@alice',
      });

      expect(response.respType, AtRpcRespType.error);
      expect(cache.clients, isEmpty);
      expect(events.single['event'], 'ruleChangeFailed');
      expect(events.single['error'], contains('db down'));
    });

    test('when @mallory sends a put, then it is refused and nothing is stored,'
        ' and one managerRequestRefused event names @mallory and the'
        ' operation', () async {
      final response = await send({
        'operation': 'put',
        'target': 'Client',
        'value': {'name': 'Mallory', 'atSign': '@mallory'},
      }, from: '@mallory');

      expect(response.respType, AtRpcRespType.error);
      expect(cache.clients, isEmpty);
      expect(events, hasLength(1));
      expect(events.single['event'], 'managerRequestRefused');
      expect(events.single['policyAtsign'], policy);
      expect(events.single['fromAtsign'], '@mallory');
      expect(events.single['operation'], 'put');
    });

    test(
      'when @policy pings, gets or simulates, then no event is sent',
      () async {
        await put('Client', {'name': 'Alice', 'atSign': '@alice'});
        events.clear();

        await send({'operation': 'ping'});
        await send({'operation': 'get', 'target': 'allClients'});
        await send({
          'operation': 'simulate',
          'clientAtsign': '@alice',
          'daemonAtsign': '@daemon',
          'daemonDeviceName': 'pi',
          'daemonDeviceGroupName': '__none__',
        });

        expect(events, isEmpty);
      },
    );

    test('when sending the event throws, then the put still succeeds with the'
        ' same answer', () async {
      callbacks = callbacksWith(
        onEvent: (_) async => throw Exception('no network'),
      );

      final response = await put('Client', {
        'name': 'Alice',
        'atSign': '@alice',
      });

      expect(response.respType, AtRpcRespType.success);
      expect(response.payload['clientId'], '1');
      expect(cache.clients, hasLength(1));
    });
  });
}
