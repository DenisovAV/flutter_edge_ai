# CI/CD Documentation

## Overview

This repository uses GitHub Actions for continuous integration and automated releases.

## Workflows

### 1. CI Tests (`test.yml`)

**Triggers:**
- Push to `main` or `develop` branches
- Pull requests to `main` or `develop` branches

**Jobs:**

#### `analyze-and-test`
- Runs Flutter analyzer
- Executes all unit tests with coverage
- Uploads coverage to Codecov (optional)
- Verifies code formatting

#### `build-example-android`
- Builds example app APK for Android
- Uploads APK as artifact (7 days retention)
- Validates that example app compiles successfully

#### `build-example-ios`
- Builds example app for iOS (unsigned)
- Validates iOS compilation

**Requirements:**
- Flutter stable channel (latest)
- Java 17 for Android builds
- macOS runner for iOS builds

---

### 2. Release Build (`release.yml`)

**Triggers:**
- Git tags matching `v*.*.*` (e.g., `v0.11.7`, `v1.0.0`)

**Jobs:**

#### `build-and-release`
- Builds release APK for example app
- Renames APK with version number
- Creates GitHub Release with auto-generated release notes
- Attaches APK to the release
- Uploads APK as artifact (90 days retention)

**Requirements:**
- `contents: write` permission (automatic for repository owners)
- Git tag following semantic versioning: `v<major>.<minor>.<patch>`

---

## Usage

### Running Tests Locally

```bash
# Analyze code
flutter analyze

# Run tests with coverage
flutter test --coverage

# Format code
dart format .
```

### Creating a Release

1. **Update version in `pubspec.yaml`:**
   ```yaml
   version: 0.11.8
   ```

2. **Update CHANGELOG.md:**
   ```markdown
   ## [0.11.8] - 2025-10-22
   - New feature description
   - Bug fixes
   ```

3. **Commit changes:**
   ```bash
   git add pubspec.yaml CHANGELOG.md
   git commit -m "Bump version to 0.11.8"
   git push origin main
   ```

4. **Create and push tag:**
   ```bash
   git tag v0.11.8
   git push origin v0.11.8
   ```

5. **Wait for GitHub Actions:**
   - Check the "Actions" tab in GitHub
   - Release workflow will build APK and create a release
   - APK will be attached to the release automatically

6. **Optional: Edit release notes:**
   - Go to "Releases" tab
   - Edit the auto-generated release
   - Add more details if needed

---

## Artifacts

### CI Tests
- **Example APK (debug)**: Available for 7 days after each push/PR
- **Coverage report**: Uploaded to Codecov (if configured)

### Releases
- **Example APK (release)**: Attached to GitHub Release
- **Artifact backup**: Available for 90 days in GitHub Actions

---

## Running Tests Locally

```bash
# Run all tests
flutter test

# Run specific test file
flutter test test/core/model_source_test.dart

# Run with coverage
flutter test --coverage
```

---

## Troubleshooting

### Build Failures

**Android build fails:**
- Check Java version (requires Java 17)
- Verify Gradle compatibility
- Check Android dependencies in `example/android/build.gradle`

**iOS build fails:**
- Check minimum iOS version (15.0, or 16.0 with `flutter_edge_ai_mediapipe`)
- Verify CocoaPods dependencies
- May need macOS runner adjustments

**Test failures:**
- Run tests locally first: `flutter test`
- Check for platform-specific issues
- Review test output in GitHub Actions logs

### Release Issues

**Tag not triggering release:**
- Ensure tag follows `v*.*.*` format (e.g., `v0.11.8`)
- Check that tag was pushed to GitHub: `git push origin v0.11.8`
- Verify workflow permissions in repository settings

**APK not attached:**
- Check release workflow logs for errors
- Verify APK was built successfully
- Check `contents: write` permission

**Missing release notes:**
- GitHub auto-generates notes from commits
- Manually edit release to add more details
- Use conventional commit messages for better notes

---

## Configuration

### Flutter Version

Both workflows use Flutter stable channel (latest version):

```yaml
uses: subosito/flutter-action@v2
with:
  channel: 'stable'
```

To pin a specific version, add `flutter-version: 'X.Y.Z'`

### Java Version

Update Java version for Android builds:

```yaml
uses: actions/setup-java@v4
with:
  distribution: 'zulu'
  java-version: '17'  # Update this
```

### Retention Days

Adjust artifact retention:

```yaml
# CI builds
retention-days: 7  # Short retention for testing

# Release builds
retention-days: 90  # Longer retention for releases
```

---

## Security

### Secrets

No secrets are required for basic CI/CD. The following are automatic:

- `GITHUB_TOKEN`: Automatically provided by GitHub Actions
- Permissions: Configured in workflow with `permissions:` key

### Optional Secrets

For advanced features, you can add:

- `CODECOV_TOKEN`: For coverage reports (optional)
- `SLACK_WEBHOOK`: For notifications (optional)
- `FIREBASE_TOKEN`: For Firebase App Distribution (optional)

Add secrets in: `Settings > Secrets and variables > Actions`

---

## Status Badges

Add to README.md:

```markdown
[![CI Tests](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/test.yml/badge.svg)](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/test.yml)
[![Release Build](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/release.yml/badge.svg)](https://github.com/DenisovAV/flutter_edge_ai/actions/workflows/release.yml)
```

---

## Future Enhancements

Potential improvements:

1. **Pub.dev Publishing**: Auto-publish to pub.dev on release
2. **Firebase Distribution**: Auto-distribute APK to testers
3. **Integration Tests**: Run integration tests on emulators
4. **iOS Signing**: Add code signing for iOS releases
5. **Web Build**: Build and deploy web version
6. **Slack/Discord Notifications**: Notify team on releases
7. **Dependency Updates**: Automated dependency updates (Dependabot)

---

## Resources

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Flutter CI/CD Best Practices](https://docs.flutter.dev/deployment/cd)
- [semantic-release](https://semantic-release.gitbook.io/) - Automated version management
