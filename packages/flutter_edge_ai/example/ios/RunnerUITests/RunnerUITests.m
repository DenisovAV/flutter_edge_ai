@import XCTest;
@import Flutter;

@interface RunnerUITests : XCTestCase
@end

@implementation RunnerUITests

- (void)testFlutterIntegrationTest {
    [[[XCUIApplication alloc] init] launch];
}

@end
