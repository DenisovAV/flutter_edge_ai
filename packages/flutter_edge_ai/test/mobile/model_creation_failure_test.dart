import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Mock PlatformService that can simulate failures
class MockPlatformService {
  bool shouldFail = false;
  String? failureMessage;
  int createModelCallCount = 0;
  int closeModelCallCount = 0;
  bool modelCreated = false;

  Future<void> createModel() async {
    createModelCallCount++;
    if (shouldFail) {
      throw Exception(failureMessage ?? 'Model creation failed');
    }
    modelCreated = true;
  }

  Future<void> closeModel() async {
    closeModelCallCount++;
    modelCreated = false;
  }

  void reset() {
    shouldFail = false;
    failureMessage = null;
    createModelCallCount = 0;
    closeModelCallCount = 0;
    modelCreated = false;
  }
}

/// Simulates the FlutterEdgeAiMobile.createModel() logic
/// with the BUG (not resetting _initCompleter on failure)
class BuggyModelCreator {
  final MockPlatformService platformService;

  Completer<String>? _initCompleter;

  BuggyModelCreator(this.platformService);

  Future<String> createModel(String modelName) async {
    // BUG: If completer exists, return it (even if it completed with error!)
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    final completer = _initCompleter = Completer<String>();

    try {
      await platformService.createModel();
      completer.complete(modelName);
      return await completer.future;
    } catch (e, st) {
      // BUG: Not resetting _initCompleter = null here!
      completer.completeError(e, st);
      return completer.future;
    }
  }

  void reset() {
    _initCompleter = null;
  }
}

/// Simulates the FIXED FlutterEdgeAiMobile.createModel() logic
class FixedModelCreator {
  final MockPlatformService platformService;

  Completer<String>? _initCompleter;
  String? _initializedModel;

  FixedModelCreator(this.platformService);

  Future<String> createModel(String modelName) async {
    // Only reuse completer if model was successfully created
    if (_initCompleter != null && _initializedModel != null) {
      return _initCompleter!.future;
    }

    // FIX: If completer exists but model is null, previous attempt failed
    // Reset and try again
    _initCompleter = null;

    final completer = _initCompleter = Completer<String>();

    try {
      // FIX: Close any existing model before creating new one
      if (platformService.modelCreated) {
        await platformService.closeModel();
      }

      await platformService.createModel();
      _initializedModel = modelName;
      completer.complete(modelName);
      return await completer.future;
    } catch (e, st) {
      // FIX: Reset completer on failure to allow retry
      _initCompleter = null;
      _initializedModel = null;
      completer.completeError(e, st);
      return completer.future;
    }
  }

  void reset() {
    _initCompleter = null;
    _initializedModel = null;
  }
}

