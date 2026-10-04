package dev.flutterberlin.workshop_flutter_edge_ai_hybrid_ai;

import androidx.test.rule.ActivityTestRule;
import dev.flutter.plugins.integration_test.FlutterTestRunner;
import org.junit.Rule;
import org.junit.runner.RunWith;

// Runs the Dart integration_test suite on-device via the Flutter engine.
// Required scaffolding for `flutter test integration_test` on a real device / FTL.
@RunWith(FlutterTestRunner.class)
public class MainActivityTest {
    @Rule
    public ActivityTestRule<MainActivity> rule =
            new ActivityTestRule<>(MainActivity.class, true, false);
}
