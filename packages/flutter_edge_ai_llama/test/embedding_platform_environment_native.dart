import 'dart:io';

bool get hostHasSimulatorUdid =>
    Platform.environment['SIMULATOR_UDID']?.isNotEmpty ?? false;

bool get supportsLibcProbe => Platform.isMacOS;
