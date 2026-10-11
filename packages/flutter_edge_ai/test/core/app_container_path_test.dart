// rebaseIntoAppContainer: a path an iOS app recorded before its data
// container moved (an update, a restore from a backup) is found at the same
// place in the current container; any other path is left alone.
//
// Run: flutter test test/core/app_container_path_test.dart

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_edge_ai/core/model_management/utils/app_container_path.dart';

const _old = 'AAAAAAAA-1111-2222-3333-444444444444';
const _new = 'BBBBBBBB-5555-6666-7777-888888888888';
const _device = '/var/mobile/Containers/Data/Application';

void main() {
  test('a file in an earlier container is at the same place in this one', () {
    expect(
      rebaseIntoAppContainer(
        '$_device/$_old/Documents/models/gemma.task',
        '$_device/$_new',
      ),
      '$_device/$_new/Documents/models/gemma.task',
    );
  });

  test('the /private spelling of the earlier container is moved too', () {
    expect(
      rebaseIntoAppContainer(
        '/private$_device/$_old/Library/Caches/tokenizer.json',
        '$_device/$_new',
      ),
      '$_device/$_new/Library/Caches/tokenizer.json',
    );
  });

  test('a simulator container is moved the same way', () {
    const sim =
        '/Users/me/Library/Developer/CoreSimulator/Devices/'
        'CCCCCCCC-9999-0000-1111-222222222222/data/Containers/Data/Application';
    expect(
      rebaseIntoAppContainer('$sim/$_old/Documents/m.task', '$sim/$_new'),
      '$sim/$_new/Documents/m.task',
    );
  });

  test('a file already in this container is unchanged', () {
    const path = '$_device/$_new/Documents/m.task';
    expect(rebaseIntoAppContainer(path, '$_device/$_new'), path);
  });

  test('a path outside any app data container is unchanged', () {
    for (final path in [
      '/private/var/mobile/Containers/Shared/AppGroup/$_old/m.task',
      '/Users/me/Downloads/m.task',
      '/storage/emulated/0/Download/m.task',
    ]) {
      expect(rebaseIntoAppContainer(path, '$_device/$_new'), path);
    }
  });

  test('a segment that only starts like a container id is unchanged', () {
    const path = '$_device/${_old}x/Documents/m.task';
    expect(rebaseIntoAppContainer(path, '$_device/$_new'), path);
  });

  test('nothing is moved when the current directory is not a container', () {
    const path = '$_device/$_old/Documents/m.task';
    for (final current in [
      '/Users/me/Library/Application Support',
      '$_device/$_new/Documents',
    ]) {
      expect(rebaseIntoAppContainer(path, current), path);
    }
  });
}