void main() {
  late MockPlatformService mockPlatform;

  setUp(() {
    mockPlatform = MockPlatformService();
  });

  tearDown(() {
    mockPlatform.reset();
  });

  group('Issue #170 - Model creation failure blocks switching', () {
    test('BUG: After failure, retry returns the same error', () async {
      final creator = BuggyModelCreator(mockPlatform);

      // First attempt: fail
      mockPlatform.shouldFail = true;
      mockPlatform.failureMessage = 'Incompatible model file';

      await expectLater(
        creator.createModel('faulty-model.task'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Incompatible model file'),
          ),
        ),
      );

      expect(mockPlatform.createModelCallCount, 1);

      // Second attempt: should work but BUG returns old error
      mockPlatform.shouldFail = false;

      // BUG: Same error returned, createModel not called again!
      await expectLater(
        creator.createModel('working-model.task'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Incompatible model file'),
          ),
        ),
      );

      expect(
        mockPlatform.createModelCallCount,
        1,
        reason: 'BUG: createModel was not called second time',
      );
    });

    test('FIX: After failure, retry works correctly', () async {
      final creator = FixedModelCreator(mockPlatform);

      // First attempt: fail
      mockPlatform.shouldFail = true;
      mockPlatform.failureMessage = 'Incompatible model file';

      await expectLater(
        creator.createModel('faulty-model.task'),
        throwsA(isA<Exception>()),
      );

      expect(mockPlatform.createModelCallCount, 1);

      // Second attempt: should work with fix
      mockPlatform.shouldFail = false;

      final result = await creator.createModel('working-model.task');

      expect(result, 'working-model.task');
      expect(
        mockPlatform.createModelCallCount,
        2,
        reason: 'FIX: createModel should be called again',
      );
    });

    test('FIX: Switching model after failure works', () async {
      final creator = FixedModelCreator(mockPlatform);

      // First model fails (e.g., FastVLM on incompatible device)
      mockPlatform.shouldFail = true;
      mockPlatform.failureMessage = 'Error building tflite model';

      await expectLater(
        creator.createModel('FastVLM-0.5B.litertlm'),
        throwsA(isA<Exception>()),
      );

      // Switch to compatible model
      mockPlatform.shouldFail = false;

      final result = await creator.createModel('gemma-3n-E2B-it-int4.task');

      expect(result, 'gemma-3n-E2B-it-int4.task');
      expect(mockPlatform.createModelCallCount, 2);
    });

    test('FIX: Multiple failures followed by success', () async {
      final creator = FixedModelCreator(mockPlatform);

      // First failure
      mockPlatform.shouldFail = true;
      mockPlatform.failureMessage = 'Error 1';

      await expectLater(
        creator.createModel('model1.task'),
        throwsA(isA<Exception>()),
      );

      // Second failure - verify we get the NEW error
      mockPlatform.failureMessage = 'Error 2';

      await expectLater(
        creator.createModel('model2.task'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Error 2'),
          ),
        ),
      );

      expect(
        mockPlatform.createModelCallCount,
        2,
        reason: 'Should have called createModel twice',
      );

      // Third attempt succeeds
      mockPlatform.shouldFail = false;

      final result = await creator.createModel('model3.task');

      expect(result, 'model3.task');
      expect(mockPlatform.createModelCallCount, 3);
    });
  });

  group('Native cleanup on model switch', () {
    test(
      'closeModel called before creating new model when previous exists',
      () async {
        final creator = FixedModelCreator(mockPlatform);

        // First model succeeds
        mockPlatform.shouldFail = false;
        await creator.createModel('model1.task');

        expect(mockPlatform.modelCreated, isTrue);
        expect(mockPlatform.closeModelCallCount, 0);

        // Reset creator state to simulate switching (normally done via close())
        creator.reset();

        // Create second model - should close first
        await creator.createModel('model2.task');

        expect(
          mockPlatform.closeModelCallCount,
          1,
          reason: 'Should close old model before creating new one',
        );
        expect(mockPlatform.createModelCallCount, 2);
      },
    );

    test('closeModel NOT called when previous model failed', () async {
      final creator = FixedModelCreator(mockPlatform);

      // First model fails
      mockPlatform.shouldFail = true;

      await expectLater(
        creator.createModel('faulty.task'),
        throwsA(isA<Exception>()),
      );

      expect(mockPlatform.modelCreated, isFalse);
      expect(mockPlatform.closeModelCallCount, 0);

      // Second model - should NOT try to close (nothing to close)
      mockPlatform.shouldFail = false;
      await creator.createModel('working.task');

      expect(
        mockPlatform.closeModelCallCount,
        0,
        reason: 'No need to close - previous model never created',
      );
      expect(mockPlatform.createModelCallCount, 2);
    });
  });

  group('Completer state management', () {
    test('Successful model reuses completer (singleton pattern)', () async {
      final creator = FixedModelCreator(mockPlatform);

      mockPlatform.shouldFail = false;

      final result1 = await creator.createModel('test.task');
      final result2 = await creator.createModel('test.task');

      expect(result1, result2);
      expect(
        mockPlatform.createModelCallCount,
        1,
        reason: 'Should reuse existing model, not create new one',
      );
    });

    test('Failed completer does not block future attempts', () async {
      final creator = FixedModelCreator(mockPlatform);

      // Fail first
      mockPlatform.shouldFail = true;

      await expectLater(
        creator.createModel('test.task'),
        throwsA(isA<Exception>()),
      );

      // Success after failure
      mockPlatform.shouldFail = false;

      final result = await creator.createModel('test.task');
      expect(result, 'test.task');
      expect(mockPlatform.createModelCallCount, 2);
    });
  });

  group('Error message preservation', () {
    test('Original error message preserved on failure', () async {
      final creator = FixedModelCreator(mockPlatform);

      mockPlatform.shouldFail = true;
      mockPlatform.failureMessage =
          'INTERNAL: RET_CHECK failure model Error building tflite model';

      await expectLater(
        creator.createModel('FastVLM.litertlm'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('RET_CHECK failure'),
              contains('Error building tflite model'),
            ),
          ),
        ),
      );
    });

    test('Different errors for different model attempts', () async {
      final creator = FixedModelCreator(mockPlatform);

      // First model error
      mockPlatform.shouldFail = true;
      mockPlatform.failureMessage = 'Model A incompatible';

      await expectLater(
        creator.createModel('modelA.task'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Model A incompatible'),
          ),
        ),
      );

      // Second model error - should be different
      mockPlatform.failureMessage = 'Model B incompatible';

      await expectLater(
        creator.createModel('modelB.task'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Model B incompatible'),
          ),
        ),
      );

      expect(
        mockPlatform.createModelCallCount,
        2,
        reason: 'Both models should have been attempted',
      );
    });
  });

  group('Embedding model creation failure (parity with inference)', () {
    test('FIX: Embedding model failure allows retry', () async {
      final creator = FixedModelCreator(mockPlatform);

      // First attempt: fail (e.g., incompatible tokenizer)
      mockPlatform.shouldFail = true;
      mockPlatform.failureMessage = 'Invalid tokenizer format';

      await expectLater(
        creator.createModel('embedding-model.tflite'),
        throwsA(isA<Exception>()),
      );

      expect(mockPlatform.createModelCallCount, 1);

      // Second attempt: should work
      mockPlatform.shouldFail = false;

      final result = await creator.createModel('embedding-model-v2.tflite');

      expect(result, 'embedding-model-v2.tflite');
      expect(mockPlatform.createModelCallCount, 2);
    });

    test('FIX: Switching embedding model after failure works', () async {
      final creator = FixedModelCreator(mockPlatform);

      // First embedding model fails
      mockPlatform.shouldFail = true;
      mockPlatform.failureMessage = 'Embedding model initialization failed';

      await expectLater(
        creator.createModel('faulty-embedder.tflite'),
        throwsA(isA<Exception>()),
      );

      // Switch to working embedding model
      mockPlatform.shouldFail = false;

      final result = await creator.createModel('gecko-embedding.tflite');

      expect(result, 'gecko-embedding.tflite');
      expect(mockPlatform.createModelCallCount, 2);
    });

    test('FIX: Embedding model multiple failures then success', () async {
      final creator = FixedModelCreator(mockPlatform);

      // First failure - bad model
      mockPlatform.shouldFail = true;
      mockPlatform.failureMessage = 'Model format error';

      await expectLater(
        creator.createModel('bad-model.tflite'),
        throwsA(isA<Exception>()),
      );

      // Second failure - bad tokenizer
      mockPlatform.failureMessage = 'Tokenizer load error';

      await expectLater(
        creator.createModel('bad-tokenizer.tflite'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Tokenizer load error'),
          ),
        ),
      );

      // Third attempt succeeds
      mockPlatform.shouldFail = false;

      final result = await creator.createModel('working-embedder.tflite');

      expect(result, 'working-embedder.tflite');
      expect(mockPlatform.createModelCallCount, 3);
    });
  });
}
